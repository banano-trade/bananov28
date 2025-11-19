#!/bin/bash
# Banano Node Cementing Progress Monitor - FIXED VERSION
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

# Check for required commands
check_dependencies() {
    local missing=""

    if ! command -v curl &> /dev/null; then
        missing="${missing}curl "
    fi

    if ! command -v jq &> /dev/null; then
        missing="${missing}jq "
    fi

    if [ -n "$missing" ]; then
        echo -e "${RED}ERROR: Missing required commands: ${missing}${NC}"
        echo ""
        echo "Please install them with:"
        echo "  apt-get install -y ${missing}"
        echo "  OR"
        echo "  yum install -y ${missing}"
        exit 1
    fi
}

# Function to format numbers with commas (without bc)
format_number() {
    local num=$1
    if [ -z "$num" ] || [ "$num" = "null" ]; then
        echo "0"
        return
    fi
    printf "%'d" "$num" 2>/dev/null || echo "$num"
}

# Function to calculate percentage (without bc)
calc_percentage() {
    local value=$1
    local total=$2

    if [ -z "$value" ] || [ -z "$total" ] || [ "$total" -eq 0 ] 2>/dev/null; then
        echo "0.00"
        return
    fi

    # Use awk instead of bc
    echo "$value $total" | awk '{printf "%.2f", ($1 * 100) / $2}'
}

# Function to calculate rate (without bc)
calc_rate() {
    local current=$1
    local previous=$2
    local time_diff=$3

    if [ -z "$current" ] || [ -z "$previous" ] || [ -z "$time_diff" ] || [ "$time_diff" -eq 0 ] 2>/dev/null; then
        echo "0.00"
        return
    fi

    local diff=$((current - previous))
    echo "$diff $time_diff" | awk '{printf "%.2f", $1 / $2}'
}

# Function to calculate ETA
calc_eta() {
    local remaining=$1
    local rate=$2

    if [ -z "$remaining" ] || [ -z "$rate" ] || [ "$remaining" -eq 0 ] 2>/dev/null; then
        echo "Complete"
        return
    fi

    # Check if rate is effectively zero
    local rate_check=$(echo "$rate" | awk '{if ($1 < 0.01) print "zero"; else print "ok"}')
    if [ "$rate_check" = "zero" ]; then
        echo "Stalled (rate too low)"
        return
    fi

    # Calculate seconds using awk
    local seconds=$(echo "$remaining $rate" | awk '{printf "%.0f", $1 / $2}')

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
    curl -s -m 5 -g -d '{"action": "block_count"}' "$RPC_URL" 2>/dev/null
}

# Function to get bootstrap status
get_bootstrap_status() {
    curl -s -m 5 -g -d '{"action": "bootstrap_status"}' "$RPC_URL" 2>/dev/null
}

# Function to get peers
get_peers() {
    curl -s -m 5 -g -d '{"action": "peers"}' "$RPC_URL" 2>/dev/null | jq -r '.peers | length' 2>/dev/null || echo "0"
}

# Function to get confirmation quorum
get_confirmation_quorum() {
    curl -s -m 5 -g -d '{"action": "confirmation_quorum"}' "$RPC_URL" 2>/dev/null
}

