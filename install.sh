#!/bin/bash
#
# XrayR 管理工具 (公开发布版)
# 用法: bash <(curl -sL https://raw.githubusercontent.com/sdars/xrayr-release/main/install.sh)
#
# 注意: 全脚本不使用 set -e。
# 原因: [[ cond ]] && { ... } 作为函数最后一条语句时, 条件为假会返回 1,
#       在 set -e 下会静默杀死整个脚本。本脚本统一使用 if 块规避。
#

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

REPO="sdars/xrayr-release"
INSTALL_DIR="/usr/local/XrayR"
CONFIG_DIR="/etc/XrayR"
SERVICE_NAME="XrayR"
SERVICE_FILE="/etc/systemd/system/XrayR.service"
COMMAND_LINK="/usr/local/bin/xrayr"

DEFAULT_GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
DEFAULT_GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
ALT_GEOIP_URL="https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
ALT_GEOSITE_URL="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
METACUBEX_GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"
METACUBEX_GEOSITE_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"
SOFFCHEN_GEOIP_URL="https://github.com/soffchen/merged/releases/latest/download/geoip.dat"
SOFFCHEN_GEOSITE_URL="https://github.com/soffchen/merged/releases/latest/download/geosite.dat"

print_info()  { echo -e "${BLUE}[信息]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[成功]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }

pause() {
    echo ""
    if [[ -t 0 ]]; then
        read -erp "  按回车继续..." _ || true
    fi
    return 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "请使用 root 运行"
        exit 1
    fi
    return 0
}

# ==================== 依赖管理 ====================
PKG_MGR=""
PKG_UPDATED=0

detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MGR="pacman"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MGR="zypper"
    else
        PKG_MGR=""
    fi
    return 0
}

pkg_update_once() {
    if [[ $PKG_UPDATED -eq 1 ]]; then
        return 0
    fi
    case "$PKG_MGR" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 ;;
        apk)    apk update >/dev/null 2>&1 ;;
        pacman) pacman -Sy --noconfirm >/dev/null 2>&1 ;;
    esac
    PKG_UPDATED=1
    return 0
}

pkg_install() {
    local pkg="$1"
    if [[ -z "$PKG_MGR" ]]; then
        return 1
    fi
    pkg_update_once
    case "$PKG_MGR" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1 ;;
        dnf)    dnf install -y -q "$pkg" >/dev/null 2>&1 ;;
        yum)    yum install -y -q "$pkg" >/dev/null 2>&1 ;;
        apk)    apk add --no-cache "$pkg" >/dev/null 2>&1 ;;
        pacman) pacman -S --noconfirm --needed "$pkg" >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive install -y "$pkg" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
    return $?
}

# 依赖表: 命令名 -> 各发行版包名
# 格式: cmd|apt包|rpm包|apk包|arch包
DEPS_TABLE="
curl|curl|curl|curl|curl
wget|wget|wget|wget|wget
crontab|cron|cronie|dcron|cronie
logrotate|logrotate|logrotate|logrotate|logrotate
python3|python3|python3|python3|python
tar|tar|tar|tar|tar
awk|gawk|gawk|gawk|gawk
openssl|openssl|openssl|openssl|openssl
"

resolve_pkg_name() {
    local cmd="$1" line apt_p rpm_p apk_p arch_p
    while IFS="|" read -r line apt_p rpm_p apk_p arch_p; do
        if [[ "$line" == "$cmd" ]]; then
            case "$PKG_MGR" in
                apt)            echo "$apt_p"; return 0 ;;
                dnf|yum|zypper) echo "$rpm_p"; return 0 ;;
                apk)            echo "$apk_p"; return 0 ;;
                pacman)         echo "$arch_p"; return 0 ;;
            esac
        fi
    done <<< "$DEPS_TABLE"
    echo "$cmd"
    return 0
}

install_dependencies() {
    print_info "检查依赖..."
    detect_pkg_mgr
    if [[ -z "$PKG_MGR" ]]; then
        print_warn "未识别包管理器, 跳过依赖自动安装"
        return 0
    fi

    local missing=() cmd pkg
    for cmd in curl wget crontab logrotate python3 tar awk openssl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        print_ok "依赖已齐全"
        return 0
    fi

    print_warn "缺少依赖: ${missing[*]}"
    for cmd in "${missing[@]}"; do
        pkg="$(resolve_pkg_name "$cmd")"
        echo -ne "  安装 ${CYAN}${pkg}${NC} (提供 ${cmd}) ... "
        if pkg_install "$pkg"; then
            if command -v "$cmd" >/dev/null 2>&1; then
                echo -e "${GREEN}成功${NC}"
            else
                echo -e "${YELLOW}已装包但命令仍缺失${NC}"
            fi
        else
            echo -e "${RED}失败${NC}"
        fi
    done

    # cron 服务需要启动
    if command -v crontab >/dev/null 2>&1; then
        local cron_svc=""
        for cron_svc in cron crond cronie; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${cron_svc}\.service"; then
                systemctl enable --now "$cron_svc" >/dev/null 2>&1
                break
            fi
        done
    fi
    return 0
}

# ==================== 版本与架构 ====================
get_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  echo "amd64"; return 0 ;;
        aarch64|arm64) echo "arm64"; return 0 ;;
        *)             echo ""; return 1 ;;
    esac
}

