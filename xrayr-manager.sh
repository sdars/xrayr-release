#!/bin/bash
#
# XrayR 管理面板
# 用法: xrayr [命令]
#

SERVICE_NAME="XrayR"
CONFIG_DIR="/etc/XrayR"
INSTALL_DIR="/usr/local/XrayR"
HELPER="${INSTALL_DIR}/config_helper.py"

# 管理脚本自身版本 (启动时按此比对远端, 有更新则静默升级)
MGR_VERSION="1.3.1"

# 更新检查相关 (与 install.sh 保持一致)
REPO="sdars/xrayr-release"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
UPDATE_CACHE_FILE="/var/lib/.xrayr-update-cache"
UPDATE_CACHE_TTL=3600

# ==================== init 系统抽象层 ====================
# 与 install.sh 同源逻辑, 覆盖 systemd / OpenRC / SysVinit / procd / 无 init。
INIT_SYS=""
SERVICE_FILE=""
BARE_PIDFILE="/var/run/xrayr.pid"
BARE_LOGFILE="/var/log/xrayr.log"

# 按 init 类型确定服务单元路径
_init_set_service_file() {
    case "$INIT_SYS" in
        systemd) SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service" ;;
        *)       SERVICE_FILE="/etc/init.d/${SERVICE_NAME}" ;;
    esac
    return 0
}

# 在当前 shell(非子 shell)完成 init 探测并同步 SERVICE_FILE。
# 必须用它而不是 $(detect_init), 否则 SERVICE_FILE 的赋值随子 shell 一起丢掉。
init_ready() {
    detect_init >/dev/null
    return 0
}

detect_init() {
    if [[ -n "$INIT_SYS" ]]; then
        echo "$INIT_SYS"
        return 0
    fi
    # 允许用 XRAYR_INIT 强制指定, 用于容器测试或探测失误时人工纠正
    if [[ -n "${XRAYR_INIT:-}" ]]; then
        case "$XRAYR_INIT" in
            systemd|openrc|sysvinit|procd|none)
                INIT_SYS="$XRAYR_INIT"
                _init_set_service_file
                echo "$INIT_SYS"
                return 0 ;;
        esac
    fi
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        INIT_SYS="systemd"
    elif [[ -f /etc/rc.common ]] && ( [[ -x /sbin/procd ]] || grep -qi openwrt /etc/os-release 2>/dev/null ); then
        INIT_SYS="procd"
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        INIT_SYS="openrc"
    elif [[ -d /etc/init.d ]] && ( command -v service >/dev/null 2>&1 || command -v update-rc.d >/dev/null 2>&1 || command -v chkconfig >/dev/null 2>&1 ); then
        INIT_SYS="sysvinit"
    elif command -v systemctl >/dev/null 2>&1; then
        INIT_SYS="systemd"
    else
        INIT_SYS="none"
    fi
    _init_set_service_file
    echo "$INIT_SYS"
    return 0
}

init_desc() {
    case "$(detect_init)" in
        systemd)  echo "systemd" ;;
        openrc)   echo "OpenRC" ;;
        sysvinit) echo "SysVinit" ;;
        procd)    echo "procd (OpenWrt)" ;;
        *)        echo "无 (裸进程)" ;;
    esac
    return 0
}

svc_is_active() {
    case "$(detect_init)" in
        systemd) systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; return $? ;;
        openrc)  rc-service "$SERVICE_NAME" status 2>/dev/null | grep -qE "status: started|已启动"; return $? ;;
        *)       pgrep -f "${INSTALL_DIR}/XrayR" >/dev/null 2>&1; return $? ;;
    esac
}

svc_is_enabled() {
    case "$(detect_init)" in
        systemd)  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; return $? ;;
        openrc)   rc-update show default 2>/dev/null | grep -q "${SERVICE_NAME}"; return $? ;;
        sysvinit) ls /etc/rc[2-5].d/S??"${SERVICE_NAME}" >/dev/null 2>&1; return $? ;;
        procd)    ls /etc/rc.d/S??"${SERVICE_NAME}" >/dev/null 2>&1; return $? ;;
        *)        [[ -f /etc/xrayr-bare-autostart ]]; return $? ;;
    esac
}

_bare_start() {
    if svc_is_active; then return 0; fi
    mkdir -p "$(dirname "$BARE_LOGFILE")" 2>/dev/null
    setsid nohup "${INSTALL_DIR}/XrayR" --config "${CONFIG_DIR}/config.yml" \
        >> "$BARE_LOGFILE" 2>&1 < /dev/null &
    echo $! > "$BARE_PIDFILE" 2>/dev/null
    sleep 1
    svc_is_active
    return $?
}

_bare_stop() {
    local p
    if [[ -f "$BARE_PIDFILE" ]]; then
        p="$(cat "$BARE_PIDFILE" 2>/dev/null)"
        if [[ -n "$p" ]]; then kill "$p" 2>/dev/null; fi
    fi
    pkill -f "${INSTALL_DIR}/XrayR --config" 2>/dev/null
    rm -f "$BARE_PIDFILE" 2>/dev/null
    return 0
}

svc_start() {
    case "$(detect_init)" in
        systemd)  systemctl start "$SERVICE_NAME" >/dev/null 2>&1 ;;
        openrc)   rc-service "$SERVICE_NAME" start >/dev/null 2>&1 ;;
        sysvinit) if command -v service >/dev/null 2>&1; then service "$SERVICE_NAME" start >/dev/null 2>&1; else "/etc/init.d/${SERVICE_NAME}" start >/dev/null 2>&1; fi ;;
        procd)    "/etc/init.d/${SERVICE_NAME}" start >/dev/null 2>&1 ;;
        *)        _bare_start ;;
    esac
    return $?
}

svc_stop() {
    case "$(detect_init)" in
        systemd)  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 ;;
        openrc)   rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 ;;
        sysvinit) if command -v service >/dev/null 2>&1; then service "$SERVICE_NAME" stop >/dev/null 2>&1; else "/etc/init.d/${SERVICE_NAME}" stop >/dev/null 2>&1; fi ;;
        procd)    "/etc/init.d/${SERVICE_NAME}" stop >/dev/null 2>&1 ;;
        *)        _bare_stop ;;
    esac
    return $?
}

svc_restart() {
    case "$(detect_init)" in
        systemd)  systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 ;;
        openrc)   rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 ;;
        sysvinit) if command -v service >/dev/null 2>&1; then service "$SERVICE_NAME" restart >/dev/null 2>&1; else "/etc/init.d/${SERVICE_NAME}" restart >/dev/null 2>&1; fi ;;
        procd)    "/etc/init.d/${SERVICE_NAME}" restart >/dev/null 2>&1 ;;
        *)        _bare_stop; sleep 1; _bare_start ;;
    esac
    return $?
}

svc_enable() {
    case "$(detect_init)" in
        systemd)  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 ;;
        openrc)   rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 ;;
        sysvinit)
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d "$SERVICE_NAME" defaults >/dev/null 2>&1
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig --add "$SERVICE_NAME" >/dev/null 2>&1; chkconfig "$SERVICE_NAME" on >/dev/null 2>&1
            fi ;;
        procd)
            "/etc/init.d/${SERVICE_NAME}" enable >/dev/null 2>&1
            # procd 环境不完整时上面会静默失败, 手工建 rc.d 链接兜底
            if ! ls /etc/rc.d/S??"${SERVICE_NAME}" >/dev/null 2>&1; then
                mkdir -p /etc/rc.d 2>/dev/null
                ln -sf "/etc/init.d/${SERVICE_NAME}" "/etc/rc.d/S99${SERVICE_NAME}" 2>/dev/null
            fi ;;
        *)        touch /etc/xrayr-bare-autostart ;;
    esac
    return $?
}

svc_disable() {
    case "$(detect_init)" in
        systemd)  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 ;;
        openrc)   rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 ;;
        sysvinit)
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d -f "$SERVICE_NAME" remove >/dev/null 2>&1
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig "$SERVICE_NAME" off >/dev/null 2>&1
            fi ;;
        procd)
            "/etc/init.d/${SERVICE_NAME}" disable >/dev/null 2>&1
            rm -f /etc/rc.d/S??"${SERVICE_NAME}" 2>/dev/null ;;
        *)        rm -f /etc/xrayr-bare-autostart ;;
    esac
    return $?
}

svc_daemon_reload() {
    if [[ "$(detect_init)" == "systemd" ]]; then
        systemctl daemon-reload >/dev/null 2>&1
    fi
    return 0
}

svc_status_text() {
    case "$(detect_init)" in
        systemd) systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || true ;;
        openrc)  rc-service "$SERVICE_NAME" status 2>&1 | head -20 ;;
        *)
            if svc_is_active; then
                echo "  运行状态: 运行中"
                pgrep -af "${INSTALL_DIR}/XrayR" 2>/dev/null | head -5
            else
                echo "  运行状态: 已停止"
            fi ;;
    esac
    return 0
}

# 日志: systemd 走 journalctl, 其余走文件
svc_log_tail() {
    local n="${1:-50}"
    if [[ "$(detect_init)" == "systemd" ]]; then
        journalctl -u "$SERVICE_NAME" --no-pager -n "$n" 2>&1
    elif [[ -f "$BARE_LOGFILE" ]]; then
        tail -n "$n" "$BARE_LOGFILE"
    else
        echo "  未找到日志 (${BARE_LOGFILE} 不存在)"
    fi
    return 0
}

svc_log_follow() {
    if [[ "$(detect_init)" == "systemd" ]]; then
        journalctl -u "$SERVICE_NAME" --no-pager -f
    elif [[ -f "$BARE_LOGFILE" ]]; then
        tail -f "$BARE_LOGFILE"
    else
        echo "  未找到日志 (${BARE_LOGFILE} 不存在)"
    fi
    return 0
}

# 按显示宽度补齐 (中文占 2 列, UTF-8 占 3 字节, printf %-Ns 会错位)
pad_disp() {
    local str="$1" want="${2:-16}"
    local bytes chars wide w pad
    bytes="$(printf '%s' "$str" | wc -c)"
    chars="$(printf '%s' "$str" | wc -m)"
    wide=$(( (bytes - chars) / 2 ))
    w=$(( chars + wide ))
    pad=$(( want - w ))
    if [[ "$pad" -lt 0 ]]; then pad=0; fi
    printf '%s%*s' "$str" "$pad" ""
}

# 从 raw 拉文件, 带 cache-buster + no-cache 头绕过 CDN 缓存
# raw.githubusercontent 有约 5 分钟 CDN 缓存, 不绕过会导致刚推的版本检测不到
_mgr_raw_fetch() {
    local file="$1" out="${2:-}"
    local url="${RAW_BASE}/${file}?nocache=$(date +%s)"
    if [[ -n "$out" ]]; then
        curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' --max-time 20 -o "$out" "$url" 2>/dev/null
        return $?
    fi
    curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' --max-time 8 "$url" 2>/dev/null
    return $?
}

# 每次启动静默自升级 (缓存 1 小时避免频繁网络请求)
# 检查两个脚本: xrayr-manager.sh (需 exec 重启才能生效) 和 install.sh (直接替换)
# 短路: XRAYR_MGR_SELF_UPDATED=1 表示本次 exec 链里已升级过, 避免死循环
_mgr_silent_selfupdate() {
    if [[ -n "$XRAYR_MGR_SELF_UPDATED" ]]; then
        return 0
    fi
    local cache="/var/lib/.xrayr-mgr-selfupd"
    local age=0 now mtime
    if [[ -f "$cache" ]]; then
        mtime="$(stat -c %Y "$cache" 2>/dev/null || echo 0)"
        now="$(date +%s)"
        age=$(( now - mtime ))
        if [[ "$age" -lt 3600 ]]; then
            return 0
        fi
    fi
    command -v curl >/dev/null 2>&1 || return 0

    # 静默拉取远端两个脚本的版本行 (只读一行, 快且省流量)
    local remote_mgr remote_ins
    remote_mgr="$(_mgr_raw_fetch xrayr-manager.sh | grep -m1 '^MGR_VERSION=' | cut -d'"' -f2)"
    remote_ins="$(_mgr_raw_fetch install.sh       | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2)"

    # 无论有无新版都写缓存, 避免同一时段反复重试
    mkdir -p "$(dirname "$cache")" "${INSTALL_DIR}" 2>/dev/null
    date +%s > "$cache" 2>/dev/null

    local updated_mgr=0 updated_ins=0 old_mgr="$MGR_VERSION" old_ins=""

    # 1) install.sh 静默升级 (不需要 exec, 下次调用时才用到新版)
    if [[ -n "$remote_ins" ]]; then
        old_ins="$(grep -m1 '^SCRIPT_VERSION=' "${INSTALL_DIR}/install.sh" 2>/dev/null | cut -d'"' -f2)"
        if [[ -z "$old_ins" ]] || _mgr_ver_lt "$old_ins" "$remote_ins"; then
            local tmp1="/tmp/.xrayr-install-selfupd.sh"
            if _mgr_raw_fetch install.sh "$tmp1" \
                && bash -n "$tmp1" 2>/dev/null \
                && grep -q 'do_install()' "$tmp1"; then
                install -m 755 "$tmp1" "${INSTALL_DIR}/install.sh"
                ln -sf "${INSTALL_DIR}/install.sh" /usr/local/bin/xrayr-install
                if [[ -f /etc/XrayR/.version ]]; then
                    sed -i "s/^SCRIPT_VERSION=.*/SCRIPT_VERSION=${remote_ins}/" /etc/XrayR/.version 2>/dev/null
                fi
                updated_ins=1
            fi
            rm -f "$tmp1"
        fi
    fi

    # 2) xrayr-manager.sh 静默升级 (需要 exec 重启当前进程, 否则本次跑的仍是旧代码)
    if [[ -n "$remote_mgr" ]] && _mgr_ver_lt "$MGR_VERSION" "$remote_mgr"; then
        local tmp2="/tmp/.xrayr-manager-selfupd.sh"
        if _mgr_raw_fetch xrayr-manager.sh "$tmp2" \
            && bash -n "$tmp2" 2>/dev/null \
            && grep -q 'interactive_menu()' "$tmp2" \
            && grep -q '^MGR_VERSION=' "$tmp2"; then
            install -m 755 "$tmp2" "${INSTALL_DIR}/xrayr-manager.sh"
            cp -f "${INSTALL_DIR}/xrayr-manager.sh" /usr/local/bin/xrayr
            chmod +x /usr/local/bin/xrayr
            updated_mgr=1
        fi
        rm -f "$tmp2"
    fi

    # 一行简明提示 (若两者都没更新则完全静默)
    if [[ $updated_mgr -eq 1 ]] || [[ $updated_ins -eq 1 ]]; then
        local msg="  ${GREEN}✓${NC} ${DIM}已静默升级脚本${NC}"
        if [[ $updated_mgr -eq 1 ]]; then
            msg="${msg} ${DIM}manager ${old_mgr}→${remote_mgr}${NC}"
        fi
        if [[ $updated_ins -eq 1 ]]; then
            msg="${msg} ${DIM}installer ${old_ins:-未记录}→${remote_ins}${NC}"
        fi
        echo -e "$msg"
    fi

    # manager 自身升级了, exec 重启, 让本次会话跑新代码
    if [[ $updated_mgr -eq 1 ]]; then
        export XRAYR_MGR_SELF_UPDATED=1
        if [[ -x /usr/local/bin/xrayr ]]; then
            exec /usr/local/bin/xrayr "$@"
        fi
    fi
    return 0
}