# Check dependencies before starting
check_dependencies

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
        echo "        Retrying in $INTERVAL seconds..."
        sleep $INTERVAL
        continue
    fi

    # Parse block count with validation
    COUNT=$(echo "$BLOCK_DATA" | jq -r '.count' 2>/dev/null | tr -d '"')
    UNCHECKED=$(echo "$BLOCK_DATA" | jq -r '.unchecked' 2>/dev/null | tr -d '"')
    CEMENTED=$(echo "$BLOCK_DATA" | jq -r '.cemented' 2>/dev/null | tr -d '"')

    # Validate and set defaults
    if [ -z "$COUNT" ] || [ "$COUNT" = "null" ]; then COUNT=0; fi
    if [ -z "$UNCHECKED" ] || [ "$UNCHECKED" = "null" ]; then UNCHECKED=0; fi
    if [ -z "$CEMENTED" ] || [ "$CEMENTED" = "null" ]; then CEMENTED=0; fi

    # Get bootstrap status
    BOOTSTRAP_DATA=$(get_bootstrap_status)
    PRIORITIES=$(echo "$BOOTSTRAP_DATA" | jq -r '.priorities' 2>/dev/null | tr -d '"')
    BLOCKING=$(echo "$BOOTSTRAP_DATA" | jq -r '.blocking' 2>/dev/null | tr -d '"')

    if [ -z "$PRIORITIES" ] || [ "$PRIORITIES" = "null" ]; then PRIORITIES=0; fi
    if [ -z "$BLOCKING" ] || [ "$BLOCKING" = "null" ]; then BLOCKING=0; fi

    # Get peers
    PEERS=$(get_peers)
    if [ -z "$PEERS" ] || [ "$PEERS" = "null" ]; then PEERS=0; fi

    # Get confirmation quorum
    QUORUM_DATA=$(get_confirmation_quorum)
    ONLINE_STAKE=$(echo "$QUORUM_DATA" | jq -r '.online_stake_total_decimal' 2>/dev/null)
    QUORUM=$(echo "$QUORUM_DATA" | jq -r '.quorum_delta_decimal' 2>/dev/null)

    if [ -z "$ONLINE_STAKE" ] || [ "$ONLINE_STAKE" = "null" ]; then ONLINE_STAKE="0"; fi
    if [ -z "$QUORUM" ] || [ "$QUORUM" = "null" ]; then QUORUM="0"; fi

    # Calculate backlog
    BACKLOG=$((COUNT - CEMENTED))
    if [ "$BACKLOG" -lt 0 ]; then BACKLOG=0; fi

    # Calculate rates (blocks per second)
    TIME_DIFF=$((CURRENT_TIME - PREV_TIME))

    if [ "$TIME_DIFF" -gt 0 ] && [ "$PREV_COUNT" -ne 0 ]; then
        BLOCK_RATE=$(calc_rate "$COUNT" "$PREV_COUNT" "$TIME_DIFF")
        CONFIRMED_RATE=$(calc_rate "$CEMENTED" "$PREV_CEMENTED" "$TIME_DIFF")
    else
        BLOCK_RATE="0.00"
        CONFIRMED_RATE="0.00"
    fi

    # Calculate progress percentages
    SYNC_PERCENT=$(calc_percentage "$COUNT" "$TARGET_BLOCKS")
    if [ "$COUNT" -gt 0 ]; then
        CEMENT_PERCENT=$(calc_percentage "$CEMENTED" "$COUNT")
    else
        CEMENT_PERCENT="0.00"
    fi

    # Calculate remaining and ETA
    REMAINING_BLOCKS=$((TARGET_BLOCKS - COUNT))
    REMAINING_CEMENT=$((COUNT - CEMENTED))

    if [ "$REMAINING_BLOCKS" -lt 0 ]; then
        REMAINING_BLOCKS=0
    fi

    # Calculate ETAs
    if [ "$REMAINING_BLOCKS" -eq 0 ]; then
        SYNC_ETA="Complete"
    else
        SYNC_ETA=$(calc_eta "$REMAINING_BLOCKS" "$BLOCK_RATE")
    fi

    if [ "$REMAINING_CEMENT" -eq 0 ]; then
        CEMENT_ETA="Complete"
    else
        CEMENT_ETA=$(calc_eta "$REMAINING_CEMENT" "$CONFIRMED_RATE")
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
    RATE_CHECK=$(echo "$CONFIRMED_RATE" | awk '{if ($1 > 100) print "excellent"; else if ($1 > 10) print "good"; else if ($1 > 0) print "slow"; else print "stalled"}')

    case "$RATE_CHECK" in
        excellent)
            RATE_COLOR="${GREEN}${BOLD}"
            RATE_STATUS="🚀 EXCELLENT"
            ;;
        good)
            RATE_COLOR="${GREEN}"
            RATE_STATUS="✅ GOOD"
            ;;
        slow)
            RATE_COLOR="${YELLOW}"
            RATE_STATUS="⚠️  SLOW"
            ;;
        *)
            RATE_COLOR="${RED}${BOLD}"
            RATE_STATUS="❌ STALLED"
            ;;
    esac

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
    if [ "$COUNT" -gt 0 ]; then
        PROGRESS=$(echo "$CEMENTED $COUNT" | awk '{printf "%.0f", ($1 * 100) / $2}')
        FILLED=$(echo "$PROGRESS" | awk '{printf "%.0f", $1 / 2}')
        EMPTY=$((50 - FILLED))

        if [ "$FILLED" -lt 0 ]; then FILLED=0; fi
        if [ "$EMPTY" -lt 0 ]; then EMPTY=0; fi
        if [ "$FILLED" -gt 50 ]; then FILLED=50; EMPTY=0; fi
    else
        PROGRESS=0
        FILLED=0
        EMPTY=50
    fi

    echo -e "${BOLD}${BLUE}📊 CEMENTING PROGRESS${NC}"
    echo "─────────────────────────────────────────────────────────────────"
    printf "  ["
    if [ "$FILLED" -gt 0 ]; then
        printf "${GREEN}%0.s█${NC}" $(seq 1 $FILLED)
    fi
    if [ "$EMPTY" -gt 0 ]; then
        printf "%0.s─" $(seq 1 $EMPTY)
    fi
    printf "] ${CYAN}${CEMENT_PERCENT}%%${NC}\n"
    echo ""

    # Tips
    if [ "$RATE_CHECK" = "stalled" ] && [ "$BACKLOG" -gt 1000000 ]; then
        echo -e "${RED}${BOLD}⚠️  WARNING: Cementing appears to be stalled!${NC}"
        echo -e "${YELLOW}   Consider applying the optimized configuration if you haven't already.${NC}"
        echo -e "${YELLOW}   Check: config-node-REAL-OPTIMIZED.toml${NC}"
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