get_latest_version() {
    local ver
    ver="$(curl -sL --max-time 15 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)"
    if [[ -z "$ver" ]]; then
        return 1
    fi
    echo "$ver"
    return 0
}

get_installed_version() {
    if [[ -x "${INSTALL_DIR}/XrayR" ]]; then
        "${INSTALL_DIR}/XrayR" version 2>/dev/null | head -1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
    return 0
}

# ==================== 下载 ====================
download_binary() {
    local version="$1" arch="$2"
    local url="https://github.com/${REPO}/releases/download/${version}/XrayR-linux-${arch}"
    local dest="${INSTALL_DIR}/XrayR"

    print_info "下载 XrayR ${version} (linux-${arch})..."
    mkdir -p "${INSTALL_DIR}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSLo "${dest}.tmp" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${dest}.tmp" "$url"
    else
        print_error "需要 curl 或 wget"
        return 1
    fi

    local sz=0
    if [[ -f "${dest}.tmp" ]]; then
        sz="$(stat -c%s "${dest}.tmp" 2>/dev/null || stat -f%z "${dest}.tmp" 2>/dev/null || echo 0)"
    fi
    if [[ "$sz" -lt 1000000 ]]; then
        print_error "下载失败或文件异常 (${sz} bytes)"
        rm -f "${dest}.tmp"
        return 1
    fi

    mv -f "${dest}.tmp" "$dest"
    chmod +x "$dest"
    print_ok "二进制安装完成 ($(awk "BEGIN{printf \"%.1f\", ${sz}/1048576}")MB)"
    return 0
}

download_manager_scripts() {
    local version="$1"
    local rel_base="https://github.com/${REPO}/releases/download/${version}"
    local raw_base="https://raw.githubusercontent.com/${REPO}/main"
    local f

    print_info "下载管理脚本..."
    for f in xrayr-manager.sh config_helper.py; do
        if command -v curl >/dev/null 2>&1; then
            curl -fsSLo "${INSTALL_DIR}/${f}" "${rel_base}/${f}" 2>/dev/null \
                || curl -fsSLo "${INSTALL_DIR}/${f}" "${raw_base}/${f}" 2>/dev/null
        else
            wget -qO "${INSTALL_DIR}/${f}" "${rel_base}/${f}" 2>/dev/null \
                || wget -qO "${INSTALL_DIR}/${f}" "${raw_base}/${f}" 2>/dev/null
        fi
    done

    if [[ -s "${INSTALL_DIR}/xrayr-manager.sh" ]]; then
        chmod +x "${INSTALL_DIR}/xrayr-manager.sh"
        chmod +x "${INSTALL_DIR}/config_helper.py" 2>/dev/null
        print_ok "管理脚本已就绪"
    else
        print_warn "管理脚本下载失败, xrayr 命令将不可用"
    fi
    return 0
}

# ==================== 配置文件 ====================
install_config_files() {
    mkdir -p "${CONFIG_DIR}" "${CONFIG_DIR}/cert"

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
        print_info "配置文件已存在, 保留"
    fi

    if [[ ! -f "${CONFIG_DIR}/route.json" ]]; then
        cat > "${CONFIG_DIR}/route.json" << 'ROUTEEOF'
{
  "domainStrategy": "IPIfNonMatch",
  "rules": [
    { "type": "field", "outboundTag": "block", "ip": ["geoip:private"] },
    { "type": "field", "outboundTag": "block", "protocol": ["bittorrent"] }
  ]
}
ROUTEEOF
    fi

    if [[ ! -f "${CONFIG_DIR}/dns.json" ]]; then
        cat > "${CONFIG_DIR}/dns.json" << 'DNSEOF'
{
  "servers": ["1.1.1.1", "8.8.8.8", "localhost"],
  "tag": "dns_inbound"
}
DNSEOF
    fi

    if [[ ! -f "${CONFIG_DIR}/custom_outbound.json" ]]; then
        cat > "${CONFIG_DIR}/custom_outbound.json" << 'OBEOF'
[
  { "tag": "IPv4_out", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
  { "tag": "block", "protocol": "blackhole", "settings": {} }
]
OBEOF
    fi

    if [[ ! -f "${CONFIG_DIR}/custom_inbound.json" ]]; then
        cat > "${CONFIG_DIR}/custom_inbound.json" << 'IBEOF'
[]
IBEOF
    fi

    if [[ ! -f "${CONFIG_DIR}/rulelist" ]]; then
        echo "# 自定义规则列表 (每行一条)" > "${CONFIG_DIR}/rulelist"
    fi
    return 0
}

# ==================== GeoData ====================
install_geodata() {
    local interactive="${1:-1}"
    local GEOIP_URL="$DEFAULT_GEOIP_URL"
    local GEOSITE_URL="$DEFAULT_GEOSITE_URL"
    local geo_choice=""

    if [[ "$interactive" == "1" ]]; then
        echo ""
        echo -e "  ${CYAN}${BOLD}选择 GeoData 数据源:${NC}"
        echo -e "  ${GREEN}1)${NC} Loyalsoldier  ${DIM}(推荐, 规则全面)${NC}"
        echo -e "  ${GREEN}2)${NC} v2fly 社区    ${DIM}(原版 v2ray 规则)${NC}"
        echo -e "  ${GREEN}3)${NC} MetaCubeX     ${DIM}(Clash Meta 规则)${NC}"
        echo -e "  ${GREEN}4)${NC} soffchen      ${DIM}(合并规则)${NC}"
        echo ""
        read -erp "  请选择 [1-4, 默认=1]: " geo_choice
    fi

    case "$geo_choice" in
        2) GEOIP_URL="$ALT_GEOIP_URL";       GEOSITE_URL="$ALT_GEOSITE_URL" ;;
        3) GEOIP_URL="$METACUBEX_GEOIP_URL"; GEOSITE_URL="$METACUBEX_GEOSITE_URL" ;;
        4) GEOIP_URL="$SOFFCHEN_GEOIP_URL";  GEOSITE_URL="$SOFFCHEN_GEOSITE_URL" ;;
        *) GEOIP_URL="$DEFAULT_GEOIP_URL";   GEOSITE_URL="$DEFAULT_GEOSITE_URL" ;;
    esac

    print_info "下载 GeoData..."
    local ok1=0 ok2=0
    if command -v curl >/dev/null 2>&1; then
        curl -fsSLo "${CONFIG_DIR}/geoip.dat"   "$GEOIP_URL"   && ok1=1
        curl -fsSLo "${CONFIG_DIR}/geosite.dat" "$GEOSITE_URL" && ok2=1
    else
        wget -qO "${CONFIG_DIR}/geoip.dat"   "$GEOIP_URL"   && ok1=1
        wget -qO "${CONFIG_DIR}/geosite.dat" "$GEOSITE_URL" && ok2=1
    fi
    if [[ $ok1 -eq 1 ]]; then print_ok "geoip.dat"; else print_warn "geoip.dat 下载失败"; fi
    if [[ $ok2 -eq 1 ]]; then print_ok "geosite.dat"; else print_warn "geosite.dat 下载失败"; fi

    # 保存数据源选择
    cat > "${CONFIG_DIR}/geodata.conf" << GEOCONFEOF