# Colors
RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[0;33m'
BLUE=$'\e[0;34m'
CYAN=$'\e[0;36m'
MAGENTA=$'\e[0;35m'
BOLD=$'\e[1m'
DIM=$'\e[2m'
NC=$'\e[0m'

# GeoData URLs
DEFAULT_GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
DEFAULT_GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
ALT_GEOIP_URL="https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
ALT_GEOSITE_URL="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
METACUBEX_GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"
METACUBEX_GEOSITE_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"
SOFFCHEN_GEOIP_URL="https://github.com/soffchen/merged/releases/latest/download/geoip.dat"
SOFFCHEN_GEOSITE_URL="https://github.com/soffchen/merged/releases/latest/download/geosite.dat"

GEO_CONFIG_FILE="/etc/XrayR/geodata.conf"
GEO_UPDATE_SCRIPT="/usr/local/XrayR/geo-update.sh"
GEO_CRON_SCHEDULE="30 4 * * *"
GEO_LOG_FILE="/var/log/xrayr-geo-update.log"

# Log limit files
LOGROTATE_FILE="/etc/logrotate.d/xrayr"
JOURNALD_LIMIT_FILE="/etc/systemd/journald.conf.d/xrayr-limits.conf"
SYSTEMD_DROPIN="/etc/systemd/system/${SERVICE_NAME}.service.d/limits.conf"

print_info() { echo -e "${BLUE}[信息]${NC} $1"; }
print_ok() { echo -e "${GREEN}[成功]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }

helper() {
    python3 "${HELPER}" "$@"
}

show_status() {
    local status
    if svc_is_active; then
        status="${GREEN}● 运行中${NC}"
    else
        status="${RED}○ 已停止${NC}"
    fi
    local enabled
    if svc_is_enabled; then
        enabled="${GREEN}已启用${NC}"
    else
        enabled="${RED}未启用${NC}"
    fi
    local version
    version=$("${INSTALL_DIR}/XrayR" version 2>/dev/null | head -1 || echo "未知")
    echo -e " ${BOLD}状态${NC}: ${status}  ${BOLD}自启${NC}: ${enabled}  ${BOLD}版本${NC}: ${DIM}${version}${NC}"
}


# ========== 服务控制 ==========
do_start() {
    print_info "正在启动 XrayR..."
    svc_start
    sleep 1
    if svc_is_active; then
        print_ok "XrayR 启动成功"
    else
        print_error "XrayR 启动失败"
        svc_log_tail 10
        return 1
    fi
}
do_stop() {
    print_info "正在停止 XrayR..."
    svc_stop
    print_ok "XrayR 已停止"
}
do_restart() {
    print_info "正在重启 XrayR..."
    svc_restart
    sleep 1
    if svc_is_active; then
        print_ok "XrayR 重启成功"
    else
        print_error "XrayR 重启失败"
        svc_log_tail 10
        return 1
    fi
}
do_status() {
    show_status
    echo ""
    echo -e " ${BOLD}init 系统${NC}: $(init_desc)"
    echo ""
    svc_status_text
}
do_log() {
    echo -e "${CYAN}正在查看实时日志 (Ctrl+C 退出)...${NC}"
    svc_log_follow
}
do_log_recent() {
    svc_log_tail 50
}
do_enable() {
    svc_enable
    print_ok "已开启开机自启"
}
do_disable() {
    svc_disable
    print_ok "已关闭开机自启"
}
do_version() {
    local vstate="/etc/XrayR/.version"
    local bin_ver core_ver script_ver inst_time inst_arch
    bin_ver="$("${INSTALL_DIR}/XrayR" version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [[ -f "$vstate" ]]; then
        core_ver="$(grep -E '^CORE_VERSION=' "$vstate" 2>/dev/null | cut -d= -f2-)"
        script_ver="$(grep -E '^SCRIPT_VERSION=' "$vstate" 2>/dev/null | cut -d= -f2-)"
        inst_time="$(grep -E '^INSTALL_TIME=' "$vstate" 2>/dev/null | cut -d= -f2-)"
        inst_arch="$(grep -E '^INSTALL_ARCH=' "$vstate" 2>/dev/null | cut -d= -f2-)"
    fi
    # 优先读二进制自报 (0.9.6+ 内置 Xray-core 行, 无需 binutils),
    # 再退回 strings / grep -a 兼容旧版与精简系统。
    if [[ -z "$core_ver" ]] || [[ "$core_ver" == "unknown" ]]; then
        core_ver="$("${INSTALL_DIR}/XrayR" version 2>/dev/null | grep -iE '^Xray-core' | head -1 | grep -oE 'v?1\.[0-9]+\.[0-9]+' | head -1)"
    fi
    if [[ -z "$core_ver" ]] && command -v strings >/dev/null 2>&1; then
        core_ver="$(strings "${INSTALL_DIR}/XrayR" 2>/dev/null | grep -oE '^v?1\.2[0-9]{5}\.[0-9]+$' | sort -Vu | tail -1)"
    fi
    if [[ -z "$core_ver" ]]; then
        core_ver="$(grep -aoE 'github\.com/xtls/xray-core@v1\.[0-9]{6}\.[0-9]+' "${INSTALL_DIR}/XrayR" 2>/dev/null | head -1 | sed 's/.*@//')"
    fi
    echo ""
    echo -e "  ${CYAN}${BOLD}────────────  版本信息  ────────────${NC}"
    echo ""
    echo "  $(pad_disp 'XrayR 主程序' 16) ${bin_ver:-未知}"
    echo "  $(pad_disp 'Xray 内核' 16) ${core_ver:-未知}"
    echo "  $(pad_disp '安装脚本版本' 16) ${script_ver:-未记录}"
    echo "  $(pad_disp '管理脚本版本' 16) ${MGR_VERSION}"
    echo "  $(pad_disp '安装架构' 16) ${inst_arch:-未知}"
    echo "  $(pad_disp '安装时间' 16) ${inst_time:-未知}"
    # 在线查询最新版本, 只有存在更新时才提示 (用户要求: 常态只显示本地)
    local latest bv sv has_new=0
    latest="$(_mgr_check_latest)"
    bv="${latest%%|*}"; sv="${latest##*|}"
    local norm_bin="${bin_ver#v}"
    local norm_bv="${bv#v}"
    if [[ -n "$bv" ]] && [[ -n "$norm_bin" ]] && _mgr_ver_lt "$norm_bin" "$norm_bv"; then
        has_new=1
        echo ""
        echo -e "  ${GREEN}${BOLD}▸ 发现新版本 ${bv}${NC} ${DIM}(当前 ${bin_ver:-未知})${NC}"
        echo -e "  ${DIM}升级命令: xrayr-install update ${bv}   或   xrayr update${NC}"
    fi
    if [[ -n "$sv" ]] && [[ -n "$script_ver" ]] && _mgr_ver_lt "$script_ver" "$sv"; then
        has_new=1
        echo ""
        echo -e "  ${GREEN}${BOLD}▸ 安装脚本有新版 ${sv}${NC} ${DIM}(当前 ${script_ver})${NC}"
        echo -e "  ${DIM}更新命令: xrayr-install update self${NC}"
    fi
    # 管理脚本自身版本比对 (启动时会静默自升级, 这里只作显示)
    local remote_mgr
    remote_mgr="$(_mgr_raw_fetch xrayr-manager.sh | grep -m1 '^MGR_VERSION=' | cut -d'"' -f2)"
    if [[ -n "$remote_mgr" ]] && _mgr_ver_lt "$MGR_VERSION" "$remote_mgr"; then
        has_new=1
        echo ""
        echo -e "  ${GREEN}${BOLD}▸ 管理脚本有新版 ${remote_mgr}${NC} ${DIM}(当前 ${MGR_VERSION}, 下次启动自动升级)${NC}"
    fi
    # 缓存文件也可能有旧的提示, 一并同步清理
    if [[ -f /etc/XrayR/.update-available ]] && [[ "$has_new" == "0" ]]; then
        rm -f /etc/XrayR/.update-available 2>/dev/null
    fi
    echo ""
    return 0
}

# 转到安装脚本的更新管理
# 找不到本地 install.sh 时会自动从远端拉一份到 /usr/local/XrayR/install.sh
# 并注册 xrayr-install 命令, 无需用户手动执行 curl。
do_update_mgmt() {
    local si="${INSTALL_DIR}/install.sh"
    if [[ -x /usr/local/bin/xrayr-install ]]; then
        /usr/local/bin/xrayr-install "$@"
        return $?
    fi
    if [[ -x "$si" ]]; then
        "$si" "$@"
        return $?
    fi
    # 自动补装: 首次通过 bash <(curl ...) 一次性安装时 install.sh 没落盘
    print_info "本地未找到安装脚本, 正在从远端获取..."
    mkdir -p "${INSTALL_DIR}"
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        print_error "系统缺少 curl/wget, 无法自动获取"
        echo -e "  ${CYAN}bash <(curl -sL ${RAW_BASE}/install.sh)${NC}"
        return 1
    fi
    local tmp="/tmp/xrayr-install-fetch.sh"
    if command -v curl >/dev/null 2>&1; then
        _mgr_raw_fetch install.sh "$tmp"
    else
        wget -qO "$tmp" "${RAW_BASE}/install.sh?nocache=$(date +%s)" 2>/dev/null
    fi
    if [[ ! -s "$tmp" ]] || ! bash -n "$tmp" 2>/dev/null; then
        print_error "远端脚本下载或校验失败"
        rm -f "$tmp"
        return 1
    fi
    install -m 755 "$tmp" "$si"
    rm -f "$tmp"
    ln -sf "$si" /usr/local/bin/xrayr-install
    print_ok "安装脚本已落盘: ${si} (命令 xrayr-install 已注册)"
    "$si" "$@"
    return $?
}

# 查询远端最新版本 (带缓存, 与 install.sh 共用缓存文件)
# 输出: <最新二进制版本>|<远端脚本版本>, 静默失败时返回空
_mgr_check_latest() {
    if [[ -f "$UPDATE_CACHE_FILE" ]]; then
        local mtime now age
        mtime="$(stat -c %Y "$UPDATE_CACHE_FILE" 2>/dev/null || echo 0)"
        now="$(date +%s)"
        age=$(( now - mtime ))
        if [[ "$age" -lt "$UPDATE_CACHE_TTL" ]]; then
            cat "$UPDATE_CACHE_FILE"
            return 0
        fi
    fi
    if ! command -v curl >/dev/null 2>&1; then
        return 1
    fi
    local bv sv
    bv="$(curl -sL --max-time 8 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)"
    sv="$(_mgr_raw_fetch install.sh | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2)"
    if [[ -n "$bv" ]] || [[ -n "$sv" ]]; then
        mkdir -p "$(dirname "$UPDATE_CACHE_FILE")" 2>/dev/null
        echo "${bv}|${sv}" > "$UPDATE_CACHE_FILE" 2>/dev/null
    fi
    echo "${bv}|${sv}"
    return 0
}

# 比较版本 (a < b 返回 0)
_mgr_ver_lt() {
    local a="${1#v}" b="${2#v}"
    if [[ "$a" == "$b" ]]; then return 1; fi
    local lower
    lower="$(printf '%s\n%s\n' "$a" "$b" | sort -V 2>/dev/null | head -1)"
    if [[ "$lower" == "$a" ]]; then return 0; fi
    return 1
}


# ========== 节点/面板管理 ==========
menu_nodes() {
    while true; do
        clear
        echo -e "  ${CYAN}${BOLD}═══ 节点/面板管理 ═══${NC}"
        echo ""
        local nodes
        nodes=$(helper list-nodes)
        if [[ "$nodes" == "NO_NODES" ]]; then
            echo -e "  ${DIM}暂无节点配置${NC}"
        else
            echo -e "  ${BOLD}序号  状态    面板类型       节点ID  协议          API地址${NC}"
            echo -e "  ──────────────────────────────────────────────────────────────────"
            while IFS="|" read -r idx status panel host nid ntype; do
                local status_zh
                if [[ "$status" == "enabled" ]]; then
                    status_zh="${GREEN}● 启用${NC}"
                else
                    status_zh="${RED}○ 禁用${NC}"
                fi
                printf "  ${GREEN}%2s${NC})  %-14b %-14s %-7s %-13s %s\n" "$idx" "$status_zh" "$panel" "$nid" "$ntype" "$host"
            done <<< "$nodes"
        fi
        echo ""
        echo -e "  ${GREEN}${BOLD}操作:${NC}"
        echo -e "  ${GREEN}a)${NC} 添加节点     ${GREEN}d)${NC} 删除节点     ${GREEN}e)${NC} 编辑节点"
        echo -e "  ${GREEN}v)${NC} 查看详情     ${GREEN}s)${NC} 启用/禁用    ${GREEN}c)${NC} 节点连通性检测"
        echo -e "  ${YELLOW}0)${NC} 返回主菜单"
        echo ""
        read -erp "  请选择: " choice
        case "$choice" in
            a) add_node_interactive ;;
            d) delete_node_interactive ;;
            e) edit_node_interactive ;;
            v) view_node_interactive ;;
            s) toggle_node_interactive ;;
            c) check_nodes_interactive ;;
            0|q) return ;;
            *) print_error "无效选项" ; sleep 1 ;;
        esac
    done
}

add_node_interactive() {
    echo ""
    echo -e "  ${CYAN}${BOLD}── 添加新节点 ──${NC}"
    echo ""
    echo -e "  支持的面板类型: ${GREEN}SSpanel, NewV2board, V2board, PMpanel, Proxypanel, V2RaySocks, GoV2Panel, BunPanel${NC}"
    read -erp "  面板类型: " panel_type
    [[ -z "$panel_type" ]] && panel_type="NewV2board"
    read -erp "  API 地址 (如 https://example.com): " api_host
    [[ -z "$api_host" ]] && { print_error "API地址不能为空"; sleep 1; return; }
    read -erp "  API 密钥: " api_key
    [[ -z "$api_key" ]] && { print_error "API密钥不能为空"; sleep 1; return; }
    read -erp "  节点 ID: " node_id
    [[ -z "$node_id" ]] && { print_error "节点ID不能为空"; sleep 1; return; }
    echo -e "  支持的协议: ${GREEN}V2ray, Vmess, Vless, Shadowsocks, Trojan, Shadowsocks-Plugin${NC}"
    read -erp "  节点协议 [Shadowsocks]: " node_type
    [[ -z "$node_type" ]] && node_type="Shadowsocks"
    echo ""
    helper add-node "$panel_type" "$api_host" "$api_key" "$node_id" "$node_type"
    print_ok "节点添加成功"
    read -erp "  按回车继续..." _
}

