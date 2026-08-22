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
# 服务单元路径由 init 系统决定, 在 detect_init() 中最终确定
SERVICE_FILE="/etc/systemd/system/XrayR.service"
# 当前 init 系统: systemd / openrc / sysvinit / procd / none
INIT_SYS=""
COMMAND_LINK="/usr/local/bin/xrayr"

# ==================== 版本与在线更新 ====================
# 本安装脚本自身的版本号 (每次发布递增, 用于脚本自更新比对)
SCRIPT_VERSION="1.3.1"
# 记录已安装的版本元数据 (二进制版本 / 脚本版本 / 安装时间 / 内嵌内核)
VERSION_STATE_FILE="/etc/XrayR/.version"
# 更新检查缓存 (避免频繁打 GitHub API), 单位秒
UPDATE_CACHE_FILE="/var/lib/.xrayr-update-cache"
UPDATE_CACHE_TTL=3600
# 自动检查更新开关配置
UPDATE_CONF_FILE="/etc/XrayR/update.conf"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"

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

# ==================== init 系统抽象层 ====================
# 目标: 同一套逻辑覆盖 systemd / OpenRC(Alpine,Gentoo) / SysVinit(老 Debian,CentOS6)
#       / procd(OpenWrt)。所有服务操作统一走 svc_* 函数, 不再直接调 systemctl。

# 按 init 类型确定服务单元路径
_init_set_service_file() {
    case "$INIT_SYS" in
        systemd)  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service" ;;
        openrc)   SERVICE_FILE="/etc/init.d/${SERVICE_NAME}" ;;
        sysvinit) SERVICE_FILE="/etc/init.d/${SERVICE_NAME}" ;;
        procd)    SERVICE_FILE="/etc/init.d/${SERVICE_NAME}" ;;
        *)        SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service" ;;
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
            *)
                echo "XRAYR_INIT 取值非法: ${XRAYR_INIT} (可选 systemd/openrc/sysvinit/procd/none)" >&2 ;;
        esac
    fi
    # 1) systemd: /run/systemd/system 存在且 systemctl 可用 (最可靠, 不看 PID1 名字)
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        INIT_SYS="systemd"
    # 2) procd (OpenWrt): 有 /etc/rc.common 与 procd 二进制
    elif [[ -f /etc/rc.common ]] && ( [[ -x /sbin/procd ]] || grep -qi openwrt /etc/os-release 2>/dev/null ); then
        INIT_SYS="procd"
    # 3) OpenRC: rc-service / rc-update 存在
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        INIT_SYS="openrc"
    # 4) SysVinit: /etc/init.d 可写 + service 或 update-rc.d/chkconfig
    elif [[ -d /etc/init.d ]] && ( command -v service >/dev/null 2>&1 || command -v update-rc.d >/dev/null 2>&1 || command -v chkconfig >/dev/null 2>&1 ); then
        INIT_SYS="sysvinit"
    # 5) 兜底: systemctl 存在但没有 /run/systemd (容器里常见), 仍按 systemd 试
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
        *)        echo "无 (裸进程管理)" ;;
    esac
    return 0
}

# 无 init 系统时的 PID 文件 (裸进程守护模式)
BARE_PIDFILE="/var/run/xrayr.pid"

svc_start() {
    case "$(detect_init)" in
        systemd)  systemctl start "$SERVICE_NAME" >/dev/null 2>&1 ;;
        openrc)   rc-service "$SERVICE_NAME" start >/dev/null 2>&1 ;;
        sysvinit) if command -v service >/dev/null 2>&1; then service "$SERVICE_NAME" start >/dev/null 2>&1; else "/etc/init.d/${SERVICE_NAME}" start >/dev/null 2>&1; fi ;;
        procd)    "/etc/init.d/${SERVICE_NAME}" start >/dev/null 2>&1 ;;
        *)        bare_start ;;
    esac
    return $?
}

svc_stop() {
    case "$(detect_init)" in
        systemd)  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 ;;
        openrc)   rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 ;;
        sysvinit) if command -v service >/dev/null 2>&1; then service "$SERVICE_NAME" stop >/dev/null 2>&1; else "/etc/init.d/${SERVICE_NAME}" stop >/dev/null 2>&1; fi ;;
        procd)    "/etc/init.d/${SERVICE_NAME}" stop >/dev/null 2>&1 ;;
        *)        bare_stop ;;
    esac
    return $?
}

svc_restart() {
    case "$(detect_init)" in
        systemd)  systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 ;;
        openrc)   rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 ;;
        sysvinit) if command -v service >/dev/null 2>&1; then service "$SERVICE_NAME" restart >/dev/null 2>&1; else "/etc/init.d/${SERVICE_NAME}" restart >/dev/null 2>&1; fi ;;
        procd)    "/etc/init.d/${SERVICE_NAME}" restart >/dev/null 2>&1 ;;
        *)        bare_stop; sleep 1; bare_start ;;
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
                chkconfig --add "$SERVICE_NAME" >/dev/null 2>&1
                chkconfig "$SERVICE_NAME" on >/dev/null 2>&1
            fi ;;
        procd)
            "/etc/init.d/${SERVICE_NAME}" enable >/dev/null 2>&1
            # procd 环境不完整时上面会静默失败, 手工建 rc.d 链接兜底
            if ! ls /etc/rc.d/S??"${SERVICE_NAME}" >/dev/null 2>&1; then
                mkdir -p /etc/rc.d 2>/dev/null
                ln -sf "/etc/init.d/${SERVICE_NAME}" "/etc/rc.d/S99${SERVICE_NAME}" 2>/dev/null
            fi ;;
        *)        bare_enable ;;
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
        *)        bare_disable ;;
    esac
    return $?
}

# 服务是否在运行 (返回 0=运行中)
svc_is_active() {
    case "$(detect_init)" in
        systemd)  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; return $? ;;
        openrc)   rc-service "$SERVICE_NAME" status 2>/dev/null | grep -qE "status: started|已启动"; return $? ;;
        sysvinit|procd)
            if pgrep -f "${INSTALL_DIR}/XrayR" >/dev/null 2>&1; then return 0; fi
            return 1 ;;
        *)
            if pgrep -f "${INSTALL_DIR}/XrayR" >/dev/null 2>&1; then return 0; fi
            return 1 ;;
    esac
}

# 是否开机自启 (返回 0=已启用)
svc_is_enabled() {
    case "$(detect_init)" in
        systemd)  systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; return $? ;;
        openrc)   rc-update show default 2>/dev/null | grep -q "^\s*${SERVICE_NAME}\b"; return $? ;;
        sysvinit) ls /etc/rc[2-5].d/S??"${SERVICE_NAME}" >/dev/null 2>&1; return $? ;;
        procd)    ls /etc/rc.d/S??"${SERVICE_NAME}" >/dev/null 2>&1; return $? ;;
        *)        [[ -f /etc/xrayr-bare-autostart ]]; return $? ;;
    esac
}

# 重载 init 配置 (仅 systemd 需要)
svc_daemon_reload() {
    if [[ "$(detect_init)" == "systemd" ]]; then
        systemctl daemon-reload >/dev/null 2>&1
    fi
    return 0
}

# 服务状态文本 (人读)
svc_status_text() {
    case "$(detect_init)" in
        systemd)  systemctl status "$SERVICE_NAME" --no-pager -l 2>&1 | head -30 ;;
        openrc)   rc-service "$SERVICE_NAME" status 2>&1 | head -20 ;;
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

# 查看日志。systemd 走 journalctl, 其余走文件日志。
BARE_LOGFILE="/var/log/xrayr.log"
svc_log_tail() {
    local n="${1:-50}"
    if [[ "$(detect_init)" == "systemd" ]]; then
        journalctl -u "$SERVICE_NAME" -n "$n" --no-pager 2>&1 | tail -"$n"
    elif [[ -f "$BARE_LOGFILE" ]]; then
        tail -n "$n" "$BARE_LOGFILE"
    else
        echo "  未找到日志 (${BARE_LOGFILE} 不存在)"
    fi
    return 0
}

svc_log_follow() {
    if [[ "$(detect_init)" == "systemd" ]]; then
        journalctl -u "$SERVICE_NAME" -f --no-pager
    elif [[ -f "$BARE_LOGFILE" ]]; then
        tail -f "$BARE_LOGFILE"
    else
        echo "  未找到日志 (${BARE_LOGFILE} 不存在)"
    fi
    return 0
}

# ---------- 裸进程守护 (无 init 系统时) ----------
bare_start() {
    if svc_is_active; then
        return 0
    fi
    mkdir -p "$(dirname "$BARE_LOGFILE")" 2>/dev/null
    setsid nohup "${INSTALL_DIR}/XrayR" --config "${CONFIG_DIR}/config.yml" \
        >> "$BARE_LOGFILE" 2>&1 < /dev/null &
    echo $! > "$BARE_PIDFILE" 2>/dev/null
    sleep 1
    svc_is_active
    return $?
}

bare_stop() {
    local p
    if [[ -f "$BARE_PIDFILE" ]]; then
        p="$(cat "$BARE_PIDFILE" 2>/dev/null)"
        if [[ -n "$p" ]]; then
            kill "$p" 2>/dev/null
        fi
    fi
    pkill -f "${INSTALL_DIR}/XrayR --config" 2>/dev/null
    rm -f "$BARE_PIDFILE" 2>/dev/null
    return 0
}

# 无 init 时用 cron @reboot 实现开机自启
bare_enable() {
    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "xrayr-bare-boot"; \
         echo "@reboot ${INSTALL_DIR}/xrayr-bare-boot.sh >/dev/null 2>&1 # xrayr-bare-boot") | crontab -
    fi
    cat > "${INSTALL_DIR}/xrayr-bare-boot.sh" <<BAREEOF
#!/bin/sh
sleep 5
exec ${INSTALL_DIR}/XrayR --config ${CONFIG_DIR}/config.yml >> ${BARE_LOGFILE} 2>&1
BAREEOF
    chmod +x "${INSTALL_DIR}/xrayr-bare-boot.sh"
    touch /etc/xrayr-bare-autostart
    return 0
}

bare_disable() {
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "xrayr-bare-boot" | crontab - >/dev/null 2>&1
    fi
    rm -f /etc/xrayr-bare-autostart
    return 0
}

# 尝试启用 cron 守护 (跨 init 系统)。成功返回 0。
_try_enable_cron_svc() {
    local svc="$1"
    case "$(detect_init)" in
        systemd)
            if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
                systemctl enable --now "$svc" >/dev/null 2>&1
                return 0
            fi
            return 1 ;;
        openrc)
            if [[ -f "/etc/init.d/$svc" ]]; then
                rc-update add "$svc" default >/dev/null 2>&1
                rc-service "$svc" start >/dev/null 2>&1
                return 0
            fi
            return 1 ;;
        sysvinit|procd)
            if [[ -f "/etc/init.d/$svc" ]]; then
                if command -v update-rc.d >/dev/null 2>&1; then
                    update-rc.d "$svc" defaults >/dev/null 2>&1
                elif command -v chkconfig >/dev/null 2>&1; then
                    chkconfig "$svc" on >/dev/null 2>&1
                fi
                "/etc/init.d/$svc" start >/dev/null 2>&1
                return 0
            fi
            return 1 ;;
        *)
            # 无 init: 直接尝试拉起 crond 前台守护
            if command -v crond >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1; then
                setsid nohup crond >/dev/null 2>&1 < /dev/null &
                return 0
            fi
            return 1 ;;
    esac
}



# ==================== 依赖管理 ====================
PKG_MGR=""
PKG_UPDATED=0

detect_pkg_mgr() {
    # 顺序有讲究: opkg/apk 要优先于通用判断, 避免 OpenWrt 上误判
    if command -v opkg >/dev/null 2>&1; then
        PKG_MGR="opkg"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    elif command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MGR="zypper"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MGR="pacman"
    elif command -v xbps-install >/dev/null 2>&1; then
        PKG_MGR="xbps"
    elif command -v emerge >/dev/null 2>&1; then
        PKG_MGR="emerge"
    elif command -v swupd >/dev/null 2>&1; then
        PKG_MGR="swupd"
    elif command -v eopkg >/dev/null 2>&1; then
        PKG_MGR="eopkg"
    elif command -v urpmi >/dev/null 2>&1; then
        PKG_MGR="urpmi"
    elif command -v slackpkg >/dev/null 2>&1; then
        PKG_MGR="slackpkg"
    elif command -v nix-env >/dev/null 2>&1; then
        PKG_MGR="nix"
    else
        PKG_MGR=""
    fi
    return 0
}

# 包管理器中文名, 用于安装时展示
# 回显包管理器名称(供 $(...) 取值用; detect_pkg_mgr 只设变量不输出)
pkg_mgr_name() {
    detect_pkg_mgr
    echo "${PKG_MGR}"
    return 0
}

pkg_mgr_desc() {
    case "${1:-$PKG_MGR}" in
        apt)      echo "apt (Debian/Ubuntu 系)" ;;
        dnf)      echo "dnf (Fedora/RHEL9+)" ;;
        yum)      echo "yum (CentOS/RHEL7-8)" ;;
        apk)      echo "apk (Alpine)" ;;
        pacman)   echo "pacman (Arch/Manjaro)" ;;
        zypper)   echo "zypper (openSUSE/SLES)" ;;
        opkg)     echo "opkg (OpenWrt/LEDE)" ;;
        xbps)     echo "xbps (Void Linux)" ;;
        emerge)   echo "emerge (Gentoo)" ;;
        swupd)    echo "swupd (Clear Linux)" ;;
        eopkg)    echo "eopkg (Solus)" ;;
        urpmi)    echo "urpmi (Mageia/OpenMandriva)" ;;
        slackpkg) echo "slackpkg (Slackware)" ;;
        nix)      echo "nix (NixOS)" ;;
        *)        echo "未识别" ;;
    esac
    return 0
}