GEO_SOURCE="$(case "$geo_choice" in 2) echo v2fly ;; 3) echo metacubex ;; 4) echo soffchen ;; *) echo loyalsoldier ;; esac)"
GEO_AUTO_UPDATE="true"
GEO_CRON="30 4 * * 2,5"
GEO_AUTO_RESTART="true"
GEO_VERIFY="true"
GEOCONFEOF
    return 0
}

# ==================== systemd ====================
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
    systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
    print_ok "systemd 服务已创建"
    return 0
}

# ==================== 日志限制 ====================
install_log_limits() {
    print_info "安装日志大小限制..."

    if ! command -v logrotate >/dev/null 2>&1; then
        detect_pkg_mgr
        pkg_install "logrotate"
    fi

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
    systemctl restart systemd-journald >/dev/null 2>&1

    mkdir -p "/etc/systemd/system/${SERVICE_NAME}.service.d"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service.d/limits.conf" << 'SDEOF'
[Service]
LogRateLimitIntervalSec=30s
LogRateLimitBurst=5000
SDEOF
    systemctl daemon-reload
    print_ok "日志限制已安装 (access/error 10M×7, geo 2M×4, journal 200M)"
    return 0
}

# ==================== GeoData 定时更新 ====================
install_geo_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        print_warn "crontab 不可用, 尝试安装..."
        detect_pkg_mgr
        pkg_install "$(resolve_pkg_name crontab)"
        local cron_svc=""
        for cron_svc in cron crond cronie; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${cron_svc}\.service"; then
                systemctl enable --now "$cron_svc" >/dev/null 2>&1
                break
            fi
        done
    fi

    if ! command -v crontab >/dev/null 2>&1; then
        print_warn "crontab 仍不可用, 改用 systemd timer"
        install_geo_timer
        return 0
    fi

    cat > "${INSTALL_DIR}/geo-update.sh" << 'GEOEOF'
#!/bin/bash
CONFIG_DIR="/etc/XrayR"
GEO_CONFIG_FILE="/etc/XrayR/geodata.conf"
LOG="/var/log/xrayr-geo-update.log"
SERVICE_NAME="XrayR"
D_IP="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
D_SITE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
V_IP="https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
V_SITE="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
M_IP="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"
M_SITE="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"
S_IP="https://github.com/soffchen/merged/releases/latest/download/geoip.dat"
S_SITE="https://github.com/soffchen/merged/releases/latest/download/geosite.dat"
GEO_SOURCE="loyalsoldier"
GEO_AUTO_RESTART="true"
GEO_VERIFY="true"
if [[ -f "$GEO_CONFIG_FILE" ]]; then
    source "$GEO_CONFIG_FILE"
fi
case "$GEO_SOURCE" in
    v2fly)     IP_URL="$V_IP"; SITE_URL="$V_SITE" ;;
    metacubex) IP_URL="$M_IP"; SITE_URL="$M_SITE" ;;
    soffchen)  IP_URL="$S_IP"; SITE_URL="$S_SITE" ;;
    *)         IP_URL="$D_IP"; SITE_URL="$D_SITE" ;;
