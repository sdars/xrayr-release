#!/bin/bash
#
# XrayR 一键安装脚本 (公开发布版)
# 用法: bash <(curl -sL https://raw.githubusercontent.com/sdars/xrayr-release/main/install.sh)
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

REPO="sdars/xrayr-release"
INSTALL_DIR="/usr/local/XrayR"
CONFIG_DIR="/etc/XrayR"
SERVICE_NAME="XrayR"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
COMMAND_LINK="/usr/local/bin/xrayr"

DEFAULT_GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
DEFAULT_GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
ALT_GEOIP_URL="https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
ALT_GEOSITE_URL="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
METACUBEX_GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"
METACUBEX_GEOSITE_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"
SOFFCHEN_GEOIP_URL="https://github.com/soffchen/merged/releases/latest/download/geoip.dat"
SOFFCHEN_GEOSITE_URL="https://github.com/soffchen/merged/releases/latest/download/geosite.dat"

print_info()  { echo -e "${CYAN}[信息]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[成功]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }

check_root() {
    [[ $EUID -ne 0 ]] && { print_error "请使用 root 运行"; exit 1; }
}

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) print_error "不支持的架构: $arch"; exit 1 ;;
    esac
}

get_latest_version() {
    local ver
    ver=$(curl -sL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    if [[ -z "$ver" ]]; then
        print_error "无法获取最新版本号"
        exit 1
    fi
    echo "$ver"
}

download_binary() {
    local version="$1" arch="$2"
    local url="https://github.com/${REPO}/releases/download/${version}/XrayR-linux-${arch}"
    local dest="${INSTALL_DIR}/XrayR"

    print_info "下载 XrayR ${version} (linux-${arch})..."
    mkdir -p "${INSTALL_DIR}"

    if command -v wget &>/dev/null; then
        wget -qO "$dest" "$url"
    elif command -v curl &>/dev/null; then
        curl -sLo "$dest" "$url"
    else
        print_error "需要 wget 或 curl"
        exit 1
    fi

    if [[ ! -f "$dest" ]] || [[ $(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest") -lt 1000000 ]]; then
        print_error "下载失败或文件异常"
        rm -f "$dest"
        exit 1
    fi

    chmod +x "$dest"
    print_ok "二进制下载完成: ${dest}"
}

download_manager_scripts() {
    local version="$1"
    local base_url="https://github.com/${REPO}/releases/download/${version}"

    # 下载管理脚本
    print_info "下载管理脚本..."
    if command -v wget &>/dev/null; then
        wget -qO "${INSTALL_DIR}/xrayr-manager.sh" "${base_url}/xrayr-manager.sh" 2>/dev/null || true
        wget -qO "${INSTALL_DIR}/config_helper.py" "${base_url}/config_helper.py" 2>/dev/null || true
    else
        curl -sLo "${INSTALL_DIR}/xrayr-manager.sh" "${base_url}/xrayr-manager.sh" 2>/dev/null || true
        curl -sLo "${INSTALL_DIR}/config_helper.py" "${base_url}/config_helper.py" 2>/dev/null || true
    fi

    # 如果 Release 没有脚本, 从 raw main 拉
    if [[ ! -s "${INSTALL_DIR}/xrayr-manager.sh" ]]; then
        local raw_base="https://raw.githubusercontent.com/${REPO}/main"
        if command -v wget &>/dev/null; then
            wget -qO "${INSTALL_DIR}/xrayr-manager.sh" "${raw_base}/xrayr-manager.sh" 2>/dev/null || true
            wget -qO "${INSTALL_DIR}/config_helper.py" "${raw_base}/config_helper.py" 2>/dev/null || true
        else
            curl -sLo "${INSTALL_DIR}/xrayr-manager.sh" "${raw_base}/xrayr-manager.sh" 2>/dev/null || true
            curl -sLo "${INSTALL_DIR}/config_helper.py" "${raw_base}/config_helper.py" 2>/dev/null || true
        fi
    fi

    chmod +x "${INSTALL_DIR}/xrayr-manager.sh" "${INSTALL_DIR}/config_helper.py" 2>/dev/null || true
}

install_config_files() {
    mkdir -p "${CONFIG_DIR}" "${CONFIG_DIR}/cert"

    # 默认配置文件（不覆盖已有）
    if [[ ! -f "${CONFIG_DIR}/config.yml" ]]; then
        cat > "${CONFIG_DIR}/config.yml" << 'CFGEOF'
Log:
  Level: warning
  AccessPath:
  ErrorPath:
DnsConfigPath:
RouteConfigPath:
InboundConfigPath:
OutboundConfigPath:
ConnectionConfig:
  Handshake: 4
  ConnIdle: 30
  UplinkOnly: 2
  DownlinkOnly: 4
  BufferSize: 64
Nodes:
  - PanelType: "NewV2board"
    ApiConfig:
      ApiHost: "http://127.0.0.1:667"
      ApiKey: "YOUR_API_KEY"
      NodeID: 1
      NodeType: V2ray
      Timeout: 30
      EnableVless: false
      SpeedLimit: 0
      DeviceLimit: 0
    ControllerConfig:
      ListenIP: 0.0.0.0
      SendIP: 0.0.0.0
      UpdatePeriodic: 60
      EnableDNS: false
      DNSType: AsIs
      EnableProxyProtocol: false
      AutoSpeedLimitConfig:
        Limit: 0
        WarnTimes: 0
        LimitSpeed: 0
        LimitDuration: 0
      GlobalDeviceLimitConfig:
        Enable: false
        RedisAddr: 127.0.0.1:6379
        RedisPassword:
        RedisDB: 0
        Timeout: 5
        Expiry: 60
      EnableFallback: false
      CertConfig:
        CertMode: none
        CertDomain: ""
        CertFile: ""
        KeyFile: ""
        Provider: ""
        Email: ""
CFGEOF
        print_ok "默认配置已生成"
    else
        print_info "配置文件已存在, 跳过"
    fi

    # route.json
    [[ ! -f "${CONFIG_DIR}/route.json" ]] && cat > "${CONFIG_DIR}/route.json" << 'ROUTEEOF'
{
  "domainStrategy": "IPIfNonMatch",
  "rules": [
    {
      "type": "field",
      "outboundTag": "block",
      "ip": ["geoip:private"]
    },
    {
      "type": "field",
      "outboundTag": "block",
      "protocol": ["bittorrent"]
    }
  ]
}
ROUTEEOF

    # dns.json
    [[ ! -f "${CONFIG_DIR}/dns.json" ]] && cat > "${CONFIG_DIR}/dns.json" << 'DNSEOF'
{
  "servers": ["1.1.1.1", "8.8.8.8", "localhost"],
  "tag": "dns_inbound"
}
DNSEOF

    # custom_outbound.json
    [[ ! -f "${CONFIG_DIR}/custom_outbound.json" ]] && cat > "${CONFIG_DIR}/custom_outbound.json" << 'OBEOF'
[
  {
    "tag": "IPv4_out",
    "protocol": "freedom",
    "settings": {
      "domainStrategy": "UseIPv4"
    }
  },
  {
    "tag": "block",
    "protocol": "blackhole",
    "settings": {}
  }
]
OBEOF

    # custom_inbound.json
    [[ ! -f "${CONFIG_DIR}/custom_inbound.json" ]] && cat > "${CONFIG_DIR}/custom_inbound.json" << 'IBEOF'
[
  {
    "tag": "socks_in",
    "port": 1234,
    "listen": "127.0.0.1",
    "protocol": "socks",
    "settings": {
      "auth": "noauth",
      "udp": true
    }
  }
]
IBEOF

    # rulelist
    [[ ! -f "${CONFIG_DIR}/rulelist" ]] && echo "# 自定义规则列表" > "${CONFIG_DIR}/rulelist"
}

install_geodata() {
    echo ""
    echo -e "${CYAN}${BOLD}选择 GeoData 数据源:${NC}"
    echo -e "  ${GREEN}1)${NC} Loyalsoldier (推荐 - 规则全面)"
    echo -e "  ${GREEN}2)${NC} v2fly 社区 (原版)"
    echo -e "  ${GREEN}3)${NC} MetaCubeX (Clash Meta)"
    echo -e "  ${GREEN}4)${NC} soffchen 合并规则"
    echo ""
    read -rp "请选择 [1-4, 默认=1]: " geo_choice
    local GEOIP_URL GEOSITE_URL
    case "$geo_choice" in
        2) GEOIP_URL="$ALT_GEOIP_URL"; GEOSITE_URL="$ALT_GEOSITE_URL" ;;
        3) GEOIP_URL="$METACUBEX_GEOIP_URL"; GEOSITE_URL="$METACUBEX_GEOSITE_URL" ;;
        4) GEOIP_URL="$SOFFCHEN_GEOIP_URL"; GEOSITE_URL="$SOFFCHEN_GEOSITE_URL" ;;
        *) GEOIP_URL="$DEFAULT_GEOIP_URL"; GEOSITE_URL="$DEFAULT_GEOSITE_URL" ;;
    esac

    print_info "下载 GeoData..."
    if command -v wget &>/dev/null; then
        wget -qO "${CONFIG_DIR}/geoip.dat" "${GEOIP_URL}" && print_ok "geoip.dat" || print_warn "下载失败"
        wget -qO "${CONFIG_DIR}/geosite.dat" "${GEOSITE_URL}" && print_ok "geosite.dat" || print_warn "下载失败"
    else
        curl -sLo "${CONFIG_DIR}/geoip.dat" "${GEOIP_URL}" && print_ok "geoip.dat" || print_warn "下载失败"
        curl -sLo "${CONFIG_DIR}/geosite.dat" "${GEOSITE_URL}" && print_ok "geosite.dat" || print_warn "下载失败"
    fi
}