delete_node_interactive() {
    echo ""
    read -erp "  输入要删除的节点序号: " idx
    [[ -z "$idx" ]] && return
    helper delete-node "$idx"
    read -erp "  按回车继续..." _
}

view_node_interactive() {
    echo ""
    read -erp "  输入要查看的节点序号: " idx
    [[ -z "$idx" ]] && return
    echo ""
    helper show-node "$idx"
    echo ""
    read -erp "  按回车继续..." _
}

toggle_node_interactive() {
    echo ""
    read -erp "  输入节点序号 (启用/禁用切换): " idx
    [[ -z "$idx" ]] && return
    # 判断当前状态
    local nodes state
    nodes=$(helper list-nodes)
    state=$(echo "$nodes" | awk -F"|" -v i="$idx" '$1==i {print $2}')
    if [[ -z "$state" ]]; then
        print_error "序号不存在"
        sleep 1
        return
    fi
    if [[ "$state" == "enabled" ]]; then
        helper disable-node "$idx"
    else
        helper enable-node "$idx"
    fi
    print_info "重启 XrayR 使更改生效: xrayr restart"
    read -erp "  按回车继续..." _
}

check_nodes_interactive() {
    echo ""
    echo -e "  ${CYAN}${BOLD}── 节点连通性检测 ──${NC}"
    echo -e "  ${DIM}正在并发检测所有节点 API 可达性...${NC}"
    echo ""
    local out
    out=$(helper check-nodes)
    if [[ "$out" == "NO_NODES" ]]; then
        print_warn "暂无节点"
        read -erp "  按回车继续..." _
        return
    fi
    echo -e "  ${BOLD}序号  状态    可达性       API 地址                      信息${NC}"
    echo -e "  ────────────────────────────────────────────────────────────────────"
    while IFS="|" read -r idx status result host msg; do
        local st_zh rs_zh
        if [[ "$status" == "enabled" ]]; then
            st_zh="${GREEN}● 启用${NC}"
        else
            st_zh="${RED}○ 禁用${NC}"
        fi
        if [[ "$result" == "ok" ]]; then
            rs_zh="${GREEN}✔ 可达${NC}"
        else
            rs_zh="${RED}✘ 不可达${NC}"
        fi
        printf "  ${GREEN}%2s${NC})  %-14b %-14b %-30s %s\n" "$idx" "$st_zh" "$rs_zh" "$host" "$msg"
    done <<< "$out"
    echo ""
    read -erp "  按回车继续..." _
}

edit_node_interactive() {
    echo ""
    read -erp "  输入要编辑的节点序号: " idx
    [[ -z "$idx" ]] && return

    while true; do
        clear
        echo ""
        echo -e "  ${CYAN}${BOLD}═══ 编辑节点 #${idx} ═══${NC}"
        echo ""

        local fields
        fields=$(helper get-node-fields "$idx")
        if [[ "$fields" == ERROR* ]]; then
            print_error "$fields"
            read -erp "  按回车继续..." _
            return
        fi

        # Print table header
        printf "  ${BOLD}%-4s %-14s %-14s %s${NC}\n" "序号" "分类" "配置项" "当前值"
        echo -e "  ──────────────────────────────────────────────────────────────"

        local last_cat=""
        while IFS="|" read -r num path cat name val opts; do
            [[ -z "$num" ]] && continue
            # Show category separator
            if [[ "$cat" != "$last_cat" ]]; then
                if [[ -n "$last_cat" ]]; then
                    echo ""
                fi
                last_cat="$cat"
            fi
            # Truncate long values
            local disp_val="$val"
            if [[ ${#disp_val} -gt 35 ]]; then
                disp_val="${disp_val:0:32}..."
            fi
            printf "  ${GREEN}%3s)${NC} %-14s %-14s ${DIM}%s${NC}\n" "$num" "$cat" "$name" "$disp_val"
        done <<< "$fields"

        echo ""
        echo -e "  ──────────────────────────────────────────────────────────────"
        echo -e "  ${YELLOW}  0)${NC} 返回上级"
        echo ""
        read -erp "  输入序号编辑 [0-32]: " choice
        [[ -z "$choice" || "$choice" == "0" || "$choice" == "q" ]] && return

        # Find the selected field
        local sel_line
        sel_line=$(echo "$fields" | awk -F'|' -v n="$choice" '$1==n')
        if [[ -z "$sel_line" ]]; then
            print_error "无效序号"
            read -erp "  按回车继续..." _
            continue
        fi

        local sel_path sel_cat sel_name sel_val sel_opts
        IFS="|" read -r _ sel_path sel_cat sel_name sel_val sel_opts <<< "$sel_line"

        echo ""
        echo -e "  ${CYAN}当前 [${sel_name}]:${NC} ${sel_val}"

        # If has options, show them
        if [[ -n "$sel_opts" ]]; then
            echo -e "  ${DIM}可选值: ${sel_opts}${NC}"
        fi

        read -erp "  新值 (回车保持不变): " new_val
        if [[ -z "$new_val" ]]; then
            print_info "未修改"
            sleep 0.5
            continue
        fi

        local result
        result=$(helper modify-node "$idx" "$sel_path" "$new_val")
        if [[ "$result" == OK* ]]; then
            print_ok "${sel_name} 已修改为: ${new_val}"
        else
            print_error "$result"
        fi
        sleep 1
    done
}


# ========== 路由管理 ==========
menu_routes() {
    while true; do
        clear
        echo -e "  ${CYAN}${BOLD}═══ 路由规则管理 ═══${NC}"
        echo ""
        local routes
        routes=$(helper list-routes)
        if [[ "$routes" == "NO_RULES" ]]; then
            echo -e "  ${DIM}暂无路由规则${NC}"
        else
            echo -e "$routes" | head -1
            echo ""
            echo -e "  ${BOLD}序号  出站标签        匹配条件${NC}"
            echo -e "  ───────────────────────────────────────────"
            echo -e "$routes" | tail -n +2 | while IFS="|" read -r idx tag detail; do
                printf "  ${GREEN}%2s${NC})  %-15s %s\n" "$idx" "$tag" "$detail"
            done
        fi
        echo ""
        echo -e "  ${GREEN}${BOLD}操作:${NC}"
        echo -e "  ${GREEN}a)${NC} 添加规则"
        echo -e "  ${GREEN}d)${NC} 删除规则"
        echo -e "  ${GREEN}s)${NC} 设置域名策略"
        echo -e "  ${GREEN}v)${NC} 查看原始文件"
        echo -e "  ${YELLOW}0)${NC} 返回主菜单"
        echo ""
        read -erp "  请选择: " choice
        case "$choice" in
            a) add_route_interactive ;;
            d) delete_route_interactive ;;
            s) set_strategy_interactive ;;
            v) echo ""; cat "${CONFIG_DIR}/route.json" 2>/dev/null || echo "文件不存在"; echo ""; read -erp "  按回车继续..." _ ;;
            0|q) return ;;
            *) print_error "无效选项" ; sleep 1 ;;
        esac
    done
}

add_route_interactive() {
    echo ""
    echo -e "  ${CYAN}${BOLD}── 添加路由规则 ──${NC}"
    echo ""
    read -erp "  出站标签 (如 block, IPv4_out, IPv6_out, socks5-warp): " tag
    [[ -z "$tag" ]] && return
    echo -e "  匹配类型: ${GREEN}domain${NC} | ${GREEN}ip${NC} | ${GREEN}protocol${NC} | ${GREEN}network${NC}"
    read -erp "  匹配类型: " rtype
    [[ -z "$rtype" ]] && return
    echo -e "  ${DIM}多个值支持: 英文逗号 / 中文逗号 / 空格 / 分号 / 顿号 / 竖线 (如: geosite:google, geosite:netflix)${NC}"
    read -erp "  匹配值: " rvalue
    [[ -z "$rvalue" ]] && return
    helper add-route "$tag" "$rtype" "$rvalue"
    print_ok "规则已添加"
    read -erp "  按回车继续..." _
}

delete_route_interactive() {
    echo ""
    read -erp "  输入要删除的规则序号: " idx
    [[ -z "$idx" ]] && return
    helper delete-route "$idx"
    print_ok "规则已删除"
    read -erp "  按回车继续..." _
}

set_strategy_interactive() {
    echo ""
    echo -e "  ${BOLD}路由域名策略 (route.domainStrategy):${NC}"
    echo ""
    echo -e "    ${GREEN}1) IPIfNonMatch${NC}  ${DIM}(⭐ 推荐)${NC} 域名规则未命中才解析 IP, 兼顾性能与精确度"
    echo -e "    ${GREEN}2) AsIs${NC}          仅域名匹配, 不做 DNS 解析, 速度最快 (适合规则全是域名)"
    echo -e "    ${GREEN}3) IPOnDemand${NC}    存在 IP 规则时立即解析所有域名 (精确但 DNS 请求多)"
    echo ""
    read -erp "  请选择 [1-3, 默认=1]: " sc
    local strategy
    case "$sc" in
        2) strategy="AsIs" ;;
        3) strategy="IPOnDemand" ;;
        *) strategy="IPIfNonMatch" ;;
    esac
    helper set-route-strategy "$strategy"
    print_ok "已设置: $strategy"
    read -erp "  按回车继续..." _
}


# ========== 出站管理 ==========
menu_outbounds() {
    while true; do
        clear
        echo -e "  ${CYAN}${BOLD}═══ 出站规则管理 ═══${NC}"
        echo ""
        local obs
        obs=$(helper list-outbounds)
        if [[ "$obs" == "NO_OUTBOUNDS" ]]; then
            echo -e "  ${DIM}暂无自定义出站${NC}"
        else
            echo -e "  ${BOLD}序号  标签            协议         详情${NC}"
            echo -e "  ─────────────────────────────────────────────"
            while IFS="|" read -r idx tag proto detail; do
                printf "  ${GREEN}%2s${NC})  %-15s %-12s %s\n" "$idx" "$tag" "$proto" "$detail"
            done <<< "$obs"
        fi
        echo ""
        echo -e "  ${GREEN}a)${NC} 添加出站  ${GREEN}d)${NC} 删除出站  ${GREEN}t)${NC} 连通性测试  ${GREEN}i)${NC} 链接导入  ${GREEN}e)${NC} 导出链接  ${GREEN}v)${NC} 查看原始  ${YELLOW}0)${NC} 返回"
        echo ""
        read -erp "  请选择: " choice
        case "$choice" in
            a) add_outbound_interactive ;;
            d)
                read -erp "  删除序号: " idx
                [[ -n "$idx" ]] && helper delete-outbound "$idx"
                sleep 1 ;;
            t) test_outbound_interactive ;;
            i) import_link_interactive ;;
            e)
                echo ""
                echo -e "  ${CYAN}── 导出分享链接 ──${NC}"
                helper export-links
                echo ""
                read -erp "  按回车继续..." _ ;;
            v) echo ""; cat "${CONFIG_DIR}/custom_outbound.json" 2>/dev/null; echo ""; read -erp "  按回车继续..." _ ;;
            0|q) return ;;
        esac
    done
}

# 询问传输层参数，回显到全局数组 STREAM_KV
import_link_interactive() {
    echo ""
    echo -e "  ${CYAN}── 链接导入 ──${NC}"
    echo -e "  支持格式: vmess:// vless:// trojan:// ss:// hysteria2:// hy2://"
    echo -e "  可一次粘贴多行 (多个链接), 输入空行结束"
    echo ""
    local links=""
    while true; do
        read -erp "  链接> " line
        [[ -z "$line" ]] && break
        links="$links $line"
    done
    if [[ -z "$links" ]]; then
        print_warn "未输入任何链接"
        sleep 1
        return
    fi
    echo ""
    helper import-link $links
    echo ""
    read -erp "  按回车继续..." _
}

test_outbound_interactive() {
    echo ""
    echo -e "  ${CYAN}── 出站连通性测试 ──${NC}"
    echo -e "  ${DIM}支持: 单个序号 / 多序号 (逗号/空格/中文逗号分隔) / all${NC}"
    read -erp "  测试序号 [all]: " idx
    [[ -z "$idx" ]] && idx="all"
    echo ""
    local out
    out=$(helper test-outbound "$idx")
    if [[ -z "$out" || "$out" == "NO_OUTBOUNDS" ]]; then
        print_warn "无出站或无可测试项"
        read -erp "  按回车继续..." _
        return
    fi
    echo -e "  ${BOLD}序号  结果      标签             协议         详情${NC}"
    echo -e "  ─────────────────────────────────────────────────────────────"
    while IFS="|" read -r i state tag proto detail; do
        local rs
        case "$state" in
            ok)     rs="${GREEN}✔ 通${NC}" ;;
            fail)   rs="${RED}✘ 失败${NC}" ;;
            skip)   rs="${DIM}○ 跳过${NC}" ;;
            noaddr) rs="${YELLOW}? 无地址${NC}" ;;
            invalid) rs="${RED}✘ 无效${NC}" ;;
            *) rs="$state" ;;
        esac
        printf "  ${GREEN}%2s${NC})  %-11b %-16s %-12s %s\n" "$i" "$rs" "$tag" "$proto" "$detail"
    done <<< "$out"
    echo ""
    read -erp "  按回车继续..." _
}

test_inbound_interactive() {
    echo ""
    echo -e "  ${CYAN}── 入站端口监听测试 ──${NC}"
    echo -e "  ${DIM}支持: 单个序号 / 多序号 (逗号/空格/中文逗号分隔) / all${NC}"
    read -erp "  测试序号 [all]: " idx
    [[ -z "$idx" ]] && idx="all"
    echo ""
    local out
    out=$(helper test-inbound "$idx")
    if [[ -z "$out" || "$out" == "NO_INBOUNDS" ]]; then
        print_warn "无入站或无可测试项"
        read -erp "  按回车继续..." _
        return
    fi
    echo -e "  ${BOLD}序号  结果      协议          监听地址              详情${NC}"
    echo -e "  ─────────────────────────────────────────────────────────────"
    while IFS="|" read -r i state proto listen detail; do
        local rs
        case "$state" in
            ok)   rs="${GREEN}✔ 监听${NC}" ;;
            fail) rs="${RED}✘ 未监听${NC}" ;;
            *) rs="$state" ;;
        esac
        printf "  ${GREEN}%2s${NC})  %-11b %-13s %-21s %s\n" "$i" "$rs" "$proto" "$listen" "$detail"
    done <<< "$out"
    echo ""
    read -erp "  按回车继续..." _
}