esac
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }
fetch() {
    local url="$1" dest="$2" name="$3" tmp="${2}.tmp"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSLo "$tmp" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp" "$url"
    else
        log "ERROR: no curl/wget"
        return 1
    fi
    if [[ ! -f "$tmp" ]]; then
        log "ERROR: ${name} download failed"
        return 1
    fi
    local sz
    sz="$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp" 2>/dev/null || echo 0)"
    if [[ "$GEO_VERIFY" == "true" ]] && [[ "$sz" -lt 102400 ]]; then
        log "ERROR: ${name} too small (${sz}B)"
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$dest"
    log "OK: ${name} updated ($(awk "BEGIN{printf \"%.1f\", ${sz}/1048576}")MB)"
    return 0
}
log "start [source=${GEO_SOURCE}]"
updated=0
fetch "$IP_URL"   "${CONFIG_DIR}/geoip.dat"   "geoip.dat"   && updated=1
fetch "$SITE_URL" "${CONFIG_DIR}/geosite.dat" "geosite.dat" && updated=1
if [[ $updated -eq 1 ]] && [[ "$GEO_AUTO_RESTART" == "true" ]]; then
    if systemctl restart "$SERVICE_NAME" 2>/dev/null; then
        log "XrayR restarted"
    else
        log "ERROR: restart failed"
    fi
fi
log "done"
tail -200 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG"
GEOEOF
    chmod +x "${INSTALL_DIR}/geo-update.sh"

    if crontab -l 2>/dev/null | grep -q "geo-update.sh"; then
        print_info "GeoData 定时更新已存在"
    else
        (crontab -l 2>/dev/null; echo "30 4 * * 2,5 ${INSTALL_DIR}/geo-update.sh >/dev/null 2>&1") | crontab -
        print_ok "GeoData 定时更新已安装 (每周二/五 04:30)"
    fi
    return 0
}

install_geo_timer() {
    cat > /etc/systemd/system/xrayr-geo-update.service << 'TSEOF'
[Unit]
Description=XrayR GeoData Update
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/XrayR/geo-update.sh
TSEOF
    cat > /etc/systemd/system/xrayr-geo-update.timer << 'TTEOF'
[Unit]
Description=XrayR GeoData Update Timer

[Timer]
OnCalendar=Tue,Fri 04:30
Persistent=true

[Install]
WantedBy=timers.target
TTEOF
    systemctl daemon-reload
    systemctl enable --now xrayr-geo-update.timer >/dev/null 2>&1
    print_ok "GeoData systemd timer 已启用 (每周二/五 04:30)"
    return 0
}

register_command() {
    if [[ -s "${INSTALL_DIR}/xrayr-manager.sh" ]]; then
        cp -f "${INSTALL_DIR}/xrayr-manager.sh" "${COMMAND_LINK}"
        chmod +x "${COMMAND_LINK}"
        print_ok "命令 ${GREEN}xrayr${NC} 已注册"
    else
        print_warn "管理脚本缺失, 跳过命令注册"
    fi
    return 0
}

# ==================== 状态检测 ====================
is_installed() {
    if [[ -x "${INSTALL_DIR}/XrayR" ]]; then
        return 0
    fi
    return 1
}

svc_state() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo "none"
        return 0
    fi
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
    return 0
}

svc_autostart() {
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "on"
    else
        echo "off"
    fi
    return 0
}

geo_conf_get() {
    local key="$1" def="$2" val=""
    if [[ -f "${CONFIG_DIR}/geodata.conf" ]]; then
        val="$(grep -E "^${key}=" "${CONFIG_DIR}/geodata.conf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d \")"
    fi
    if [[ -z "$val" ]]; then
        val="$def"
    fi
    echo "$val"
    return 0
}

geo_conf_set() {
    local key="$1" val="$2"
    mkdir -p "${CONFIG_DIR}"
    touch "${CONFIG_DIR}/geodata.conf"
    if grep -qE "^${key}=" "${CONFIG_DIR}/geodata.conf" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "${CONFIG_DIR}/geodata.conf"
    else
        echo "${key}=\"${val}\"" >> "${CONFIG_DIR}/geodata.conf"
    fi
    return 0
}

geo_source_name() {
    case "$1" in
        v2fly)     echo "v2fly 社区 (原版)" ;;
        metacubex) echo "MetaCubeX (Clash Meta)" ;;
        soffchen)  echo "soffchen (合并规则)" ;;
        custom)    echo "自定义 URL" ;;
        *)         echo "Loyalsoldier (推荐)" ;;
    esac
    return 0
}

file_size_h() {
    local f="$1" sz=0
    if [[ -f "$f" ]]; then
        sz="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)"
        echo "$(awk "BEGIN{printf \"%.1f\", ${sz}/1048576}")MB"
    else
        echo "缺失"
    fi
    return 0
}

geo_schedule_desc() {
    local line=""
    if command -v crontab >/dev/null 2>&1; then
        line="$(crontab -l 2>/dev/null | grep "geo-update.sh" | head -1)"
        if [[ -n "$line" ]]; then
            echo "cron: $(echo "$line" | cut -d\  -f1-5)"
            return 0
        fi
    fi
    if systemctl is-enabled --quiet xrayr-geo-update.timer 2>/dev/null; then
        echo "systemd timer (已启用)"
        return 0
    fi
    echo "未启用"
    return 0
}