install_systemd_service() {
    cat > "${SERVICE_FILE}" << 'SVCEOF'
[Unit]
Description=XrayR Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/XrayR/XrayR --config /etc/XrayR/config.yml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
LimitNPROC=512

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME} 2>/dev/null
    print_ok "systemd 服务已创建"
}

install_log_limits() {
    print_info "安装日志限制..."
    # logrotate
    command -v logrotate &>/dev/null || {
        apt-get install -y logrotate &>/dev/null 2>&1 || yum install -y logrotate &>/dev/null 2>&1 || true
    }
    cat > /etc/logrotate.d/xrayr << 'LREOF'
/etc/XrayR/access.log /etc/XrayR/error.log {
    daily
    size 10M
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0644 root root
}

/var/log/xrayr-geo-update.log {
    weekly
    size 2M
    rotate 4
    missingok
    notifempty
    compress
    copytruncate
}
LREOF

    # journald limits
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/xrayr-limits.conf << 'JDEOF'
[Journal]
SystemMaxUse=200M
SystemKeepFree=500M
SystemMaxFileSize=20M
MaxRetentionSec=2week
RateLimitIntervalSec=30s
RateLimitBurst=10000
JDEOF
    systemctl restart systemd-journald 2>/dev/null || true

    # service drop-in
    mkdir -p "/etc/systemd/system/${SERVICE_NAME}.service.d"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service.d/limits.conf" << 'SDEOF'
[Service]
LogRateLimitIntervalSec=30s
LogRateLimitBurst=5000
SDEOF
    systemctl daemon-reload
    print_ok "日志限制已安装"
}