ask_stream_params() {
    STREAM_KV=()
    echo ""
    echo -e "  ${DIM}── 传输层设置 (可留空) ──${NC}"
    echo -e "  传输网络: ${GREEN}tcp|ws|grpc|h2|kcp|quic${NC} (回车=不设置)"
    read -erp "  network: " net
    if [[ -n "$net" ]]; then
        STREAM_KV+=("network=$net")
        case "$net" in
            ws)
                read -erp "  path [/]: " path; [[ -z "$path" ]] && path="/"
                STREAM_KV+=("path=$path")
                read -erp "  host (可选): " host
                [[ -n "$host" ]] && STREAM_KV+=("host=$host")
                ;;
            grpc)
                read -erp "  serviceName: " sn
                [[ -n "$sn" ]] && STREAM_KV+=("service_name=$sn")
                read -erp "  multiMode [true/false, 默认false]: " mm
                [[ "$mm" == "true" ]] && STREAM_KV+=("multi_mode=true")
                ;;
            h2)
                read -erp "  path [/]: " path; [[ -z "$path" ]] && path="/"
                STREAM_KV+=("path=$path")
                read -erp "  host (逗号分隔, 可选): " host
                [[ -n "$host" ]] && STREAM_KV+=("host=$host")
                ;;
            tcp)
                echo -e "  伪装: ${GREEN}空=无${NC} | ${GREEN}http${NC}"
                read -erp "  header_type: " ht
                [[ -n "$ht" ]] && STREAM_KV+=("header_type=$ht")
                ;;
            kcp)
                echo -e "  伪装类型: none|srtp|utp|wechat-video|dtls|wireguard"
                read -erp "  header_type [none]: " ht; [[ -z "$ht" ]] && ht="none"
                STREAM_KV+=("header_type=$ht")
                read -erp "  seed (可选): " sd
                [[ -n "$sd" ]] && STREAM_KV+=("seed=$sd")
                ;;
            quic)
                read -erp "  quic_security [none/aes-128-gcm/chacha20-poly1305]: " qs
                [[ -n "$qs" ]] && STREAM_KV+=("quic_security=$qs")
                read -erp "  quic_key (可选): " qk
                [[ -n "$qk" ]] && STREAM_KV+=("quic_key=$qk")
                read -erp "  header_type [none]: " ht; [[ -z "$ht" ]] && ht="none"
                STREAM_KV+=("header_type=$ht")
                ;;
        esac
    fi
    echo -e "  安全层: ${GREEN}none|tls|reality${NC} (回车=不设置)"
    read -erp "  security: " sec
    if [[ -n "$sec" && "$sec" != "none" ]]; then
        STREAM_KV+=("security=$sec")
        read -erp "  serverName / SNI: " sni
        [[ -n "$sni" ]] && STREAM_KV+=("sni=$sni")
        if [[ "$sec" == "tls" ]]; then
            read -erp "  alpn (逗号分隔, 可选): " alpn
            [[ -n "$alpn" ]] && STREAM_KV+=("alpn=$alpn")
            read -erp "  fingerprint [chrome/firefox/safari/random, 可选]: " fp
            [[ -n "$fp" ]] && STREAM_KV+=("fingerprint=$fp")
            read -erp "  允许不安全 allowInsecure [true/false, 默认false]: " ai
            [[ "$ai" == "true" ]] && STREAM_KV+=("allow_insecure=true")
        elif [[ "$sec" == "reality" ]]; then
            read -erp "  publicKey: " pk
            [[ -n "$pk" ]] && STREAM_KV+=("public_key=$pk")
            read -erp "  shortId: " sid
            [[ -n "$sid" ]] && STREAM_KV+=("short_id=$sid")
            read -erp "  fingerprint [chrome]: " fp; [[ -z "$fp" ]] && fp="chrome"
            STREAM_KV+=("fingerprint=$fp")
            read -erp "  spiderX (可选): " sx
            [[ -n "$sx" ]] && STREAM_KV+=("spider_x=$sx")
        fi
    fi
}

add_outbound_interactive() {
    echo ""
    echo -e "  ${CYAN}── 添加出站 ──${NC}"
    read -erp "  标签名: " tag
    [[ -z "$tag" ]] && return
    echo ""
    echo -e "  ${BOLD}支持协议:${NC}"
    echo -e "    ${GREEN}freedom${NC}     直连"
    echo -e "    ${GREEN}blackhole${NC}   黑洞（拦截）"
    echo -e "    ${GREEN}dns${NC}         DNS 转发"
    echo -e "    ${GREEN}loopback${NC}    回环"
    echo -e "    ${GREEN}http${NC}        HTTP 代理"
    echo -e "    ${GREEN}socks${NC}       SOCKS5 代理"
    echo -e "    ${GREEN}shadowsocks${NC} Shadowsocks"
    echo -e "    ${GREEN}trojan${NC}      Trojan"
    echo -e "    ${GREEN}vmess${NC}       VMess"
    echo -e "    ${GREEN}vless${NC}       VLESS (含 XTLS/REALITY)"
    echo -e "    ${GREEN}wireguard${NC}   WireGuard"
    read -erp "  协议 [freedom]: " proto
    [[ -z "$proto" ]] && proto="freedom"
    local addr="" port="0"
    local extra=()
    case "$proto" in
        freedom)
            echo ""
            echo -e "  ${BOLD}freedom 域名策略 (选择怎样解析目标):${NC}"
            echo ""
            echo -e "    ${GREEN}1) AsIs${NC}       原样连接, 不本地解析 ${DIM}(代理/回落建议)${NC}"
            echo -e "    ${GREEN}2) UseIPv4${NC}    ${DIM}(⭐ 直连推荐)${NC} 强制解析为 IPv4"
            echo -e "    ${GREEN}3) UseIPv6${NC}    强制解析为 IPv6 ${DIM}(WARP/IPv6 出口)${NC}"
            echo -e "    ${GREEN}4) UseIP${NC}      解析为任意 IP (v4/v6 均可)"
            echo -e "    ${GREEN}5) UseIPv4v6${NC}  优先 IPv4, 回退 IPv6"
            echo -e "    ${GREEN}6) UseIPv6v4${NC}  优先 IPv6, 回退 IPv4"
            echo -e "    ${GREEN}0) 空${NC}          不设置 (等同 AsIs)"
            echo ""
            read -erp "  请选择 [1-6/0, 默认=2]: " sc
            local strategy
            case "$sc" in
                1) strategy="AsIs" ;;
                3) strategy="UseIPv6" ;;
                4) strategy="UseIP" ;;
                5) strategy="UseIPv4v6" ;;
                6) strategy="UseIPv6v4" ;;
                0) strategy="" ;;
                *) strategy="UseIPv4" ;;
            esac
            addr="$strategy"
            ;;
        blackhole)
            read -erp "  response_type [none/http, 回车=none]: " rt
            [[ -n "$rt" ]] && extra+=("response_type=$rt")
            ;;
        dns)
            read -erp "  DNS 服务器地址 [8.8.8.8]: " addr; [[ -z "$addr" ]] && addr="8.8.8.8"
            read -erp "  端口 [53]: " port; [[ -z "$port" ]] && port="53"
            read -erp "  网络 [udp/tcp, 默认udp]: " dn
            [[ -n "$dn" ]] && extra+=("dns_network=$dn")
            ;;
        loopback)
            read -erp "  inboundTag: " it
            extra+=("inbound_tag=$it")
            ;;
        http)
            read -erp "  服务器地址: " addr
            read -erp "  端口: " port
            read -erp "  用户名 (可选): " un
            if [[ -n "$un" ]]; then
                extra+=("username=$un")
                read -erp "  密码: " pw
                extra+=("password=$pw")
            fi
            ;;
        socks)
            read -erp "  服务器地址: " addr
            read -erp "  端口: " port
            read -erp "  用户名 (可选): " un
            if [[ -n "$un" ]]; then
                extra+=("username=$un")
                read -erp "  密码: " pw
                extra+=("password=$pw")
            fi
            ;;
        shadowsocks)
            read -erp "  服务器地址: " addr
            read -erp "  端口: " port
            echo -e "  加密方式: aes-128-gcm | aes-256-gcm | chacha20-poly1305 | chacha20-ietf-poly1305 | 2022-blake3-aes-128-gcm | 2022-blake3-aes-256-gcm | 2022-blake3-chacha20-poly1305 | none"
            read -erp "  method [aes-128-gcm]: " m; [[ -z "$m" ]] && m="aes-128-gcm"
            extra+=("method=$m")
            read -erp "  password: " pw
            extra+=("password=$pw")
            ;;
        trojan)
            read -erp "  服务器地址: " addr
            read -erp "  端口 [443]: " port; [[ -z "$port" ]] && port="443"
            read -erp "  password: " pw
            extra+=("password=$pw")
            ;;
        vmess)
            read -erp "  服务器地址: " addr
            read -erp "  端口: " port
            read -erp "  UUID: " uuid
            extra+=("uuid=$uuid")
            read -erp "  alterId [0]: " aid; [[ -z "$aid" ]] && aid="0"
            extra+=("alter_id=$aid")
            echo -e "  加密: auto | aes-128-gcm | chacha20-poly1305 | none | zero"
            read -erp "  security [auto]: " sc; [[ -z "$sc" ]] && sc="auto"
            extra+=("security_cipher=$sc")
            ;;
        vless)
            read -erp "  服务器地址: " addr
            read -erp "  端口: " port
            read -erp "  UUID: " uuid
            extra+=("uuid=$uuid")
            echo -e "  flow: ${GREEN}空=普通${NC} | xtls-rprx-vision"
            read -erp "  flow: " fl
            [[ -n "$fl" ]] && extra+=("flow=$fl")
            ;;
        wireguard)
            read -erp "  peer 地址: " addr
            read -erp "  peer 端口 [51820]: " port; [[ -z "$port" ]] && port="51820"
            read -erp "  本机 secretKey: " sk
            extra+=("secret_key=$sk")
            read -erp "  peer publicKey: " pk
            extra+=("public_key=$pk")
            read -erp "  preSharedKey (可选): " psk
            [[ -n "$psk" ]] && extra+=("preshared_key=$psk")
            read -erp "  本机地址 CIDR [10.0.0.2/32]: " la; [[ -z "$la" ]] && la="10.0.0.2/32"
            extra+=("local_addr=$la")
            read -erp "  allowedIPs [0.0.0.0/0,::/0]: " ai; [[ -z "$ai" ]] && ai="0.0.0.0/0,::/0"
            extra+=("allowed_ips=$ai")
            read -erp "  MTU [1420]: " mtu; [[ -z "$mtu" ]] && mtu="1420"
            extra+=("mtu=$mtu")
            read -erp "  keepAlive [0]: " ka; [[ -z "$ka" ]] && ka="0"
            extra+=("keep_alive=$ka")
            ;;
        *)
            print_error "不支持的协议: $proto"
            read -erp "  按回车继续..." _
            return ;;
    esac
    STREAM_KV=()
    case "$proto" in
        vmess|vless|trojan|shadowsocks|http|socks)
            read -erp "  是否配置传输层/TLS [y/N]: " ans
            [[ "$ans" == "y" || "$ans" == "Y" ]] && ask_stream_params
            ;;
    esac
    helper add-outbound "$tag" "$proto" "$addr" "$port" "${extra[@]}" "${STREAM_KV[@]}"
    print_ok "出站已添加"
    read -erp "  按回车继续..." _
}

# ========== 入站管理 ==========
menu_inbounds() {
    while true; do
        clear
        echo -e "  ${CYAN}${BOLD}═══ 自定义入站管理 ═══${NC}"
        echo ""
        local ibs
        ibs=$(helper list-inbounds)
        if [[ "$ibs" == "NO_INBOUNDS" ]]; then
            echo -e "  ${DIM}暂无自定义入站${NC}"
        else
            echo -e "  ${BOLD}序号  协议           监听地址              标签/传输${NC}"
            echo -e "  ────────────────────────────────────────────────────────"
            while IFS="|" read -r idx proto listen tag; do
                printf "  ${GREEN}%2s${NC})  %-14s %-21s %s\n" "$idx" "$proto" "$listen" "$tag"
            done <<< "$ibs"
        fi
        echo ""
        echo -e "  ${GREEN}a)${NC} 添加入站  ${GREEN}d)${NC} 删除入站  ${GREEN}t)${NC} 端口监听测试  ${GREEN}v)${NC} 查看原始  ${YELLOW}0)${NC} 返回"
        echo ""
        read -erp "  请选择: " choice
        case "$choice" in
            a) add_inbound_interactive ;;
            d)
                read -erp "  删除序号: " idx
                [[ -n "$idx" ]] && helper delete-inbound "$idx"
                sleep 1 ;;
            t) test_inbound_interactive ;;
            v) echo ""; cat "${CONFIG_DIR}/custom_inbound.json" 2>/dev/null; echo ""; read -erp "  按回车继续..." _ ;;
            0|q) return ;;
        esac
    done
}

