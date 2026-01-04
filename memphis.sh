#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/main_script.sh"
STOP_SCRIPT="$SCRIPT_DIR/stop_and_clean_nft.sh"
CONF_FILE="$SCRIPT_DIR/conf.env"
RESULTS_FILE="$SCRIPT_DIR/discord_check_results.txt"
NFT_RULES_FILE="/tmp/nft_rules_dump.txt"

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
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

check_current_strategy() {
    echo -e "${BOLD}${BLUE}=== Проверка текущей ситуации ===${NC}"
    echo ""
    
    # 1. Проверяем запущен ли zapret
    echo -e "${BOLD}1. Проверка запущенных процессов:${NC}"
    if pgrep -f "zapret" > /dev/null || pgrep -f "tpws" > /dev/null; then
        echo -e "   ${GREEN}✓ Zapret запущен${NC}"
        ZAPRET_RUNNING=1
    else
        echo -e "   ${YELLOW}⚠ Zapret не запущен${NC}"
        ZAPRET_RUNNING=0
    fi
    
    # 2. Проверяем nftables правила
    echo -e "${BOLD}2. Проверка nftables правил:${NC}"
    if sudo nft list ruleset 2>/dev/null | grep -q "zapret\|tpws"; then
        echo -e "   ${GREEN}✓ Есть правила zapret${NC}"
        NFT_RULES=1
    else
        echo -e "   ${YELLOW}⚠ Нет правил zapret${NC}"
        NFT_RULES=0
    fi
    
    # 3. Проверяем конфигурационный файл
    echo -e "${BOLD}3. Конфигурационный файл ($CONF_FILE):${NC}"
    if [ -f "$CONF_FILE" ]; then
        CURRENT_STRATEGY=$(grep -i "strategy=" "$CONF_FILE" | cut -d'=' -f2)
        if [ -n "$CURRENT_STRATEGY" ]; then
            echo -e "   ${GREEN}✓ Текущая стратегия: $CURRENT_STRATEGY${NC}"
        else
            echo -e "   ${YELLOW}⚠ Стратегия не указана в конфиге${NC}"
            CURRENT_STRATEGY="не указана"
        fi
    else
        echo -e "   ${YELLOW}⚠ Конфиг не найден${NC}"
        CURRENT_STRATEGY="конфиг отсутствует"
    fi
    
    # 4. Проверяем Discord
    echo -e "${BOLD}4. Проверка Discord:${NC}"
    check_discord_status
    
    echo ""
}

check_discord_status() {
    local total=${#TEST_ENDPOINTS[@]}
    local working=0
    
    for endpoint in "${TEST_ENDPOINTS[@]}"; do
        echo -n "   $endpoint... "
        if curl -s --connect-timeout "$CURL_TIMEOUT" "https://$endpoint" > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}"
            ((working++))
        else
            echo -e "${RED}✗${NC}"
        fi
    done
    
    echo -e "   ${BOLD}Итого: $working/$total эндпоинтов работают${NC}"
    
    if [ $working -eq $total ]; then
        DISCORD_STATUS="full"
        echo -e "   ${GREEN}✓ Discord полностью доступен${NC}"
    elif [ $working -ge 2 ]; then
        DISCORD_STATUS="partial"
        echo -e "   ${YELLOW}⚠ Discord частично доступен${NC}"
    else
        DISCORD_STATUS="none"
        echo -e "   ${RED}✗ Discord недоступен${NC}"
    fi
}

