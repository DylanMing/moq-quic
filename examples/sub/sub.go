package main

import (
	"flag"
	"io"
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

var ALPNS = []string{"moq-00"}

const RELAY = "127.0.0.1:4443"

var (
	totalBytesReceived int64
	totalGroups        int64
	totalObjects       int64
	startTime          time.Time
	once               sync.Once
	bytesMutex         sync.Mutex
	continuous         = flag.Bool("continuous", false, "Enable continuous receiving mode")
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
			EnableDatagrams: true,
			MaxIdleTimeout:  time.Hour,
			KeepAlivePeriod: time.Second * 30,
		},
		InsecureSkipVerify: true,
	}

	log.Info().Msg("Connecting to relay...")

	sub := api.NewMOQSub(Options, RELAY)

	handler, err := sub.Connect()

	if err != nil {
		log.Error().Msgf("Connection failed - %s", err)
		return
	}

	log.Info().Msg("Connected to relay successfully")

	sub.OnStream(func(ss moqt.SubStream) {
		log.Info().Msg("New stream received from publisher")
		go handleStream(&ss)
	})

	sub.OnAnnounce(func(ns string) {
		log.Info().Msgf("Received announce for namespace: %s", ns)
		handler.Subscribe(ns, "dumeel", 0)
	})

	handler.Subscribe("bbb", "dumeel", 0)

	log.Info().Msg("Waiting for data...")

	<-sub.Ctx.Done()
	log.Info().Msg("Subscriber context done")
}

func handleStream(ss *moqt.SubStream) {

	for moqtstream := range ss.StreamsChan {
		once.Do(func() {
			startTime = time.Now()
			log.Info().Msg("Started receiving data...")
		})

		if moqtstream == nil {
			log.Warn().Msg("Received nil stream, breaking")
			break
		}

		go handleMOQStream(moqtstream)
	}

	log.Info().Msg("Stream channel closed")
}

func handleMOQStream(stream wire.MOQTStream) {

	gs := stream.(*wire.GroupStream)

	objectcount := 0
	groupBytes := int64(0)

	for {
		_, object, err := stream.ReadObject()

		if err == io.EOF {
			break
		}

		if err != nil {
			log.Error().Msgf("Error Reading Objects - %s", err)
			break
		}

		objectcount++
		groupBytes += int64(len(object.Payload))
	}

	bytesMutex.Lock()
	totalBytesReceived += groupBytes
	totalGroups++
	totalObjects += int64(objectcount)
	currentTotal := totalBytesReceived
	currentGroups := totalGroups
	currentObjects := totalObjects
	bytesMutex.Unlock()

	elapsed := time.Since(startTime)
	throughput := float64(currentTotal) / elapsed.Seconds() / (1024 * 1024)

	log.Info().Msgf("Group %d: %d objects, %d bytes | Total: %.2f MB, %d groups, %d objects, %.2f MB/s",
		gs.GroupID, objectcount, groupBytes, float64(currentTotal)/(1024*1024), currentGroups, currentObjects, throughput)

	if !*continuous && objectcount != 10 {
		log.Warn().Msgf("Group %d has %d objects (expected 10)", gs.GroupID, objectcount)
	}
}