add_inbound_interactive() {
    echo ""
    echo -e "  ${CYAN}── 添加入站 ──${NC}"
    echo -e "  ${BOLD}支持协议:${NC}"
    echo -e "    ${GREEN}socks${NC}         SOCKS5 入站"
    echo -e "    ${GREEN}http${NC}          HTTP 代理入站"
    echo -e "    ${GREEN}shadowsocks${NC}   Shadowsocks 入站"
    echo -e "    ${GREEN}trojan${NC}        Trojan 入站"
    echo -e "    ${GREEN}vmess${NC}         VMess 入站"
    echo -e "    ${GREEN}vless${NC}         VLESS 入站 (含 REALITY)"
    echo -e "    ${GREEN}dokodemo-door${NC} 任意门 (透明代理)"
    read -erp "  协议 [socks]: " proto
    [[ -z "$proto" ]] && proto="socks"
    read -erp "  监听地址 [0.0.0.0]: " addr
    [[ -z "$addr" ]] && addr="0.0.0.0"
    read -erp "  端口: " port
    [[ -z "$port" ]] && { print_error "端口不能为空"; sleep 1; return; }
    read -erp "  标签 tag (可选): " tag
    local extra=()
    [[ -n "$tag" ]] && extra+=("tag=$tag")
    case "$proto" in
        socks)
            echo -e "  鉴权: ${GREEN}noauth | password${NC}"
            read -erp "  auth [noauth]: " au; [[ -z "$au" ]] && au="noauth"
            extra+=("auth=$au")
            if [[ "$au" == "password" ]]; then
                read -erp "  用户名: " un
                extra+=("username=$un")
                read -erp "  密码: " pw
                extra+=("password=$pw")
            fi
            read -erp "  udp 支持 [y/N]: " u
            [[ "$u" == "y" || "$u" == "Y" ]] && extra+=("udp=true")
            ;;
        http)
            read -erp "  超时秒数 [300]: " to; [[ -z "$to" ]] && to="300"
            extra+=("timeout=$to")
            read -erp "  用户名 (可选): " un
            if [[ -n "$un" ]]; then
                extra+=("username=$un")
                read -erp "  密码: " pw
                extra+=("password=$pw")
            fi
            ;;
        shadowsocks)
            echo -e "  加密方式: aes-128-gcm | aes-256-gcm | chacha20-poly1305 | chacha20-ietf-poly1305 | 2022-blake3-aes-128-gcm | 2022-blake3-aes-256-gcm | 2022-blake3-chacha20-poly1305 | none"
            read -erp "  method [aes-128-gcm]: " m; [[ -z "$m" ]] && m="aes-128-gcm"
            extra+=("method=$m")
            read -erp "  password: " pw
            extra+=("password=$pw")
            ;;
        trojan)
            read -erp "  password: " pw
            extra+=("password=$pw")
            read -erp "  flow (可选, e.g. xtls-rprx-vision): " fl
            [[ -n "$fl" ]] && extra+=("flow=$fl")
            read -erp "  回落 fallback dest (可选, e.g. 127.0.0.1:8080): " fd
            [[ -n "$fd" ]] && extra+=("fallback_dest=$fd")
            ;;
        vmess)
            read -erp "  UUID: " uuid
            extra+=("uuid=$uuid")
            read -erp "  alterId [0]: " aid; [[ -z "$aid" ]] && aid="0"
            extra+=("alter_id=$aid")
            ;;
        vless)
            read -erp "  UUID: " uuid
            extra+=("uuid=$uuid")
            echo -e "  flow: ${GREEN}空 | xtls-rprx-vision${NC}"
            read -erp "  flow: " fl
            [[ -n "$fl" ]] && extra+=("flow=$fl")
            read -erp "  decryption [none]: " dc; [[ -z "$dc" ]] && dc="none"
            extra+=("decryption=$dc")
            read -erp "  回落 fallback dest (可选): " fd
            [[ -n "$fd" ]] && extra+=("fallback_dest=$fd")
            ;;
        dokodemo-door)
            read -erp "  目标地址: " ta
            extra+=("target_addr=$ta")
            read -erp "  目标端口: " tp
            extra+=("target_port=$tp")
            read -erp "  网络 [tcp,udp]: " nw; [[ -z "$nw" ]] && nw="tcp,udp"
            extra+=("net=$nw")
            read -erp "  followRedirect [y/N]: " fr
            [[ "$fr" == "y" || "$fr" == "Y" ]] && extra+=("follow_redirect=true")
            ;;
        *)
            print_error "不支持的协议: $proto"
            read -erp "  按回车继续..." _
            return ;;
    esac
    STREAM_KV=()
    case "$proto" in
        vmess|vless|trojan|shadowsocks|http|socks)
            read -erp "  是否配置传输层/TLS [y/N]: " ans
            [[ "$ans" == "y" || "$ans" == "Y" ]] && ask_stream_params
            ;;
    esac
    read -erp "  启用嗅探 sniffing [y/N]: " sn
    if [[ "$sn" == "y" || "$sn" == "Y" ]]; then
        extra+=("sniffing=true")
        read -erp "  嗅探目的 [http,tls]: " sd; [[ -z "$sd" ]] && sd="http,tls"
        extra+=("sniff_dest=$sd")
    fi
    helper add-inbound "$proto" "$addr" "$port" "${extra[@]}" "${STREAM_KV[@]}"
    print_ok "入站已添加"
    read -erp "  按回车继续..." _
}

# ========== DNS 管理 ==========
menu_dns() {
    clear
    echo -e "  ${CYAN}${BOLD}═══ DNS 配置管理 ═══${NC}"
    echo ""
    echo -e "  ${BOLD}当前 DNS 配置:${NC}"
    echo ""
    helper show-dns
    echo ""
    echo -e "  ${GREEN}s)${NC} 设置 DNS 服务器"
    echo -e "  ${GREEN}e)${NC} 编辑原始文件"
    echo -e "  ${YELLOW}0)${NC} 返回"
    echo ""
    read -erp "  请选择: " choice
    case "$choice" in
        s)
            echo -e "  ${DIM}多个服务器用逗号分隔${NC}"
            read -erp "  DNS 服务器 [1.1.1.1,8.8.8.8]: " servers
            [[ -z "$servers" ]] && servers="1.1.1.1,8.8.8.8"
            helper set-dns "$servers"
            read -erp "  按回车继续..." _ ;;
        e)
            local editor
            editor="${EDITOR:-nano}"
            command -v "$editor" &>/dev/null || editor="vi"
            "$editor" "${CONFIG_DIR}/dns.json" ;;
        0|q) return ;;
    esac
}


# ========== 全局设置 ==========
menu_global() {
    clear
    echo -e "  ${CYAN}${BOLD}═══ 全局配置 ═══${NC}"
    echo ""
    local info
    info=$(helper show-global)
    if [[ "$info" == "NO_CONFIG" ]]; then
        print_error "配置文件不存在"
        read -erp "  按回车继续..." _
        return
    fi
    echo -e "  ${BOLD}当前配置:${NC}"
    while IFS="=" read -r key val; do
        case $key in
            LogLevel)        echo -e "    日志级别:     ${GREEN}${val}${NC}" ;;
            DnsConfigPath)   echo -e "    DNS配置路径:  ${val:-${DIM}未设置${NC}}" ;;
            RouteConfigPath) echo -e "    路由配置路径: ${val:-${DIM}未设置${NC}}" ;;
            InboundConfigPath)  echo -e "    入站配置路径: ${val:-${DIM}未设置${NC}}" ;;
            OutboundConfigPath) echo -e "    出站配置路径: ${val:-${DIM}未设置${NC}}" ;;
            ConnIdle)        echo -e "    连接空闲:     ${val}s" ;;
            BufferSize)      echo -e "    缓冲区大小:   ${val}KB" ;;
            NodeCount)       echo -e "    节点数量:     ${GREEN}${val}${NC}" ;;
        esac
    done <<< "$info"
    echo ""
    echo -e "  ${GREEN}1)${NC} 设置日志级别 (none/error/warning/info/debug)"
    echo -e "  ${GREEN}2)${NC} 启用/禁用 DNS 配置路径"
    echo -e "  ${GREEN}3)${NC} 启用/禁用 路由配置路径"
    echo -e "  ${GREEN}4)${NC} 启用/禁用 入站配置路径"
    echo -e "  ${GREEN}5)${NC} 启用/禁用 出站配置路径"
    echo -e "  ${GREEN}6)${NC} 设置连接空闲超时"
    echo -e "  ${GREEN}7)${NC} 设置缓冲区大小"
    echo -e "  ${YELLOW}0)${NC} 返回"
    echo ""
    read -erp "  请选择: " choice
    case "$choice" in
        1)
            read -erp "  日志级别 [none/error/warning/info/debug]: " val
            [[ -n "$val" ]] && helper set-global LogLevel "$val" ;;
        2)
            read -erp "  DNS配置路径 [/etc/XrayR/dns.json 或 none]: " val
            [[ -n "$val" ]] && helper set-global DnsConfigPath "$val" ;;
        3)
            read -erp "  路由配置路径 [/etc/XrayR/route.json 或 none]: " val
            [[ -n "$val" ]] && helper set-global RouteConfigPath "$val" ;;
        4)
            read -erp "  入站配置路径 [/etc/XrayR/custom_inbound.json 或 none]: " val
            [[ -n "$val" ]] && helper set-global InboundConfigPath "$val" ;;
        5)
            read -erp "  出站配置路径 [/etc/XrayR/custom_outbound.json 或 none]: " val
            [[ -n "$val" ]] && helper set-global OutboundConfigPath "$val" ;;
        6)
            read -erp "  连接空闲超时(秒) [30]: " val
            [[ -n "$val" ]] && helper set-global ConnIdle "$val" ;;
        7)
            echo -e "  ${DIM}实测参考: 16 以上对速度无影响(高延迟瓶颈在内核 TCP 窗口);"
            echo -e "  低于 16 会掉速约 20%; 缓冲按需增长非预分配, 512 在 150 并发下"
            echo -e "  仅比 4 多占约 8MB。建议 >=2GB 内存用 512, 1~2GB 用 128。${NC}"
            read -erp "  缓冲区大小(KB) [推荐 512, 小内存 64]: " val
            [[ -n "$val" ]] && helper set-global BufferSize "$val" ;;
        0|q) return ;;
    esac
    [[ "$choice" != "0" && "$choice" != "q" ]] && { read -erp "  按回车继续..." _; }
}

# ========== GeoData ==========
# 加载 geo 配置
_geo_load_conf() {
    # Defaults
    GEO_SOURCE="loyalsoldier"
    GEO_CUSTOM_GEOIP_URL=""
    GEO_CUSTOM_GEOSITE_URL=""
    GEO_AUTO_UPDATE="true"
    GEO_CRON="${GEO_CRON_SCHEDULE}"
    GEO_AUTO_RESTART="true"
    GEO_VERIFY="true"
    GEO_RETRY="3"
    if [[ -f "$GEO_CONFIG_FILE" ]]; then
        source "$GEO_CONFIG_FILE"
    fi
}

_geo_save_conf() {
    cat > "$GEO_CONFIG_FILE" << GEOEOF
# XrayR GeoData 自动更新配置
# 数据源: loyalsoldier / v2fly / metacubex / soffchen / custom
GEO_SOURCE="${GEO_SOURCE}"
GEO_CUSTOM_GEOIP_URL="${GEO_CUSTOM_GEOIP_URL}"
GEO_CUSTOM_GEOSITE_URL="${GEO_CUSTOM_GEOSITE_URL}"
# 自动更新: true/false
GEO_AUTO_UPDATE="${GEO_AUTO_UPDATE}"
# cron 表达式 (默认: 每天 04:30)
GEO_CRON="${GEO_CRON}"
# 更新后自动重启 XrayR: true/false
GEO_AUTO_RESTART="${GEO_AUTO_RESTART}"
# 下载后校验文件完整性: true/false
GEO_VERIFY="${GEO_VERIFY}"
# 单个文件下载失败重试次数
GEO_RETRY="${GEO_RETRY:-3}"
GEOEOF
}

_geo_resolve_urls() {
    case "$GEO_SOURCE" in
        loyalsoldier) _GEO_IP="$DEFAULT_GEOIP_URL"; _GEO_SITE="$DEFAULT_GEOSITE_URL" ;;
        v2fly)        _GEO_IP="$ALT_GEOIP_URL"; _GEO_SITE="$ALT_GEOSITE_URL" ;;
        metacubex)    _GEO_IP="$METACUBEX_GEOIP_URL"; _GEO_SITE="$METACUBEX_GEOSITE_URL" ;;
        soffchen)     _GEO_IP="$SOFFCHEN_GEOIP_URL"; _GEO_SITE="$SOFFCHEN_GEOSITE_URL" ;;
        custom)       _GEO_IP="$GEO_CUSTOM_GEOIP_URL"; _GEO_SITE="$GEO_CUSTOM_GEOSITE_URL" ;;
        *)            _GEO_IP="$DEFAULT_GEOIP_URL"; _GEO_SITE="$DEFAULT_GEOSITE_URL" ;;
    esac
}

_geo_download_one() {
    local url="$1" dest="$2" name="$3"
    local tmp="${dest}.tmp"
    local ok=0
    if command -v wget &>/dev/null; then
        wget -qO "$tmp" "$url" && ok=1
    elif command -v curl &>/dev/null; then
        curl -sLo "$tmp" "$url" && ok=1
    else
        print_error "未找到 wget 或 curl"
        return 1
    fi
    if [[ $ok -ne 1 ]]; then
        rm -f "$tmp"
        print_error "${name} 下载失败"
        return 1
    fi
    # 校验: 文件至少 100KB
    local size
    size=$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp" 2>/dev/null || echo 0)
    if [[ "$GEO_VERIFY" == "true" && $size -lt 102400 ]]; then
        print_error "${name} 文件异常 (${size} bytes, 预期 > 100KB)"
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$dest"
    local size_mb
    size_mb=$(awk "BEGIN{printf \"%.1f\", ${size}/1048576}")
    print_ok "${name} 已更新 (${size_mb}MB)"
    return 0
}

do_update_geodata() {
    _geo_load_conf
    _geo_resolve_urls
    print_info "数据源: ${GEO_SOURCE}"
    print_info "正在下载 GeoData..."
    local updated=0
    _geo_download_one "$_GEO_IP" "${CONFIG_DIR}/geoip.dat" "geoip.dat" && updated=1
    _geo_download_one "$_GEO_SITE" "${CONFIG_DIR}/geosite.dat" "geosite.dat" && updated=1
    if [[ $updated -eq 1 && "$GEO_AUTO_RESTART" == "true" ]]; then
        print_info "正在重启 XrayR..."
        if svc_restart; then print_ok "服务已重启"; else print_error "重启失败"; fi
    fi
}

# 安装/卸载 cron 自动更新
_geo_install_cron() {
    _geo_load_conf
    # 创建自动更新脚本
    cat > "$GEO_UPDATE_SCRIPT" << 'GEOSCRIPT'
#!/bin/bash
# XrayR GeoData 自动更新脚本 (由 xrayr 安装/管理脚本自动生成, 请勿手工编辑)
# 特性: 每日检查 / 多源可切 / 失败重试 / 内容未变则不重启
CONFIG_DIR="/etc/XrayR"
GEO_CONFIG_FILE="/etc/XrayR/geodata.conf"
LOG="/var/log/xrayr-geo-update.log"
SERVICE_NAME="XrayR"
LOCK="/tmp/.xrayr-geo-update.lock"

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
GEO_CUSTOM_GEOIP_URL=""
GEO_CUSTOM_GEOSITE_URL=""
GEO_RETRY="3"
if [[ -f "$GEO_CONFIG_FILE" ]]; then
    source "$GEO_CONFIG_FILE"
fi

case "$GEO_SOURCE" in
    v2fly)     IP_URL="$V_IP"; SITE_URL="$V_SITE" ;;
    metacubex) IP_URL="$M_IP"; SITE_URL="$M_SITE" ;;
    soffchen)  IP_URL="$S_IP"; SITE_URL="$S_SITE" ;;
    custom)    IP_URL="$GEO_CUSTOM_GEOIP_URL"; SITE_URL="$GEO_CUSTOM_GEOSITE_URL" ;;
    *)         IP_URL="$D_IP"; SITE_URL="$D_SITE" ;;
