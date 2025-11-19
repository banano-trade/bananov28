#!/bin/bash
# Banano Node Cementing Progress Monitor
# This script monitors the cementing progress and shows real-time statistics
# Usage: ./monitor_cementing.sh [interval_seconds]

# Configuration
RPC_URL="localhost:7072"
INTERVAL=${1:-10}  # Default to 10 seconds if not specified
TARGET_BLOCKS=66150246
LOG_FILE="/tmp/banano_cementing_monitor.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Function to format numbers with commas
format_number() {
    printf "%'d" "$1" 2>/dev/null || echo "$1"
}

# Function to calculate percentage
calc_percentage() {
    local value=$1
    local total=$2
    if [ "$total" -eq 0 ]; then
        echo "0.00"
    else
        echo "scale=2; ($value * 100) / $total" | bc
    fi
}

# Function to calculate ETA
calc_eta() {
    local remaining=$1
    local rate=$2

    if [ "$rate" = "0" ] || [ "$rate" = "0.00" ]; then
        echo "Unknown (rate is 0)"
        return
    fi

    # Calculate seconds
    local seconds=$(echo "scale=0; $remaining / $rate" | bc)

    # Convert to human readable
    local days=$((seconds / 86400))
    local hours=$(((seconds % 86400) / 3600))
    local minutes=$(((seconds % 3600) / 60))

    if [ "$days" -gt 0 ]; then
        echo "${days}d ${hours}h ${minutes}m"
    elif [ "$hours" -gt 0 ]; then
        echo "${hours}h ${minutes}m"
    else
        echo "${minutes}m"
    fi
}

# Function to get block count
get_block_count() {
    curl -s -g -d '{"action": "block_count"}' "$RPC_URL" 2>/dev/null
}

# Function to get bootstrap status
get_bootstrap_status() {
    curl -s -g -d '{"action": "bootstrap_status"}' "$RPC_URL" 2>/dev/null
}

# Function to get peers
get_peers() {
    curl -s -g -d '{"action": "peers"}' "$RPC_URL" 2>/dev/null | jq -r '.peers | length' 2>/dev/null || echo "0"
}

# Function to get confirmation quorum
get_confirmation_quorum() {
    curl -s -g -d '{"action": "confirmation_quorum"}' "$RPC_URL" 2>/dev/null
}

# Function to get active difficulty
get_active_difficulty() {
    curl -s -g -d '{"action": "active_difficulty"}' "$RPC_URL" 2>/dev/null
}

# Initialize previous values
PREV_COUNT=0
PREV_CEMENTED=0
PREV_TIME=$(date +%s)

echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║     Banano Node Cementing Progress Monitor - LIVE             ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Monitoring interval: ${INTERVAL} seconds${NC}"
echo -e "${YELLOW}RPC endpoint: ${RPC_URL}${NC}"
echo -e "${YELLOW}Target blocks: $(format_number $TARGET_BLOCKS)${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""
echo "─────────────────────────────────────────────────────────────────"

# Log header
echo "timestamp,count,cemented,unchecked,backlog,confirmed_rate,block_rate,peers" > "$LOG_FILE"

