#!/bin/bash

# Automated QUIC Connection Resilience Test Script for macOS
# This script automatically simulates network interruption to test QUIC's connection migration capability
# Requires sudo privileges

set -e

PORT=4443
INTERRUPT_DURATION=15

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

cleanup() {
    log_info "Cleaning up..."
    pkill -f "bin/relay" 2>/dev/null || true
    pkill -f "bin/pub" 2>/dev/null || true
    pkill -f "bin/sub" 2>/dev/null || true
    lsof -ti:4443 | xargs kill -9 2>/dev/null || true
    pfctl -d 2>/dev/null || true
    sleep 1
}

block_network() {
    log_warn "Blocking UDP port $PORT..."
    
    cat > /tmp/moq_pf.conf <<EOF
block drop out proto udp from any to any port $PORT
block drop in proto udp from any to any port $PORT
EOF
    
    pfctl -e 2>/dev/null || true
    pfctl -f /tmp/moq_pf.conf 2>/dev/null || true
    
    log_warn "Network port $PORT is now BLOCKED"
}

unblock_network() {
    log_info "Unblocking UDP port $PORT..."
    pfctl -d 2>/dev/null || true
    log_info "Network port $PORT is now UNBLOCKED"
}

show_status() {
    log_info "=== Publisher Status ==="
    tail -3 /tmp/moq_pub.log 2>/dev/null || echo "No log"
    log_info "=== Subscriber Status ==="
    tail -3 /tmp/moq_sub.log 2>/dev/null || echo "No log"
}

# Check root
if [ "$EUID" -ne 0 ]; then
    log_error "This script requires root privileges for network manipulation"
    log_info "Please run with: sudo $0"
    exit 1
fi

log_info "=========================================="
log_info "QUIC Connection Resilience Test"
log_info "=========================================="
log_info ""
log_info "This test simulates network interruption to test QUIC's ability"
log_info "to maintain connections during brief network outages."
log_info ""
log_info "Test Configuration:"
log_info "  - MaxIdleTimeout: 1 hour"
log_info "  - KeepAlivePeriod: 30 seconds"
log_info "  - Network interruption duration: ${INTERRUPT_DURATION} seconds"
log_info ""

cleanup

log_step "Building components..."
go build -o bin/relay examples/relay/relay.go
go build -o bin/pub examples/pub/pub.go
go build -o bin/sub examples/sub/sub.go

log_step "Starting Relay..."
./bin/relay -certpath=./examples/certs/localhost.crt -keypath=./examples/certs/localhost.key -debug > /tmp/moq_relay.log 2>&1 &
PID_RELAY=$!
sleep 2

log_step "Starting Publisher (continuous mode)..."
./bin/pub -debug -groups=0 > /tmp/moq_pub.log 2>&1 &
PID_PUB=$!
sleep 2

log_step "Starting Subscriber..."
./bin/sub -debug > /tmp/moq_sub.log 2>&1 &
PID_SUB=$!
sleep 5

log_info "All components running. Data is flowing..."
sleep 10

log_info ""
log_info "=== BEFORE NETWORK INTERRUPTION ==="
show_status

log_info ""
log_warn "=========================================="
log_warn "SIMULATING NETWORK INTERRUPTION"
log_warn "=========================================="
log_warn "Blocking port $PORT for ${INTERRUPT_DURATION} seconds..."
log_warn "QUIC should maintain connection state during this time"
log_warn ""

block_network

log_warn "Network is interrupted... waiting ${INTERRUPT_DURATION} seconds..."

# Show status during interruption
for i in $(seq 1 $INTERRUPT_DURATION); do
    sleep 1
    echo -n "."
done
echo ""

log_info ""
log_info "=== DURING NETWORK INTERRUPTION ==="
show_status

log_info ""
log_info "=========================================="
log_info "RESTORING NETWORK"
log_info "=========================================="
unblock_network

log_info "Network restored. Waiting for QUIC to recover..."
sleep 10

log_info ""
log_info "=== AFTER NETWORK RESTORATION ==="
show_status

log_info ""
log_info "Continuing for 20 more seconds to observe recovery..."
sleep 20

log_info ""
log_info "=== FINAL STATUS ==="
show_status

log_info ""
log_info "=== RELAY LOG (last 15 lines) ==="
tail -15 /tmp/moq_relay.log 2>/dev/null || echo "No log"

# Check if connections are still alive
log_info ""
log_info "=========================================="
log_info "CONNECTION STATUS CHECK"
log_info "=========================================="

if ps -p $PID_RELAY > /dev/null 2>&1; then
    log_info "✓ Relay is still running (PID: $PID_RELAY)"
else
    log_error "✗ Relay has crashed!"
fi

if ps -p $PID_PUB > /dev/null 2>&1; then
    log_info "✓ Publisher is still running (PID: $PID_PUB)"
else
    log_error "✗ Publisher has crashed!"
fi

if ps -p $PID_SUB > /dev/null 2>&1; then
    log_info "✓ Subscriber is still running (PID: $PID_SUB)"
else
    log_error "✗ Subscriber has crashed!"
fi

cleanup

log_info ""
log_info "=========================================="
log_info "Test completed!"
log_info "=========================================="
log_info ""
log_info "QUIC Connection Resilience Analysis:"
log_info ""
log_info "If data transfer resumed after network restoration,"
log_info "it indicates that QUIC successfully maintained the"
log_info "connection state during the brief network outage."
log_info ""
log_info "Key QUIC features that enable this:"
log_info "  1. Connection IDs - Allow connection migration"
log_info "  2. Packet retransmission - Recover lost packets"
log_info "  3. Keep-alive mechanism - Prevent idle timeout"
log_info "  4. MaxIdleTimeout - Allow long idle periods"
log_info ""