# 发行版识别 (仅用于展示与问题定位)
detect_distro() {
    local n=""
    if [[ -f /etc/os-release ]]; then
        n="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$NAME $VERSION_ID}")"
    fi
    if [[ -z "$n" ]] && [[ -f /etc/openwrt_release ]]; then
        n="$(. /etc/openwrt_release 2>/dev/null; echo "OpenWrt ${DISTRIB_RELEASE}")"
    fi
    if [[ -z "$n" ]] && [[ -f /etc/redhat-release ]]; then
        n="$(head -1 /etc/redhat-release 2>/dev/null)"
    fi
    if [[ -z "$n" ]] && [[ -f /etc/alpine-release ]]; then
        n="Alpine Linux $(head -1 /etc/alpine-release 2>/dev/null)"
    fi
    if [[ -z "$n" ]] && [[ -f /etc/debian_version ]]; then
        n="Debian $(head -1 /etc/debian_version 2>/dev/null)"
    fi
    if [[ -z "$n" ]]; then
        n="$(uname -s) $(uname -r)"
    fi
    echo "$n"
    return 0
}

# libc 类型 (glibc / musl), 影响某些依赖包名
# 注意: Debian 等系统可能同时存在 /lib/ld-musl-* 兼容层与 glibc,
#       所以必须优先用 ldd --version 判断真实主 libc, 不能只看文件。
detect_libc() {
    local v=""
    if command -v ldd >/dev/null 2>&1; then
        v="$(ldd --version 2>&1 | head -2)"
        if echo "$v" | grep -qiE "glibc|GNU libc"; then
            echo "glibc"
            return 0
        fi
        if echo "$v" | grep -qi musl; then
            echo "musl"
            return 0
        fi
    fi
    # 无 ldd (Alpine 上 ldd 是 busybox 链接) 时看动态链接器
    if [[ -f /etc/alpine-release ]]; then
        echo "musl"
        return 0
    fi
    if ls /lib/ld-linux*.so* >/dev/null 2>&1 || ls /lib64/ld-linux*.so* >/dev/null 2>&1; then
        echo "glibc"
        return 0
    fi
    if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
        echo "musl"
        return 0
    fi
    echo "未知"
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
        opkg)   opkg update >/dev/null 2>&1 ;;
        xbps)   xbps-install -S >/dev/null 2>&1 ;;
        emerge) emerge --sync --quiet >/dev/null 2>&1 ;;
        urpmi)  urpmi.update -a >/dev/null 2>&1 ;;
        slackpkg) slackpkg -batch=on update >/dev/null 2>&1 ;;
        nix)    nix-channel --update >/dev/null 2>&1 ;;
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
        apt)      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1 ;;
        dnf)      dnf install -y -q "$pkg" >/dev/null 2>&1 ;;
        yum)      yum install -y -q "$pkg" >/dev/null 2>&1 ;;
        apk)      apk add --no-cache "$pkg" >/dev/null 2>&1 ;;
        pacman)   pacman -S --noconfirm --needed "$pkg" >/dev/null 2>&1 ;;
        zypper)   zypper --non-interactive install -y "$pkg" >/dev/null 2>&1 ;;
        opkg)     opkg install "$pkg" >/dev/null 2>&1 ;;
        xbps)     xbps-install -y "$pkg" >/dev/null 2>&1 ;;
        emerge)   emerge --quiet --noreplace "$pkg" >/dev/null 2>&1 ;;
        swupd)    swupd bundle-add "$pkg" >/dev/null 2>&1 ;;
        eopkg)    eopkg install -y "$pkg" >/dev/null 2>&1 ;;
        urpmi)    urpmi --auto "$pkg" >/dev/null 2>&1 ;;
        slackpkg) slackpkg -batch=on -default_answer=y install "$pkg" >/dev/null 2>&1 ;;
        nix)      nix-env -iA "nixpkgs.$pkg" >/dev/null 2>&1 ;;
        *)        return 1 ;;
    esac
    return $?
}

# 依赖表: 命令名 -> 各发行版包名
# 格式: cmd|apt|rpm(dnf/yum/zypper)|apk|arch|opkg|xbps|emerge|swupd
# 某列为 - 表示该系统上无独立包 (通常已内置)
DEPS_TABLE="
curl|curl|curl|curl|curl|curl|curl|net-misc/curl|curl
wget|wget|wget|wget|wget|wget|wget|net-misc/wget|wget
crontab|cron|cronie|dcron|cronie|cron|cronie|sys-process/cronie|cronie
logrotate|logrotate|logrotate|logrotate|logrotate|logrotate|logrotate|app-admin/logrotate|-
python3|python3|python3|python3|python|python3-light|python3|dev-lang/python|python3-basic
tar|tar|tar|tar|tar|tar|tar|app-arch/tar|-
awk|gawk|gawk|gawk|gawk|gawk|gawk|sys-apps/gawk|-
openssl|openssl|openssl|openssl|openssl|openssl-util|openssl|dev-libs/openssl|openssl
ca-certificates|ca-certificates|ca-certificates|ca-certificates|ca-certificates|ca-bundle|ca-certificates|app-misc/ca-certificates|-
"

resolve_pkg_name() {
    local cmd="$1" line apt_p rpm_p apk_p arch_p opkg_p xbps_p emerge_p swupd_p out=""
    while IFS="|" read -r line apt_p rpm_p apk_p arch_p opkg_p xbps_p emerge_p swupd_p; do
        if [[ "$line" == "$cmd" ]]; then
            case "$PKG_MGR" in
                apt)                   out="$apt_p" ;;
                dnf|yum|zypper|urpmi)  out="$rpm_p" ;;
                apk)                   out="$apk_p" ;;
                pacman)                out="$arch_p" ;;
                opkg)                  out="$opkg_p" ;;
                xbps|nix)              out="$xbps_p" ;;
                emerge)                out="$emerge_p" ;;
                swupd)                 out="$swupd_p" ;;
                eopkg|slackpkg)        out="$cmd" ;;
                *)                     out="$cmd" ;;
            esac
            # 该系统无独立包时用命令名兜底
            if [[ -z "$out" ]] || [[ "$out" == "-" ]]; then
                out="$cmd"
            fi
            echo "$out"
            return 0
        fi
    done <<< "$DEPS_TABLE"
    echo "$cmd"
    return 0
}

# 必需依赖: 缺失会导致安装失败
DEPS_REQUIRED="curl tar"
# 重要依赖: 缺失会导致部分功能不可用, 但不阻断安装
DEPS_IMPORTANT="wget awk openssl"
# 可选依赖: 缺失只影响附加能力 (定时任务/日志轮转/高级配置)
DEPS_OPTIONAL="crontab logrotate python3"

# 记录哪些能力因依赖缺失被降级, 安装结束时统一提示
DEGRADED_FEATURES=""

install_dependencies() {
    print_info "检查依赖..."
    detect_pkg_mgr

    echo -e "   系统: ${CYAN}$(detect_distro)${NC}"
    echo -e "   架构: ${CYAN}$(uname -m)${NC} → 资产 ${GREEN}$(get_arch)${NC} ${DIM}($(arch_desc "$(get_arch)"))${NC}"
    echo -e "   init: ${CYAN}$(init_desc)${NC}   libc: ${CYAN}$(detect_libc)${NC}   包管理: ${CYAN}$(pkg_mgr_desc)${NC}"
    echo ""

    local missing=() cmd pkg all_deps
    all_deps="$DEPS_REQUIRED $DEPS_IMPORTANT $DEPS_OPTIONAL"
    for cmd in $all_deps; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        print_ok "依赖已齐全"
        _post_dep_setup
        return 0
    fi

    if [[ -z "$PKG_MGR" ]]; then
        print_warn "未识别包管理器, 无法自动安装依赖: ${missing[*]}"
        _check_required_deps
        return $?
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
                _try_alt_pkg "$cmd"
            fi
        else
            echo -e "${RED}失败${NC}"
            _try_alt_pkg "$cmd"
        fi
    done

    _post_dep_setup
    _check_required_deps
    return $?
}

# 主包名装不上时尝试备用包名 (不同发行版命名差异很大)
_try_alt_pkg() {
    local cmd="$1" alts="" a
    case "$cmd" in
        crontab)   alts="cronie cron dcron busybox-cron vixie-cron fcron" ;;
        python3)   alts="python3 python3-minimal python311 python310 python39 python3-light python3-base" ;;
        awk)       alts="gawk mawk busybox-awk original-awk" ;;
        openssl)   alts="openssl openssl-util libressl openssl1.1" ;;
        wget)      alts="wget wget-ssl uclient-fetch busybox-wget" ;;
        curl)      alts="curl libcurl4 curl-minimal" ;;
        logrotate) alts="logrotate busybox-logrotate" ;;
        tar)       alts="tar gnu-tar busybox-tar" ;;
        *)         return 1 ;;
    esac
    for a in $alts; do
        if [[ "$a" == "$(resolve_pkg_name "$cmd")" ]]; then
            continue
        fi
        echo -ne "    尝试备用包 ${CYAN}${a}${NC} ... "
        if pkg_install "$a" && command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${GREEN}成功${NC}"
            return 0
        fi
        echo -e "${DIM}无效${NC}"
    done
    return 1
}

# 依赖安装后的收尾: 启动 cron, 标记降级能力
_post_dep_setup() {
    # cron 守护需要启动 (定时任务依赖)
    if command -v crontab >/dev/null 2>&1; then
        local cron_svc=""
        for cron_svc in cron crond cronie dcron fcron; do
            if _try_enable_cron_svc "$cron_svc"; then
                break
            fi
        done
    fi

    DEGRADED_FEATURES=""
    # 定时任务能力: systemd timer 或 crontab 二者有一即可
    if [[ "$(detect_init)" != "systemd" ]] && ! command -v crontab >/dev/null 2>&1; then
        DEGRADED_FEATURES="${DEGRADED_FEATURES}GeoData 自动更新与更新检查 (无 systemd timer 也无 crontab)\n"
    fi
    if ! command -v logrotate >/dev/null 2>&1; then
        DEGRADED_FEATURES="${DEGRADED_FEATURES}访问/错误日志自动轮转 (缺 logrotate, 已改用内置大小裁剪)\n"
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        DEGRADED_FEATURES="${DEGRADED_FEATURES}面板高级配置 (节点编辑/路由/链接导入需 python3)\n"
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        DEGRADED_FEATURES="${DEGRADED_FEATURES}自签证书生成 (缺 openssl)\n"
    fi
    return 0
}

# 校验必需依赖。缺失则返回 1 阻断安装。
_check_required_deps() {
    local cmd lack=""
    for cmd in $DEPS_REQUIRED; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            lack="${lack}${cmd} "
        fi
    done
    # curl 缺失但有 wget 时可以互替
    if [[ "$lack" == *curl* ]] && command -v wget >/dev/null 2>&1; then
        lack="${lack/curl /}"
    fi
    if [[ -n "$lack" ]]; then
        print_error "必需依赖缺失且无法自动安装: ${lack}"
        print_info "请手动安装后重试。例如:"
        case "$PKG_MGR" in
            opkg) echo "  opkg update && opkg install ${lack}" ;;
            apk)  echo "  apk add ${lack}" ;;
            *)    echo "  用本机包管理器安装: ${lack}" ;;
        esac
        return 1
    fi
    if [[ -n "$DEGRADED_FEATURES" ]]; then
        echo ""
        print_warn "以下能力因依赖缺失被降级:"
        printf "%b" "$DEGRADED_FEATURES" | while IFS= read -r l; do
            if [[ -n "$l" ]]; then echo -e "    ${DIM}· ${l}${NC}"; fi
        done
    fi
    return 0
}

# ==================== 版本与架构 ====================
# 判断 32 位 ARM 是否具备硬浮点 (VFP)。无 VFP 只能用 armv5 软浮点二进制。
_arm_has_vfp() {
    if grep -qiE "^Features.*\b(vfpv3|vfpv4|neon|vfpd32)\b" /proc/cpuinfo 2>/dev/null; then
        return 0
    fi
    if grep -qiE "^Features.*\bvfp\b" /proc/cpuinfo 2>/dev/null; then
        return 0
    fi
    return 1
}

# 判断 ARM 架构代号 (armv6 需要 VFPv2+, armv7 需要 ARMv7 指令集)
_arm_variant() {
    local archline model
    archline="$(grep -iE "^CPU architecture" /proc/cpuinfo 2>/dev/null | head -1 | grep -oE "[0-9]+" | head -1)"
    model="$(uname -m)"
    # uname -m 已经给出明确代号时优先采用
    case "$model" in
        armv7*|armv8*) echo "armv7"; return 0 ;;
        armv6*)
            if _arm_has_vfp; then echo "armv6"; else echo "armv5"; fi
            return 0 ;;
        armv5*|armv4*) echo "armv5"; return 0 ;;
    esac
    if [[ -n "$archline" ]]; then
        if [[ "$archline" -ge 7 ]] && _arm_has_vfp; then echo "armv7"; return 0; fi
        if [[ "$archline" -ge 6 ]] && _arm_has_vfp; then echo "armv6"; return 0; fi
    fi
    echo "armv5"
    return 0
}

# 判断 64 位内核是否跑在 32 位用户态 (常见于树莓派 32 位系统)。
# uname -m 报 aarch64 但 /bin/sh 是 32 位 ELF 时, 必须下 32 位二进制。
_userland_is_32bit() {
    local f
    f="$(command -v sh 2>/dev/null)"
    if [[ -z "$f" ]]; then return 1; fi
    # ELF 头第 5 字节: 1=32位, 2=64位
    local c
    c="$(od -An -tu1 -j4 -N1 "$f" 2>/dev/null | tr -d " ")"
    if [[ "$c" == "1" ]]; then return 0; fi
    return 1
}