install_geo_cron() {
    if crontab -l 2>/dev/null | grep -q "geo-update"; then
        print_info "GeoData 定时更新已存在"
        return
    fi

    cat > "${INSTALL_DIR}/geo-update.sh" << 'GEOEOF'
#!/bin/bash
CONFIG_DIR="/etc/XrayR"
GEO_CONFIG_FILE="/etc/XrayR/geodata.conf"
LOG="/var/log/xrayr-geo-update.log"
SERVICE_NAME="XrayR"
DEFAULT_GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
DEFAULT_GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
GEO_SOURCE="loyalsoldier"
GEO_AUTO_RESTART="true"
GEO_VERIFY="true"
[[ -f "$GEO_CONFIG_FILE" ]] && source "$GEO_CONFIG_FILE"
case "$GEO_SOURCE" in
    loyalsoldier) IP_URL="$DEFAULT_GEOIP_URL"; SITE_URL="$DEFAULT_GEOSITE_URL" ;;
    *) IP_URL="$DEFAULT_GEOIP_URL"; SITE_URL="$DEFAULT_GEOSITE_URL" ;;
esac
log() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" >> "$LOG"; }
download() {
    local url="$1" dest="$2" name="$3" tmp="${2}.tmp"
    if command -v wget &>/dev/null; then wget -qO "$tmp" "$url"
    elif command -v curl &>/dev/null; then curl -sLo "$tmp" "$url"
    else log "ERROR: no wget/curl"; return 1; fi
    [[ ! -f "$tmp" ]] && { log "ERROR: ${name} download failed"; return 1; }
    local sz=$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp" 2>/dev/null || echo 0)
    if [[ "$GEO_VERIFY" == "true" && $sz -lt 102400 ]]; then
        log "ERROR: ${name} too small (${sz}B)"; rm -f "$tmp"; return 1; fi
    mv -f "$tmp" "$dest"
    log "OK: ${name} updated ($(awk "BEGIN{printf \"%.1f\",${sz}/1048576}")MB)"
}
log "Starting GeoData update [source: ${GEO_SOURCE}]"
updated=0
download "$IP_URL" "${CONFIG_DIR}/geoip.dat" "geoip.dat" && updated=1
download "$SITE_URL" "${CONFIG_DIR}/geosite.dat" "geosite.dat" && updated=1
if [[ $updated -eq 1 && "$GEO_AUTO_RESTART" == "true" ]]; then
    systemctl restart "$SERVICE_NAME" 2>/dev/null && log "XrayR restarted" || log "ERROR: restart failed"
