package moqt

import (
	"io"
	"sync"

	"github.com/DineshAdhi/moq-go/moqt/wire"

	"github.com/quic-go/quic-go/quicvarint"
	"github.com/rs/zerolog/log"
)

const (
	DEFAULT_CACHE_SIZE    = 1000
	DEFAULT_CACHE_SIZE_MB = 50
	MAX_OBJECT_SIZE       = 1024 * 1024
)

type CachedObject struct {
	GroupID uint64
	ID      uint64
	Payload []byte
}

type RelayStream struct {
	SubID           uint64
	StreamID        string
	Map             *StreamsMap[*RelayStream]
	Subscribers     map[string]*RelayHandler
	SubscribersLock sync.RWMutex

	ObjectCache   []*CachedObject
	CacheLock     sync.RWMutex
	MaxCacheSize  int
	MaxCacheBytes int64
	CurrentBytes  int64
	CacheEnabled  bool
}

func (rs *RelayStream) GetSubID() uint64 {
	return rs.SubID
}

func (rs *RelayStream) GetStreamID() string {
	return rs.StreamID
}

func NewRelayStream(subid uint64, id string, smap *StreamsMap[*RelayStream]) *RelayStream {

	rs := &RelayStream{}
	rs.SubID = subid
	rs.StreamID = id
	rs.Map = smap
	rs.Subscribers = map[string]*RelayHandler{}
	rs.SubscribersLock = sync.RWMutex{}
	rs.ObjectCache = make([]*CachedObject, 0)
	rs.CacheLock = sync.RWMutex{}
	rs.MaxCacheSize = DEFAULT_CACHE_SIZE
	rs.MaxCacheBytes = DEFAULT_CACHE_SIZE_MB * 1024 * 1024
	rs.CacheEnabled = true

	return rs
}

func NewRelayStreamWithCache(subid uint64, id string, smap *StreamsMap[*RelayStream], maxObjects int, maxBytes int64) *RelayStream {

	rs := NewRelayStream(subid, id, smap)
	rs.MaxCacheSize = maxObjects
	rs.MaxCacheBytes = maxBytes
	return rs
}

func (rs *RelayStream) AddSubscriber(handler *RelayHandler) {
	rs.SubscribersLock.Lock()
	defer rs.SubscribersLock.Unlock()

	rs.Subscribers[handler.Id] = handler
}

func (os *RelayStream) RemoveSubscriber(id string) {
	os.SubscribersLock.Lock()
	defer os.SubscribersLock.Unlock()

	delete(os.Subscribers, id)
}

func (rs *RelayStream) ForwardSubscribeOk(msg wire.SubscribeOk) {

	for _, sub := range rs.Subscribers {
		if handler := sub.RelayHandler(); handler != nil {
			handler.SendSubscribeOk(rs.GetStreamID(), msg)
		}
	}
}

func (rs *RelayStream) ForwardStream(stream wire.MOQTStream) {
	rs.SubscribersLock.RLock()
	defer rs.SubscribersLock.RUnlock()

	for _, sub := range rs.Subscribers {
		stream.WgAdd()
		go sub.ProcessMOQTStream(stream)
	}

	stream.WgWait()
}

func (rs *RelayStream) cacheObject(groupID, objectID uint64, payload []byte) {
	if !rs.CacheEnabled {
		return
	}

	rs.CacheLock.Lock()
	defer rs.CacheLock.Unlock()

	for len(rs.ObjectCache) >= rs.MaxCacheSize || rs.CurrentBytes >= rs.MaxCacheBytes {
		if len(rs.ObjectCache) == 0 {
			break
		}
		removed := rs.ObjectCache[0]
		rs.ObjectCache = rs.ObjectCache[1:]
		rs.CurrentBytes -= int64(len(removed.Payload))
	}

	cached := &CachedObject{
		GroupID: groupID,
		ID:      objectID,
		Payload: make([]byte, len(payload)),
	}
	copy(cached.Payload, payload)

	rs.ObjectCache = append(rs.ObjectCache, cached)
	rs.CurrentBytes += int64(len(payload))
}

func (rs *RelayStream) GetCachedObjects() []*CachedObject {
	rs.CacheLock.RLock()
	defer rs.CacheLock.RUnlock()

	result := make([]*CachedObject, len(rs.ObjectCache))
	copy(result, rs.ObjectCache)
	return result
}

func (rs *RelayStream) GetCacheStats() (int, int64) {
	rs.CacheLock.RLock()
	defer rs.CacheLock.RUnlock()
	return len(rs.ObjectCache), rs.CurrentBytes
}

func (rs *RelayStream) SendCachedObjects(subscriber *RelayHandler, subID uint64) error {
	rs.CacheLock.RLock()
	cachedObjects := make([]*CachedObject, len(rs.ObjectCache))
	copy(cachedObjects, rs.ObjectCache)
	rs.CacheLock.RUnlock()

	if len(cachedObjects) == 0 {
		return nil
	}

	log.Info().Msgf("[Sending %d cached objects to new subscriber][Stream - %s][SubID - %X]", len(cachedObjects), rs.StreamID, subID)

	groups := make(map[uint64][]*CachedObject)
	for _, obj := range cachedObjects {
		groups[obj.GroupID] = append(groups[obj.GroupID], obj)
	}

	for groupID, objects := range groups {
		unistream, err := subscriber.Conn.OpenUniStream()
		if err != nil {
			return err
		}

		var header []byte
		header = quicvarint.Append(header, wire.STREAM_HEADER_GROUP)
		header = quicvarint.Append(header, subID)
		header = quicvarint.Append(header, 0)
		header = quicvarint.Append(header, groupID)
		header = quicvarint.Append(header, 0)
		unistream.Write(header)

		for _, obj := range objects {
			object := &wire.Object{
				GroupID: groupID,
				ID:      obj.ID,
				Payload: obj.Payload,
			}
			unistream.Write(object.GetBytes())
		}

		unistream.Close()
	}

	return nil
}

func (rs *RelayStream) ProcessObjects(stream wire.MOQTStream, reader quicvarint.Reader) {

	rs.ForwardStream(stream)

	for {
		_, object, err := stream.ReadObject()

		if err == io.EOF {
			break
		}

		if err != nil {
			log.Debug().Msgf("[Error Reading Object][%s]", err)
			return
		}

		rs.cacheObject(object.GroupID, object.ID, object.Payload)
	}
}

func (rs *RelayStream) ClearCache() {
	rs.CacheLock.Lock()
	defer rs.CacheLock.Unlock()

	rs.ObjectCache = make([]*CachedObject, 0)
	rs.CurrentBytes = 0
}