# 发布资产支持的架构白名单 (与 build-release.sh 的 ARCH_LIST 必须一致)
SUPPORTED_ARCHES="amd64 386 arm64 armv7 armv6 armv5 mips mipsle mips64 mips64le ppc64 ppc64le riscv64 s390x loong64"

# 返回发布资产使用的架构名。覆盖 Go 支持的全部 linux 架构。
# 可用 XRAYR_ARCH 环境变量强制指定 (自动识别失败或需要交叉安装时)。
get_arch() {
    local arch le
    if [[ -n "$XRAYR_ARCH" ]]; then
        # 校验是否在白名单内, 防止拼错导致下载 404
        case " $SUPPORTED_ARCHES " in
            *" $XRAYR_ARCH "*) echo "$XRAYR_ARCH"; return 0 ;;
            *) print_warn "XRAYR_ARCH=$XRAYR_ARCH 不在支持列表内, 已忽略" >&2 ;;
        esac
    fi
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64|x64)
            if _userland_is_32bit; then echo "386"; else echo "amd64"; fi
            return 0 ;;
        i386|i486|i586|i686|x86|i86pc)
            echo "386"; return 0 ;;
        aarch64|aarch64_be|arm64|armv8b|armv8l)
            if _userland_is_32bit; then _arm_variant; else echo "arm64"; fi
            return 0 ;;
        armv7*|armv6*|armv5*|armv4*|arm|armel|armhf)
            _arm_variant; return 0 ;;
        loongarch64|loong64)
            echo "loong64"; return 0 ;;
        riscv64)
            echo "riscv64"; return 0 ;;
        s390x)
            echo "s390x"; return 0 ;;
        ppc64le|powerpc64le)
            echo "ppc64le"; return 0 ;;
        ppc64|powerpc64)
            echo "ppc64"; return 0 ;;
        mips64el|mips64le)
            echo "mips64le"; return 0 ;;
        mips64)
            # 部分系统 mips64 小端也报 mips64, 用运行时字节序兜底
            le="$(_cpu_endian)"
            if [[ "$le" == "little" ]]; then echo "mips64le"; else echo "mips64"; fi
            return 0 ;;
        mipsel|mipsle)
            echo "mipsle"; return 0 ;;
        mips)
            le="$(_cpu_endian)"
            if [[ "$le" == "little" ]]; then echo "mipsle"; else echo "mips"; fi
            return 0 ;;
        *)
            echo ""; return 1 ;;
    esac
}

# 运行时字节序检测 (mips/mips64 的 uname -m 不区分大小端)
_cpu_endian() {
    if [[ -r /bin/sh ]]; then
        local c
        c="$(od -An -tu1 -j5 -N1 /bin/sh 2>/dev/null | tr -d " ")"
        if [[ "$c" == "1" ]]; then echo "little"; return 0; fi
        if [[ "$c" == "2" ]]; then echo "big"; return 0; fi
    fi
    # 退化方案: printf 输出多字节整数看首字节
    if printf "\x01\x02" | od -An -tx2 2>/dev/null | grep -q "0201"; then
        echo "little"
    else
        echo "big"
    fi
    return 0
}

# 架构中文说明, 用于安装时展示
arch_desc() {
    case "$1" in
        amd64)    echo "64 位 x86 (Intel/AMD)" ;;
        386)      echo "32 位 x86" ;;
        arm64)    echo "64 位 ARM (ARMv8/v9)" ;;
        armv7)    echo "32 位 ARM (ARMv7 硬浮点)" ;;
        armv6)    echo "32 位 ARM (ARMv6 硬浮点)" ;;
        armv5)    echo "32 位 ARM (ARMv5 软浮点)" ;;
        mips)     echo "MIPS 大端 (软浮点)" ;;
        mipsle)   echo "MIPS 小端 (软浮点)" ;;
        mips64)   echo "MIPS64 大端" ;;
        mips64le) echo "MIPS64 小端" ;;
        ppc64)    echo "PowerPC64 大端" ;;
        ppc64le)  echo "PowerPC64 小端" ;;
        riscv64)  echo "RISC-V 64 位" ;;
        s390x)    echo "IBM Z (s390x)" ;;
        loong64)  echo "龙芯 LoongArch 64 位" ;;
        *)        echo "未知" ;;
    esac
    return 0
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

# 按"显示宽度"补齐字符串, 用于中文表格对齐。
# printf %-Ns 按字节计数, 中文在 UTF-8 下占 3 字节但只显示 2 列, 直接用会错位。
# 显示宽度 = 字符数 + 全角字符数; UTF-8 中文 3 字节 1 字符, 故 (bytes-chars)/2 即全角数。
pad_disp() {
    local str="$1" want="${2:-10}"
    local bytes chars wide w pad
    bytes="$(printf '%s' "$str" | wc -c)"
    chars="$(printf '%s' "$str" | wc -m)"
    wide=$(( (bytes - chars) / 2 ))
    w=$(( chars + wide ))
    pad=$(( want - w ))
    if [[ "$pad" -lt 0 ]]; then
        pad=0
    fi
    printf '%s%*s' "$str" "$pad" ""
    return 0
}

# 从 raw 拉文件, 带 cache-buster + no-cache 头绕过 CDN 缓存
# raw.githubusercontent 有约 5 分钟 CDN 缓存, 不绕过会导致刚推的版本检测不到
raw_fetch() {
    local file="$1" out="${2:-}"
    local url="${RAW_BASE}/${file}?nocache=$(date +%s)"
    if [[ -n "$out" ]]; then
        curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' --max-time 30 -o "$out" "$url" 2>/dev/null
        return $?
    fi
    curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' --max-time 15 "$url" 2>/dev/null
    return $?
}

# ==================== 版本元数据 ====================
# 写入 /etc/XrayR/.version, 记录本次安装的完整版本信息
write_version_state() {
    local bin_ver="$1" script_ver="${2:-$SCRIPT_VERSION}"
    mkdir -p "$CONFIG_DIR"
    local core_ver
    core_ver="$(get_core_version)"
    cat > "$VERSION_STATE_FILE" <<VSEOF
BINARY_VERSION=${bin_ver}
SCRIPT_VERSION=${script_ver}
CORE_VERSION=${core_ver:-unknown}
INSTALL_TIME=$(date '+%Y-%m-%d %H:%M:%S')
INSTALL_ARCH=$(get_arch)
VSEOF
    return 0
}

read_version_state() {
    local key="$1"
    if [[ -f "$VERSION_STATE_FILE" ]]; then
        grep -E "^${key}=" "$VERSION_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-
    fi
    return 0
}

# 从二进制里提取内嵌的 Xray 内核版本
# 优先级: XrayR version 自报 (0.9.6+ 内置, 无外部依赖)
#      -> strings 扫描 (兼容 0.9.5 及更早, 需 binutils)
#      -> go version -m (Go 工具链存在时可用)
# 精简系统常常没有 strings/readelf, 因此不能只依赖它。
get_core_version() {
    if [[ ! -x "${INSTALL_DIR}/XrayR" ]]; then
        return 0
    fi
    local v out
    out="$("${INSTALL_DIR}/XrayR" version 2>/dev/null)"
    v="$(echo "$out" | grep -iE '^Xray-core' | head -1 | grep -oE 'v?1\.[0-9]+\.[0-9]+' | head -1)"
    if [[ -z "$v" ]] && command -v strings >/dev/null 2>&1; then
        v="$(strings "${INSTALL_DIR}/XrayR" 2>/dev/null | grep -oE '^v1\.[0-9]{6}\.[0-9]+$' | sort -Vu | tail -1)"
    fi
    if [[ -z "$v" ]] && command -v go >/dev/null 2>&1; then
        v="$(go version -m "${INSTALL_DIR}/XrayR" 2>/dev/null | awk '$2=="github.com/xtls/xray-core"{print $3; exit}')"
    fi
    if [[ -z "$v" ]]; then
        # 最后兜底: 用 grep 直接在二进制里找模块版本串 (grep -a 处理二进制)
        v="$(grep -aoE 'github\.com/xtls/xray-core@v1\.[0-9]{6}\.[0-9]+' "${INSTALL_DIR}/XrayR" 2>/dev/null | head -1 | sed 's/.*@//')"
    fi
    echo "$v"
    return 0
}

# 当前正在运行的安装脚本自身版本 (已安装副本)
get_installed_script_version() {
    local sv
    sv="$(read_version_state SCRIPT_VERSION)"
    if [[ -z "$sv" ]] && [[ -f "${INSTALL_DIR}/install.sh" ]]; then
        sv="$(grep -m1 '^SCRIPT_VERSION=' "${INSTALL_DIR}/install.sh" 2>/dev/null | cut -d'"' -f2)"
    fi
    echo "$sv"
    return 0
}

# ==================== 在线更新检查 ====================
# 版本号比较: 返回 0 表示 $1 < $2 (即有新版本)
version_lt() {
    local a="${1#v}" b="${2#v}"
    if [[ "$a" == "$b" ]]; then
        return 1
    fi
    local lower
    lower="$(printf '%s\n%s\n' "$a" "$b" | sort -V 2>/dev/null | head -1)"
    if [[ "$lower" == "$a" ]]; then
        return 0
    fi
    return 1
}

# 列出发布仓库所有可用版本 (新→旧)
list_remote_versions() {
    curl -sL --max-time 20 "https://api.github.com/repos/${REPO}/releases?per_page=100" 2>/dev/null \
        | grep '"tag_name"' | cut -d'"' -f4
    return 0
}

# 校验某个版本在远端是否存在对应架构的二进制
remote_version_exists() {
    local ver="$1" arch="${2:-$(get_arch)}"
    local code
    code="$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 20 \
        "https://github.com/${REPO}/releases/download/${ver}/XrayR-linux-${arch}" 2>/dev/null)"
    if [[ "$code" == "200" ]]; then
        return 0
    fi
    return 1
}

# 获取远端安装脚本的 SCRIPT_VERSION
get_remote_script_version() {
    raw_fetch install.sh | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2
    return 0
}

# 带缓存的更新检查, 输出: <最新二进制版本>|<远端脚本版本>
check_updates_cached() {
    local force="${1:-0}"
    if [[ "$force" != "1" ]] && [[ -f "$UPDATE_CACHE_FILE" ]]; then
        local mtime now age
        mtime="$(stat -c %Y "$UPDATE_CACHE_FILE" 2>/dev/null || echo 0)"
        now="$(date +%s)"
        age=$(( now - mtime ))
        if [[ "$age" -lt "$UPDATE_CACHE_TTL" ]]; then
            cat "$UPDATE_CACHE_FILE"
            return 0
        fi
    fi
    local bv sv
    bv="$(get_latest_version)"
    sv="$(get_remote_script_version)"
    mkdir -p "$(dirname "$UPDATE_CACHE_FILE")" 2>/dev/null
    echo "${bv}|${sv}" > "$UPDATE_CACHE_FILE" 2>/dev/null
    echo "${bv}|${sv}"
    return 0
}

# 打印更新检查结果 (中文表格)
do_check_update() {
    local force="${1:-1}"
    echo ""
    echo -e "${CYAN}${BOLD}  ──────────────  检测更新  ──────────────${NC}"
    echo ""
    print_info "正在查询远端版本..."
    local res bv sv
    res="$(check_updates_cached "$force")"
    bv="${res%%|*}"
    sv="${res##*|}"

    local cur_bin cur_script cur_core
    cur_bin="$(get_installed_version)"
    cur_script="$(get_installed_script_version)"
    cur_core="$(read_version_state CORE_VERSION)"
    # 旧版 .version 里可能记着 unknown (当时没有 strings), 需要重新探测
    if [[ -z "$cur_core" ]] || [[ "$cur_core" == "unknown" ]]; then
        cur_core="$(get_core_version)"
    fi

    echo ""
    echo -e "  $(pad_disp '项目' 18)$(pad_disp '当前版本' 20)$(pad_disp '最新版本' 20)状态"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────────${NC}"

    local bin_state="已是最新"
    if [[ -z "$cur_bin" ]]; then
        bin_state="${YELLOW}未安装${NC}"
    elif [[ -z "$bv" ]]; then
        bin_state="${RED}查询失败${NC}"
    elif version_lt "$cur_bin" "$bv"; then
        bin_state="${GREEN}可更新${NC}"
    else
        bin_state="${DIM}已是最新${NC}"
    fi
    echo -e "  $(pad_disp 'XrayR 主程序' 18)$(pad_disp "${cur_bin:-未安装}" 20)$(pad_disp "${bv:-查询失败}" 20)${bin_state}"

    local scr_state
    if [[ -z "$sv" ]]; then
        scr_state="${RED}查询失败${NC}"
    elif [[ -z "$cur_script" ]]; then
        scr_state="${YELLOW}未记录${NC}"
    elif version_lt "$cur_script" "$sv"; then
        scr_state="${GREEN}可更新${NC}"
    else
        scr_state="${DIM}已是最新${NC}"
    fi
    echo -e "  $(pad_disp '安装脚本' 18)$(pad_disp "${cur_script:-未记录}" 20)$(pad_disp "${sv:-查询失败}" 20)${scr_state}"

    echo -e "  $(pad_disp '内嵌 Xray 内核' 18)$(pad_disp "${cur_core:-未知}" 20)$(pad_disp '-' 20)${DIM}随主程序更新${NC}"
    echo ""

    local has_update=0
    if [[ -n "$cur_bin" ]] && [[ -n "$bv" ]] && version_lt "$cur_bin" "$bv"; then
        has_update=1
        echo -e "  ${GREEN}▸${NC} 主程序有新版本 ${GREEN}${bv}${NC}, 可用菜单 [2] 或 ${CYAN}xrayr-install upgrade${NC} 升级"
    fi
    if [[ -n "$cur_script" ]] && [[ -n "$sv" ]] && version_lt "$cur_script" "$sv"; then
        has_update=1
        echo -e "  ${GREEN}▸${NC} 安装脚本有新版本 ${GREEN}${sv}${NC}, 可用菜单 [10] 更新脚本自身"
    fi
    if [[ "$has_update" == "0" ]]; then
        echo -e "  ${DIM}当前已是最新, 无需更新${NC}"
    fi
    echo ""
    return 0
}

