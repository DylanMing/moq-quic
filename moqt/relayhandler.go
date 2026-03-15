package moqt

import (
	"io"
	"math/rand/v2"
	"strings"
	"time"

	"github.com/DineshAdhi/moq-go/moqt/wire"

	"github.com/quic-go/quic-go/quicvarint"
	"github.com/rs/zerolog/log"
)

type RelayHandler struct {
	*MOQTSession
	IncomingStreams   StreamsMap[*RelayStream]
	SubscribedStreams StreamsMap[*RelayStream]
}

func NewRelayHandler(session *MOQTSession) *RelayHandler {

	handler := &RelayHandler{
		MOQTSession: session,
	}

	handler.IncomingStreams = NewStreamsMap[*RelayStream](session)
	handler.SubscribedStreams = NewStreamsMap[*RelayStream](session)

	return handler
}

func (rh *RelayHandler) HandleClose() {
	for _, rs := range rh.SubscribedStreams.streams {
		rs.RemoveSubscriber(rh.Id)
	}
}

func (subscriber *RelayHandler) SendSubscribeOk(streamid string, okm wire.SubscribeOk) {
	if subid, err := subscriber.SubscribedStreams.GetSubID(streamid); err == nil {
		okm.SubscribeID = subid
		subscriber.CS.WriteControlMessage(&okm)
	}
}

func (publisher *RelayHandler) SendSubscribe(msg wire.Subscribe) *RelayStream {

	streamid := msg.GetStreamID()
	subid := uint64(rand.Uint32())

	rs := NewRelayStream(subid, streamid, &publisher.IncomingStreams)
	publisher.IncomingStreams.AddStream(subid, rs)

	publisher.Slogger.Info().Msgf("[New Incoming Stream][SubID - %x][Stream ID - %s]", subid, streamid)

	msg.SubscribeID = subid
	publisher.CS.WriteControlMessage(&msg)

	return rs
}

func (publisher *RelayHandler) GetObjectStream(msg *wire.Subscribe) (bool, *RelayStream) {

	stream, ok := publisher.IncomingStreams.StreamIDGetStream(msg.GetStreamID())

	if !ok || strings.Contains(msg.TrackName, ".catalog") || strings.Contains(msg.TrackName, ".mp4") {
		return false, publisher.SendSubscribe(*msg)
	}

	return true, stream
}

func (sub *RelayHandler) ProcessMOQTStream(stream wire.MOQTStream) {

	streamid := stream.GetStreamID()

	subid, err := sub.SubscribedStreams.GetSubID(streamid)

	if err != nil {
		sub.Slogger.Error().Msgf("[Unable to find SubscribedStreams for StreamID - %s]", streamid)
		stream.WgDone()
		return
	}

	unistream, err := sub.Conn.OpenUniStream()

	if err != nil {
		stream.WgDone()
		return
	}

	unistream.Write(stream.GetHeaderSubIDBytes(subid))
	stream.WgDone()

	itr := 0

	for {
		itr, err = stream.Pipe(itr, unistream)

		if err == io.EOF {
			break
		}

		if err != nil {
			log.Error().Msgf("[Error Piping Stream to Unistream][%s]", err)
			break
		}
	}

	unistream.Close()
}