esac

log() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" >> "$LOG"; }

hash_of() {
    if [[ ! -f "$1" ]]; then
        echo "none"
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | cut -d" " -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk "{print \$NF}"
    else
        stat -c%s-%Y "$1" 2>/dev/null || echo "unknown"
    fi
}

# 返回: 0=已更新(内容变化)  1=失败  2=内容未变
download() {
    local url="$1" dest="$2" name="$3" tmp="${2}.tmp"
    local tries="${GEO_RETRY:-3}" i=1 ok=0
    if [[ -z "$url" ]]; then
        log "ERROR: ${name} 下载地址为空 (源=${GEO_SOURCE})"
        return 1
    fi
    while [[ $i -le $tries ]]; do
        rm -f "$tmp"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 15 --max-time 300 -o "$tmp" "$url" && ok=1
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=30 -O "$tmp" "$url" && ok=1
        else
            log "ERROR: 未找到 curl/wget"
            return 1
        fi
        if [[ $ok -eq 1 && -s "$tmp" ]]; then
            break
        fi
        ok=0
        log "WARN: ${name} 第 ${i}/${tries} 次下载失败, 5 秒后重试"
        sleep 5
        i=$((i + 1))
    done
    if [[ $ok -ne 1 ]]; then
        rm -f "$tmp"
        log "ERROR: ${name} 下载失败 (已重试 ${tries} 次)"
        return 1
    fi
    local sz
    sz="$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp" 2>/dev/null || echo 0)"
    if [[ "$GEO_VERIFY" == "true" ]] && [[ "$sz" -lt 102400 ]]; then
        log "ERROR: ${name} 文件异常 (${sz} bytes, 预期 > 100KB), 保留原文件"
        rm -f "$tmp"
        return 1
    fi
    local old_h new_h
    old_h="$(hash_of "$dest")"
    new_h="$(hash_of "$tmp")"
    if [[ "$old_h" == "$new_h" ]]; then
        rm -f "$tmp"
        log "SKIP: ${name} 内容未变化, 无需替换"
        return 2
    fi
    mv -f "$tmp" "$dest"
    log "OK: ${name} 已更新 ($(awk "BEGIN{printf \"%.1f\", ${sz}/1048576}")MB, sha256 ${new_h:0:12})"
    return 0
}

# 单实例锁, 避免定时任务与手动执行叠加
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    if ! flock -n 9; then
        log "SKIP: 已有更新任务在运行"
        exit 0
    fi
fi

log "开始 GeoData 检查 [源=${GEO_SOURCE}]"
updated=0
failed=0
download "$IP_URL"   "${CONFIG_DIR}/geoip.dat"   "geoip.dat"
rc=$?
if [[ $rc -eq 0 ]]; then updated=1; fi
if [[ $rc -eq 1 ]]; then failed=1; fi
download "$SITE_URL" "${CONFIG_DIR}/geosite.dat" "geosite.dat"
rc=$?
if [[ $rc -eq 0 ]]; then updated=1; fi
if [[ $rc -eq 1 ]]; then failed=1; fi

if [[ $updated -eq 1 ]] && [[ "$GEO_AUTO_RESTART" == "true" ]]; then
    if svc_restart; then
        log "XrayR 已重启以加载新规则"
    else
        log "ERROR: XrayR 重启失败"
    fi
elif [[ $updated -eq 1 ]]; then
    log "规则已更新, 但自动重启已关闭 (需手动重启生效)"
else
    if [[ $failed -eq 1 ]]; then
        log "本次检查存在下载失败, 未做任何替换"
    else
        log "两份规则均无变化, 不重启服务"
    fi
fi
log "检查结束"
tail -300 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG"
GEOSCRIPT
    chmod +x "$GEO_UPDATE_SCRIPT"
    # 安装 cron
    local cron_line="${GEO_CRON} ${GEO_UPDATE_SCRIPT} >/dev/null 2>&1"
    # 移除旧条目
    crontab -l 2>/dev/null | grep -v "geo-update.sh" | crontab - 2>/dev/null
    # 添加新条目
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    print_ok "自动更新 cron 已安装: ${GEO_CRON}"
}

_geo_remove_cron() {
    crontab -l 2>/dev/null | grep -v "geo-update.sh" | crontab - 2>/dev/null
    rm -f "$GEO_UPDATE_SCRIPT"
    print_ok "自动更新 cron 已移除"
}

# GeoData 管理面板
menu_geodata() {
    _geo_load_conf
    while true; do
        clear
        echo -e "  ${CYAN}${BOLD}═══ GeoData 管理 ═══${NC}"
        echo ""
        # 显示当前状态
        local ip_size site_size ip_time site_time
        if [[ -f "${CONFIG_DIR}/geoip.dat" ]]; then
            ip_size=$(stat -c%s "${CONFIG_DIR}/geoip.dat" 2>/dev/null || echo 0)
            ip_size=$(awk "BEGIN{printf \"%.1f\", ${ip_size}/1048576}")MB
            ip_time=$(stat -c%Y "${CONFIG_DIR}/geoip.dat" 2>/dev/null || echo 0)
            ip_time=$(date -d "@${ip_time}" "+%Y-%m-%d %H:%M" 2>/dev/null || date -r "${ip_time}" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "未知")
        else
            ip_size="未下载"; ip_time="-"
        fi
        if [[ -f "${CONFIG_DIR}/geosite.dat" ]]; then
            site_size=$(stat -c%s "${CONFIG_DIR}/geosite.dat" 2>/dev/null || echo 0)
            site_size=$(awk "BEGIN{printf \"%.1f\", ${site_size}/1048576}")MB
            site_time=$(stat -c%Y "${CONFIG_DIR}/geosite.dat" 2>/dev/null || echo 0)
            site_time=$(date -d "@${site_time}" "+%Y-%m-%d %H:%M" 2>/dev/null || date -r "${site_time}" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "未知")
        else
            site_size="未下载"; site_time="-"
        fi
        echo -e "  ${BOLD}当前状态:${NC}"
        echo -e "    geoip.dat   : ${GREEN}${ip_size}${NC}  (${ip_time})"
        echo -e "    geosite.dat : ${GREEN}${site_size}${NC}  (${site_time})"
        echo ""
        echo -e "  ${BOLD}配置:${NC}"
        echo -e "    数据源:     ${GREEN}${GEO_SOURCE}${NC}"
        if [[ "$GEO_SOURCE" == "custom" ]]; then
            echo -e "    GeoIP URL:  ${DIM}${GEO_CUSTOM_GEOIP_URL}${NC}"
            echo -e "    GeoSite URL:${DIM}${GEO_CUSTOM_GEOSITE_URL}${NC}"
        fi
        local auto_status
        if [[ "$GEO_AUTO_UPDATE" == "true" ]]; then
            auto_status="${GREEN}已启用${NC} (${GEO_CRON})"
        else
            auto_status="${RED}已禁用${NC}"
        fi
        echo -e "    自动更新:   ${auto_status}"
        echo -e "    更新后重启: ${GEO_AUTO_RESTART}"
        echo -e "    文件校验:   ${GEO_VERIFY}"
        echo -e "    失败重试:   ${GEO_RETRY:-3} 次"
        echo -e "    ${DIM}内容无变化时不会替换文件, 也不会重启服务${NC}"
        echo ""
        echo -e "  ${GREEN}1)${NC} 立即检查并更新 GeoData"
        echo -e "  ${GREEN}2)${NC} 切换数据源"
        echo -e "  ${GREEN}3)${NC} 设置自定义 URL"
        echo -e "  ${GREEN}4)${NC} 开关自动更新"
        echo -e "  ${GREEN}5)${NC} 设置自动更新时间"
        echo -e "  ${GREEN}6)${NC} 开关更新后重启"
        echo -e "  ${GREEN}7)${NC} 开关文件校验"
        echo -e "  ${GREEN}8)${NC} 查看更新日志"
        echo -e "  ${YELLOW}0)${NC} 返回"
        echo ""
        read -erp "  请选择: " choice
        case "$choice" in
            1)
                echo ""
                do_update_geodata
                read -erp "  按回车继续..." _ ;;
            2)
                echo ""
                echo -e "  ${CYAN}选择数据源:${NC}"
                echo -e "  ${GREEN}1)${NC} Loyalsoldier (推荐, 规则全面)"
                echo -e "  ${GREEN}2)${NC} v2fly 社区 (原版 v2ray)"
                echo -e "  ${GREEN}3)${NC} MetaCubeX (Clash Meta 规则)"
                echo -e "  ${GREEN}4)${NC} soffchen (合并规则集)"
                echo -e "  ${GREEN}5)${NC} 自定义 URL"
                read -erp "  请选择 [1-5]: " src
                case "$src" in
                    1) GEO_SOURCE="loyalsoldier" ;;
                    2) GEO_SOURCE="v2fly" ;;
                    3) GEO_SOURCE="metacubex" ;;
                    4) GEO_SOURCE="soffchen" ;;
                    5) GEO_SOURCE="custom"
                       read -erp "  GeoIP URL: " GEO_CUSTOM_GEOIP_URL
                       read -erp "  GeoSite URL: " GEO_CUSTOM_GEOSITE_URL ;;
                esac
                _geo_save_conf
                [[ "$GEO_AUTO_UPDATE" == "true" ]] && _geo_install_cron
                print_ok "数据源已更新: $GEO_SOURCE"
                sleep 1 ;;
            3)
                echo ""
                echo -e "  当前自定义 URL:"
                echo -e "    GeoIP:  ${GEO_CUSTOM_GEOIP_URL:-${DIM}未设置${NC}}"
                echo -e "    GeoSite:${GEO_CUSTOM_GEOSITE_URL:-${DIM}未设置${NC}}"
                read -erp "  GeoIP 下载 URL: " GEO_CUSTOM_GEOIP_URL
                read -erp "  GeoSite 下载 URL: " GEO_CUSTOM_GEOSITE_URL
                GEO_SOURCE="custom"
                _geo_save_conf
                [[ "$GEO_AUTO_UPDATE" == "true" ]] && _geo_install_cron
                print_ok "自定义 URL 已保存"
                sleep 1 ;;
            4)
                if [[ "$GEO_AUTO_UPDATE" == "true" ]]; then
                    GEO_AUTO_UPDATE="false"
                    _geo_save_conf
                    _geo_remove_cron
                else
                    GEO_AUTO_UPDATE="true"
                    _geo_save_conf
                    _geo_install_cron
                fi
                sleep 1 ;;
            5)
                echo ""
                echo -e "  ${DIM}cron 表达式格式: 分 时 日 月 星期${NC}"
                echo -e "  ${DIM}当前: ${GEO_CRON}${NC}"
                echo -e "  ${DIM}示例: 30 4 * * *   = 每天 04:30 (默认)${NC}"
                echo -e "  ${DIM}示例: 0 3 * * * = 每天 03:00${NC}"
                echo -e "  ${DIM}示例: 0 5 */3 * * = 每3天 05:00${NC}"
                read -erp "  cron 表达式: " new_cron
                if [[ -n "$new_cron" ]]; then
                    GEO_CRON="$new_cron"
                    _geo_save_conf
                    [[ "$GEO_AUTO_UPDATE" == "true" ]] && _geo_install_cron
                    print_ok "更新时间已设置: $GEO_CRON"
                fi
                sleep 1 ;;
            6)
                if [[ "$GEO_AUTO_RESTART" == "true" ]]; then
                    GEO_AUTO_RESTART="false"
                else
                    GEO_AUTO_RESTART="true"
                fi
                _geo_save_conf
                [[ "$GEO_AUTO_UPDATE" == "true" ]] && _geo_install_cron
                print_ok "更新后重启: $GEO_AUTO_RESTART"
                sleep 1 ;;
            7)
                if [[ "$GEO_VERIFY" == "true" ]]; then
                    GEO_VERIFY="false"
                else
                    GEO_VERIFY="true"
                fi
                _geo_save_conf
                [[ "$GEO_AUTO_UPDATE" == "true" ]] && _geo_install_cron
                print_ok "文件校验: $GEO_VERIFY"
                sleep 1 ;;
            8)
                echo ""
                if [[ -f "$GEO_LOG_FILE" ]]; then
                    tail -30 "$GEO_LOG_FILE"
                else
                    echo -e "  ${DIM}暂无更新日志${NC}"
                fi
                echo ""
                read -erp "  按回车继续..." _ ;;
            0|q) return ;;
        esac
    done
}

# ========== 编辑配置 ==========
do_config() {
    local editor="${EDITOR:-nano}"
    command -v "$editor" &>/dev/null || editor="vi"
    "$editor" "${CONFIG_DIR}/config.yml"
}

# ========== 卸载 ==========
do_uninstall() {
    echo -e "${RED}${BOLD}警告: 即将完全卸载 XrayR!${NC}"
    read -erp "确认卸载? [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) ;;
        *) echo "已取消"; return ;;
    esac
    print_info "正在停止服务..."
    svc_stop
    svc_disable
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    svc_daemon_reload
    rm -rf "${INSTALL_DIR}"
    rm -f "/usr/bin/xrayr"
    read -erp "是否删除配置文件 (${CONFIG_DIR})? [y/N]: " rm_config
    case "$rm_config" in
        [yY][eE][sS]|[yY]) rm -rf "${CONFIG_DIR}"; print_ok "配置已删除" ;;
        *) print_info "配置已保留在 ${CONFIG_DIR}" ;;
    esac
    print_ok "XrayR 已卸载"
}


# ========== 主菜单 ==========

# ========== 日志大小限制 ==========
_size_h() { local b="$1"; awk -v b="$b" 'BEGIN{if(b<1024)printf "%dB",b; else if(b<1048576)printf "%.1fK",b/1024; else if(b<1073741824)printf "%.1fM",b/1048576; else printf "%.2fG",b/1073741824}'; }