# ==================== 更新到指定版本 ====================
# 交互式选择版本, 或直接指定
do_upgrade_to() {
    check_root
    local target="${1:-}"
    if ! is_installed; then
        print_error "XrayR 未安装, 请先执行安装"
        return 1
    fi
    install_dependencies

    local arch cur
    arch="$(get_arch)"
    cur="$(get_installed_version)"

    if [[ -z "$target" ]]; then
        echo ""
        print_info "正在获取可用版本列表..."
        local vers
        vers="$(list_remote_versions)"
        if [[ -z "$vers" ]]; then
            print_error "无法获取版本列表 (网络问题?)"
            return 1
        fi
        echo ""
        echo -e "  ${BOLD}可用版本${NC} (当前: ${YELLOW}${cur:-未知}${NC})"
        echo -e "  ${DIM}──────────────────────────────────────${NC}"
        local i=0 v
        local -a vlist=()
        while IFS= read -r v; do
            [[ -z "$v" ]] && continue
            i=$(( i + 1 ))
            vlist+=("$v")
            local mark=""
            if [[ "$v" == "$cur" ]]; then
                mark=" ${CYAN}← 当前${NC}"
            fi
            if [[ "$i" == "1" ]]; then
                mark="${mark} ${GREEN}(最新)${NC}"
            fi
            echo -e "  ${GREEN}${i})${NC} ${v}${mark}"
            if [[ "$i" -ge 20 ]]; then
                break
            fi
        done <<< "$vers"
        echo -e "  ${GREEN}0)${NC} 取消"
        echo ""
        echo -e "  ${DIM}提示: 也可直接输入版本号, 如 v0.9.5${NC}"
        local sel=""
        read -erp "  请选择版本序号或直接输入版本号: " sel
        if [[ -z "$sel" ]] || [[ "$sel" == "0" ]]; then
            print_info "已取消"
            return 0
        fi
        if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -le "${#vlist[@]}" ]]; then
            target="${vlist[$(( sel - 1 ))]}"
        else
            target="$sel"
        fi
    fi

    # 归一化: 允许用户输入不带 v 前缀
    if [[ ! "$target" =~ ^v ]] && [[ "$target" =~ ^[0-9] ]]; then
        target="v${target}"
    fi

    echo ""
    print_info "校验目标版本 ${target} 是否存在 (${arch})..."
    if ! remote_version_exists "$target" "$arch"; then
        print_error "远端不存在版本 ${target} 的 ${arch} 二进制"
        print_info "可用版本: $(list_remote_versions | head -5 | tr '\n' ' ')"
        return 1
    fi
    print_ok "目标版本可用"

    echo ""
    echo -e "   当前版本: ${YELLOW}${cur:-未知}${NC}   →   目标版本: ${GREEN}${target}${NC}"
    if [[ -n "$cur" ]] && version_lt "$target" "$cur"; then
        print_warn "这是一次${BOLD}降级${NC}操作"
    fi
    if [[ -t 0 ]]; then
        local ok=""
        read -erp "  确认继续? [y/N]: " ok
        if [[ ! "$ok" =~ ^[Yy]$ ]]; then
            print_info "已取消"
            return 0
        fi
    fi

    # 备份当前二进制, 失败可回滚
    local bak="${INSTALL_DIR}/XrayR.bak-$(date +%Y%m%d-%H%M%S)"
    cp -f "${INSTALL_DIR}/XrayR" "$bak" 2>/dev/null
    print_info "已备份原二进制: ${bak}"

    local was_running=0
    if [[ "$(svc_state)" == "running" ]]; then
        was_running=1
    fi
    svc_stop

    if ! download_binary "$target" "$arch"; then
        print_error "下载失败, 回滚到原版本"
        cp -f "$bak" "${INSTALL_DIR}/XrayR" 2>/dev/null
        chmod +x "${INSTALL_DIR}/XrayR"
        if [[ $was_running -eq 1 ]]; then
            svc_start
        fi
        return 1
    fi

    # 启动自检: 新二进制能否正常执行
    if ! "${INSTALL_DIR}/XrayR" version >/dev/null 2>&1; then
        print_error "新二进制无法执行, 自动回滚"
        cp -f "$bak" "${INSTALL_DIR}/XrayR" 2>/dev/null
        chmod +x "${INSTALL_DIR}/XrayR"
        if [[ $was_running -eq 1 ]]; then
            svc_start
        fi
        return 1
    fi

    download_manager_scripts "$target"
    install_systemd_service
    install_log_limits
    register_command
    install_self_copy
    write_version_state "$target"

    if [[ $was_running -eq 1 ]]; then
        svc_start
        sleep 2
        if [[ "$(svc_state)" != "running" ]]; then
            print_error "服务启动失败! 正在回滚到 ${cur}"
            svc_stop
            cp -f "$bak" "${INSTALL_DIR}/XrayR" 2>/dev/null
            chmod +x "${INSTALL_DIR}/XrayR"
            write_version_state "${cur}"
            svc_start
            print_warn "已回滚, 请检查日志: xrayr 菜单 [8] 查看日志"
            return 1
        fi
    fi

    echo ""
    print_ok "已更新到 ${target}"
    local nc
    nc="$(get_core_version)"
    if [[ -n "$nc" ]]; then
        echo -e "   内嵌 Xray 内核: ${GREEN}${nc}${NC}"
    fi
    # 仅保留最近 3 个备份
    ls -1t "${INSTALL_DIR}"/XrayR.bak-* 2>/dev/null | tail -n +4 | xargs -r rm -f
    return 0
}

# ==================== 脚本自更新 ====================
do_self_update() {
    check_root
    echo ""
    echo -e "${CYAN}${BOLD}  ──────────  更新安装脚本自身  ──────────${NC}"
    echo ""
    local remote_sv
    remote_sv="$(get_remote_script_version)"
    if [[ -z "$remote_sv" ]]; then
        print_error "无法获取远端脚本版本 (网络问题?)"
        return 1
    fi
    echo -e "   本地脚本版本: ${YELLOW}${SCRIPT_VERSION}${NC}   远端版本: ${GREEN}${remote_sv}${NC}"
    if ! version_lt "$SCRIPT_VERSION" "$remote_sv"; then
        print_ok "安装脚本已是最新"
        return 0
    fi

    local tmp="/tmp/xrayr-install-new.sh"
    print_info "下载新版安装脚本..."
    if ! raw_fetch install.sh "$tmp"; then
        print_error "下载失败"
        return 1
    fi
    # 完整性自检: 必须是合法 bash 且含关键函数
    if ! bash -n "$tmp" 2>/dev/null; then
        print_error "下载的脚本语法校验失败, 已丢弃"
        rm -f "$tmp"
        return 1
    fi
    if ! grep -q 'do_install()' "$tmp" || ! grep -q '^SCRIPT_VERSION=' "$tmp"; then
        print_error "下载的脚本内容异常, 已丢弃"
        rm -f "$tmp"
        return 1
    fi

    mkdir -p "$INSTALL_DIR"
    local self_bak="${INSTALL_DIR}/install.sh.bak-$(date +%Y%m%d-%H%M%S)"
    if [[ -f "${INSTALL_DIR}/install.sh" ]]; then
        cp -f "${INSTALL_DIR}/install.sh" "$self_bak"
    fi
    install -m 755 "$tmp" "${INSTALL_DIR}/install.sh"
    rm -f "$tmp"
    # 同步注册 xrayr-install 命令
    ln -sf "${INSTALL_DIR}/install.sh" /usr/local/bin/xrayr-install
    # 更新版本记录里的脚本版本
    if [[ -f "$VERSION_STATE_FILE" ]]; then
        sed -i "s/^SCRIPT_VERSION=.*/SCRIPT_VERSION=${remote_sv}/" "$VERSION_STATE_FILE"
    fi
    rm -f "$UPDATE_CACHE_FILE"

    print_ok "安装脚本已更新到 ${remote_sv}"
    echo -e "   安装位置: ${CYAN}${INSTALL_DIR}/install.sh${NC}"
    echo -e "   调用命令: ${GREEN}xrayr-install${NC}"
    echo -e "   ${YELLOW}提示: 请重新运行 xrayr-install 以使用新版脚本${NC}"
    return 0
}

# ==================== 自动检查更新 (定时) ====================
read_update_conf() {
    local key="$1" def="$2"
    if [[ -f "$UPDATE_CONF_FILE" ]]; then
        local v
        v="$(grep -E "^${key}=" "$UPDATE_CONF_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
        if [[ -n "$v" ]]; then
            echo "$v"
            return 0
        fi
    fi
    echo "$def"
    return 0
}

write_update_conf() {
    mkdir -p "$CONFIG_DIR"
    cat > "$UPDATE_CONF_FILE" <<UCEOF
# XrayR 自动更新检查配置
# AUTO_CHECK: 是否启用每日自动检查更新 (true/false)
AUTO_CHECK=${1:-true}
# AUTO_APPLY: 检测到新版本后是否自动升级 (true/false, 默认仅提醒不自动升级)
AUTO_APPLY=${2:-false}
# CHECK_SCHEDULE: 检查时间 (cron 格式)
CHECK_SCHEDULE=${3:-25 5 * * *}
UCEOF
    return 0
}

install_update_checker() {
    local auto_check="${1:-true}" auto_apply="${2:-false}"
    local sched
    sched="$(read_update_conf CHECK_SCHEDULE '25 5 * * *')"
    write_update_conf "$auto_check" "$auto_apply" "$sched"

    cat > "${INSTALL_DIR}/update-check.sh" <<'UPEOF'
#!/bin/bash
# XrayR 自动更新检查 (由 systemd timer 或 cron 调用)
REPO="sdars/xrayr-release"
INSTALL_DIR="/usr/local/XrayR"
CONFIG_DIR="/etc/XrayR"
CONF="/etc/XrayR/update.conf"
LOG="/var/log/xrayr-update-check.log"
STATE="/etc/XrayR/.version"
NOTIFY="/etc/XrayR/.update-available"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

conf_get() {
    local k="$1" d="$2" v=""
    if [[ -f "$CONF" ]]; then
        v="$(grep -E "^${k}=" "$CONF" 2>/dev/null | head -1 | cut -d= -f2-)"
    fi
    if [[ -n "$v" ]]; then echo "$v"; else echo "$d"; fi
}

AUTO_CHECK="$(conf_get AUTO_CHECK true)"
AUTO_APPLY="$(conf_get AUTO_APPLY false)"
if [[ "$AUTO_CHECK" != "true" ]]; then
    exit 0
fi

cur="$("${INSTALL_DIR}/XrayR" version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
latest="$(curl -sL --max-time 20 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)"

if [[ -z "$latest" ]]; then
    log "查询远端版本失败"
    exit 0
fi

norm() { echo "${1#v}"; }
if [[ "$(norm "$cur")" == "$(norm "$latest")" ]]; then
    log "已是最新 (${cur})"
    rm -f "$NOTIFY"
    exit 0
fi
lower="$(printf '%s\n%s\n' "$(norm "$cur")" "$(norm "$latest")" | sort -V | head -1)"
if [[ "$lower" != "$(norm "$cur")" ]]; then
    log "本地版本 ${cur} 高于远端 ${latest}, 跳过"
    exit 0
fi

log "发现新版本: ${cur} -> ${latest}"
echo "${latest}" > "$NOTIFY"

if [[ "$AUTO_APPLY" == "true" ]]; then
    log "AUTO_APPLY=true, 开始自动升级"
    if [[ -x "${INSTALL_DIR}/install.sh" ]]; then
        yes y | "${INSTALL_DIR}/install.sh" upgrade >> "$LOG" 2>&1
        rc=$?
        log "自动升级结束, 退出码=${rc}"
        if [[ $rc -eq 0 ]]; then rm -f "$NOTIFY"; fi
    else
        log "找不到 ${INSTALL_DIR}/install.sh, 无法自动升级"
    fi
else
    log "仅提醒模式 (AUTO_APPLY=false), 运行 xrayr-install 查看"
fi
UPEOF
    chmod +x "${INSTALL_DIR}/update-check.sh"

    # 优先 systemd timer, 回退 cron; 非 systemd 系统直接走 cron
    if [[ "$(detect_init)" == "systemd" ]]; then
        cat > /etc/systemd/system/xrayr-update-check.service <<'USEOF'
[Unit]
Description=XrayR Update Check
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/XrayR/update-check.sh
USEOF
        local hh mm
        mm="$(echo "$sched" | awk '{print $1}')"
        hh="$(echo "$sched" | awk '{print $2}')"
        cat > /etc/systemd/system/xrayr-update-check.timer <<UTEOF
[Unit]
Description=XrayR Update Check Timer

[Timer]
OnCalendar=*-*-* ${hh:-5}:${mm:-25}:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
UTEOF
        svc_daemon_reload
        if [[ "$auto_check" == "true" ]]; then
            systemctl enable --now xrayr-update-check.timer >/dev/null 2>&1
            print_ok "自动更新检查已启用 (systemd timer, 每日 ${hh:-5}:${mm:-25})"
        else
            systemctl disable --now xrayr-update-check.timer >/dev/null 2>&1
            print_info "自动更新检查已关闭"
        fi
    elif command -v crontab >/dev/null 2>&1; then
        if [[ "$auto_check" == "true" ]]; then
            (crontab -l 2>/dev/null | grep -v "update-check.sh"; \
             echo "${sched} ${INSTALL_DIR}/update-check.sh >/dev/null 2>&1") | crontab -
            print_ok "自动更新检查已启用 (cron: ${sched})"
        else
            crontab -l 2>/dev/null | grep -v "update-check.sh" | crontab - >/dev/null 2>&1
            print_info "自动更新检查已关闭"
        fi
    else
        print_warn "系统既无 systemd 也无 crontab, 自动检查未安装"
    fi
    return 0
}