func (publisher *RelayHandler) DoHandle() {
	retryCount := 0
	maxRetries := 10
	retryDelay := 100 * time.Millisecond

	for {
		select {
		case <-publisher.ctx.Done():
			publisher.Slogger.Info().Msg("[Context cancelled, stopping RelayHandler]")
			return
		default:
		}

		unistream, err := publisher.Conn.AcceptUniStream(publisher.ctx)

		if err != nil {
			if publisher.isConnectionAlive() {
				retryCount++
				if retryCount > maxRetries {
					publisher.Slogger.Error().Msgf("[Max retries reached, stopping RelayHandler][%s]", err)
					return
				}
				publisher.Slogger.Warn().Msgf("[Temporary error accepting unistream, retrying (%d/%d)][%s]", retryCount, maxRetries, err)
				time.Sleep(retryDelay)
				continue
			}
			publisher.Slogger.Error().Msgf("[Connection closed, stopping RelayHandler][%s]", err)
			return
		}

		retryCount = 0

		reader := quicvarint.NewReader(unistream)

		subid, stream, err := wire.ParseMOQTStream(reader)

		if err != nil {
			publisher.Slogger.Error().Msgf("[Error Parsing MOQT Stream][%s]", err)
			continue
		}

		if rs, ok := publisher.IncomingStreams.SubIDGetStream(subid); ok {
			stream.SetStreamID(rs.StreamID)
			go rs.ProcessObjects(stream, reader)
		} else {
			log.Error().Msgf("[Stream not found for SubID - %X]", subid)
		}
	}
}

func (publisher *RelayHandler) isConnectionAlive() bool {
	select {
	case <-publisher.ctx.Done():
		return false
	default:
		return true
	}
}

func (publisher *RelayHandler) HandleAnnounce(msg *wire.Announce) {

	publisher.Slogger.Info().Msgf(msg.String())

	okmsg := wire.AnnounceOk{}
	okmsg.TrackNameSpace = msg.TrackNameSpace

	sm.addPublisher(msg.TrackNameSpace, publisher)

	publisher.CS.WriteControlMessage(&okmsg)
}

func (publisher *RelayHandler) HandleSubscribeOk(msg *wire.SubscribeOk) {
	publisher.Slogger.Info().Msg(msg.String())

	subid := msg.SubscribeID

	if rs, ok := publisher.IncomingStreams.SubIDGetStream(subid); ok {
		rs.ForwardSubscribeOk(*msg)
	}
}

func (publisher *RelayHandler) HandleSubscribeDone(msg *wire.SubscribeDone) {
	publisher.Slogger.Info().Msg(msg.String())
}

func (subscriber *RelayHandler) HandleSubscribe(msg *wire.Subscribe) {

	subscriber.Slogger.Info().Msg(msg.String())

	pub := sm.getPublisher(msg.TrackNameSpace)

	if pub == nil {
		log.Error().Msgf("[No Publisher found with Namespace - %s]", msg.TrackNameSpace)
		return
	}

	isCached, rs := pub.GetObjectStream(msg)

	if rs == nil {
		log.Error().Msgf("[Object Stream not found][%s]", msg.GetStreamID())
		return
	}

	okmsg := &wire.SubscribeOk{
		SubscribeID:   msg.SubscribeID,
		Expires:       1024,
		ContentExists: 0,
	}

	if isCached {
		go subscriber.CS.WriteControlMessage(okmsg)
	} else {
		rs.AddSubscriber(subscriber)
		subscriber.SubscribedStreams.AddStream(msg.SubscribeID, rs)
		return
	}

	rs.AddSubscriber(subscriber)
	subscriber.SubscribedStreams.AddStream(msg.SubscribeID, rs)

	cacheCount, cacheBytes := rs.GetCacheStats()
	if cacheCount > 0 {
		log.Info().Msgf("[New subscriber will receive cached data][%d objects, %.2f MB]", cacheCount, float64(cacheBytes)/(1024*1024))
		go rs.SendCachedObjects(subscriber, msg.SubscribeID)
	}
}

func (subscriber *RelayHandler) HandleAnnounceOk(msg *wire.AnnounceOk) {
	subscriber.Slogger.Info().Msg(msg.String())
}

func (subscriber *RelayHandler) HandleUnsubscribe(msg *wire.Unsubcribe) {

	subscriber.Slogger.Info().Msg(msg.String())

	subid := msg.SubscriptionID

	if rs, ok := subscriber.SubscribedStreams.SubIDGetStream(subid); ok {
		rs.RemoveSubscriber(subscriber.Id)
	}
}