_show_log_status() {
    echo -e "  ${BOLD}当前日志占用与限制:${NC}"
    echo ""
    printf "    %-32s %-10s %s\n" "日志文件" "大小" "限制/轮转"
    printf "    %-32s %-10s %s\n" "--------------------------------" "----------" "--------------------------------"
    local ju
    if [[ "$(detect_init)" == "systemd" ]]; then ju=$(journalctl -u "${SERVICE_NAME}" --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]?' | head -1); else ju=""; fi
    local jlim="未限制 (系统默认)"
    if [[ -f "$JOURNALD_LIMIT_FILE" ]]; then
        jlim=$(grep -E '^SystemMaxUse' "$JOURNALD_LIMIT_FILE" | cut -d= -f2)
        jlim="SystemMaxUse=${jlim} (systemd)"
    fi
    printf "    %-32s %-10s %s\n" "journald: XrayR 单元" "${ju:-0B}" "$jlim"
    local gz=0
    [[ -f "$GEO_LOG_FILE" ]] && gz=$(stat -c%s "$GEO_LOG_FILE" 2>/dev/null || echo 0)
    local grot="logrotate 未启用"
    if [[ -f "$LOGROTATE_FILE" ]] && grep -q "xrayr-geo-update.log" "$LOGROTATE_FILE"; then
        grot=$(awk '/xrayr-geo-update.log/,/^}/' "$LOGROTATE_FILE" | grep -E 'size|rotate' | tr '\n' ' ')
    fi
    printf "    %-32s %-10s %s\n" "$GEO_LOG_FILE" "$(_size_h $gz)" "$grot"
    for f in /etc/XrayR/access.log /etc/XrayR/error.log; do
        local sz=0
        [[ -f "$f" ]] && sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        local rot="logrotate 未启用"
        if [[ -f "$LOGROTATE_FILE" ]] && grep -qF "$f" "$LOGROTATE_FILE"; then
            rot=$(awk '/access.log|error.log/,/^}/' "$LOGROTATE_FILE" | grep -E 'size|rotate' | tr '\n' ' ')
        fi
        printf "    %-32s %-10s %s\n" "$f" "$(_size_h $sz)" "$rot"
    done
    echo ""
    echo -e "  ${BOLD}journald 全局:${NC}"
    local jtotal
    if [[ "$(detect_init)" == "systemd" ]]; then jtotal=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]?[Bb]?' | head -1); else jtotal=""; fi
    echo "    磁盘占用: ${jtotal:-N/A}"
    if [[ -f "$JOURNALD_LIMIT_FILE" ]]; then
        grep -E '^(SystemMaxUse|SystemMaxFileSize|MaxRetentionSec)' "$JOURNALD_LIMIT_FILE" | sed 's/^/    /'
    else
        echo "    未安装 XrayR 自定义限制 (使用系统默认)"
    fi
}

_install_log_limits_runtime() {
    local geo_size="${1:-2M}" geo_rot="${2:-4}"
    local acc_size="${3:-10M}" acc_rot="${4:-7}"
    local j_max="${5:-200M}" j_file="${6:-20M}" j_ret="${7:-2week}"
    cat > "$LOGROTATE_FILE" << LREOF
# XrayR 日志轮转规则 (由 xrayr log-limit 管理)
/var/log/xrayr-geo-update.log {
    weekly
    rotate ${geo_rot}
    size ${geo_size}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 root root
}
/etc/XrayR/access.log /etc/XrayR/error.log {
    daily
    rotate ${acc_rot}
    size ${acc_size}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 root root
}
LREOF
    mkdir -p /etc/systemd/journald.conf.d
    cat > "$JOURNALD_LIMIT_FILE" << JEOF
[Journal]
SystemMaxUse=${j_max}
SystemKeepFree=500M
SystemMaxFileSize=${j_file}
MaxRetentionSec=${j_ret}
RateLimitIntervalSec=30s
RateLimitBurst=10000
JEOF
    if [[ "$(detect_init)" == "systemd" ]]; then systemctl restart systemd-journald 2>/dev/null || true; fi
    logrotate -d "$LOGROTATE_FILE" &>/dev/null && print_ok "日志限制已更新" || print_warn "logrotate 规则 dry-run 有告警"
}

_run_logrotate_now() {
    if ! command -v logrotate &>/dev/null; then
        print_error "未安装 logrotate"
        return 1
    fi
    logrotate -f "$LOGROTATE_FILE" 2>&1 | tail -20
    print_ok "logrotate 已强制执行"
}

_purge_journal() {
    read -erp "  保留最近多少天的 journald 日志? [7]: " days
    days="${days:-7}"
    if [[ "$(detect_init)" == "systemd" ]]; then journalctl --vacuum-time=${days}d 2>&1 | tail -5; else echo "  非 systemd 系统, 无 journal 可清理"; fi
    print_ok "journald 已清理 (保留 ${days} 天)"
}

menu_log_limit() {
    while true; do
        clear
        echo -e "  ${CYAN}${BOLD}═══ 日志大小限制 ═══${NC}"
        echo ""
        _show_log_status
        echo ""
        echo -e "  ${GREEN}1)${NC} 安装/重置默认限制 (推荐)"
        echo -e "  ${GREEN}2)${NC} 自定义阈值 (交互输入)"
        echo -e "  ${GREEN}3)${NC} 立即执行 logrotate"
        echo -e "  ${GREEN}4)${NC} 清理 journald 旧日志"
        echo -e "  ${GREEN}5)${NC} 卸载 XrayR 日志限制 (还原系统默认)"
        echo -e "  ${YELLOW}0)${NC} 返回"
        echo ""
        read -erp "  请选择: " c
        case "$c" in
            1) _install_log_limits_runtime; read -erp "  按回车继续..." _ ;;
            2)
                read -erp "  geo-update.log 单文件大小 [2M]: " a; a=${a:-2M}
                read -erp "  geo-update.log 保留数 [4]: " b; b=${b:-4}
                read -erp "  access/error.log 单文件大小 [10M]: " cc; cc=${cc:-10M}
                read -erp "  access/error.log 保留数 [7]: " d; d=${d:-7}
                read -erp "  journald SystemMaxUse [200M]: " e; e=${e:-200M}
                read -erp "  journald SystemMaxFileSize [20M]: " f; f=${f:-20M}
                read -erp "  journald MaxRetentionSec [2week]: " g; g=${g:-2week}
                _install_log_limits_runtime "$a" "$b" "$cc" "$d" "$e" "$f" "$g"
                read -erp "  按回车继续..." _ ;;
            3) _run_logrotate_now; read -erp "  按回车继续..." _ ;;
            4) _purge_journal; read -erp "  按回车继续..." _ ;;
            5)
                rm -f "$LOGROTATE_FILE" "$JOURNALD_LIMIT_FILE"
                if [[ "$(detect_init)" == "systemd" ]]; then systemctl restart systemd-journald 2>/dev/null || true; fi
                print_ok "XrayR 日志限制已卸载"
                read -erp "  按回车继续..." _ ;;
            0|q) return ;;
        esac
    done
}

# ========== 入站 Socket 调优 ==========
# 全部为可选项，默认不改动系统既有状态。每次写入前自动备份并生成 restore.sh。

SOCKOPT_SYSCTL_FILE="/etc/sysctl.d/99-xrayr-tfo.conf"

_tfo_kernel_val() { sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0; }

_tfo_desc() {
    local v="$1"
    case "$v" in
        0) echo "完全关闭" ;;
        1) echo "仅客户端(作为服务端不接受 TFO)" ;;
        2) echo "仅服务端(推荐: 纯服务端节点)" ;;
        3) echo "客户端+服务端(推荐: 兼作出站/中转)" ;;
        *) echo "自定义位图" ;;
    esac
}

_sockopt_cfg_state() {
    if [[ ! -f "${CONFIG_DIR}/config.yml" ]]; then
        echo "未安装"
        return
    fi
    if grep -qE '^[[:space:]]*SocketConfig:[[:space:]]*$' "${CONFIG_DIR}/config.yml" 2>/dev/null; then
        if grep -qE '^[[:space:]]*TCPFastOpen:[[:space:]]*true' "${CONFIG_DIR}/config.yml" 2>/dev/null; then
            echo "已启用"
        else
            echo "已配置但未开启 TFO"
        fi
    else
        echo "未配置(保持默认)"
    fi
}

_show_sockopt_status() {
    local kv kd cs nodes
    kv="$(_tfo_kernel_val)"
    kd="$(_tfo_desc "$kv")"
    cs="$(_sockopt_cfg_state)"
    echo -e "  ${BOLD}当前状态${NC}"
    echo "  ┌────────────────────┬──────────────────────────────────────────┐"
    printf '  │ %s │ %s │\n' "$(pad_disp '内核 TFO 开关' 18)" "$(pad_disp "${kv} (${kd})" 40)"
    printf '  │ %s │ %s │\n' "$(pad_disp 'XrayR 配置状态' 18)" "$(pad_disp "${cs}" 40)"
    if [[ -f /proc/sys/net/ipv4/tcp_fastopen_blackhole_timeout_sec ]]; then
        local bh
        bh="$(sysctl -n net.ipv4.tcp_fastopen_blackhole_timeout_sec 2>/dev/null)"
        local bhd="已禁用黑洞检测(推荐)"
        if [[ "$bh" != "0" ]]; then bhd="${bh}秒内探测到丢包则暂停 TFO"; fi
        printf '  │ %s │ %s │\n' "$(pad_disp '黑洞检测' 18)" "$(pad_disp "${bhd}" 40)"
    fi
    echo "  └────────────────────┴──────────────────────────────────────────┘"
    echo ""
    echo -e "  ${BOLD}TFO 握手统计 (内核累计)${NC}"
    if command -v nstat >/dev/null 2>&1; then
        local pass pfail ckreq ovf
        pass="$(nstat -az 2>/dev/null  | awk '/TCPFastOpenPassive /{print $2}')"
        pfail="$(nstat -az 2>/dev/null | awk '/TCPFastOpenPassiveFail/{print $2}')"
        ckreq="$(nstat -az 2>/dev/null | awk '/TCPFastOpenCookieReqd/{print $2}')"
        ovf="$(nstat -az 2>/dev/null   | awk '/TCPFastOpenListenOverflow/{print $2}')"
        echo "  ┌──────────────────────────────┬────────────┐"
        printf '  │ %s │ %s │\n' "$(pad_disp '成功接受的 TFO 连接' 28)" "$(pad_disp "${pass:-0}" 10)"
        printf '  │ %s │ %s │\n' "$(pad_disp '接受失败次数' 28)" "$(pad_disp "${pfail:-0}" 10)"
        printf '  │ %s │ %s │\n' "$(pad_disp '客户端索取 cookie 次数' 28)" "$(pad_disp "${ckreq:-0}" 10)"
        printf '  │ %s │ %s │\n' "$(pad_disp '半开队列溢出' 28)" "$(pad_disp "${ovf:-0}" 10)"
        echo "  └──────────────────────────────┴────────────┘"
        if [[ "${pass:-0}" == "0" && "${ckreq:-0}" != "0" ]]; then
            print_warn "检测到客户端在索取 cookie 但无成功连接: 内核服务端位可能未开启"
        fi
        if [[ "${ovf:-0}" != "0" ]]; then
            print_warn "半开队列有溢出: 建议增大 TCPFastOpenQueueLength"
        fi
    else
        echo "  (未安装 nstat, 无法读取统计; 可执行 apt install iproute2)"
    fi
}

_sockopt_backup() {
    local ts bk
    ts="$(date +%Y%m%d-%H%M%S)"
    bk="/root/xrayr-restore-${ts}-sockopt"
    mkdir -p "$bk" || return 1
    cp -f "${CONFIG_DIR}/config.yml" "${bk}/config.yml" 2>/dev/null
    _tfo_kernel_val > "${bk}/tcp_fastopen.val"
    if [[ -f "$SOCKOPT_SYSCTL_FILE" ]]; then
        cp -f "$SOCKOPT_SYSCTL_FILE" "${bk}/99-xrayr-tfo.conf"
    fi
    {
        echo '#!/bin/bash'
        echo '# 回滚入站 Socket 调优到本次修改之前的状态'
        echo "if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl stop XrayR 2>/dev/null; elif command -v rc-service >/dev/null 2>&1; then rc-service XrayR stop 2>/dev/null; elif [ -x /etc/init.d/XrayR ]; then /etc/init.d/XrayR stop 2>/dev/null; else pkill -f '/usr/local/XrayR/XrayR --config' 2>/dev/null; fi"
        echo "cp -f '${bk}/config.yml' '${CONFIG_DIR}/config.yml'"
        echo "sysctl -w net.ipv4.tcp_fastopen=\$(cat '${bk}/tcp_fastopen.val') >/dev/null"
        if [[ -f "${bk}/99-xrayr-tfo.conf" ]]; then
            echo "cp -f '${bk}/99-xrayr-tfo.conf' '${SOCKOPT_SYSCTL_FILE}'"
        else
            echo "rm -f '${SOCKOPT_SYSCTL_FILE}'"
        fi
        echo "if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl start XrayR 2>/dev/null; elif command -v rc-service >/dev/null 2>&1; then rc-service XrayR start 2>/dev/null; elif [ -x /etc/init.d/XrayR ]; then /etc/init.d/XrayR start 2>/dev/null; else setsid nohup /usr/local/XrayR/XrayR --config /etc/XrayR/config.yml >> /var/log/xrayr.log 2>&1 < /dev/null & fi"
        echo "sleep 2"
        echo "if pgrep -f '/usr/local/XrayR/XrayR --config' >/dev/null 2>&1; then echo '已回滚, 服务状态: 运行中'; else echo '已回滚, 服务状态: 已停止'; fi"
    } > "${bk}/restore.sh"
    chmod +x "${bk}/restore.sh"
    echo "$bk"
}

_set_kernel_tfo() {
    local want="$1"
    sysctl -w "net.ipv4.tcp_fastopen=${want}" >/dev/null 2>&1 || return 1
    cat > "$SOCKOPT_SYSCTL_FILE" <<EOF
# 由 XrayR 管理脚本写入: 入站 TCP Fast Open
net.ipv4.tcp_fastopen = ${want}
# 禁用黑洞检测, 避免个别链路丢包导致内核长时间停用 TFO
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 0
EOF
    sysctl -p "$SOCKOPT_SYSCTL_FILE" >/dev/null 2>&1
    return 0
}

menu_sockopt() {
    while true; do
        clear
        echo -e "  ${CYAN}${BOLD}═══ 入站 Socket 调优 ═══${NC}"
        echo ""
        _show_sockopt_status
        echo ""
        echo -e "  ${GREEN}1)${NC} 一键开启 TFO (推荐: 自动设内核 + 写配置)"
        echo -e "  ${GREEN}2)${NC} 仅设置内核 TFO 开关"
        echo -e "  ${GREEN}3)${NC} 编辑 XrayR SocketConfig (逐项交互)"
        echo -e "  ${GREEN}4)${NC} 关闭 TFO (仅改 XrayR, 不动内核)"
        echo -e "  ${GREEN}5)${NC} 完全移除 SocketConfig (回到默认行为)"
        echo -e "  ${GREEN}6)${NC} 重置 TFO 统计计数"
        echo -e "  ${YELLOW}0)${NC} 返回"
        echo ""
        read -erp "  请选择: " c
        case "$c" in
            1) _sockopt_enable_all; read -erp "  按回车继续..." _ ;;
            2) _sockopt_kernel_only; read -erp "  按回车继续..." _ ;;
            3) _sockopt_edit; read -erp "  按回车继续..." _ ;;
            4) _sockopt_disable_tfo; read -erp "  按回车继续..." _ ;;
            5) _sockopt_remove; read -erp "  按回车继续..." _ ;;
            6)
                if command -v nstat >/dev/null 2>&1; then
                    nstat >/dev/null 2>&1
                    print_ok "统计计数已重置"
                else
                    print_error "未安装 nstat"
                fi
                read -erp "  按回车继续..." _ ;;
            0|q) return ;;
            *) print_error "无效选项"; sleep 1 ;;
        esac
    done
}

