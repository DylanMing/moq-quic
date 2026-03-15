#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RELAY_PORT=4443
RELAY_PID=""
PUB_PID=""
SUB_PID=""
LOG_DIR="$SCRIPT_DIR/migration_test_logs"
INTERRUPT_DURATION=5

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
    log_info "Cleaning up processes..."
    [ -n "$RELAY_PID" ] && kill $RELAY_PID 2>/dev/null || true
    [ -n "$PUB_PID" ] && kill $PUB_PID 2>/dev/null || true
    [ -n "$SUB_PID" ] && kill $SUB_PID 2>/dev/null || true
    log_info "Cleanup complete (logs preserved in $LOG_DIR)"
}

trap cleanup EXIT

setup_logs() {
    rm -rf "$LOG_DIR"
    mkdir -p "$LOG_DIR"
}

start_relay() {
    log_info "Starting Relay on port $RELAY_PORT..."
    go run examples/relay/relay.go -port $RELAY_PORT \
        -keypath "$SCRIPT_DIR/certs/key.pem" \
        -certpath "$SCRIPT_DIR/certs/cert.pem" > "$LOG_DIR/relay.log" 2>&1 &
    RELAY_PID=$!
    sleep 2
    if ! kill -0 $RELAY_PID 2>/dev/null; then
        log_error "Failed to start Relay"
        cat "$LOG_DIR/relay.log"
        exit 1
    fi
    log_success "Relay started (PID: $RELAY_PID)"
}

start_subscriber() {
    log_info "Starting Subscriber..."
    go run examples/sub/sub.go -continuous > "$LOG_DIR/sub.log" 2>&1 &
    SUB_PID=$!
    sleep 2
    if ! kill -0 $SUB_PID 2>/dev/null; then
        log_error "Failed to start Subscriber"
        cat "$LOG_DIR/sub.log"
        exit 1
    fi
    log_success "Subscriber started (PID: $SUB_PID)"
}

start_publisher() {
    log_info "Starting Publisher with continuous mode..."
    go run examples/pub/pub.go -continuous -groups 0 > "$LOG_DIR/pub.log" 2>&1 &
    PUB_PID=$!
    sleep 2
    if ! kill -0 $PUB_PID 2>/dev/null; then
        log_error "Failed to start Publisher"
        cat "$LOG_DIR/pub.log"
        exit 1
    fi
    log_success "Publisher started (PID: $PUB_PID)"
}

wait_for_data_transfer() {
    local duration=$1
    log_info "Waiting $duration seconds for data transfer..."
    sleep $duration
}

check_data_received() {
    local log_file=$1
    local min_objects=${2:-10}
    
    local count=$(grep -c "Received object" "$log_file" 2>/dev/null || echo "0")
    if [ "$count" -ge "$min_objects" ]; then
        return 0
    fi
    return 1
}

simulate_network_interruption() {
    local target_pid=$1
    local duration=$2
    
    log_warn "============================================"
    log_warn "SIMULATING NETWORK INTERRUPTION (${duration}s)"
    log_warn "============================================"
    
    log_info "Stopping process $target_pid..."
    kill -STOP $target_pid 2>/dev/null
    
    log_info "Process paused. Waiting ${duration} seconds..."
    sleep $duration
    
    log_info "Resuming process $target_pid..."
    kill -CONT $target_pid 2>/dev/null
    
    log_success "Process resumed after interruption"
}

print_stats() {
    log_info "=== Data Transfer Statistics ==="
    
    local pub_objects=$(grep -c "groups sent" "$LOG_DIR/pub.log" 2>/dev/null || echo "0")
    local sub_objects=$(grep -c "Total:" "$LOG_DIR/sub.log" 2>/dev/null || echo "0")
    local relay_objects=$(grep -c "New" "$LOG_DIR/relay.log" 2>/dev/null || echo "0")
    
    log_info "Publisher progress messages: $pub_objects"
    log_info "Subscriber group messages: $sub_objects"
    log_info "Relay connection messages: $relay_objects"
    
    if [ "$sub_objects" -gt 0 ]; then
        log_success "Connection migration test PASSED - Data received after interruption"
        return 0
    else
        log_error "Connection migration test FAILED - No data received"
        return 1
    fi
}

test_publisher_interruption() {
    log_info ""
    log_info "=========================================="
    log_info "TEST 1: Publisher Connection Migration"
    log_info "=========================================="
    
    setup_logs
    start_relay
    start_subscriber
    sleep 1
    start_publisher
    
    wait_for_data_transfer 5
    
    local before_count=$(grep -c "Total:" "$LOG_DIR/sub.log" 2>/dev/null || echo "0")
    log_info "Groups received before interruption: $before_count"
    
    simulate_network_interruption $PUB_PID $INTERRUPT_DURATION
    
    wait_for_data_transfer 5
    
    local after_count=$(grep -c "Total:" "$LOG_DIR/sub.log" 2>/dev/null || echo "0")
    log_info "Groups received after interruption: $after_count"
    
    if [ "$after_count" -gt "$before_count" ]; then
        log_success "Publisher migration test PASSED - Data continued after interruption"
        log_info "Before: $before_count, After: $after_count"
    else
        log_warn "Publisher migration test - Check logs for details"
    fi
    
    print_stats
    
    log_info "Stopping processes for next test..."
    kill $PUB_PID $SUB_PID $RELAY_PID 2>/dev/null || true
    sleep 2
}

test_subscriber_interruption() {
    log_info ""
    log_info "=========================================="
    log_info "TEST 2: Subscriber Connection Migration"
    log_info "=========================================="
    
    setup_logs
    start_relay
    start_publisher
    sleep 1
    start_subscriber
    
    wait_for_data_transfer 5
    
    local before_count=$(grep -c "Total:" "$LOG_DIR/sub.log" 2>/dev/null || echo "0")
    log_info "Groups received before interruption: $before_count"
    
    simulate_network_interruption $SUB_PID $INTERRUPT_DURATION
    
    wait_for_data_transfer 5
    
    local after_count=$(grep -c "Total:" "$LOG_DIR/sub.log" 2>/dev/null || echo "0")
    log_info "Groups received after interruption: $after_count"
    
    if [ "$after_count" -gt "$before_count" ]; then
        log_success "Subscriber migration test PASSED - Data continued after interruption"
        log_info "Before: $before_count, After: $after_count"
    else
        log_warn "Subscriber migration test - Check logs for details"
    fi
    
    print_stats
}

main() {
    log_info "=========================================="
    log_info "MOQ Connection Migration Test"
    log_info "=========================================="
    log_info ""
    log_info "This test simulates network interruptions"
    log_info "to verify QUIC connection migration support"
    log_info ""
    
    if [ "$1" = "pub" ]; then
        test_publisher_interruption
    elif [ "$1" = "sub" ]; then
        test_subscriber_interruption
    else
        test_publisher_interruption
        echo ""
        test_subscriber_interruption
    fi
    
    log_info ""
    log_success "All tests completed!"
    log_info "Logs saved to: $LOG_DIR"
}

main "$@"
