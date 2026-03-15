package main

import (
	"crypto/rand"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/DineshAdhi/moq-go/moqt"
	"github.com/DineshAdhi/moq-go/moqt/api"
	"github.com/DineshAdhi/moq-go/moqt/wire"
	"github.com/quic-go/quic-go"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

const PORT = 4443

var ALPNS = []string{"moq-00"}

const RELAY = "127.0.0.1:4443"

const (
	CHUNKSIZE         = 64 * 1024
	OBJECTS_PER_GROUP = 10
)

var subscriberReady sync.WaitGroup

var (
	rateLimit     = flag.Int("rate", 0, "Rate limit in KB/s (0 = unlimited)")
	delayPerObj   = flag.Duration("delay", 2*time.Millisecond, "Delay per object (e.g. 1ms, 100us)")
	delayPerGroup = flag.Duration("group-delay", 20*time.Millisecond, "Delay between groups")
	continuous    = flag.Bool("continuous", false, "Enable continuous sending mode for reconnection testing")
	groupCount    = flag.Int("groups", 8, "Number of groups to send in continuous mode (0 = infinite)")
)

func main() {

	debug := flag.Bool("debug", false, "sets log level to debug")
	flag.Parse()

	zerolog.CallerMarshalFunc = func(pc uintptr, file string, line int) string {
		return filepath.Base(file) + ":" + strconv.Itoa(line)
	}

	log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.StampMilli}).With().Caller().Logger()
	zerolog.SetGlobalLevel(zerolog.InfoLevel)

	if *debug {
		zerolog.SetGlobalLevel(zerolog.DebugLevel)
	}

	Options := moqt.DialerOptions{
		ALPNs: ALPNS,
		QuicConfig: &quic.Config{
			EnableDatagrams:       true,
			MaxIncomingUniStreams: 1000,
			MaxIdleTimeout:        time.Hour,
			KeepAlivePeriod:       time.Second * 30,
		},
		InsecureSkipVerify: true,
	}

	pub := api.NewMOQPub(Options, RELAY)
	handler, err := pub.Connect()

	subscriberReady.Add(1)

	pub.OnSubscribe(func(ps moqt.PubStream) {
		log.Info().Msgf("New Subscribe Request - %s", ps.TrackName)
		time.Sleep(500 * time.Millisecond)
		subscriberReady.Done()
		go handleStream(&ps)
	})

	if err != nil {
		log.Error().Msgf("error - %s", err)
		return
	}

	handler.SendAnnounce("bbb")

	log.Info().Msg("Waiting for subscriber to connect...")
	subscriberReady.Wait()
	log.Info().Msg("Subscriber connected, starting file transfer...")

	<-pub.Ctx.Done()
}

func handleStream(stream *moqt.PubStream) {
	stream.Accept()

	log.Info().Msgf("Continuous mode: %v, Groups: %d", *continuous, *groupCount)
	log.Info().Msgf("Rate limit: %d KB/s, Object delay: %v, Group delay: %v", *rateLimit, *delayPerObj, *delayPerGroup)

	startTime := time.Now()
	groupid := uint64(0)
	var bytesSent int64

	maxGroups := *groupCount
	if maxGroups == 0 {
		maxGroups = -1
	}

	for maxGroups < 0 || groupid < uint64(maxGroups) {
		gs, err := stream.NewGroup(groupid)

		if err != nil {
			log.Error().Msgf("[Error opening new stream for group %d] [%s]", groupid, err)
			return
		}

		objectid := uint64(0)

		for i := 0; i < OBJECTS_PER_GROUP; i++ {
			payload := make([]byte, CHUNKSIZE)
			rand.Read(payload)

			gs.WriteObject(&wire.Object{
				GroupID: groupid,
				ID:      objectid,
				Payload: payload,
			})

			bytesSent += int64(len(payload))
			objectid++

			if *delayPerObj > 0 {
				time.Sleep(*delayPerObj)
			}

			if *rateLimit > 0 {
				sleepDuration := time.Duration(len(payload)) * time.Second / time.Duration(*rateLimit*1024)
				time.Sleep(sleepDuration)
			}
		}

		gs.Close()
		groupid++

		if *delayPerGroup > 0 {
			time.Sleep(*delayPerGroup)
		}

		if groupid%10 == 0 {
			elapsed := time.Since(startTime)
			currentThroughput := float64(bytesSent) / elapsed.Seconds() / (1024 * 1024)
			log.Info().Msgf("Progress: %d groups sent, %.2f MB/s, %.2f MB total", groupid, currentThroughput, float64(bytesSent)/(1024*1024))
		}
	}

	elapsed := time.Since(startTime)
	throughput := float64(bytesSent) / elapsed.Seconds() / (1024 * 1024)

	log.Info().Msgf("========================================")
	log.Info().Msgf("Transfer complete!")
	log.Info().Msgf("  Total bytes sent: %d (%.2f MB)", bytesSent, float64(bytesSent)/(1024*1024))
	log.Info().Msgf("  Total time: %v", elapsed)
	log.Info().Msgf("  Throughput: %.2f MB/s", throughput)
	log.Info().Msgf("  Total groups: %d", groupid)
	log.Info().Msgf("========================================")
}

func formatBytes(bytes int) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(bytes)/float64(div), "KMGTPE"[exp])
}
