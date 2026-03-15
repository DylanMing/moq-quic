#!/bin/bash

# QUIC Connection Resilience Test Script
# This script tests QUIC's ability to handle connection interruptions

set -e

PORT=4443

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
    sleep 1
}

show_status() {
    log_info "=== Publisher Status ==="
    tail -3 /tmp/moq_pub.log 2>/dev/null || echo "No log"
    log_info "=== Subscriber Status ==="
    tail -3 /tmp/moq_sub.log 2>/dev/null || echo "No log"
}

log_info "=========================================="
log_info "QUIC Connection Resilience Test"
log_info "=========================================="
log_info ""
log_info "This test demonstrates QUIC's ability to maintain connections"
log_info "during brief network outages."
log_info ""
log_info "Current QUIC Configuration:"
log_info "  - MaxIdleTimeout: 1 hour"
log_info "  - KeepAlivePeriod: 30 seconds"
log_info ""
log_info "QUIC Connection Resilience Features:"
log_info "  1. Connection IDs - Allow connection migration without IP/port"
log_info "  2. Packet retransmission - Recover lost packets automatically"
log_info "  3. Keep-alive mechanism - Prevent idle timeout (every 30s)"
log_info "  4. MaxIdleTimeout - Allow long idle periods (1 hour)"
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

show_status

log_info ""
log_warn "=========================================="
log_warn "MANUAL NETWORK INTERRUPTION TEST"
log_warn "=========================================="
log_info ""
log_info "To test QUIC's connection resilience, you can:"
log_info ""
echo -e "${YELLOW}Option 1: Use macOS Firewall (requires sudo)${NC}"
echo "  In another terminal, run:"
echo ""
echo "  # Block port 4443:"
echo "  sudo pfctl -e"
echo "  echo 'block drop out proto udp from any to any port $PORT' | sudo pfctl -f -"
echo "  echo 'block drop in proto udp from any to any port $PORT' | sudo pfctl -f -"
echo ""
echo "  # Unblock port 4443:"
echo "  sudo pfctl -d"
echo ""
echo -e "${YELLOW}Option 2: Disable/Enable Network Interface${NC}"
echo "  # Disable network (WiFi):"
echo "  sudo ifconfig en0 down"
echo ""
echo "  # Enable network (WiFi):"
echo "  sudo ifconfig en0 up"
echo ""
echo -e "${YELLOW}Option 3: Use Network Link Conditioner${NC}"
echo "  Install from Xcode > Open Developer Tool > More Developer Tools"
echo "  This allows you to simulate various network conditions"
echo ""
echo -e "${YELLOW}Option 4: Physical Network Disconnect${NC}"
echo "  Simply unplug your ethernet cable or turn off WiFi"
echo "  Wait 10-15 seconds, then reconnect"
echo ""

log_info "Press Enter to start monitoring mode (Ctrl+C to exit)..."
read

log_info ""
log_info "Monitoring connections... (Press Ctrl+C to stop)"
log_info ""

COUNTER=0
while true; do
    sleep 5
    COUNTER=$((COUNTER + 5))
    log_info "--- ${COUNTER}s elapsed ---"
    
    # Show publisher progress
    PUB_LINE=$(tail -1 /tmp/moq_pub.log 2>/dev/null | grep -E "Progress|Error" || true)
    if [ -n "$PUB_LINE" ]; then
        log_info "Pub: $PUB_LINE"
    fi
    
    # Show subscriber progress
    SUB_LINE=$(tail -1 /tmp/moq_sub.log 2>/dev/null | grep -E "Group|Error|Total" || true)
    if [ -n "$SUB_LINE" ]; then
        log_info "Sub: $SUB_LINE"
    fi
    
    # Check for errors
    if grep -q "Error" /tmp/moq_pub.log 2>/dev/null; then
        log_error "Publisher encountered an error!"
        tail -5 /tmp/moq_pub.log
    fi
    
    if grep -q "Error" /tmp/moq_sub.log 2>/dev/null; then
        log_error "Subscriber encountered an error!"
        tail -5 /tmp/moq_sub.log
    fi
done