# ==================== 横幅与状态面板 ====================
show_banner() {
    if [[ -t 1 ]]; then
        clear 2>/dev/null
    fi
    echo ""
    echo -e "${CYAN}${BOLD}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}  ║          XrayR 安装管理工具  ·  中文面板         ║${NC}"
    echo -e "${CYAN}${BOLD}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    return 0
}

show_status_block() {
    local ver state auto src
    if is_installed; then
        ver="$(get_installed_version)"
        if [[ -z "$ver" ]]; then
            ver="未知"
        fi
        echo -e "   安装状态   ${GREEN}已安装${NC}    程序版本  ${GREEN}${ver}${NC}"
    else
        echo -e "   安装状态   ${YELLOW}未安装${NC}"
    fi

    state="$(svc_state)"
    auto="$(svc_autostart)"
    case "$state" in
        running) echo -e "   运行状态   ${GREEN}运行中${NC}" ;;
        stopped) echo -e "   运行状态   ${RED}已停止${NC}" ;;
        *)       echo -e "   运行状态   ${DIM}服务未注册${NC}" ;;
    esac
    if [[ "$auto" == "on" ]]; then
        echo -e "   开机自启   ${GREEN}已启用${NC}"
    else
        echo -e "   开机自启   ${YELLOW}未启用${NC}"
    fi

    if is_installed; then
        src="$(geo_conf_get GEO_SOURCE loyalsoldier)"
        echo -e "   Geo 数据源 ${CYAN}$(geo_source_name "$src")${NC}"
        echo -e "   Geo 文件   geoip $(file_size_h "${CONFIG_DIR}/geoip.dat") / geosite $(file_size_h "${CONFIG_DIR}/geosite.dat")"
        echo -e "   定时更新   $(geo_schedule_desc)"
        if [[ -x "$COMMAND_LINK" ]]; then
            echo -e "   管理命令   ${GREEN}xrayr${NC} (已注册)"
        else
            echo -e "   管理命令   ${YELLOW}未注册${NC}"
        fi
        echo -e "   配置目录   ${CYAN}${CONFIG_DIR}${NC}"
    fi
    echo ""
    return 0
}


# ==================== 安装 / 升级 / 卸载 ====================
do_install() {
    local interactive="${1:-1}"
    check_root

    if is_installed && [[ "$interactive" == "1" ]]; then
        local ver_now choice
        ver_now="$(get_installed_version)"
        echo ""
        print_warn "检测到 XrayR 已安装 (版本: ${ver_now:-未知})"
        echo ""
        echo -e "   ${GREEN}1)${NC} 覆盖安装 (保留现有配置)"
        echo -e "   ${GREEN}2)${NC} 升级到最新版本"
        echo -e "   ${GREEN}3)${NC} 全新安装 (重置配置文件)"
        echo -e "   ${GREEN}0)${NC} 返回"
        echo ""
        read -erp "   请选择 [0-3, 默认=1]: " choice
        case "$choice" in
            0) print_info "已取消"; return 0 ;;
            2) do_upgrade; return 0 ;;
            3) RESET_CONFIG=1 ;;
            *) RESET_CONFIG=0 ;;
        esac
    fi

    install_dependencies

    local arch version
    arch="$(get_arch)"
    if [[ -z "$arch" ]]; then
        print_error "不支持的系统架构: $(uname -m)"
        return 1
    fi
    version="$(get_latest_version)"
    if [[ -z "$version" ]]; then
        print_warn "无法获取最新版本号, 回退使用 v0.9.5"
        version="v0.9.5"
    fi

    echo ""
    echo -e "${CYAN}${BOLD}  ────────────  开始安装 XrayR ${version}  ────────────${NC}"
    echo -e "   系统架构: ${GREEN}${arch}${NC}   目标版本: ${GREEN}${version}${NC}"
    echo ""

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1

    if ! download_binary "$version" "$arch"; then
        print_error "二进制下载失败, 安装中止"
        return 1
    fi
    download_manager_scripts "$version"

    if [[ "${RESET_CONFIG:-0}" == "1" ]]; then
        print_warn "重置配置文件..."
        rm -f "${CONFIG_DIR}/config.yml" "${CONFIG_DIR}/route.json" "${CONFIG_DIR}/dns.json" \
              "${CONFIG_DIR}/custom_outbound.json" "${CONFIG_DIR}/custom_inbound.json"
    fi
    install_config_files
    install_geodata "$interactive"
    install_systemd_service
    install_log_limits
    install_geo_cron
    register_command

    echo ""
    echo -e "${GREEN}${BOLD}  ══════════  XrayR ${version} 安装完成  ══════════${NC}"
    echo ""
    echo -e "   管理面板命令 : ${GREEN}${BOLD}xrayr${NC}"
    echo -e "   主配置文件   : ${CYAN}${CONFIG_DIR}/config.yml${NC}"
    echo -e "   下一步       : ${YELLOW}运行 xrayr 进入面板配置对接信息, 再启动服务${NC}"
    echo ""
    RESET_CONFIG=0
    return 0
}