# 启动面板时的静默更新提示
show_update_notice() {
    if [[ -f /etc/XrayR/.update-available ]]; then
        local nv
        nv="$(cat /etc/XrayR/.update-available 2>/dev/null)"
        if [[ -n "$nv" ]]; then
            echo -e "  ${GREEN}${BOLD}▸ 发现新版本 ${nv}${NC} ${DIM}(菜单 [2] 升级, [9] 查看详情)${NC}"
        fi
    fi
    return 0
}

# 把当前正在运行的安装脚本落盘到 INSTALL_DIR 并注册 xrayr-install 命令
# 这样后续无需再 curl 远端即可进入面板, 也让脚本自更新有明确目标路径
install_self_copy() {
    mkdir -p "$INSTALL_DIR"
    local self="${BASH_SOURCE[0]}"
    # 通过 bash <(curl ...) 运行时 BASH_SOURCE 是 /dev/fd/63 之类, 需回落到远端拉取
    if [[ -f "$self" ]] && [[ -s "$self" ]] && grep -q '^SCRIPT_VERSION=' "$self" 2>/dev/null; then
        install -m 755 "$self" "${INSTALL_DIR}/install.sh" 2>/dev/null
    else
        raw_fetch install.sh "${INSTALL_DIR}/install.sh"
        chmod +x "${INSTALL_DIR}/install.sh" 2>/dev/null
    fi
    if [[ -s "${INSTALL_DIR}/install.sh" ]]; then
        ln -sf "${INSTALL_DIR}/install.sh" /usr/local/bin/xrayr-install
        print_ok "命令 ${GREEN}xrayr-install${NC} 已注册 (安装/更新管理)"
    else
        print_warn "安装脚本自身落盘失败, xrayr-install 命令不可用"
    fi
    return 0
}

# 安装时询问是否启用自动更新检查
prompt_update_checker() {
    local interactive="${1:-1}"
    if [[ "$interactive" != "1" ]] || [[ ! -t 0 ]]; then
        # 非交互: 默认启用"每日检查 + 仅提醒"
        install_update_checker true false
        return 0
    fi
    echo ""
    echo -e "${CYAN}${BOLD}  ──────────  自动更新检查  ──────────${NC}"
    echo -e "   ${GREEN}1)${NC} 每日检查并${BOLD}仅提醒${NC}   ${DIM}(推荐, 不会自动改动服务)${NC}"
    echo -e "   ${GREEN}2)${NC} 每日检查并${BOLD}自动升级${NC} ${DIM}(会自动重启服务, 有短暂断流)${NC}"
    echo -e "   ${GREEN}3)${NC} 不启用自动检查"
    echo ""
    local c=""
    read -erp "   请选择 [1-3, 默认=1]: " c
    case "$c" in
        2) install_update_checker true true ;;
        3) install_update_checker false false ;;
        *) install_update_checker true false ;;
    esac
    return 0
}

# ==================== 更新管理菜单 ====================
menu_update() {
    while true
    do
        clear
        echo ""
        echo -e "${CYAN}${BOLD}  ══════════  更新管理  ══════════${NC}"
        echo ""
        local cur_bin cur_script cur_core
        cur_bin="$(get_installed_version)"
        cur_script="$(get_installed_script_version)"
        cur_core="$(read_version_state CORE_VERSION)"
        if [[ -z "$cur_core" ]] || [[ "$cur_core" == "unknown" ]]; then
            cur_core="$(get_core_version)"
        fi
        echo -e "   主程序版本   : ${GREEN}${cur_bin:-未安装}${NC}"
        echo -e "   安装脚本版本 : ${GREEN}${cur_script:-${SCRIPT_VERSION}}${NC}"
        echo -e "   Xray 内核    : ${GREEN}${cur_core:-未知}${NC}"
        local ac aa
        ac="$(read_update_conf AUTO_CHECK true)"
        aa="$(read_update_conf AUTO_APPLY false)"
        local ac_txt="${RED}已关闭${NC}" aa_txt="${DIM}仅提醒${NC}"
        if [[ "$ac" == "true" ]]; then
            ac_txt="${GREEN}已开启${NC}"
        fi
        if [[ "$aa" == "true" ]]; then
            aa_txt="${YELLOW}自动升级${NC}"
        fi
        echo -e "   自动检查     : ${ac_txt}   处理方式: ${aa_txt}"
        echo ""
        echo -e "  ${CYAN}──────────────────────────────────────────${NC}"
        echo -e "   ${GREEN}1)${NC} 立即检测更新 (主程序 + 脚本)"
        echo -e "   ${GREEN}2)${NC} 升级主程序到最新版"
        echo -e "   ${GREEN}3)${NC} 更新到${BOLD}指定版本${NC} (可升级/降级)"
        echo -e "   ${GREEN}4)${NC} 更新安装脚本自身"
        echo -e "   ${GREEN}5)${NC} 更新管理面板脚本 (xrayr 命令)"
        echo -e "   ${GREEN}6)${NC} 开启/关闭 每日自动检查"
        echo -e "   ${GREEN}7)${NC} 切换 检测到新版是否自动升级"
        echo -e "   ${GREEN}8)${NC} 修改自动检查时间"
        echo -e "   ${GREEN}9)${NC} 查看更新检查日志"
        echo -e "   ${GREEN}10)${NC} 回滚到上一个备份版本"
        echo -e "   ${GREEN}0)${NC} 返回"
        echo -e "  ${CYAN}──────────────────────────────────────────${NC}"
        echo ""
        local c=""
        if ! read -erp "   请选择 [0-10]: " c; then
            return 0
        fi
        case "$c" in
            1) do_check_update 1; pause ;;
            2) do_upgrade; pause ;;
            3) do_upgrade_to; pause ;;
            4) do_self_update; pause ;;
            5)
                local v
                v="$(get_installed_version)"
                if [[ -z "$v" ]]; then
                    v="$(get_latest_version)"
                fi
                download_manager_scripts "${v:-v0.9.5}"
                register_command
                pause ;;
            6)
                local nac="true"
                if [[ "$ac" == "true" ]]; then
                    nac="false"
                fi
                install_update_checker "$nac" "$aa"
                pause ;;
            7)
                local naa="true"
                if [[ "$aa" == "true" ]]; then
                    naa="false"
                fi
                if [[ "$naa" == "true" ]]; then
                    print_warn "开启后将在检测到新版本时${BOLD}自动升级${NC}并重启服务"
                    local ok=""
                    read -erp "   确认开启? [y/N]: " ok
                    if [[ ! "$ok" =~ ^[Yy]$ ]]; then
                        print_info "已取消"
                        pause
                        continue
                    fi
                fi
                install_update_checker "$ac" "$naa"
                pause ;;
            8)
                echo ""
                echo -e "  ${DIM}当前: $(read_update_conf CHECK_SCHEDULE '25 5 * * *')${NC}"
                echo -e "  ${DIM}格式: 分 时 日 月 周, 例 '25 5 * * *' 表示每天 05:25${NC}"
                local ns=""
                read -erp "   新的检查时间: " ns
                if [[ -n "$ns" ]]; then
                    write_update_conf "$ac" "$aa" "$ns"
                    install_update_checker "$ac" "$aa"
                else
                    print_info "未修改"
                fi
                pause ;;
            9)
                echo ""
                if [[ -f /var/log/xrayr-update-check.log ]]; then
                    tail -40 /var/log/xrayr-update-check.log
                else
                    print_info "暂无更新检查日志"
                fi
                pause ;;
            10)
                echo ""
                local -a baks=()
                local b
                while IFS= read -r b; do
                    [[ -n "$b" ]] && baks+=("$b")
                done < <(ls -1t "${INSTALL_DIR}"/XrayR.bak-* 2>/dev/null)
                if [[ "${#baks[@]}" -eq 0 ]]; then
                    print_warn "没有可用的二进制备份"
                    pause
                    continue
                fi
                echo -e "  ${BOLD}可用备份${NC}"
                local i=0
                for b in "${baks[@]}"; do
                    i=$(( i + 1 ))
                    local bv
                    bv="$("$b" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
                    echo -e "  ${GREEN}${i})${NC} $(basename "$b")  ${DIM}版本 ${bv:-未知}${NC}"
                done
                echo -e "  ${GREEN}0)${NC} 取消"
                local sel=""
                read -erp "   选择要回滚的备份: " sel
                if [[ -z "$sel" ]] || [[ "$sel" == "0" ]]; then
                    print_info "已取消"
                    pause
                    continue
                fi
                if [[ ! "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -gt "${#baks[@]}" ]]; then
                    print_error "无效选择"
                    pause
                    continue
                fi
                local src="${baks[$(( sel - 1 ))]}"
                local was=0
                if [[ "$(svc_state)" == "running" ]]; then
                    was=1
                fi
                svc_stop
                cp -f "$src" "${INSTALL_DIR}/XrayR"
                chmod +x "${INSTALL_DIR}/XrayR"
                write_version_state "$("${INSTALL_DIR}/XrayR" version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
                if [[ $was -eq 1 ]]; then
                    svc_start
                fi
                print_ok "已回滚到 $(basename "$src")"
                pause ;;
            0|q) return 0 ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
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
  AccessPath: /dev/null
  ErrorPath:
DnsConfigPath: /etc/XrayR/dns.json
RouteConfigPath: /etc/XrayR/route.json
InboundConfigPath:
OutboundConfigPath: /etc/XrayR/custom_outbound.json
ConnectionConfig:
  Handshake: 8
  ConnIdle: 600
  UplinkOnly: 2
  DownlinkOnly: 5
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
      # ---------------------------------------------------------------
      # 入站 Socket 调优（可选，默认全部关闭 = 保持系统/内核既有行为）
      # 说明: 原版 XrayR 只在「非 tcp/ws 传输 + 开启 ProxyProtocol」时才下发
      #       sockopt，导致纯 TCP 入站(Shadowsocks/VMess-tcp 等)完全没有 socket
      #       调优能力。本版已修复为任意传输协议均可下发。
      #
      # TCPFastOpen: 开启后客户端可在 SYN 包中携带数据，省掉「客户端<->本机」
      #   整 1 个 RTT 的三次握手。对 SS2022/VLESS 这类 0-RTT 协议收益最直接，
      #   客户端 RTT 越高收益越大(200ms 客户端实测冷连接 TTFB 降低约 5%~20%)。
      #   需内核 net.ipv4.tcp_fastopen 含服务端位(值 2 或 3)才真正生效，
      #   可用管理脚本「入站 Socket 调优」菜单自动检查并设置。
      # SocketConfig:
      #   TCPFastOpen: true
      #   TCPFastOpenQueueLength: 4096   # TFO 半开队列，0=用 xray 默认(256)
      #   TCPKeepAliveIdle: 30           # 空闲多少秒后开始 keepalive 探测
      #   TCPKeepAliveInterval: 15       # keepalive 探测间隔(秒)
      #   TCPUserTimeout: 0              # 未确认数据最大存活(毫秒)，0=不设置
      #   TCPCongestion: ""              # 该入站独立拥塞算法，如 bbr
      #   TCPMptcp: false                # Multipath TCP，需内核 5.6+ 且客户端支持
      #   TCPWindowClamp: 0              # 通告窗口上限(字节)，0=不设置
      #   TCPMaxSeg: 0                   # 单段最大长度(字节)，0=不设置
      #   Interface: ""                  # 绑定网卡名，空=不绑定
      # ---------------------------------------------------------------
CFGEOF
        print_ok "默认配置已生成"
        # BufferSize 按内存自适应 (依据实测: 编译机 xray 26.3.27 压测)
        #   吞吐: buf=16~512 无显著差异(1315~1698 MB/s, 波动即噪声); 仅 buf=4 掉到 1169
        #         50ms/150ms 高延迟段 buf 4~512 完全一致(瓶颈在内核 TCP 窗口, 非 xray 缓冲)
        #   内存: bufferSize 是"每连接上限"而非预分配。150 并发实测客户端峰值 RSS
        #         buf=4 -> 54MB, buf=64 -> 51MB, buf=512 -> 54MB (服务端 72/73/80MB)
        #   结论: 只要不低于 16 就不影响速度; 512 在中小并发下也无内存风险。
        #         故小内存机取 64(留足余量), 其余取 512(极端高并发时上限更宽松)。
        local mem_mb
        mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
        if [[ -n "$mem_mb" && "$mem_mb" -ge 2048 ]]; then
            sed -i 's/BufferSize: 64/BufferSize: 512/' "${CONFIG_DIR}/config.yml"
            print_info "系统内存 ${mem_mb}MB >= 2GB, BufferSize 设为 512 (实测无额外内存开销)"
        elif [[ -n "$mem_mb" && "$mem_mb" -ge 1024 ]]; then
            sed -i 's/BufferSize: 64/BufferSize: 128/' "${CONFIG_DIR}/config.yml"
            print_info "系统内存 ${mem_mb}MB >= 1GB, BufferSize 设为 128"
        else
            print_info "系统内存 ${mem_mb:-未知}MB < 1GB, BufferSize 保持 64 (仍高于影响吞吐的临界值 16)"
        fi
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
  "queryStrategy": "UseIPv4",
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
GEO_CRON="30 4 * * *"
GEO_AUTO_RESTART="true"
GEO_VERIFY="true"
GEO_RETRY="3"
GEOCONFEOF
    return 0
}

# ==================== 服务单元安装 (多 init 系统) ====================
# install_systemd_service 保留旧名作为统一入口, 内部按 init 系统分派。
install_systemd_service() {
    init_ready
    local it
    it="$(detect_init)"
    case "$it" in
        systemd)  _svcfile_systemd ;;
        openrc)   _svcfile_openrc ;;
        sysvinit) _svcfile_sysvinit ;;
        procd)    _svcfile_procd ;;
        *)        _svcfile_bare ;;
    esac
    return 0
}

