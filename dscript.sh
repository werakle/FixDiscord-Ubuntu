#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/main_script.sh"
STOP_SCRIPT="$SCRIPT_DIR/stop_and_clean_nft.sh"
REPO_DIR="$SCRIPT_DIR/zapret-latest"
RESULTS_FILE="$SCRIPT_DIR/auto_tune_discord_results.txt"

WAIT_TIME=2
CURL_TIMEOUT=3

TEST_ENDPOINTS=(
    "discord.com"
    "gateway.discord.gg"
    "cdn.discordapp.com"
    "media.discordapp.net"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

declare -a STRATEGY_FILES=()
declare -a WORKING_STRATEGIES=()
TESTED_COUNT=0
SUCCESS_COUNT=0
FAILED_COUNT=0

load_strategy_files() {
    STRATEGY_FILES=()
    
    if [ -d "$REPO_DIR" ]; then
        for file in "$REPO_DIR"/*.bat; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")
                if [[ "$filename" == general*.bat ]] || [[ "$filename" == discord*.bat ]]; then
                    STRATEGY_FILES+=("$filename")
                fi
            fi
        done
    fi
}

get_strategy_name() {
    local idx=$(($1 - 1))
    if [ $idx -ge 0 ] && [ $idx -lt ${#STRATEGY_FILES[@]} ]; then
        echo "${STRATEGY_FILES[$idx]}"
    else
        echo ""
    fi
}

stop_zapret() {
    sudo "$STOP_SCRIPT" 2>/dev/null
    sleep 1
}

run_strategy() {
    local num=$1
    printf "y\n%d\n1\n" "$num" | "$MAIN_SCRIPT" &
    sleep "$WAIT_TIME"
}

check_discord_endpoint() {
    local endpoint=$1
    if curl -s --tlsv1.3 --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_TIMEOUT" \
        "https://$endpoint" > /dev/null 2>&1; then
        echo 1
    else
        echo 0
    fi
}

test_strategy() {
    local score=0
    local endpoint_list=""
    
    for endpoint in "${TEST_ENDPOINTS[@]}"; do
        if [ $(check_discord_endpoint "$endpoint") -eq 1 ]; then
            ((score++))
            endpoint_list="${endpoint_list}${endpoint},"
        fi
    done
    
    endpoint_list="${endpoint_list%,}"
    echo "$score:$endpoint_list"
}

echo ""
echo -e "${BOLD}${CYAN}=== Discord Auto Tune ===${NC}"
echo ""

load_strategy_files
MAX_STRATEGY=${#STRATEGY_FILES[@]}

if [ $MAX_STRATEGY -eq 0 ]; then
    echo "❌ No strategies found"
    exit 1
fi

echo -e "Found strategies: ${BOLD}$MAX_STRATEGY${NC}"
echo ""

if ! command -v curl &>/dev/null; then
    echo "❌ curl not installed"
    exit 1
fi

if [ ! -f "$MAIN_SCRIPT" ]; then
    echo "❌ main_script.sh not found"
    exit 1
fi

echo "Testing Discord without zapret..."
echo ""

total_ok=0
for endpoint in "${TEST_ENDPOINTS[@]}"; do
    echo -n "  $endpoint... "
    if [ $(check_discord_endpoint "$endpoint") -eq 1 ]; then
        echo -e "${GREEN}OK${NC}"
        ((total_ok++))
    else
        echo -e "${RED}FALL${NC}"
    fi
done

echo ""
if [ $total_ok -eq ${#TEST_ENDPOINTS[@]} ]; then
    echo -e "${GREEN}✓ Discord is already working${NC}"
    exit 0
fi

echo "Discord not working. Testing strategies..."
echo ""

stop_zapret

for ((i=1; i<=MAX_STRATEGY; i++)); do
    name=$(get_strategy_name $i)
    if [ -z "$name" ]; then
        continue
    fi
    
    printf "  [%2d/%d] %-30s " "$i" "$MAX_STRATEGY" "$name"
    
    run_strategy $i >/dev/null 2>&1
    ((TESTED_COUNT++))
    
    result=$(test_strategy)
    score="${result%%:*}"
    endpoints="${result#*:}"
    
    if [ $score -ge 1 ]; then
        ((SUCCESS_COUNT++))
        WORKING_STRATEGIES+=("$i:$name:$score:$endpoints")
        if [ $score -eq ${#TEST_ENDPOINTS[@]} ]; then
            echo -e "${GREEN}$score/${#TEST_ENDPOINTS[@]}${NC}"
        elif [ $score -ge 2 ]; then
            echo -e "${YELLOW}$score/${#TEST_ENDPOINTS[@]}${NC}"
        else
            echo -e "${RED}$score/${#TEST_ENDPOINTS[@]}${NC}"
        fi
    else
        ((FAILED_COUNT++))
        echo -e "${RED}$score/${#TEST_ENDPOINTS[@]}${NC}"
    fi
    
    stop_zapret >/dev/null 2>&1
    sleep 1
done

echo ""
echo -e "${GREEN}Done!${NC}"
echo ""

if [ $SUCCESS_COUNT -gt 0 ]; then
    echo "Working strategies:"
    echo "-------------------"
    for entry in "${WORKING_STRATEGIES[@]}"; do
        num="${entry%%:*}"
        rest="${entry#*:}"
        name="${rest%%:*}"
        rest="${rest#*:}"
        score="${rest%%:*}"
        endpoints="${rest#*:}"
        
        echo "  [$num] $name - $score/${#TEST_ENDPOINTS[@]} - $endpoints"
    done
    echo ""
    
    echo "Enter strategy number to use:"
    read -p "> " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -le $MAX_STRATEGY ]; then
        echo ""
        echo "Starting strategy $choice..."
        stop_zapret
        printf "y\n%d\n1\n" "$choice" | "$MAIN_SCRIPT"
    else
        echo "Invalid choice"
    fi
else
    echo "❌ No working strategies found"
fi

echo ""