do_upgrade() {
    check_root
    if ! is_installed; then
        print_error "XrayR 未安装, 请先执行安装"
        return 1
    fi
    install_dependencies

    local arch version cur
    arch="$(get_arch)"
    cur="$(get_installed_version)"
    version="$(get_latest_version)"
    if [[ -z "$version" ]]; then
        print_error "无法获取最新版本号 (网络问题?)"
        return 1
    fi
    echo ""
    echo -e "   当前版本: ${YELLOW}${cur:-未知}${NC}   最新版本: ${GREEN}${version}${NC}"
    if [[ -n "$cur" ]] && [[ "$cur" == "$version" ]]; then
        print_ok "已经是最新版本"
        return 0
    fi

    local was_running=0
    if [[ "$(svc_state)" == "running" ]]; then
        was_running=1
    fi
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1

    if ! download_binary "$version" "$arch"; then
        print_error "升级失败, 保持原版本"
        if [[ $was_running -eq 1 ]]; then
            systemctl start "$SERVICE_NAME" >/dev/null 2>&1
        fi
        return 1
    fi
    download_manager_scripts "$version"
    install_systemd_service
    install_log_limits
    register_command

    if [[ $was_running -eq 1 ]]; then
        systemctl start "$SERVICE_NAME" >/dev/null 2>&1
    fi
    print_ok "已升级到 ${version}"
    return 0
}

do_uninstall() {
    check_root
    if ! is_installed && [[ ! -f "$SERVICE_FILE" ]]; then
        print_error "XrayR 未安装, 无需卸载"
        return 1
    fi

    echo ""
    echo -e "${RED}${BOLD}   即将卸载 XrayR (程序 / 服务 / 命令 / 定时任务 / 日志规则)${NC}"
    echo ""
    local confirm=""
    read -erp "   确认卸载请输入 yes : " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "已取消卸载"
        return 0
    fi

    print_info "停止并注销服务..."
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$SERVICE_FILE"
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service.d/limits.conf"
    rmdir "/etc/systemd/system/${SERVICE_NAME}.service.d" 2>/dev/null
    systemctl stop xrayr-geo-update.timer >/dev/null 2>&1
    systemctl disable xrayr-geo-update.timer >/dev/null 2>&1
    rm -f /etc/systemd/system/xrayr-geo-update.timer /etc/systemd/system/xrayr-geo-update.service
    systemctl daemon-reload >/dev/null 2>&1
    print_ok "服务已注销"

    print_info "删除程序文件..."
    rm -rf "$INSTALL_DIR"
    print_ok "程序目录已删除"

    print_info "注销 xrayr 命令..."
    rm -f "$COMMAND_LINK" /usr/bin/xrayr
    hash -r 2>/dev/null
    print_ok "命令已注销"

    print_info "清理定时任务与日志规则..."
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "geo-update" | crontab - >/dev/null 2>&1
    fi
    rm -f /etc/logrotate.d/xrayr
    rm -f /etc/systemd/journald.conf.d/xrayr-limits.conf
    rm -f /var/log/xrayr-geo-update.log
    systemctl restart systemd-journald >/dev/null 2>&1
    print_ok "定时任务与日志规则已清理"

    local del_conf=""
    echo ""
    read -erp "   是否同时删除配置目录 ${CONFIG_DIR} ? [y/N]: " del_conf
    if [[ "$del_conf" == "y" ]] || [[ "$del_conf" == "Y" ]]; then
        rm -rf "$CONFIG_DIR"
        print_ok "配置目录已删除"
    else
        print_info "配置目录已保留: ${CONFIG_DIR}"
    fi

    echo ""
    print_ok "XrayR 卸载完成"
    return 0
}

# ==================== 服务控制 ====================
menu_service() {
    while true; do
        show_banner
        echo -e "${BOLD}   服务控制${NC}"
        echo ""
        show_status_block
        echo -e "   ${GREEN}1)${NC} 启动服务          ${GREEN}2)${NC} 停止服务"
        echo -e "   ${GREEN}3)${NC} 重启服务          ${GREEN}4)${NC} 查看运行状态"
        echo -e "   ${GREEN}5)${NC} 启用开机自启      ${GREEN}6)${NC} 关闭开机自启"
        echo -e "   ${GREEN}7)${NC} 查看实时日志      ${GREEN}8)${NC} 查看最近 100 行日志"
        echo -e "   ${GREEN}0)${NC} 返回上级菜单"
        echo ""
        local c=""
        if ! read -erp "   请选择 [0-8]: " c; then
            echo ""
            print_info "输入已结束, 返回"
            return 0
        fi
        case "$c" in
            1) systemctl start "$SERVICE_NAME" && print_ok "已启动" || print_error "启动失败"; pause ;;
            2) systemctl stop "$SERVICE_NAME" && print_ok "已停止" || print_error "停止失败"; pause ;;
            3) systemctl restart "$SERVICE_NAME" && print_ok "已重启" || print_error "重启失败"; pause ;;
            4) systemctl status "$SERVICE_NAME" --no-pager -l 2>&1 | head -30; pause ;;
            5) systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 && print_ok "开机自启已启用"; pause ;;
            6) systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 && print_ok "开机自启已关闭"; pause ;;
            7) echo -e "   ${DIM}Ctrl+C 退出日志查看${NC}"; journalctl -u "$SERVICE_NAME" -f --no-pager ;;
            8) journalctl -u "$SERVICE_NAME" -n 100 --no-pager 2>&1 | tail -100; pause ;;
            0) return 0 ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