_svcfile_systemd() {
    mkdir -p /etc/systemd/system
    cat > "${SERVICE_FILE}" << SVCEOF
[Unit]
Description=XrayR Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/XrayR --config ${CONFIG_DIR}/config.yml
Restart=always
RestartSec=3s
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
LimitMEMLOCK=infinity
TasksMax=infinity
OOMScoreAdjust=-500
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=2

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload >/dev/null 2>&1
    svc_enable
    print_ok "systemd 服务已创建"
    return 0
}

# OpenRC (Alpine / Gentoo)
_svcfile_openrc() {
    mkdir -p /etc/init.d
    cat > "${SERVICE_FILE}" << OREOF
#!/sbin/openrc-run

name="XrayR"
description="XrayR Service"
command="${INSTALL_DIR}/XrayR"
command_args="--config ${CONFIG_DIR}/config.yml"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/xrayr.log"
error_log="/var/log/xrayr.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    # 提升文件描述符上限 (OpenRC 无 LimitNOFILE, 用 ulimit)
    ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null
    return 0
}
OREOF
    chmod +x "${SERVICE_FILE}"
    # OpenRC 的 rlimit 配置
    mkdir -p /etc/conf.d
    cat > /etc/conf.d/XrayR << ORCEOF
rc_ulimit="-n 1048576"
ORCEOF
    svc_enable
    print_ok "OpenRC 服务已创建 (${SERVICE_FILE})"
    return 0
}

# SysVinit (老 Debian / CentOS 6 / Devuan)
_svcfile_sysvinit() {
    mkdir -p /etc/init.d
    cat > "${SERVICE_FILE}" << SVEOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          XrayR
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: XrayR Service
### END INIT INFO

BIN="${INSTALL_DIR}/XrayR"
CFG="${CONFIG_DIR}/config.yml"
PIDFILE="/var/run/xrayr.pid"
LOGFILE="/var/log/xrayr.log"

is_running() {
    if [ -f "\$PIDFILE" ]; then
        p=\$(cat "\$PIDFILE" 2>/dev/null)
        if [ -n "\$p" ] && kill -0 "\$p" 2>/dev/null; then return 0; fi
    fi
    pgrep -f "\$BIN --config" >/dev/null 2>&1
    return \$?
}

do_start() {
    if is_running; then echo "XrayR 已在运行"; return 0; fi
    ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null
    setsid nohup "\$BIN" --config "\$CFG" >> "\$LOGFILE" 2>&1 < /dev/null &
    echo \$! > "\$PIDFILE"
    sleep 1
    if is_running; then echo "XrayR 已启动"; return 0; fi
    echo "XrayR 启动失败, 见 \$LOGFILE"
    return 1
}

do_stop() {
    if [ -f "\$PIDFILE" ]; then
        p=\$(cat "\$PIDFILE" 2>/dev/null)
        [ -n "\$p" ] && kill "\$p" 2>/dev/null
    fi
    pkill -f "\$BIN --config" 2>/dev/null
    rm -f "\$PIDFILE"
    echo "XrayR 已停止"
    return 0
}

case "\$1" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 1; do_start ;;
    status)
        if is_running; then echo "XrayR 运行中"; exit 0; else echo "XrayR 已停止"; exit 3; fi ;;
    *) echo "用法: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
exit \$?
SVEOF
    chmod +x "${SERVICE_FILE}"
    svc_enable
    print_ok "SysVinit 服务已创建 (${SERVICE_FILE})"
    return 0
}

# procd (OpenWrt)
_svcfile_procd() {
    mkdir -p /etc/init.d
    cat > "${SERVICE_FILE}" << PDEOF
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command ${INSTALL_DIR}/XrayR --config ${CONFIG_DIR}/config.yml
    procd_set_param respawn 3600 5 0
    procd_set_param limits nofile="1048576 1048576"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    killall XrayR 2>/dev/null
}

reload_service() {
    stop
    start
}
PDEOF
    chmod +x "${SERVICE_FILE}"
    svc_enable
    print_ok "procd 服务已创建 (${SERVICE_FILE})"
    return 0
}

# 无 init 系统 (极简容器 / chroot)
_svcfile_bare() {
    print_warn "未检测到受支持的 init 系统, 使用裸进程守护模式"
    bare_enable
    print_ok "裸进程模式已配置 (开机自启走 cron @reboot, 日志 ${BARE_LOGFILE})"
    print_info "手动控制: ${GREEN}xrayr${NC} 面板内启动/停止, 或直接 ${INSTALL_DIR}/XrayR --config ${CONFIG_DIR}/config.yml"
    return 0
}

# ==================== 内核调优 (可选) ====================
TUNE_BACKUP_ROOT="/var/backups/xrayr-tuning"

# 需要备份/回滚的内核参数清单
TUNE_SYSCTL_KEYS="net.ipv4.tcp_congestion_control net.core.default_qdisc
net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default
net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min
net.core.netdev_max_backlog net.core.somaxconn net.ipv4.tcp_max_syn_backlog
net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl
net.ipv4.tcp_keepalive_probes net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse
net.ipv4.ip_local_port_range net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat
net.ipv4.tcp_fastopen net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_no_metrics_save
net.ipv4.ip_forward net.netfilter.nf_conntrack_max
net.netfilter.nf_conntrack_tcp_timeout_established
net.netfilter.nf_conntrack_udp_timeout net.netfilter.nf_conntrack_udp_timeout_stream"

