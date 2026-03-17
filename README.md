# MOQT - GO

Simple Implementation of Media Over QUIC Transport (MOQT) in Go, in compliant with the [DRAFT04](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/04/)

This MOQT library currently supports WebTransport and QUIC Protocols.

| Module      | Support |
| ----------- | ------- |
| Relay       | ✅      |
| Publisher   | ✅      |
| Subscriber  | ✅      |

## Features

- **Relay Caching**: Relay caches received objects and can replay them to late subscribers
- **Rate Control**: Publisher supports configurable sending rate and delays
- **Multiple Subscribers**: Multiple subscribers can subscribe to the same track at different times
- **Connection Migration**: QUIC connection migration support for both Publisher and Subscriber

## Setup

### 1. Generate Self-Signed Certificates

```bash
make cert
```

### 2. Run the Components

Start the components in order:

```bash
# Terminal 1: Start the Relay
make relay

# Terminal 2: Start the Publisher
make pub

# Terminal 3: Start the Subscriber
make sub
```

## Usage

### Publisher

The publisher supports rate control via command-line flags:

```bash
# Default settings (2ms delay per object, 20ms delay per group)
make pub

# Custom delays
bin/pub -delay=5ms -group-delay=50ms

# Rate limit in KB/s
bin/pub -rate=1000

# Debug mode
bin/pub -debug
```

**Available Flags:**
| Flag          | Default | Description                          |
| ------------- | ------- | ------------------------------------ |
| `-delay`      | 2ms     | Delay between each object            |
| `-group-delay`| 20ms    | Delay between groups                 |
| `-rate`       | 0       | Rate limit in KB/s (0 = unlimited)   |
| `-debug`      | false   | Enable debug logging                 |

### Subscriber

```bash
# Start subscriber
make sub

# Debug mode
bin/sub -debug
```

### Relay

```bash
# Start relay
make relay

# Debug mode
bin/relay -debug
```

## Cache Replay Feature

The relay caches received objects and can replay them to subscribers that connect later:

```
Timeline:
─────────────────────────────────────────────────────────────────>
     │                    │                    │
     ▼                    ▼                    ▼
Publisher           Subscriber 1         Subscriber 2
  sends               receives            receives from
   │                    │                    cache
   │                    │                    │
   └──────Relay─────────┴────────────────────┘
          │
          └── Caches all objects (default: 1000 objects or 50MB)
```

**How it works:**
1. Subscriber 1 connects and triggers the publisher to start sending
2. Relay receives and caches all objects while forwarding to Subscriber 1
3. Subscriber 2 connects later and receives cached data from the relay

**Cache Configuration:**
- Default cache size: 1000 objects
- Default cache memory: 50MB
- FIFO eviction when cache is full

## Connection Migration

MOQ-GO supports QUIC connection migration, allowing Publisher and Subscriber to recover from temporary network interruptions without dropping the connection.

### How It Works

When a network interruption occurs (e.g., NAT rebind, brief connectivity loss):

1. **QUIC Layer**: Connection is maintained via Connection IDs and packet retransmission
2. **Application Layer**: Retry mechanism in `AcceptUniStream` handles temporary errors
3. **Automatic Recovery**: Data transfer continues after network restores

### Implementation Details

**SubHandler & RelayHandler** - Retry logic for receiving streams:

```go
func (sub *SubHandler) DoHandle() {
    retryCount := 0
    maxRetries := 10
    
    for {
        unistream, err := sub.Conn.AcceptUniStream(sub.ctx)
        if err != nil {
            if sub.isConnectionAlive() {
                retryCount++
                time.Sleep(100 * time.Millisecond)
                continue  // Retry on temporary error
            }
            return  // Connection truly closed
        }
        retryCount = 0
        // ... process stream
    }
}
```

**PubStream** - Retry logic for opening streams:

```go
func (pub *PubStream) NewStream(stream wire.MOQTStream) {
    for i := 0; i < maxRetries; i++ {
        unistream, err = pub.session.Conn.OpenUniStream()
        if err == nil {
            break
        }
        time.Sleep(retryDelay)
    }
    // ... continue with stream
}
```

### Testing Connection Migration

Run the migration test script:

```bash
# Test Publisher connection migration
./test_migration.sh pub

# Test Subscriber connection migration
./test_migration.sh sub

# Test both
./test_migration.sh
```

### Test Results

| Test Scenario | Before Interruption | After Interruption | Result |
|--------------|---------------------|-------------------|--------|
| Publisher Migration | 145 groups | 378 groups | ✅ Passed |
| Subscriber Migration | 147 groups | 382 groups | ✅ Passed |

The test simulates network interruption by pausing the process for 5 seconds, then verifies that data transfer continues after resuming.

## Example Output

### Publisher
```
INF pub.go:100 > Generated 5242880 bytes (5.00 MB) of random data
INF pub.go:105 > Sending 80 chunks across 8 groups
INF pub.go:106 > Rate limit: 0 KB/s, Object delay: 2ms, Group delay: 20ms
INF pub.go:169 > ========================================
INF pub.go:170 > Transfer complete!
INF pub.go:171 >   Total bytes sent: 5242880 (5.00 MB)
INF pub.go:172 >   Total time: 340.529792ms
INF pub.go:173 >   Throughput: 14.68 MB/s
INF pub.go:174 >   Total groups: 8, Total chunks: 80
```

### Subscriber (from cache)
```
INF relayhandler.go:203 > [New subscriber will receive cached data][80 objects, 5.00 MB]
INF relaystream.go:161 > [Sending 80 cached objects to new subscriber][Stream - bbb_dumeel]
INF sub.go:134 > ========================================
INF sub.go:135 > File transfer complete!
INF sub.go:136 >   Total bytes received: 5242880 (5.00 MB)
INF sub.go:137 >   Total time: 52.462792ms
INF sub.go:138 >   Throughput: 95.31 MB/s
```

## Project Structure

```
moq-go/
├── moqt/
│   ├── api/           # High-level API for pub/sub
│   ├── wire/          # Wire protocol implementation
│   ├── relayhandler.go    # Relay message handling (with migration support)
│   ├── relaystream.go     # Relay caching logic
│   ├── pubhandler.go      # Publisher handler
│   ├── pubstream.go       # Publisher stream (with migration support)
│   └── subhandler.go      # Subscriber handler (with migration support)
├── examples/
│   ├── relay/         # Relay example
│   ├── pub/           # Publisher example
│   └── sub/           # Subscriber example
├── certs/             # TLS certificates
├── test_migration.sh  # Connection migration test script
├── Makefile
└── README.md
```

## Configuration

### Relay Cache Settings

You can modify cache settings in `moqt/relaystream.go`:

```go
const (
    DEFAULT_CACHE_SIZE    = 1000      // Max cached objects
    DEFAULT_CACHE_SIZE_MB = 50        // Max cache size in MB
)
```

### File Transfer Settings

You can modify file transfer settings in `examples/pub/pub.go`:

```go
const (
    FILESIZE          = 5 * 1024 * 1024  // 5 MB
    CHUNKSIZE         = 64 * 1024        // 64 KB per object
    OBJECTS_PER_GROUP = 10               // Objects per group
)
```

## License

MIT
