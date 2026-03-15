#!/bin/bash

# Network Control Script for QUIC Resilience Testing
# Usage: sudo ./network_control.sh {block|unblock|status}

PORT=4443
ANCHOR="moq_test"

block_network() {
    echo "Blocking port $PORT..."
    
    # Create a temporary pf.conf file
    cat > /tmp/moq_pf.conf <<EOF
# MOQ Test - Block port $PORT
block drop out proto udp from any to any port $PORT
block drop in proto udp from any to any port $PORT
EOF
    
    # Enable pf and load rules
    pfctl -e 2>/dev/null || true
    pfctl -f /tmp/moq_pf.conf
    
    echo "Port $PORT is now BLOCKED"
    echo "QUIC connections should pause but not disconnect"
}

unblock_network() {
    echo "Unblocking port $PORT..."
    
    # Disable pf (simplest way to remove rules)
    pfctl -d 2>/dev/null || true
    
    # Or flush all rules
    # pfctl -F all
    
    echo "Port $PORT is now UNBLOCKED"
    echo "QUIC connections should resume"
}

show_status() {
    echo "=== PF Status ==="
    pfctl -s info 2>/dev/null || echo "PF is disabled"
    echo ""
    echo "=== Current Rules ==="
    pfctl -s rules 2>/dev/null || echo "No rules loaded"
    echo ""
    echo "=== Port $PORT Status ==="
    lsof -i :$PORT 2>/dev/null || echo "No processes using port $PORT"
}

case "${1:-status}" in
    block)
        block_network
        ;;
    unblock)
        unblock_network
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: sudo $0 {block|unblock|status}"
        echo ""
        echo "  block   - Block UDP port $PORT (simulate network interruption)"
        echo "  unblock - Unblock UDP port $PORT (restore network)"
        echo "  status  - Show current network status"
        exit 1
        ;;
esac