fi
log "GeoData update done"
tail -200 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
GEOEOF
    chmod +x "${INSTALL_DIR}/geo-update.sh"
    (crontab -l 2>/dev/null; echo "30 4 * * 2,5 ${INSTALL_DIR}/geo-update.sh >/dev/null 2>&1") | crontab -
    print_ok "GeoData 定时更新已安装 (每周二/五 04:30)"
}

register_command() {
    cp -f "${INSTALL_DIR}/xrayr-manager.sh" "${COMMAND_LINK}"
    chmod +x "${COMMAND_LINK}"
    print_ok "命令 'xrayr' 已注册"
}

# ==================== 卸载 ====================
uninstall() {
    check_root
    [[ ! -f "${INSTALL_DIR}/XrayR" ]] && { print_error "XrayR 未安装"; exit 1; }
    echo -e "${RED}${BOLD}即将完全卸载 XrayR!${NC}"
    read -rp "确认? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    systemctl disable ${SERVICE_NAME} 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service.d/limits.conf"
    rmdir "/etc/systemd/system/${SERVICE_NAME}.service.d" 2>/dev/null || true
    systemctl daemon-reload

    rm -rf "${INSTALL_DIR}"
    rm -f "${COMMAND_LINK}"
    rm -f /etc/logrotate.d/xrayr
    rm -f /etc/systemd/journald.conf.d/xrayr-limits.conf
    crontab -l 2>/dev/null | grep -v "geo-update" | crontab - 2>/dev/null
    rm -f /var/log/xrayr-geo-update.log

    read -rp "是否删除配置文件 (${CONFIG_DIR})? [y/N]: " del_conf
    if [[ "$del_conf" == "y" || "$del_conf" == "Y" ]]; then
        rm -rf "${CONFIG_DIR}"
        print_ok "配置已删除"
    fi

    print_ok "XrayR 卸载完成"
}

# ==================== 升级 ====================
upgrade() {
    check_root
    local arch version
    arch=$(get_arch)
    version=$(get_latest_version)
    print_info "当前最新版本: ${version}"

    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    download_binary "$version" "$arch"
    download_manager_scripts "$version"
    register_command
    systemctl start ${SERVICE_NAME} 2>/dev/null
    print_ok "升级到 ${version} 完成!"
}

# ==================== 安装 ====================
install() {
    check_root

    if [[ -f "${INSTALL_DIR}/XrayR" ]]; then
        print_warn "XrayR 已安装"
        read -rp "是否覆盖安装? [y/N]: " overwrite
        [[ "$overwrite" != "y" && "$overwrite" != "Y" ]] && exit 0
        systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    fi

    local arch version
    arch=$(get_arch)
    version=$(get_latest_version)

    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║      XrayR 一键安装 ${version}       ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  架构: ${GREEN}${arch}${NC}  版本: ${GREEN}${version}${NC}"
    echo ""

    download_binary "$version" "$arch"
    download_manager_scripts "$version"
    install_config_files
    install_geodata
    install_systemd_service
    install_log_limits
    install_geo_cron
    register_command

    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  XrayR ${version} 安装成功!${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
    echo ""
    echo -e "  管理命令: ${GREEN}xrayr${NC}"
    echo -e "  配置文件: ${CYAN}${CONFIG_DIR}/config.yml${NC}"
    echo -e "  ${YELLOW}请编辑配置后运行: xrayr start${NC}"
    echo ""
}

# ==================== 主入口 ====================
case "${1:-}" in
    uninstall) uninstall ;;
    upgrade|update) upgrade ;;
    *) install ;;
esac
