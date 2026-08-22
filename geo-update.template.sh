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
    if systemctl restart "$SERVICE_NAME" 2>/dev/null; then
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