# 备份当前内核参数与相关文件, 并生成独立回滚脚本
tune_backup() {
    local ts bdir k v
    ts="$(date +%Y%m%d-%H%M%S)"
    bdir="${TUNE_BACKUP_ROOT}/${ts}"
    mkdir -p "${bdir}/files"

    # 备份可能被覆盖的文件
    local f
    for f in /etc/sysctl.conf /etc/sysctl.d/99-xrayr-perf.conf \
             /etc/security/limits.d/99-xrayr.conf \
             /etc/systemd/system/XrayR.service \
             /etc/systemd/system/XrayR.service.d/perf.conf \
             /etc/systemd/system/XrayR.service.d/limits.conf; do
        if [[ -f "$f" ]]; then
            mkdir -p "${bdir}/files$(dirname "$f")"
            cp -a "$f" "${bdir}/files${f}"
        fi
    done

    # 快照内核参数原值
    : > "${bdir}/sysctl-original.txt"
    for k in $TUNE_SYSCTL_KEYS; do
        v="$(sysctl -n "$k" 2>/dev/null)"
        if [[ -n "$v" ]]; then
            printf '%s = %s\n' "$k" "$(echo "$v" | tr '\t' ' ')" >> "${bdir}/sysctl-original.txt"
        else
            printf '# %s = (调优前该参数不存在/模块未加载)\n' "$k" >> "${bdir}/sysctl-original.txt"
        fi
    done

    # 记录调优前已存在的文件清单(用于识别哪些是调优新增的)
    ls -1 /etc/sysctl.d/ 2>/dev/null > "${bdir}/sysctl.d-before.txt"
    ls -1 /etc/security/limits.d/ 2>/dev/null > "${bdir}/limits.d-before.txt"
    ls -1 /etc/systemd/system/XrayR.service.d/ 2>/dev/null > "${bdir}/XrayR.service.d-before.txt"

    {
        echo "备份时间: $(date -Is)"
        echo "主机: $(hostname)"
        echo "内核: $(uname -r)"
        echo "调优前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
        echo "调优前默认qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    } > "${bdir}/state-before.txt"

    # 生成独立回滚脚本
    cat > "${bdir}/restore.sh" << 'RESTOREEOF'
#!/bin/bash
# XrayR 调优回滚脚本 (自动生成)
# 用法: bash restore.sh [--yes]
set +e
BDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G=$'\033[0;32m'; Y=$'\033[0;33m'; C=$'\033[0;36m'; R=$'\033[0;31m'; N=$'\033[0m'
echo ""
echo "${C}=== XrayR 调优回滚 -> 恢复到调优前状态 ===${N}"
if [[ -f "$BDIR/state-before.txt" ]]; then
    sed 's/^/  /' "$BDIR/state-before.txt"
fi
echo ""
if [[ "$1" != "--yes" ]] && [[ "$1" != "-y" ]]; then
    read -erp "确认回滚? 输入 yes: " ok
    if [[ "$ok" != "yes" ]]; then echo "${Y}已取消${N}"; exit 0; fi
fi

echo "${C}[1/4] 恢复被覆盖的文件${N}"
if [[ -d "$BDIR/files" ]]; then
    (cd "$BDIR/files" && find . -type f 2>/dev/null) | while read -r rel; do
        cp -a "$BDIR/files/${rel#./}" "/${rel#./}" && echo "  已恢复 /${rel#./}"
    done
fi

echo "${C}[2/4] 删除调优新增的文件${N}"
clean_new() {
    local dir="$1" lst="$2" f base
    [[ -d "$dir" ]] || return 0
    [[ -f "$lst" ]] || return 0
    for f in "$dir"/*; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f")"
        if ! grep -qxF "$base" "$lst" 2>/dev/null; then
            rm -f "$f" && echo "  已删除 $f"
        fi
    done
}
clean_new /etc/sysctl.d "$BDIR/sysctl.d-before.txt"
clean_new /etc/security/limits.d "$BDIR/limits.d-before.txt"
clean_new /etc/systemd/system/XrayR.service.d "$BDIR/XrayR.service.d-before.txt"

echo "${C}[3/4] 回写内核参数原值${N}"
okc=0; skipc=0
while IFS= read -r line; do
    case "$line" in \#*|"") continue ;; esac
    k="${line%% = *}"; v="${line#* = }"
    if sysctl -w "$k=$v" >/dev/null 2>&1; then okc=$((okc+1)); else skipc=$((skipc+1)); fi
done < "$BDIR/sysctl-original.txt"
echo "  已回写 $okc 项, 跳过 $skipc 项"
sysctl --system >/dev/null 2>&1

echo "${C}[4/4] 重载并重启服务${N}"
# init 系统自适应 (restore.sh 是独立脚本, 需自带检测)
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl restart XrayR 2>/dev/null
    SVCSTAT="$(systemctl is-active XrayR 2>/dev/null)"
elif command -v rc-service >/dev/null 2>&1; then
    rc-service XrayR restart >/dev/null 2>&1
    SVCSTAT="$(rc-service XrayR status 2>/dev/null | head -1)"
elif [ -x /etc/init.d/XrayR ]; then
    /etc/init.d/XrayR restart >/dev/null 2>&1
    SVCSTAT="$(/etc/init.d/XrayR status 2>/dev/null | head -1)"
else
    pkill -f "/usr/local/XrayR/XrayR --config" 2>/dev/null
    sleep 1
    setsid nohup /usr/local/XrayR/XrayR --config /etc/XrayR/config.yml >> /var/log/xrayr.log 2>&1 < /dev/null &
    SVCSTAT="裸进程模式已重启"
fi
sleep 3
echo ""
echo "  服务状态 : ${SVCSTAT}
echo "  拥塞控制 : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "  默认qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
echo "  rmem_max : $(sysctl -n net.core.rmem_max 2>/dev/null)"
echo ""
echo "${G}回滚完成${N}"
RESTOREEOF
    chmod +x "${bdir}/restore.sh"
    echo "${bdir}" > /var/lib/.xrayr-last-tuning-backup 2>/dev/null
    TUNE_LAST_BACKUP="$bdir"
    print_ok "调优前状态已备份: ${CYAN}${bdir}${NC}"
    print_info "回滚命令: ${GREEN}bash ${bdir}/restore.sh${NC}  或面板内 [回滚调优]"
    return 0
}

# 显示当前网络参数现状, 供用户判断是否需要调优
tune_show_current() {
    local cc qd rmax keep somax nproc_v
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    rmax="$(sysctl -n net.core.rmem_max 2>/dev/null)"
    keep="$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)"
    somax="$(sysctl -n net.core.somaxconn 2>/dev/null)"
    if [[ "$(detect_init)" == "systemd" ]]; then
        nproc_v="$(systemctl show XrayR -p LimitNPROC --value 2>/dev/null)"
    else
        nproc_v="$(ulimit -u 2>/dev/null)"
    fi

    # 中文列对齐 (中文按 2 列宽计算)
    _trow() {
        local a="$1" b="$2" c="$3" dw pad
        dw=$(awk -v s="$a" 'BEGIN{
            n=length(s); w=0;
            for(i=1;i<=n;i++){ ch=substr(s,i,1); w += (ch ~ /[\x80-\xff]/) ? 0 : 1 }
            bl=0; cmd="printf %s \047" s "\047 | wc -c"; cmd | getline bl; close(cmd);
            print w + ((bl-w)/3)*2
        }')
        pad=$((22-dw)); [[ $pad -lt 1 ]] && pad=1
        printf "    %s%*s%-16s %s\n" "$a" "$pad" "" "$b" "$c"
    }
    echo ""
    echo -e "  ${BOLD}当前系统网络参数${NC}"
    _trow "参数" "当前值" "调优目标值"
    echo -e "    ${DIM}──────────────────────────────────────────────${NC}"
    _trow "拥塞控制算法" "${cc:-未知}" "bbr"
    _trow "默认队列调度" "${qd:-未知}" "fq"
    _trow "接收缓冲上限" "${rmax:-未知}" "67108864"
    _trow "TCP保活时间(秒)" "${keep:-未知}" "300"
    _trow "somaxconn" "${somax:-未知}" "65535"
    _trow "服务进程数上限" "${nproc_v:-未知}" "infinity"
    unset -f _trow

    # 已有自定义 sysctl 配置提示
    local existing
    existing="$(ls /etc/sysctl.d/*.conf 2>/dev/null | grep -v '99-xrayr-perf.conf' | head -5)"
    if [[ -n "$existing" ]]; then
        print_warn "检测到系统已有自定义 sysctl 配置:"
        echo "$existing" | sed 's/^/      /'
        print_warn "若已针对本机手动调优过, 建议选择 [跳过] 以免覆盖"
    fi
    if [[ "$cc" == "bbr" ]] && [[ "$qd" == "fq" ]] && [[ "${rmax:-0}" -ge 16777216 ]]; then
        print_ok "本机看起来已完成过网络调优, 可直接跳过"
    fi

    # 异常低值主动检测 (母机模板常埋的坑, 会导致代理"用一会就断流")
    local tw pr syn abnormal=0
    tw="$(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null)"
    syn="$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null)"
    pr="$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | tr '\t' ' ')"
    if [[ -n "$tw" && "$tw" -lt 32768 ]]; then
        print_warn "tcp_max_tw_buckets=${tw} 偏低 (代理机建议 >=262144): TIME_WAIT 易爆满, 表现为'刚连正常, 过一会断流'"
        abnormal=1
    fi
    if [[ -n "$syn" && "$syn" -lt 1024 ]]; then
        print_warn "tcp_max_syn_backlog=${syn} 偏低 (建议 >=8192): 突发连接易被丢弃"
        abnormal=1
    fi
    if [[ -n "$pr" ]]; then
        local plo phi span
        plo="${pr%% *}"; phi="${pr##* }"
        span=$(( phi - plo ))
        if [[ "$span" -lt 20000 ]]; then
            print_warn "ip_local_port_range=${pr} 可用端口仅 ${span} 个 (建议 >=40000): 高负载下易端口耗尽"
            abnormal=1
        fi
    fi
    if [[ "$abnormal" == "1" ]]; then
        print_warn "以上为异常低值, 多由 VPS 母机模板预置, 而非本机优化结果; 建议执行 [safe] 或 [full] 调优修正"
    fi
    return 0
}

# install_kernel_tuning [mode]
#   full   = 全量调优 (默认)
#   safe   = 仅保守项 (不改拥塞控制/qdisc, 只调缓冲/保活/backlog)
install_kernel_tuning() {
    local mode="${1:-full}"

    # 调优前自动备份 + 生成回滚脚本
    tune_backup

    if [[ "$mode" == "safe" ]]; then
        print_info "应用保守调优 (保留现有拥塞控制与 qdisc)..."
        cat > /etc/sysctl.d/99-xrayr-perf.conf << 'SAFEEOF'
# XrayR 保守调优 (不改动拥塞控制算法与队列调度)
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
SAFEEOF
        sysctl --system >/dev/null 2>&1
        print_ok "保守调优已应用 (拥塞控制保持: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null))"
        return 0
    fi

    print_info "应用全量内核网络调优 (BBR + fq + 大缓冲 + keepalive + conntrack)..."
    cat > /etc/sysctl.d/99-xrayr-perf.conf << 'SYSEOF'
# XrayR 性能与稳定性调优
# 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# 大缓冲 (长肥管道)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
# 队列 / backlog
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_max_tw_buckets = 1440000
# 保活 (需与 XrayR ConnIdle 匹配, 避免 NAT 中断)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
# 端口范围
net.ipv4.ip_local_port_range = 10000 65535
# MTU 探测 / 中间盒鲁棒
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 131072
# 快开 / 无延迟
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
# 连接跟踪 (若加载)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
# 转发
net.ipv4.ip_forward = 1
SYSEOF
    modprobe nf_conntrack 2>/dev/null
    sysctl --system >/dev/null 2>&1

    cat > /etc/security/limits.d/99-xrayr.conf << 'LIMEOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  unlimited
* hard nproc  unlimited
root soft nofile 1048576
root hard nofile 1048576
LIMEOF

    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    if [[ "$cc" == "bbr" ]]; then
        print_ok "内核调优已应用 (拥塞控制: bbr)"
    else
        print_warn "内核调优已写入, 但当前拥塞控制仍为: ${cc:-未知} (可能需重启或内核不支持 BBR)"
    fi
    return 0
}

# 交互询问是否执行内核调优 (可选, 默认跳过以免覆盖既有优化)
# 调优管理子菜单 (可选调优 + 回滚)
menu_tuning() {
    while true
    do
        show_banner
        echo -e "${BOLD}   内核网络调优管理${NC}  ${DIM}(全部可选, 调优前自动备份)${NC}"
        tune_show_current

        local bdir=""
        if [[ -f /var/lib/.xrayr-last-tuning-backup ]]; then
            bdir="$(cat /var/lib/.xrayr-last-tuning-backup 2>/dev/null)"
        fi
        if [[ -n "$bdir" ]] && [[ -d "$bdir" ]]; then
            echo -e "   最近备份 : ${CYAN}${bdir}${NC}"
        else
            echo -e "   最近备份 : ${DIM}无 (尚未执行过调优)${NC}"
        fi
        echo ""
        echo -e "   ${GREEN}1)${NC} 保守调优 ${DIM}(只调缓冲/保活/backlog, 保留拥塞控制与 qdisc)${NC}"
        echo -e "   ${GREEN}2)${NC} 全量调优 ${DIM}(BBR + fq + 大缓冲 + keepalive + conntrack)${NC}"
        echo -e "   ${GREEN}3)${NC} ${YELLOW}回滚到调优前状态${NC}"
        echo -e "   ${GREEN}4)${NC} 查看所有备份点"
        echo -e "   ${GREEN}5)${NC} 仅备份当前状态 ${DIM}(不做任何修改)${NC}"
        echo -e "   ${GREEN}0)${NC} 返回上级菜单"
        echo ""
        local c=""
        if ! read -erp "   请选择 [0-5]: " c; then
            echo ""
            print_info "输入已结束, 返回"
            return 0
        fi
        case "$c" in
            1) install_kernel_tuning safe; pause ;;
            2) install_kernel_tuning full; pause ;;
            3)
                local rb=""
                if [[ -f /var/lib/.xrayr-last-tuning-backup ]]; then
                    rb="$(cat /var/lib/.xrayr-last-tuning-backup 2>/dev/null)"
                fi
                if [[ -n "$rb" ]] && [[ -x "${rb}/restore.sh" ]]; then
                    bash "${rb}/restore.sh"
                else
                    print_error "找不到可用的备份点"
                    print_info "备份目录: ${TUNE_BACKUP_ROOT}"
                fi
                pause ;;
            4)
                echo ""
                if [[ -d "$TUNE_BACKUP_ROOT" ]]; then
                    local d
                    for d in "$TUNE_BACKUP_ROOT"/*; do
                        [[ -d "$d" ]] || continue
                        echo -e "   ${CYAN}$(basename "$d")${NC}"
                        if [[ -f "$d/state-before.txt" ]]; then
                            sed 's/^/       /' "$d/state-before.txt"
                        fi
                        echo -e "       ${DIM}回滚: bash ${d}/restore.sh${NC}"
                        echo ""
                    done
                else
                    print_info "暂无备份点"
                fi
                pause ;;
            5) tune_backup; pause ;;
            0) return 0 ;;
            *) print_warn "无效选择"; sleep 1 ;;
        esac
    done
}

prompt_kernel_tuning() {
    local interactive="${1:-1}"

    if [[ "$interactive" != "1" ]]; then
        print_info "非交互安装: 已跳过内核调优 (如需调优请运行 ${GREEN}xrayr-install tune${NC} 或面板内选择)"
        return 0
    fi

    tune_show_current

    echo -e "  ${BOLD}是否应用内核网络调优?${NC} ${DIM}(调优前会自动备份并生成回滚脚本)${NC}"
    echo ""
    echo -e "    ${GREEN}1)${NC} 跳过 ${DIM}(推荐: 本机已手动调优过, 或不确定时)${NC}"
    echo -e "    ${GREEN}2)${NC} 保守调优 ${DIM}(只调缓冲/保活/backlog, 不动拥塞控制与 qdisc)${NC}"
    echo -e "    ${GREEN}3)${NC} 全量调优 ${DIM}(BBR + fq + 大缓冲 + keepalive + conntrack)${NC}"
    echo ""
    local tc=""
    read -erp "  请选择 [1-3, 默认=1 跳过]: " tc
    case "$tc" in
        2) install_kernel_tuning safe ;;
        3) install_kernel_tuning full ;;
        *) print_info "已跳过内核调优 (保留系统现有网络参数)" ;;
    esac
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
    if [[ "$(detect_init)" == "systemd" ]]; then systemctl restart systemd-journald >/dev/null 2>&1; fi

    mkdir -p "/etc/systemd/system/${SERVICE_NAME}.service.d"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service.d/limits.conf" << 'SDEOF'
[Service]
LogRateLimitIntervalSec=30s
LogRateLimitBurst=5000
SDEOF
    svc_daemon_reload
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
            if _try_enable_cron_svc "$cron_svc"; then
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
GEOEOF
    chmod +x "${INSTALL_DIR}/geo-update.sh"

    if crontab -l 2>/dev/null | grep -q "geo-update.sh"; then
        print_info "GeoData 定时更新已存在"
    else
        (crontab -l 2>/dev/null; echo "$(geo_cron_expr) ${INSTALL_DIR}/geo-update.sh >/dev/null 2>&1") | crontab -
        print_ok "GeoData 定时更新已安装 ($(geo_cron_desc))"
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
OnCalendar=*-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
TTEOF
    svc_daemon_reload
    systemctl enable --now xrayr-geo-update.timer >/dev/null 2>&1  # 仅 systemd 路径调用
    print_ok "GeoData systemd timer 已启用 (每天 04:30)"
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
    init_ready
    # 裸进程模式不写服务单元, 只能看二进制是否装了 + 进程是否在
    if [[ "$(detect_init)" == "none" ]]; then
        if [[ ! -x "${INSTALL_DIR}/XrayR" ]]; then
            echo "none"
        elif svc_is_active; then
            echo "running"
        else
            echo "stopped"
        fi
        return 0
    fi
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo "none"
        return 0
    fi
    if svc_is_active; then
        echo "running"
    else
        echo "stopped"
    fi
    return 0
}

svc_autostart() {
    if svc_is_enabled; then
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

cron_human() {
    local expr="$1"
    case "$expr" in
        "30 4 * * *")  echo "每天 04:30" ;;
        "0 4 * * *")   echo "每天 04:00" ;;
        *" * * *")     echo "每天 $(echo "$expr" | awk '{printf "%02d:%02d", $2, $1}')" ;;
        *)             echo "cron: $expr" ;;
    esac
    return 0
}

geo_cron_expr() {
    local expr=""
    expr="$(geo_conf_get GEO_CRON "")"
    if [[ -z "$expr" ]]; then expr="30 4 * * *"; fi
    echo "$expr"
    return 0
}

geo_cron_desc() {
    local expr=""
    expr="$(geo_cron_expr)"
    cron_human "$expr"
    return 0
}

geo_schedule_desc() {
    local line=""
    if command -v crontab >/dev/null 2>&1; then
        line="$(crontab -l 2>/dev/null | grep "geo-update.sh" | head -1)"
        if [[ -n "$line" ]]; then
            echo "$(cron_human "$(echo "$line" | cut -d\  -f1-5)") (cron)"
            return 0
        fi
    fi
    if [[ "$(detect_init)" == "systemd" ]] && systemctl is-enabled --quiet xrayr-geo-update.timer 2>/dev/null; then
        echo "每天 04:30 (systemd timer)"
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
        local _core
        _core="$(read_version_state CORE_VERSION)"
        if [[ -z "$_core" ]] || [[ "$_core" == "unknown" ]]; then
            _core="$(get_core_version)"
        fi
        if [[ -n "$_core" ]]; then
            echo -e "   Xray 内核  ${CYAN}${_core}${NC}"
        fi
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
        echo -e "   开机自启   ${GREEN}已启用${NC}    服务管理  ${CYAN}$(init_desc)${NC}"
    else
        echo -e "   开机自启   ${YELLOW}未启用${NC}    服务管理  ${CYAN}$(init_desc)${NC}"
    fi
    echo -e "   系统架构   ${CYAN}$(get_arch)${NC} ${DIM}($(arch_desc "$(get_arch)"))${NC}"

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
        local _ac
        _ac="$(read_update_conf AUTO_CHECK true)"
        if [[ "$_ac" == "true" ]]; then
            local _aa
            _aa="$(read_update_conf AUTO_APPLY false)"
            if [[ "$_aa" == "true" ]]; then
                echo -e "   自动更新   ${GREEN}每日检查 + 自动升级${NC}"
            else
                echo -e "   自动更新   ${GREEN}每日检查${NC} ${DIM}(仅提醒)${NC}"
            fi
        else
            echo -e "   自动更新   ${YELLOW}未启用${NC}"
        fi
    fi
    show_update_notice
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
        print_error "无法识别系统架构: $(uname -m)"
        echo ""
        print_info "当前发布支持以下架构 (共 15 种):"
        echo -e "   ${CYAN}amd64${NC} ${CYAN}386${NC} ${CYAN}arm64${NC} ${CYAN}armv7${NC} ${CYAN}armv6${NC} ${CYAN}armv5${NC}"
        echo -e "   ${CYAN}mips${NC} ${CYAN}mipsle${NC} ${CYAN}mips64${NC} ${CYAN}mips64le${NC}"
        echo -e "   ${CYAN}ppc64${NC} ${CYAN}ppc64le${NC} ${CYAN}riscv64${NC} ${CYAN}s390x${NC} ${CYAN}loong64${NC}"
        echo ""
        print_info "若你的架构在上表中, 可用环境变量强制指定后重试:"
        echo -e "   ${GREEN}XRAYR_ARCH=mipsle bash install.sh${NC}"
        echo ""
        print_info "诊断信息 (反馈问题时请附上):"
        echo "   uname -m  : $(uname -m)"
        echo "   uname -a  : $(uname -a 2>/dev/null | cut -c1-120)"
        echo "   发行版    : $(detect_distro)"
        echo "   libc      : $(detect_libc)"
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

    svc_stop

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
    prompt_kernel_tuning "$interactive"
    install_log_limits
    install_geo_cron
    register_command
    install_self_copy
    write_version_state "$version"
    prompt_update_checker "$interactive"

    echo ""
    echo -e "${GREEN}${BOLD}  ══════════  XrayR ${version} 安装完成  ══════════${NC}"
    echo ""
    echo -e "   管理面板命令 : ${GREEN}${BOLD}xrayr${NC}"
    echo -e "   安装管理命令 : ${GREEN}${BOLD}xrayr-install${NC} ${DIM}(更新/降级/卸载)${NC}"
    echo -e "   主配置文件   : ${CYAN}${CONFIG_DIR}/config.yml${NC}"
    local _ic
    _ic="$(get_core_version)"
    if [[ -n "$_ic" ]]; then
        echo -e "   Xray 内核    : ${CYAN}${_ic}${NC}"
    fi
    echo -e "   检测更新     : ${CYAN}xrayr-install check-update${NC}"
    echo -e "   指定版本     : ${CYAN}xrayr-install update <版本号>${NC}"
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
    svc_stop

    if ! download_binary "$version" "$arch"; then
        print_error "升级失败, 保持原版本"
        if [[ $was_running -eq 1 ]]; then
            svc_start
        fi
        return 1
    fi
    download_manager_scripts "$version"
    install_systemd_service
    install_log_limits
    register_command
    install_self_copy
    write_version_state "$version"
    rm -f /etc/XrayR/.update-available "$UPDATE_CACHE_FILE"

    if [[ $was_running -eq 1 ]]; then
        svc_start
    fi
    print_ok "已升级到 ${version}"
    local _nc
    _nc="$(get_core_version)"
    if [[ -n "$_nc" ]]; then
        echo -e "   内嵌 Xray 内核: ${GREEN}${_nc}${NC}"
    fi
    return 0
}

do_uninstall() {
    check_root
    init_ready
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
    svc_stop
    svc_disable
    rm -f "$SERVICE_FILE"
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service.d/limits.conf"
    rmdir "/etc/systemd/system/${SERVICE_NAME}.service.d" 2>/dev/null
    if [[ "$(detect_init)" == "systemd" ]]; then
    systemctl stop xrayr-geo-update.timer >/dev/null 2>&1
    systemctl disable xrayr-geo-update.timer >/dev/null 2>&1
    fi
    rm -f /etc/systemd/system/xrayr-geo-update.timer /etc/systemd/system/xrayr-geo-update.service
    if [[ "$(detect_init)" == "systemd" ]]; then
    systemctl stop xrayr-update-check.timer >/dev/null 2>&1
    systemctl disable xrayr-update-check.timer >/dev/null 2>&1
    fi
    rm -f /etc/systemd/system/xrayr-update-check.timer /etc/systemd/system/xrayr-update-check.service
    svc_daemon_reload
    print_ok "服务已注销"

    print_info "删除程序文件..."
    rm -rf "$INSTALL_DIR"
    print_ok "程序目录已删除"

    print_info "注销 xrayr 命令..."
    rm -f "$COMMAND_LINK" /usr/bin/xrayr
    rm -f /usr/local/bin/xrayr-install /usr/bin/xrayr-install
    hash -r 2>/dev/null
    print_ok "命令已注销"

    print_info "清理定时任务与日志规则..."
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "geo-update" | grep -v "update-check.sh" | crontab - >/dev/null 2>&1
    fi
    rm -f /etc/logrotate.d/xrayr
    rm -f /etc/systemd/journald.conf.d/xrayr-limits.conf
    rm -f /var/log/xrayr-geo-update.log
    rm -f /var/log/xrayr-update-check.log
    rm -f "$UPDATE_CACHE_FILE" /etc/XrayR/.update-available
    if [[ "$(detect_init)" == "systemd" ]]; then systemctl restart systemd-journald >/dev/null 2>&1; fi
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
            1) svc_start && print_ok "已启动" || print_error "启动失败"; pause ;;
            2) svc_stop && print_ok "已停止" || print_error "停止失败"; pause ;;
            3) svc_restart && print_ok "已重启" || print_error "重启失败"; pause ;;
            4) svc_status_text; pause ;;
            5) svc_enable && print_ok "开机自启已启用"; pause ;;
            6) svc_disable && print_ok "开机自启已关闭"; pause ;;
            7) echo -e "   ${DIM}Ctrl+C 退出日志查看${NC}"; svc_log_follow ;;
            8) svc_log_tail 100; pause ;;
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
                echo -e "   ${DIM}cron 格式: 分 时 日 月 周   例: 30 4 * * * (每天 04:30) / 30 4 * * 2,5 (每周二五 04:30)${NC}"
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
                    if [[ "$(detect_init)" == "systemd" ]]; then systemctl disable --now xrayr-geo-update.timer >/dev/null 2>&1; fi
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
        for cmd in curl wget crontab logrotate python3 tar awk openssl
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
        echo -e "   ${GREEN}2)${NC} 内核网络调优管理 ${DIM}(可选/可回滚)${NC}"
        echo -e "   ${GREEN}3)${NC} 重新安装日志大小限制"
        echo -e "   ${GREEN}4)${NC} 重新注册 xrayr 命令"
        echo -e "   ${GREEN}5)${NC} 重新生成 systemd 服务"
        echo -e "   ${GREEN}6)${NC} 补齐缺失配置文件"
        echo -e "   ${GREEN}7)${NC} 查看磁盘 / 内存占用"
        echo -e "   ${GREEN}0)${NC} 返回上级菜单"
        echo ""
        local c=""
        if ! read -erp "   请选择 [0-7]: " c; then
            echo ""
            print_info "输入已结束, 返回"
            return 0
        fi
        case "$c" in
            1) install_dependencies; pause ;;
            2) menu_tuning ;;
            3) install_log_limits; pause ;;
            4) register_command; pause ;;
            5) install_systemd_service; pause ;;
            6) install_config_files; print_ok "配置文件检查完成"; pause ;;
            7)
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
        echo -e "   ${GREEN}9)${NC} ${BOLD}更新管理 (检测/指定版本/自动更新)${NC}"
        echo -e "   ${GREEN}0)${NC} 退出"
        echo -e "${CYAN}  ──────────────────────────────────────────────────${NC}"
        echo ""
        local c=""
        if ! read -erp "   请输入选项 [0-9]: " c; then
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
            9) menu_update ;;
            8)
                echo ""
                echo -e "   已安装版本 : ${GREEN}$(get_installed_version)${NC}"
                echo -e "   安装脚本版 : ${GREEN}$(get_installed_script_version)${NC} ${DIM}(本次运行: ${SCRIPT_VERSION})${NC}"
                echo -e "   Xray 内核  : ${GREEN}$(get_core_version)${NC}"
                echo -e "   仓库最新版 : ${GREEN}$(get_latest_version)${NC}"
                echo -e "   发布仓库   : ${CYAN}${REPO}${NC}"
                echo ""
                echo -e "   ${BOLD}运行环境${NC}"
                echo -e "   操作系统   : ${CYAN}$(detect_distro)${NC}"
                echo -e "   内核版本   : ${CYAN}$(uname -r)${NC}"
                echo -e "   系统架构   : ${CYAN}$(uname -m)${NC} → 资产 ${GREEN}$(get_arch)${NC} ${DIM}($(arch_desc "$(get_arch)"))${NC}"
                echo -e "   C 运行库   : ${CYAN}$(detect_libc)${NC}"
                echo -e "   服务管理   : ${CYAN}$(init_desc)${NC}"
                detect_pkg_mgr
                echo -e "   包管理器   : ${CYAN}$(pkg_mgr_desc)${NC}"
                echo -e "   CPU 核心   : ${CYAN}$(nproc 2>/dev/null || echo 未知)${NC}"
                local _mem
                _mem="$(awk '/MemTotal/{printf "%.0fMB", $2/1024}' /proc/meminfo 2>/dev/null)"
                echo -e "   内存总量   : ${CYAN}${_mem:-未知}${NC}"
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
    echo -e "  upgrade <版本> 更新到指定版本 (可升级/降级)"
    echo -e "  update         同 upgrade"
    echo -e "  update <版本>  更新到指定版本, 例 update v0.9.5"
    echo -e "  update check   仅检测更新, 不做改动"
    echo -e "  update list    列出发布仓库所有可用版本"
    echo -e "  update self    更新安装脚本自身"
    echo -e "  update scripts 更新管理面板脚本 (xrayr 命令)"
    echo -e "  update auto on|off    开关每日自动检查更新"
    echo -e "  update apply on|off   开关检测到新版后自动升级"
    echo -e "  check-update   检测更新 (同 update check)"
    echo -e "  self-update    更新安装脚本自身 (同 update self)"
    echo -e "  uninstall      卸载"
    echo -e "  deps           仅检查并安装依赖"
    echo -e "  log-limit      仅安装日志大小限制
  tune show      查看当前网络参数与调优目标值对比
  tune safe      保守调优 (不动拥塞控制/qdisc)
  tune full      全量调优 (BBR + fq + 大缓冲 + keepalive)
  tune backup    仅备份当前状态并生成回滚脚本
  tune restore   回滚到调优前状态"
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
        upgrade)
            # upgrade            -> 升级到最新
            # upgrade v0.9.5     -> 升级/降级到指定版本
            if [[ -n "${2:-}" ]]; then
                do_upgrade_to "$2"
            else
                do_upgrade
            fi
            ;;
        update)
            # update             -> 等同 upgrade
            # update <版本>      -> 指定版本
            # update check       -> 仅检测更新
            # update list        -> 列出可用版本
            # update self        -> 更新安装脚本自身
            # update scripts     -> 更新管理面板脚本
            # update auto on|off -> 开关每日自动检查
            # update apply on|off-> 开关自动升级
            case "${2:-}" in
                ""|latest)   do_upgrade ;;
                check)       do_check_update 1 ;;
                list|versions)
                    echo ""
                    echo -e "  ${BOLD}发布仓库可用版本${NC} (${CYAN}${REPO}${NC})"
                    local cv
                    cv="$(get_installed_version)"
                    local v
                    while IFS= read -r v; do
                        [[ -z "$v" ]] && continue
                        if [[ "$v" == "$cv" ]]; then
                            echo -e "   ${GREEN}${v}${NC} ${CYAN}← 当前${NC}"
                        else
                            echo -e "   ${v}"
                        fi
                    done < <(list_remote_versions)
                    echo "" ;;
                self|script)  do_self_update ;;
                scripts|manager)
                    local mv
                    mv="$(get_installed_version)"
                    if [[ -z "$mv" ]]; then
                        mv="$(get_latest_version)"
                    fi
                    download_manager_scripts "${mv:-v0.9.5}"
                    register_command ;;
                auto)
                    local aa
                    aa="$(read_update_conf AUTO_APPLY false)"
                    case "${3:-}" in
                        on|enable|true)   install_update_checker true "$aa" ;;
                        off|disable|false) install_update_checker false "$aa" ;;
                        *) print_error "用法: update auto on|off"; return 1 ;;
                    esac ;;
                apply)
                    local ac
                    ac="$(read_update_conf AUTO_CHECK true)"
                    case "${3:-}" in
                        on|enable|true)   install_update_checker "$ac" true ;;
                        off|disable|false) install_update_checker "$ac" false ;;
                        *) print_error "用法: update apply on|off"; return 1 ;;
                    esac ;;
                *)           do_upgrade_to "$2" ;;
            esac
            ;;
        check-update|check)
            do_check_update 1
            ;;
        update-menu|updates)
            if [[ -t 0 ]]; then
                menu_update
            else
                do_check_update 1
            fi
            ;;
        self-update)
            do_self_update
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
        tune|tuning|sysctl)
            case "${2:-}" in
                safe)    install_kernel_tuning safe ;;
                full|"") install_kernel_tuning full ;;
                restore|rollback)
                    local rb=""
                    if [[ -f /var/lib/.xrayr-last-tuning-backup ]]; then
                        rb="$(cat /var/lib/.xrayr-last-tuning-backup 2>/dev/null)"
                    fi
                    if [[ -n "$rb" ]] && [[ -x "${rb}/restore.sh" ]]; then
                        bash "${rb}/restore.sh" "${3:-}"
                    else
                        print_error "找不到可用的备份点 (目录: ${TUNE_BACKUP_ROOT})"
                        return 1
                    fi
                    ;;
                show|status)
                    tune_show_current ;;
                backup)
                    tune_backup ;;
                *)
                    print_error "未知调优子命令: $2"
                    echo "  可用: safe | full | restore | show | backup"
                    return 1 ;;
            esac
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