# ==================== GeoData 菜单 ====================
menu_geodata() {
    while true
    do
        show_banner
        echo -e "${BOLD}   GeoData 数据管理${NC}"
        echo ""
        echo -e "   当前数据源 : ${CYAN}$(geo_source_name "$(geo_conf_get GEO_SOURCE loyalsoldier)")${NC}"
        echo -e "   geoip.dat  : $(file_size_h "${CONFIG_DIR}/geoip.dat")"
        echo -e "   geosite.dat: $(file_size_h "${CONFIG_DIR}/geosite.dat")"
        echo -e "   定时更新   : $(geo_schedule_desc)"
        echo -e "   更新后重启 : $(geo_conf_get GEO_AUTO_RESTART true)"
        echo ""
        echo -e "   ${GREEN}1)${NC} 立即更新 GeoData"
        echo -e "   ${GREEN}2)${NC} 切换数据源"
        echo -e "   ${GREEN}3)${NC} 修改定时更新时间"
        echo -e "   ${GREEN}4)${NC} 关闭 / 开启定时更新"
        echo -e "   ${GREEN}5)${NC} 查看更新日志"
        echo -e "   ${GREEN}0)${NC} 返回上级菜单"
        echo ""
        local c=""
        if ! read -erp "   请选择 [0-5]: " c; then
            echo ""
            print_info "输入已结束, 返回"
            return 0
        fi
        case "$c" in
            1)
                if [[ -x "${INSTALL_DIR}/geo-update.sh" ]]; then
                    "${INSTALL_DIR}/geo-update.sh"
                    print_ok "更新任务已执行"
                    tail -6 /var/log/xrayr-geo-update.log 2>/dev/null
                else
                    install_geodata 0
                fi
                pause ;;
            2)
                install_geodata 1
                pause ;;
            3)
                local newcron=""
                echo ""
                echo -e "   ${DIM}cron 格式: 分 时 日 月 周   例: 30 4 * * 2,5 (每周二/五 04:30)${NC}"
                read -erp "   输入新的 cron 表达式: " newcron
                if [[ -z "$newcron" ]]; then
                    print_warn "未输入, 取消"
                else
                    geo_conf_set GEO_CRON "$newcron"
                    if command -v crontab >/dev/null 2>&1; then
                        (crontab -l 2>/dev/null | grep -v "geo-update.sh"; echo "${newcron} ${INSTALL_DIR}/geo-update.sh >/dev/null 2>&1") | crontab -
                        print_ok "定时更新已改为: ${newcron}"
                    else
                        print_warn "crontab 不可用, 请使用 systemd timer 方式"
                    fi
                fi
                pause ;;
            4)
                if [[ "$(geo_schedule_desc)" == "未启用" ]]; then
                    install_geo_cron
                    geo_conf_set GEO_AUTO_UPDATE true
                else
                    if command -v crontab >/dev/null 2>&1; then
                        crontab -l 2>/dev/null | grep -v "geo-update.sh" | crontab - >/dev/null 2>&1
                    fi
                    systemctl disable --now xrayr-geo-update.timer >/dev/null 2>&1
                    geo_conf_set GEO_AUTO_UPDATE false
                    print_ok "定时更新已关闭"
                fi
                pause ;;
            5)
                if [[ -f /var/log/xrayr-geo-update.log ]]; then
                    tail -40 /var/log/xrayr-geo-update.log
                else
                    print_info "暂无更新日志"
                fi
                pause ;;
            0) return 0 ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

# ==================== 依赖与工具 ====================
menu_tools() {
    while true
    do
        show_banner
        echo -e "${BOLD}   系统工具与维护${NC}"
        echo ""
        detect_pkg_mgr
        echo -e "   包管理器 : ${CYAN}${PKG_MGR:-未识别}${NC}"
        echo ""
        local cmd mark
        echo -e "   ${BOLD}依赖检查${NC}"
        for cmd in curl wget crontab logrotate python3 tar awk openssl systemctl
        do
            if command -v "$cmd" >/dev/null 2>&1; then
                mark="${GREEN}已安装${NC}"
            else
                mark="${RED}缺失${NC}"
            fi
            echo -e "     ${cmd}  ->  ${mark}"
        done
        echo ""
        echo -e "   ${GREEN}1)${NC} 自动安装缺失依赖"
        echo -e "   ${GREEN}2)${NC} 重新安装日志大小限制"
        echo -e "   ${GREEN}3)${NC} 重新注册 xrayr 命令"
        echo -e "   ${GREEN}4)${NC} 重新生成 systemd 服务"
        echo -e "   ${GREEN}5)${NC} 补齐缺失配置文件"
        echo -e "   ${GREEN}6)${NC} 查看磁盘 / 内存占用"
        echo -e "   ${GREEN}0)${NC} 返回上级菜单"
        echo ""
        local c=""
        if ! read -erp "   请选择 [0-6]: " c; then
            echo ""
            print_info "输入已结束, 返回"
            return 0
        fi
        case "$c" in
            1) install_dependencies; pause ;;
            2) install_log_limits; pause ;;
            3) register_command; pause ;;
            4) install_systemd_service; pause ;;
            5) install_config_files; print_ok "配置文件检查完成"; pause ;;
            6)
                echo ""
                df -h / 2>/dev/null | head -2
                echo ""
                free -h 2>/dev/null | head -3
                echo ""
                if [[ -d "$INSTALL_DIR" ]]; then
                    du -sh "$INSTALL_DIR" 2>/dev/null
                fi
                if [[ -d "$CONFIG_DIR" ]]; then
                    du -sh "$CONFIG_DIR" 2>/dev/null
                fi
                pause ;;
            0) return 0 ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