while true; do
    CURRENT_TIME=$(date +%s)
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Get block count data
    BLOCK_DATA=$(get_block_count)

    if [ -z "$BLOCK_DATA" ]; then
        echo -e "${RED}[ERROR]${NC} Failed to connect to node RPC at $RPC_URL"
        echo "        Make sure the node is running and RPC is enabled"
        sleep $INTERVAL
        continue
    fi

    # Parse block count
    COUNT=$(echo "$BLOCK_DATA" | jq -r '.count' | tr -d '"')
    UNCHECKED=$(echo "$BLOCK_DATA" | jq -r '.unchecked' | tr -d '"')
    CEMENTED=$(echo "$BLOCK_DATA" | jq -r '.cemented' | tr -d '"')

    # Get bootstrap status
    BOOTSTRAP_DATA=$(get_bootstrap_status)
    PRIORITIES=$(echo "$BOOTSTRAP_DATA" | jq -r '.priorities' | tr -d '"' 2>/dev/null || echo "0")
    BLOCKING=$(echo "$BOOTSTRAP_DATA" | jq -r '.blocking' | tr -d '"' 2>/dev/null || echo "0")

    # Get peers
    PEERS=$(get_peers)

    # Get confirmation quorum
    QUORUM_DATA=$(get_confirmation_quorum)
    ONLINE_STAKE=$(echo "$QUORUM_DATA" | jq -r '.online_stake_total_decimal' 2>/dev/null || echo "0")
    QUORUM=$(echo "$QUORUM_DATA" | jq -r '.quorum_delta_decimal' 2>/dev/null || echo "0")

    # Calculate backlog
    BACKLOG=$((COUNT - CEMENTED))

    # Calculate rates (blocks per second)
    TIME_DIFF=$((CURRENT_TIME - PREV_TIME))

    if [ "$TIME_DIFF" -gt 0 ] && [ "$PREV_COUNT" -ne 0 ]; then
        BLOCK_RATE=$(echo "scale=2; ($COUNT - $PREV_COUNT) / $TIME_DIFF" | bc)
        CONFIRMED_RATE=$(echo "scale=2; ($CEMENTED - $PREV_CEMENTED) / $TIME_DIFF" | bc)
    else
        BLOCK_RATE="0.00"
        CONFIRMED_RATE="0.00"
    fi

    # Calculate progress percentages
    SYNC_PERCENT=$(calc_percentage "$COUNT" "$TARGET_BLOCKS")
    CEMENT_PERCENT=$(calc_percentage "$CEMENTED" "$COUNT")

    # Calculate remaining and ETA
    REMAINING_BLOCKS=$((TARGET_BLOCKS - COUNT))
    REMAINING_CEMENT=$((COUNT - CEMENTED))

    if [ "$REMAINING_BLOCKS" -lt 0 ]; then
        REMAINING_BLOCKS=0
    fi

    # Calculate ETAs
    if [ "$BLOCK_RATE" != "0.00" ] && [ "$REMAINING_BLOCKS" -gt 0 ]; then
        SYNC_ETA=$(calc_eta "$REMAINING_BLOCKS" "$BLOCK_RATE")
    else
        SYNC_ETA="Complete"
    fi

    if [ "$CONFIRMED_RATE" != "0.00" ] && [ "$REMAINING_CEMENT" -gt 0 ]; then
        CEMENT_ETA=$(calc_eta "$REMAINING_CEMENT" "$CONFIRMED_RATE")
    else
        if [ "$REMAINING_CEMENT" -eq 0 ]; then
            CEMENT_ETA="Complete"
        else
            CEMENT_ETA="Stalled!"
        fi
    fi

    # Display header
    clear
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║     Banano Node Cementing Progress Monitor - LIVE             ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}⏰ Last Update: ${TIMESTAMP}${NC}"
    echo -e "${YELLOW}🎯 Target: $(format_number $TARGET_BLOCKS) blocks${NC}"
    echo ""

    # Block sync status
    echo -e "${BOLD}${BLUE}📦 BLOCK DOWNLOAD STATUS${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    echo -e "  Total Blocks:     ${GREEN}$(format_number $COUNT)${NC} / $(format_number $TARGET_BLOCKS) ${CYAN}(${SYNC_PERCENT}%)${NC}"
    echo -e "  Remaining:        ${YELLOW}$(format_number $REMAINING_BLOCKS)${NC} blocks"
    echo -e "  Download Rate:    ${GREEN}${BLOCK_RATE}${NC} blocks/sec"
    echo -e "  ETA to Sync:      ${MAGENTA}${SYNC_ETA}${NC}"
    echo ""

    # Cementing status
    echo -e "${BOLD}${BLUE}🔨 CEMENTING (CONFIRMATION) STATUS${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    echo -e "  Cemented Blocks:  ${GREEN}$(format_number $CEMENTED)${NC} / $(format_number $COUNT) ${CYAN}(${CEMENT_PERCENT}%)${NC}"
    echo -e "  Backlog:          ${YELLOW}$(format_number $BACKLOG)${NC} blocks waiting"
    echo -e "  Unchecked:        ${YELLOW}$(format_number $UNCHECKED)${NC} blocks"

    # Color code the confirmation rate
    if (( $(echo "$CONFIRMED_RATE > 100" | bc -l) )); then
        RATE_COLOR="${GREEN}${BOLD}"
        RATE_STATUS="🚀 EXCELLENT"
    elif (( $(echo "$CONFIRMED_RATE > 10" | bc -l) )); then
        RATE_COLOR="${GREEN}"
        RATE_STATUS="✅ GOOD"
    elif (( $(echo "$CONFIRMED_RATE > 0" | bc -l) )); then
        RATE_COLOR="${YELLOW}"
        RATE_STATUS="⚠️  SLOW"
    else
        RATE_COLOR="${RED}${BOLD}"
        RATE_STATUS="❌ STALLED"
    fi

    echo -e "  Confirmation Rate: ${RATE_COLOR}${CONFIRMED_RATE}${NC} blocks/sec ${RATE_STATUS}"
    echo -e "  ETA to Cement:    ${MAGENTA}${CEMENT_ETA}${NC}"
    echo ""

    # Bootstrap status
    echo -e "${BOLD}${BLUE}🔄 BOOTSTRAP STATUS${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    echo -e "  Priority Queue:   ${YELLOW}$(format_number $PRIORITIES)${NC}"
    echo -e "  Blocking:         ${YELLOW}$(format_number $BLOCKING)${NC}"
    echo ""

    # Network status
    echo -e "${BOLD}${BLUE}🌐 NETWORK STATUS${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    echo -e "  Connected Peers:  ${GREEN}${PEERS}${NC}"
    echo -e "  Online Stake:     ${GREEN}${ONLINE_STAKE}${NC} BANANO"
    echo -e "  Quorum:           ${GREEN}${QUORUM}${NC} BANANO"
    echo ""

    # Progress bar for cementing
    PROGRESS=$((CEMENTED * 100 / COUNT))
    FILLED=$((PROGRESS / 2))
    EMPTY=$((50 - FILLED))

    echo -e "${BOLD}${BLUE}📊 CEMENTING PROGRESS${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    printf "  ["
    printf "${GREEN}%0.s█${NC}" $(seq 1 $FILLED)
    printf "%0.s─" $(seq 1 $EMPTY)
    printf "] ${CYAN}${CEMENT_PERCENT}%%${NC}\n"
    echo ""

    # Tips
    if [ "$CONFIRMED_RATE" = "0.00" ] && [ "$BACKLOG" -gt 1000000 ]; then
        echo -e "${RED}${BOLD}⚠️  WARNING: Cementing appears to be stalled!${NC}"
        echo -e "${YELLOW}   Consider applying the optimized configuration if you haven't already.${NC}"
        echo ""
    fi

    echo "─────────────────────────────────────────────────────────────────"
    echo -e "${YELLOW}Next update in ${INTERVAL} seconds... (Ctrl+C to stop)${NC}"
    echo -e "${YELLOW}Log file: ${LOG_FILE}${NC}"

    # Log to file
    echo "$TIMESTAMP,$COUNT,$CEMENTED,$UNCHECKED,$BACKLOG,$CONFIRMED_RATE,$BLOCK_RATE,$PEERS" >> "$LOG_FILE"

    # Update previous values
    PREV_COUNT=$COUNT
    PREV_CEMENTED=$CEMENTED
    PREV_TIME=$CURRENT_TIME

    # Wait for next iteration
    sleep $INTERVAL
done
