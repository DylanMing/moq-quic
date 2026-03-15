#!/bin/bash

# MOQT Reconnection Test Script
# This script simulates network disconnection and reconnection for testing

set -e

PORT=4443
PID_RELAY=""
PID_PUB=""
PID_SUB=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    log_info "Cleaning up..."
    pkill -f "bin/relay" 2>/dev/null || true
    pkill -f "bin/pub" 2>/dev/null || true
    pkill -f "bin/sub" 2>/dev/null || true
    lsof -ti:4443 | xargs kill -9 2>/dev/null || true
    sleep 1
}

start_relay() {
    log_info "Starting Relay..."
    ./bin/relay -certpath=./examples/certs/localhost.crt -keypath=./examples/certs/localhost.key -debug > /tmp/moq_relay.log 2>&1 &
    PID_RELAY=$!
    sleep 2
    log_info "Relay started (PID: $PID_RELAY)"
}

start_pub() {
    log_info "Starting Publisher..."
    ./bin/pub -debug -groups=0 > /tmp/moq_pub.log 2>&1 &
    PID_PUB=$!
    sleep 2
    log_info "Publisher started (PID: $PID_PUB)"
}

start_sub() {
    log_info "Starting Subscriber..."
    ./bin/sub -debug > /tmp/moq_sub.log 2>&1 &
    PID_SUB=$!
    sleep 2
    log_info "Subscriber started (PID: $PID_SUB)"
}

stop_sub() {
    log_warn "Stopping Subscriber (simulating disconnect)..."
    kill $PID_SUB 2>/dev/null || true
    PID_SUB=""
}

stop_pub() {
    log_warn "Stopping Publisher (simulating disconnect)..."
    kill $PID_PUB 2>/dev/null || true
    PID_PUB=""
}

show_logs() {
    log_info "=== Relay Log (last 10 lines) ==="
    tail -10 /tmp/moq_relay.log 2>/dev/null || echo "No relay log"
    
    log_info "=== Publisher Log (last 10 lines) ==="
    tail -10 /tmp/moq_pub.log 2>/dev/null || echo "No publisher log"
    
    log_info "=== Subscriber Log (last 10 lines) ==="
    tail -10 /tmp/moq_sub.log 2>/dev/null || echo "No subscriber log"
}

test_sub_reconnect() {
    log_info "=========================================="
    log_info "Test: Subscriber Reconnection"
    log_info "=========================================="
    
    cleanup
    
    # Build
    log_info "Building components..."
    go build -o bin/relay examples/relay/relay.go
    go build -o bin/pub examples/pub/pub.go
    go build -o bin/sub examples/sub/sub.go
    
    # Start all components
    start_relay
    start_pub
    start_sub
    
    # Let it run for a while
    log_info "Running for 10 seconds..."
    sleep 10
    
    show_logs
    
    # Simulate subscriber disconnect
    stop_sub
    
    log_info "Subscriber disconnected, waiting 5 seconds..."
    sleep 5
    
    # Reconnect subscriber
    start_sub
    
    log_info "Subscriber reconnected, running for 10 more seconds..."
    sleep 10
    
    show_logs
    
    log_info "Test completed!"
    cleanup
}

test_pub_reconnect() {
    log_info "=========================================="
    log_info "Test: Publisher Reconnection"
    log_info "=========================================="
    
    cleanup
    
    # Build
    log_info "Building components..."
    go build -o bin/relay examples/relay/relay.go
    go build -o bin/pub examples/pub/pub.go
    go build -o bin/sub examples/sub/sub.go
    
    # Start all components
    start_relay
    start_pub
    start_sub
    
    # Let it run for a while
    log_info "Running for 10 seconds..."
    sleep 10
    
    show_logs
    
    # Simulate publisher disconnect
    stop_pub
    
    log_info "Publisher disconnected, waiting 5 seconds..."
    sleep 5
    
    # Reconnect publisher
    start_pub
    
    log_info "Publisher reconnected, running for 10 more seconds..."
    sleep 10
    
    show_logs
    
    log_info "Test completed!"
    cleanup
}

test_both_reconnect() {
    log_info "=========================================="
    log_info "Test: Both Publisher and Subscriber Reconnection"
    log_info "=========================================="
    
    cleanup
    
    # Build
    log_info "Building components..."
    go build -o bin/relay examples/relay/relay.go
    go build -o bin/pub examples/pub/pub.go
    go build -o bin/sub examples/sub/sub.go
    
    # Start all components
    start_relay
    start_pub
    start_sub
    
    # Let it run for a while
    log_info "Running for 10 seconds..."
    sleep 10
    
    show_logs
    
    # Simulate both disconnect
    stop_pub
    stop_sub
    
    log_info "Both disconnected, waiting 5 seconds..."
    sleep 5
    
    # Reconnect
    start_pub
    sleep 2
    start_sub
    
    log_info "Both reconnected, running for 10 more seconds..."
    sleep 10
    
    show_logs
    
    log_info "Test completed!"
    cleanup
}

# Main
case "${1:-all}" in
    sub)
        test_sub_reconnect
        ;;
    pub)
        test_pub_reconnect
        ;;
    both)
        test_both_reconnect
        ;;
    all)
        test_sub_reconnect
        echo ""
        echo "Press Enter to continue to publisher reconnect test..."
        read
        test_pub_reconnect
        echo ""
        echo "Press Enter to continue to both reconnect test..."
        read
        test_both_reconnect
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo "Usage: $0 {sub|pub|both|all|cleanup}"
        echo "  sub     - Test subscriber reconnection"
        echo "  pub     - Test publisher reconnection"
        echo "  both    - Test both reconnection"
        echo "  all     - Run all tests"
        echo "  cleanup - Clean up all processes"
        exit 1
        ;;
esac