show_available_strategies() {
    echo ""
    echo -e "${BOLD}${CYAN}=== Доступные стратегии ===${NC}"
    echo ""
    
    local strategies=()
    local custom_dir="$SCRIPT_DIR/custom-strategies"
    local repo_dir="$SCRIPT_DIR/zapret-latest"
    
    # Ищем стратегии
    if [ -d "$repo_dir" ]; then
        for file in "$repo_dir"/*.bat; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")
                if [[ "$filename" == general*.bat ]] || [[ "$filename" == discord*.bat ]]; then
                    strategies+=("$filename")
                fi
            fi
        done
    fi
    
    if [ -d "$custom_dir" ]; then
        for file in "$custom_dir"/*.bat; do
            if [ -f "$file" ]; then
                strategies+=("$(basename "$file")")
            fi
        done
    fi
    
    if [ ${#strategies[@]} -eq 0 ]; then
        echo -e "${RED}❌ Стратегии не найдены${NC}"
        return 1
    fi
    
    echo -e "Найдено стратегий: ${BOLD}${#strategies[@]}${NC}"
    echo ""
    
    for i in "${!strategies[@]}"; do
        num=$((i + 1))
        echo -e "  ${BOLD}[$num]${NC} ${strategies[$i]}"
    done
    
    AVAILABLE_STRATEGIES=("${strategies[@]}")
    return 0
}

test_single_strategy() {
    local strategy_num=$1
    local strategy_name=${AVAILABLE_STRATEGIES[$((strategy_num-1))]}
    
    if [ -z "$strategy_name" ]; then
        echo -e "${RED}❌ Неверный номер стратегии${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${BOLD}Тестируем стратегию [$strategy_num] $strategy_name...${NC}"
    
    # Останавливаем текущий zapret
    echo -n "Останавливаем zapret... "
    sudo "$STOP_SCRIPT" 2>/dev/null
    sleep 1
    echo -e "${GREEN}готово${NC}"
    
    # Запускаем новую стратегию
    echo -n "Запускаем стратегию... "
    printf "y\n%d\n1\n" "$strategy_num" | "$MAIN_SCRIPT" > /dev/null 2>&1 &
    sleep 3
    
    # Проверяем Discord
    echo "Проверяем Discord..."
    local total=${#TEST_ENDPOINTS[@]}
    local working=0
    
    for endpoint in "${TEST_ENDPOINTS[@]}"; do
        echo -n "  $endpoint... "
        if curl -s --connect-timeout "$CURL_TIMEOUT" "https://$endpoint" > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}"
            ((working++))
        else
            echo -e "${RED}✗${NC}"
        fi
    done
    
    echo -e "${BOLD}Результат: $working/$total эндпоинтов${NC}"
    
    # Останавливаем для чистоты
    sudo "$STOP_SCRIPT" 2>/dev/null
    sleep 1
    
    if [ $working -ge 2 ]; then
        echo -e "${GREEN}✓ Стратегия работает${NC}"
        return 0
    else
        echo -e "${RED}✗ Стратегия не работает${NC}"
        return 1
    fi
}

save_strategy() {
    local strategy_num=$1
    local strategy_name=${AVAILABLE_STRATEGIES[$((strategy_num-1))]}
    
    if [ -z "$strategy_name" ]; then
        echo -e "${RED}❌ Неверный номер стратегии${NC}"
        return 1
    fi
    
    cat > "$CONF_FILE" << EOF
interface=any
gamefilter=false
strategy=$strategy_name
EOF
    
    echo -e "${GREEN}✓ Стратегия сохранена в $CONF_FILE${NC}"
    echo -e "   Теперь можно запускать: ${BOLD}sudo $MAIN_SCRIPT -nointeractive${NC}"
}

show_menu() {
    echo ""
    echo -e "${BOLD}${CYAN}=== МЕНЮ ===${NC}"
    echo ""
    echo "1. Проверить текущее состояние"
    echo "2. Протестировать стратегию"
    echo "3. Сохранить стратегию в конфиг"
    echo "4. Запустить стратегию на постоянной основе"
    echo "5. Остановить zapret"
    echo "6. Выход"
    echo ""
}

main() {
    clear
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}          Discord Zapret Checker & Tester          ${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
    echo ""
    
    # Проверяем зависимости
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}❌ Установите curl: sudo apt install curl${NC}"
        exit 1
    fi
    
    if [ ! -f "$MAIN_SCRIPT" ]; then
        echo -e "${RED}❌ Файл $MAIN_SCRIPT не найден${NC}"
        exit 1
    fi
    
    # Загружаем список стратегий
    show_available_strategies
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    while true; do
        show_menu
        read -p "Выберите действие (1-6): " choice
        
        case $choice in
            1)
                check_current_strategy
                ;;
            2)
                echo ""
                echo "Введите номер стратегии для теста (1-${#AVAILABLE_STRATEGIES[@]}):"
                read -p "Номер: " strat_num
                if [[ "$strat_num" =~ ^[0-9]+$ ]] && [ $strat_num -ge 1 ] && [ $strat_num -le ${#AVAILABLE_STRATEGIES[@]} ]; then
                    test_single_strategy $strat_num
                else
                    echo -e "${RED}❌ Неверный номер${NC}"
                fi
                ;;
            3)
                echo ""
                echo "Введите номер стратегии для сохранения в конфиг (1-${#AVAILABLE_STRATEGIES[@]}):"
                read -p "Номер: " strat_num
                if [[ "$strat_num" =~ ^[0-9]+$ ]] && [ $strat_num -ge 1 ] && [ $strat_num -le ${#AVAILABLE_STRATEGIES[@]} ]; then
                    save_strategy $strat_num
                else
                    echo -e "${RED}❌ Неверный номер${NC}"
                fi
                ;;
            4)
                echo ""
                echo "Введите номер стратегии для запуска (1-${#AVAILABLE_STRATEGIES[@]}):"
                read -p "Номер: " strat_num
                if [[ "$strat_num" =~ ^[0-9]+$ ]] && [ $strat_num -ge 1 ] && [ $strat_num -le ${#AVAILABLE_STRATEGIES[@]} ]; then
                    echo ""
                    echo -e "${BOLD}Запускаем стратегию...${NC}"
                    sudo "$STOP_SCRIPT" 2>/dev/null
                    sleep 1
                    printf "y\n%d\n1\n" "$strat_num" | sudo "$MAIN_SCRIPT"
                    break
                else
                    echo -e "${RED}❌ Неверный номер${NC}"
                fi
                ;;
            5)
                echo ""
                echo -e "${YELLOW}Останавливаем zapret...${NC}"
                sudo "$STOP_SCRIPT"
                sleep 2
                echo -e "${GREEN}✓ Zapret остановлен${NC}"
                ;;
            6)
                echo ""
                echo "Выход..."
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Неверный выбор${NC}"
                ;;
        esac
        
        echo ""
        read -p "Нажмите Enter для продолжения..." dummy
        clear
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}          Discord Zapret Checker & Tester          ${NC}"
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
        echo ""
    done
}

main