open_manager() {
    if [[ -x "$COMMAND_LINK" ]]; then
        "$COMMAND_LINK"
        return 0
    fi
    if [[ -x "${INSTALL_DIR}/xrayr-manager.sh" ]]; then
        "${INSTALL_DIR}/xrayr-manager.sh"
        return 0
    fi
    print_error "管理面板脚本缺失, 请先安装或在 [6] 中重新注册命令"
    pause
    return 1
}

# ==================== 主菜单 ====================
main_menu() {
    while true
    do
        show_banner
        show_status_block
        echo -e "${CYAN}  ──────────────────────────────────────────────────${NC}"
        if is_installed; then
            echo -e "   ${GREEN}1)${NC} 重新安装 / 覆盖安装      ${GREEN}2)${NC} 升级到最新版本"
        else
            echo -e "   ${GREEN}1)${NC} ${BOLD}安装 XrayR${NC}               ${GREEN}2)${NC} 升级到最新版本"
        fi
        echo -e "   ${GREEN}3)${NC} 卸载 XrayR               ${GREEN}4)${NC} 服务控制 (启停/日志)"
        echo -e "   ${GREEN}5)${NC} 打开 XrayR 管理面板      ${GREEN}6)${NC} GeoData 数据管理"
        echo -e "   ${GREEN}7)${NC} 系统工具与依赖维护       ${GREEN}8)${NC} 查看版本信息"
        echo -e "   ${GREEN}0)${NC} 退出"
        echo -e "${CYAN}  ──────────────────────────────────────────────────${NC}"
        echo ""
        local c=""
        if ! read -erp "   请输入选项 [0-8]: " c; then
            echo ""
            print_info "输入已结束, 退出"
            return 0
        fi
        case "$c" in
            1) do_install 1; pause ;;
            2) do_upgrade; pause ;;
            3) do_uninstall; pause ;;
            4) menu_service ;;
            5) open_manager ;;
            6) menu_geodata ;;
            7) menu_tools ;;
            8)
                echo ""
                echo -e "   已安装版本 : ${GREEN}$(get_installed_version)${NC}"
                echo -e "   仓库最新版 : ${GREEN}$(get_latest_version)${NC}"
                echo -e "   发布仓库   : ${CYAN}${REPO}${NC}"
                echo -e "   系统架构   : ${CYAN}$(get_arch)${NC}"
                if [[ -f /etc/os-release ]]; then
                    echo -e "   操作系统   : ${CYAN}$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d \")${NC}"
                fi
                pause ;;
            0) echo ""; print_info "已退出"; return 0 ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

show_help() {
    echo ""
    echo -e "${BOLD}XrayR 安装管理工具${NC}"
    echo ""
    echo -e "  用法: bash install.sh [子命令]"
    echo ""
    echo -e "  无参数         进入中文交互管理面板 (默认)"
    echo -e "  menu           同上, 进入管理面板"
    echo -e "  install        交互式安装"
    echo -e "  auto-install   非交互安装 (使用默认 Geo 数据源)"
    echo -e "  upgrade        升级到最新版本"
    echo -e "  uninstall      卸载"
    echo -e "  deps           仅检查并安装依赖"
    echo -e "  log-limit      仅安装日志大小限制"
    echo -e "  geo            仅更新 GeoData"
    echo -e "  status         打印当前状态"
    echo -e "  help           显示本帮助"
    echo ""
    return 0
}

# ==================== 主入口 ====================
# 默认进入管理面板, 不直接执行安装等破坏性操作
main() {
    check_root
    case "${1:-}" in
        ""|menu|panel)
            if [[ -t 0 ]]; then
                main_menu
            else
                print_warn "当前为非交互环境 (无终端输入), 不进入交互面板"
                echo ""
                show_status_block
                show_help
                echo -e "  ${DIM}提示: 非交互场景请使用 auto-install / upgrade / uninstall 等子命令${NC}"
            fi
            ;;
        install)
            do_install 1
            ;;
        auto-install|--auto|auto)
            do_install 0
            ;;
        upgrade|update)
            do_upgrade
            ;;
        uninstall|remove)
            do_uninstall
            ;;
        deps|dep)
            install_dependencies
            ;;
        log-limit|loglimit)
            install_log_limits
            ;;
        geo|geodata)
            if [[ -x "${INSTALL_DIR}/geo-update.sh" ]]; then
                "${INSTALL_DIR}/geo-update.sh"
                tail -6 /var/log/xrayr-geo-update.log 2>/dev/null
            else
                install_geodata 0
            fi
            ;;
        status)
            show_status_block
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            print_error "未知子命令: $1"
            show_help
            return 1
            ;;
    esac
    return 0
}

main "$@"