_sockopt_kernel_only() {
    local cur
    cur="$(_tfo_kernel_val)"
    echo ""
    echo -e "  ${BOLD}内核 TFO 位图取值说明${NC}"
    echo "  ┌──────┬──────────────────────────────────────────────────┐"
    printf '  │ %s │ %s │\n' "$(pad_disp '取值' 4)" "$(pad_disp '含义' 48)"
    echo "  ├──────┼──────────────────────────────────────────────────┤"
    printf '  │ %s │ %s │\n' "$(pad_disp '0' 4)" "$(pad_disp '完全关闭 TFO' 48)"
    printf '  │ %s │ %s │\n' "$(pad_disp '1' 4)" "$(pad_disp '仅客户端: 本机对外发起时用, 作为服务端不接受' 48)"
    printf '  │ %s │ %s │\n' "$(pad_disp '2' 4)" "$(pad_disp '仅服务端: 纯节点机推荐, 攻击面最小' 48)"
    printf '  │ %s │ %s │\n' "$(pad_disp '3' 4)" "$(pad_disp '客户端+服务端: 兼做中转/出站时推荐' 48)"
    echo "  └──────┴──────────────────────────────────────────────────┘"
    echo ""
    echo "  提示: XrayR 作为入站服务端只需要位 2。若本机同时用 XrayR 出站到"
    echo "        上游代理(custom_outbound 里配了 socks/http/vless 上游),"
    echo "        则需要位 1 才能对上游发起 TFO, 此时选 3。"
    echo ""
    read -erp "  设为 [0/1/2/3, 当前=${cur}, 回车取消]: " want
    if [[ -z "$want" ]]; then echo "  已取消"; return; fi
    if [[ ! "$want" =~ ^[0-9]+$ ]]; then print_error "必须是数字"; return; fi
    local bk
    bk="$(_sockopt_backup)"
    if _set_kernel_tfo "$want"; then
        print_ok "内核 TFO 已设为 ${want} ($(_tfo_desc "$want"))"
        echo "  已持久化到 ${SOCKOPT_SYSCTL_FILE}"
        echo "  回滚脚本: ${bk}/restore.sh"
    else
        print_error "设置失败"
    fi
}

_sockopt_enable_all() {
    if [[ ! -f "${CONFIG_DIR}/config.yml" ]]; then
        print_error "未找到配置文件"
        return
    fi
    echo ""
    echo "  将执行以下操作:"
    echo "    1) 备份当前配置并生成 restore.sh"
    echo "    2) 内核 net.ipv4.tcp_fastopen 设为 3 并持久化"
    echo "    3) 在每个节点 ControllerConfig 下写入 SocketConfig.TCPFastOpen=true"
    echo "    4) 重启 XrayR 并校验"
    echo ""
    read -erp "  确认继续? [y/N]: " ok
    if [[ ! "$ok" =~ ^[Yy]$ ]]; then echo "  已取消"; return; fi

    local bk
    bk="$(_sockopt_backup)"
    print_ok "备份完成: ${bk}"

    _set_kernel_tfo 3 && print_ok "内核 TFO 已设为 3"

    if helper sockopt-set --tcp-fast-open true --queue-length 4096 \
        --keepalive-idle 30 --keepalive-interval 15 2>/dev/null; then
        print_ok "SocketConfig 已写入"
    else
        print_error "配置写入失败, 可用 ${bk}/restore.sh 回滚"
        return
    fi

    echo ""
    print_info "重启服务..."
    svc_restart
    sleep 4
    if svc_is_active; then
        print_ok "服务运行正常"
        echo ""
        echo "  验证方式: 让客户端连接后回到本菜单查看"
        echo "  「成功接受的 TFO 连接」计数是否增长。"
        echo "  回滚: ${bk}/restore.sh"
    else
        print_error "服务启动失败! 正在自动回滚..."
        bash "${bk}/restore.sh"
    fi
}

_sockopt_edit() {
    if [[ ! -f "${CONFIG_DIR}/config.yml" ]]; then
        print_error "未找到配置文件"
        return
    fi
    echo ""
    echo -e "  ${BOLD}逐项设置 (回车 = 保持当前/跳过)${NC}"
    echo ""
    local a b c d e f g h i j
    read -erp "  开启 TCP Fast Open? [true/false]: " a
    read -erp "  TFO 半开队列长度 [建议 4096]: " b
    read -erp "  keepalive 空闲秒数 [建议 30]: " c
    read -erp "  keepalive 探测间隔秒 [建议 15]: " d
    read -erp "  TCPUserTimeout 毫秒 [0=不设置]: " e
    read -erp "  该入站拥塞算法 [如 bbr, 空=不改]: " f
    read -erp "  开启 Multipath TCP? [true/false]: " g
    read -erp "  TCPWindowClamp 字节 [0=不设置]: " h
    read -erp "  TCPMaxSeg 字节 [0=不设置]: " i
    read -erp "  绑定网卡名 [空=不绑定]: " j

    local args=()
    [[ -n "$a" ]] && args+=(--tcp-fast-open "$a")
    [[ -n "$b" ]] && args+=(--queue-length "$b")
    [[ -n "$c" ]] && args+=(--keepalive-idle "$c")
    [[ -n "$d" ]] && args+=(--keepalive-interval "$d")
    [[ -n "$e" ]] && args+=(--user-timeout "$e")
    [[ -n "$f" ]] && args+=(--congestion "$f")
    [[ -n "$g" ]] && args+=(--mptcp "$g")
    [[ -n "$h" ]] && args+=(--window-clamp "$h")
    [[ -n "$i" ]] && args+=(--max-seg "$i")
    [[ -n "$j" ]] && args+=(--bind-interface "$j")

    if [[ ${#args[@]} -eq 0 ]]; then
        echo "  未做任何修改"
        return
    fi

    local bk
    bk="$(_sockopt_backup)"
    if helper sockopt-set "${args[@]}"; then
        print_ok "已写入, 备份: ${bk}"
        read -erp "  立即重启服务生效? [Y/n]: " r
        if [[ ! "$r" =~ ^[Nn]$ ]]; then
            svc_restart
            sleep 3
            if svc_is_active; then
                print_ok "服务运行正常"
            else
                print_error "启动失败, 自动回滚"
                bash "${bk}/restore.sh"
            fi
        fi
    else
        print_error "写入失败"
    fi
}

_sockopt_disable_tfo() {
    local bk
    bk="$(_sockopt_backup)"
    if helper sockopt-set --tcp-fast-open false; then
        print_ok "已关闭 XrayR 侧 TFO (内核开关未改动)"
        svc_restart
        sleep 3
        if svc_is_active; then print_ok "服务正常"; fi
        echo "  回滚: ${bk}/restore.sh"
    else
        print_error "操作失败"
    fi
}

_sockopt_remove() {
    read -erp "  确认移除全部 SocketConfig, 回到默认行为? [y/N]: " ok
    if [[ ! "$ok" =~ ^[Yy]$ ]]; then echo "  已取消"; return; fi
    local bk
    bk="$(_sockopt_backup)"
    if helper sockopt-remove; then
        print_ok "SocketConfig 已移除"
        read -erp "  同时还原内核 TFO 开关? [y/N]: " k
        if [[ "$k" =~ ^[Yy]$ ]]; then
            rm -f "$SOCKOPT_SYSCTL_FILE"
            sysctl -w net.ipv4.tcp_fastopen=1 >/dev/null 2>&1
            print_ok "内核 TFO 已还原为 1 (系统默认)"
        fi
        svc_restart
        sleep 3
        if svc_is_active; then print_ok "服务正常"; fi
        echo "  回滚: ${bk}/restore.sh"
    else
        print_error "操作失败"
    fi
}

show_main_menu() {
    clear
    echo ""
    echo -e "  ${CYAN}${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}${BOLD}║        XrayR 管理面板                ║${NC}"
    echo -e "  ${CYAN}${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""
    show_status
    if [[ -f /etc/XrayR/.update-available ]]; then
        local _nv
        _nv="$(cat /etc/XrayR/.update-available 2>/dev/null)"
        if [[ -n "$_nv" ]]; then
            echo -e "  ${GREEN}${BOLD}▸ 发现新版本 ${_nv}${NC} ${DIM}(选 20 进入更新管理)${NC}"
        fi
    fi
    echo ""
    echo -e "  ${GREEN}${BOLD}─── 服务控制 ───${NC}"
    echo -e "  ${GREEN} 1)${NC} 启动        ${GREEN} 2)${NC} 停止        ${GREEN}3)${NC} 重启"
    echo -e "  ${GREEN} 4)${NC} 查看状态    ${GREEN} 5)${NC} 实时日志    ${GREEN}6)${NC} 近期日志"
    echo ""
    echo -e "  ${BLUE}${BOLD}─── 配置管理 ───${NC}"
    echo -e "  ${BLUE} 7)${NC} 节点/面板管理          ${BLUE} 8)${NC} 路由规则管理"
    echo -e "  ${BLUE} 9)${NC} 出站规则管理          ${BLUE}10)${NC} 入站规则管理"
    echo -e "  ${BLUE}11)${NC} DNS 配置              ${BLUE}12)${NC} 全局设置"
    echo -e "  ${BLUE}13)${NC} 编辑配置文件 (文本)"
    echo ""
    echo -e "  ${YELLOW}${BOLD}─── 系统维护 ───${NC}"
    echo -e "  ${YELLOW}14)${NC} GeoData 管理         ${YELLOW}15)${NC} 开启自启"
    echo -e "  ${YELLOW}16)${NC} 关闭自启             ${YELLOW}17)${NC} 查看版本"
    echo -e "  ${YELLOW}19)${NC} 日志大小限制         ${YELLOW}20)${NC} ${BOLD}更新管理${NC}"
    echo -e "  ${YELLOW}21)${NC} 入站 Socket 调优"
    echo ""
    echo -e "  ${RED}${BOLD}─── 危险操作 ───${NC}"
    echo -e "  ${RED}18)${NC} 卸载 XrayR"
    echo ""
    echo -e "  ${BOLD} 0)${NC} 退出"
    echo ""
}

interactive_menu() {
    while true; do
        show_main_menu
        read -erp "  请选择 [0-21]: " choice
        echo ""
        case "$choice" in
            1) do_start ;;
            2) do_stop ;;
            3) do_restart ;;
            4) do_status ;;
            5) do_log ;;
            6) do_log_recent ;;
            7) menu_nodes; continue ;;
            8) menu_routes; continue ;;
            9) menu_outbounds; continue ;;
            10) menu_inbounds; continue ;;
            11) menu_dns; continue ;;
            12) menu_global; continue ;;
            13) do_config ;;
            14) menu_geodata; continue ;;
            15) do_enable ;;
            16) do_disable ;;
            17) do_version ;;
            18) do_uninstall; exit 0 ;;
            19) menu_log_limit; continue ;;
            20) do_update_mgmt update-menu ;;
            21) menu_sockopt; continue ;;
            0) exit 0 ;;
            *) print_error "无效选项" ;;
        esac
        echo ""
        read -erp "  按回车继续..." _
    done
}

# ========== CLI 模式 ==========
cli_mode() {
    case "$1" in
        start)       do_start ;;
        stop)        do_stop ;;
        restart)     do_restart ;;
        status)      do_status ;;
        log)         do_log ;;
        log-recent)  do_log_recent ;;
        enable)      do_enable ;;
        disable)     do_disable ;;
        config)      do_config ;;
        update-geo)  menu_geodata ;;
        uninstall)   do_uninstall ;;
        version)     do_version ;;
        nodes)       menu_nodes ;;
        routes)      menu_routes ;;
        outbounds)   menu_outbounds ;;
        inbounds)    menu_inbounds ;;
        dns)         menu_dns ;;
        global)      menu_global ;;
        log-limit)   menu_log_limit ;;
        update|upgrade)
            shift
            do_update_mgmt update "$@" ;;
        check-update)
            do_update_mgmt check-update ;;
        self-update)
            do_update_mgmt self-update ;;
        update-menu)
            do_update_mgmt update-menu ;;
        import-link|import)
            shift
            if [[ $# -eq 0 ]]; then
                import_link_interactive
            else
                helper import-link "$@"
            fi
            ;;
        export-links|export)
            helper export-links ;;
        help|--help|-h)
            echo "XrayR 管理工具"
            echo ""
            echo "用法: xrayr [命令]"
            echo ""
            echo "服务控制:"
            echo "  start        启动服务"
            echo "  stop         停止服务"
            echo "  restart      重启服务"
            echo "  status       查看状态"
            echo "  log          实时日志"
            echo "  log-recent   近期日志"
            echo ""
            echo "配置管理:"
            echo "  nodes        节点/面板管理"
            echo "  routes       路由规则管理"
            echo "  outbounds    出站规则管理"
            echo "  inbounds     入站规则管理"
            echo "  dns          DNS 配置"
            echo "  global       全局设置"
            echo "  config       文本编辑配置"
            echo ""
            echo "链接导入/导出:"
            echo "  import-link [links...]  导入分享链接 (vmess/vless/trojan/ss/hy2)"
            echo "  export-links            导出所有出站为分享链接"
            echo ""
            echo "系统维护:"
            echo "  update-geo   GeoData 管理"
            echo "  enable       开启自启"
            echo "  disable      关闭自启"
            echo "  version      查看版本"
            echo "  log-limit    日志大小限制管理"
            echo ""
            echo "更新管理 (转发到 xrayr-install):"
            echo "  update-menu       进入更新管理面板"
            echo "  check-update      检测更新"
            echo "  update            升级到最新版"
            echo "  update <版本>     更新到指定版本, 例 update v0.9.5"
            echo "  update list       列出可用版本"
            echo "  self-update       更新安装脚本自身"
            echo "  uninstall    卸载 XrayR"
            echo ""
            echo "不带参数: 打开交互式管理面板"
            ;;
        *)
            print_error "未知命令: $1"
            echo "运行 'xrayr help' 查看帮助"
            return 1 ;;
    esac
}

# ========== 入口 ==========
# 每次启动时静默检查/升级脚本自身与 install.sh (缓存 1 小时)
# 参数会通过 exec 透传, 用户无感知
_mgr_silent_selfupdate "$@"

if [[ $# -eq 0 ]]; then
    interactive_menu
else
    cli_mode "$@"
fi
