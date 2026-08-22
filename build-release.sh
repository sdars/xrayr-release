#!/bin/bash
# build-release.sh - 编译 XrayR 发布二进制 (自动应用 xray-core 上游 bug 补丁)
#
# 用途: 在编译机上执行, 产出 Go 支持的全部 linux 架构二进制。
# 关键: 会把 scripts/patch-xray-udp-nil.sh 应用到 xray-core 源码副本,
#       再用 go.mod replace 指向该副本, 修掉上游 freedom UDP 空指针崩溃。
#
# 用法: bash scripts/build-release.sh [输出目录]
#
# 注意: 不使用 set -e (见 install.sh 同款说明)。

SRC_DIR="$(cd "$(dirname "$0")/../src" 2>/dev/null && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
OUT_DIR="${1:-/tmp/xrayr-release-out}"
WORK="${WORK:-/tmp/xrayr-build-$$}"

if [ ! -d "$SRC_DIR" ]; then
  echo "[错误] 找不到 src 目录: $SRC_DIR"
  exit 1
fi

CORE_VER="$(grep -oE "github.com/xtls/xray-core v[0-9.]+" "$SRC_DIR/go.mod" | head -1 | awk "{print \$2}")"
if [ -z "$CORE_VER" ]; then
  echo "[错误] 无法从 go.mod 解析 xray-core 版本"
  exit 1
fi
echo "[信息] xray-core 版本: $CORE_VER"

export GOPATH="${GOPATH:-/root/go}"
export CGO_ENABLED=0

# 确保模块已下载到本地 module cache
MODCACHE="$GOPATH/pkg/mod/github.com/xtls/xray-core@$CORE_VER"
if [ ! -d "$MODCACHE" ]; then
  echo "[信息] 下载 xray-core $CORE_VER 到 module cache..."
  ( cd "$SRC_DIR" && go mod download github.com/xtls/xray-core )
fi
if [ ! -d "$MODCACHE" ]; then
  echo "[错误] module cache 中找不到 $MODCACHE"
  exit 1
fi

mkdir -p "$WORK"
CORE_COPY="$WORK/xray-core"
echo "[信息] 复制 xray-core 源码到 $CORE_COPY"
rm -rf "$CORE_COPY"
cp -r "$MODCACHE" "$CORE_COPY"
chmod -R u+w "$CORE_COPY"

echo "[信息] 应用上游 bug 补丁 (freedom UDP 空指针)"
bash "$SCRIPT_DIR/patch-xray-udp-nil.sh" "$CORE_COPY"
PRC=$?
if [ $PRC -ne 0 ]; then
  echo "[错误] 补丁应用失败 (RC=$PRC), 中止编译"
  echo "       上游代码可能已变动, 需要人工核对 patch-xray-udp-nil.sh"
  rm -rf "$WORK"
  exit 1
fi

# 复制源码到工作区, 避免污染仓库的 go.mod
BUILD_SRC="$WORK/src"
rm -rf "$BUILD_SRC"
mkdir -p "$BUILD_SRC"
cp -r "$SRC_DIR/." "$BUILD_SRC/"

cd "$BUILD_SRC" || exit 1
echo "[信息] 注入 go.mod replace"
go mod edit -replace "github.com/xtls/xray-core=$CORE_COPY"
go mod tidy > /dev/null 2>&1

ACTUAL="$(go list -m github.com/xtls/xray-core 2>/dev/null)"
echo "[信息] 生效模块: $ACTUAL"
case "$ACTUAL" in
  *"=> $CORE_COPY"*) echo "[成功] replace 已生效" ;;
  *) echo "[错误] replace 未生效, 中止"; rm -rf "$WORK"; exit 1 ;;
esac

# 二次确认补丁标记确实在待编译源码里
NG=$(grep -rc XRAYR_NILGUARD "$CORE_COPY/common/net/destination.go" "$CORE_COPY/proxy/freedom/freedom.go" 2>/dev/null | awk -F: "{s+=\$2} END {print s+0}")
if [ "${NG:-0}" -lt 2 ]; then
  echo "[错误] 补丁标记缺失 (找到 $NG 处, 期望>=2), 中止"
  rm -rf "$WORK"
  exit 1
fi
echo "[成功] 补丁校验通过 ($NG 处标记)"

mkdir -p "$OUT_DIR"

# ==================== 全架构编译 ====================
# 清单格式: 资产名|GOARCH|额外环境变量(空格分隔)
# 资产名即 install.sh 里 get_arch() 的返回值, 两边必须一致。
#
# 取值说明:
#   GO386=sse2      : 386 默认就是 sse2, 显式写死避免 Go 版本变动
#   GOARM=5/6/7     : 5=软浮点(最老最通用) 6=VFPv2 7=VFPv3+
#   GOMIPS=softfloat: 绝大多数 MIPS 路由器没有硬件 FPU, 必须软浮点
#   GOAMD64=v1      : 保证老 CPU (无 AVX) 也能跑
ARCH_LIST="
amd64|amd64|GOAMD64=v1
386|386|GO386=sse2
arm64|arm64|
armv7|arm|GOARM=7
armv6|arm|GOARM=6
armv5|arm|GOARM=5
mipsle|mipsle|GOMIPS=softfloat
mips|mips|GOMIPS=softfloat
mips64le|mips64le|GOMIPS64=softfloat
mips64|mips64|GOMIPS64=softfloat
ppc64le|ppc64le|
ppc64|ppc64|
riscv64|riscv64|
s390x|s390x|
loong64|loong64|
"

# 只编指定架构: ONLY_ARCH="amd64 arm64" bash build-release.sh
if [ -n "$ONLY_ARCH" ]; then
  FILTERED=""
  for want in $ONLY_ARCH; do
    line=$(echo "$ARCH_LIST" | grep "^${want}|")
    if [ -n "$line" ]; then
      FILTERED="${FILTERED}${line}
"
    else
      echo "[警告] 未知架构名, 已忽略: $want"
    fi
  done
  ARCH_LIST="$FILTERED"
fi

# 并行度: 默认 CPU 核数的一半, 每个 go build 内部还会再并行,
# 全开会把机器打爆 (实测 8 核开 15 路并行 load 冲到 480)。
NPROC=$(nproc 2>/dev/null || echo 4)
JOBS="${JOBS:-$(( NPROC / 2 ))}"
if [ "$JOBS" -lt 1 ]; then JOBS=1; fi
echo "[信息] 并行度: $JOBS (CPU $NPROC 核)"

# 预热: 先单独编一次 amd64, 把依赖包编译结果灌进 build cache。
# 这样后续架构能复用与架构无关的分析结果, 也能第一时间发现通用编译错误。
echo "[信息] 预热编译 (amd64) ..."
GOOS=linux GOARCH=amd64 GOAMD64=v1 go build -trimpath -ldflags "-s -w" -o "$OUT_DIR/XrayR-linux-amd64" . 2>&1 | tail -20
if [ ! -s "$OUT_DIR/XrayR-linux-amd64" ]; then
  echo "[错误] 预热编译失败, 说明源码本身有问题, 中止"
  cd /tmp || cd /
  rm -rf "$WORK"
  exit 1
fi
echo "[成功] 预热完成: $(du -h "$OUT_DIR/XrayR-linux-amd64" | cut -f1)"

LOGDIR="$WORK/buildlogs"
mkdir -p "$LOGDIR"

# 单架构编译函数 (子进程中执行)
build_one() {
  NAME="$1"; GOA="$2"; EXTRA="$3"
  # amd64 已在预热阶段编好, 跳过
  if [ "$NAME" = "amd64" ] && [ -s "$OUT_DIR/XrayR-linux-amd64" ]; then
    echo "RC=0" > "$LOGDIR/$NAME.rc"
    echo "[跳过] amd64 (预热已产出)" > "$LOGDIR/$NAME.log"
    return 0
  fi
  T0=$(date +%s)
  (
    export GOOS=linux GOARCH="$GOA" CGO_ENABLED=0
    if [ -n "$EXTRA" ]; then
      for kv in $EXTRA; do export "$kv"; done
    fi
    go build -trimpath -ldflags "-s -w" -o "$OUT_DIR/XrayR-linux-$NAME" .
  ) > "$LOGDIR/$NAME.log" 2>&1
  RC=$?
  T1=$(date +%s)
  # 产物必须存在且非空, 否则即使 RC=0 也算失败
  if [ $RC -eq 0 ] && [ ! -s "$OUT_DIR/XrayR-linux-$NAME" ]; then
    RC=90
    echo "[错误] go build 返回 0 但产物为空" >> "$LOGDIR/$NAME.log"
  fi
  echo "RC=$RC SEC=$(( T1 - T0 ))" > "$LOGDIR/$NAME.rc"
  return $RC
}

echo "[信息] 开始全架构编译..."
RUNNING=0
echo "$ARCH_LIST" | while IFS="|" read -r NAME GOA EXTRA; do
  if [ -z "$NAME" ]; then continue; fi
  build_one "$NAME" "$GOA" "$EXTRA" &
  RUNNING=$(( RUNNING + 1 ))
  if [ "$RUNNING" -ge "$JOBS" ]; then
    wait -n 2>/dev/null || wait
    RUNNING=$(( RUNNING - 1 ))
  fi
done
wait
# 上面的 while 在管道子 shell 里, 后台任务归属子 shell,
# 外层 wait 拿不到它们 -> 必须靠 .rc 文件数量确认真正结束。
EXPECT=$(echo "$ARCH_LIST" | grep -c "|")
WAITED=0
while [ "$(ls "$LOGDIR"/*.rc 2>/dev/null | wc -l)" -lt "$EXPECT" ]; do
  sleep 5
  WAITED=$(( WAITED + 5 ))
  if [ $(( WAITED % 60 )) -eq 0 ]; then
    echo "[信息] 已完成 $(ls "$LOGDIR"/*.rc 2>/dev/null | wc -l)/$EXPECT (等待 ${WAITED}s, load $(cut -d" " -f1 /proc/loadavg))"
  fi
  if [ "$WAITED" -gt 3600 ]; then
    echo "[错误] 编译超时 (1 小时), 强制结束"
    break
  fi
done

echo ""
echo "===== 编译结果 ====="
FAIL=0
OKCNT=0
FAILED_ARCH=""
echo "$ARCH_LIST" | while IFS="|" read -r NAME GOA EXTRA; do
  if [ -z "$NAME" ]; then continue; fi
  RCF="$LOGDIR/$NAME.rc"
  if [ ! -f "$RCF" ]; then
    printf "  %-10s %s\n" "$NAME" "未完成"
    continue
  fi
  . "$RCF" 2>/dev/null
  RCV=$(grep -oE "RC=[0-9]+" "$RCF" | cut -d= -f2)
  SECV=$(grep -oE "SEC=[0-9]+" "$RCF" | cut -d= -f2)
  if [ "${RCV:-1}" = "0" ]; then
    SZ=$(du -m "$OUT_DIR/XrayR-linux-$NAME" 2>/dev/null | cut -f1)
    printf "  %-10s 成功  %sMB  %ss\n" "$NAME" "${SZ:-?}" "${SECV:-?}"
  else
    printf "  %-10s 失败 (RC=%s)\n" "$NAME" "$RCV"
  fi
done

# 汇总 (在主 shell 里重算, 避免管道子 shell 变量丢失)
for RCF in "$LOGDIR"/*.rc; do
  if [ ! -f "$RCF" ]; then continue; fi
  N=$(basename "$RCF" .rc)
  RCV=$(grep -oE "RC=[0-9]+" "$RCF" | cut -d= -f2)
  if [ "${RCV:-1}" = "0" ]; then
    OKCNT=$(( OKCNT + 1 ))
  else
    FAIL=1
    FAILED_ARCH="$FAILED_ARCH $N"
  fi
done
echo ""
echo "[信息] 成功 $OKCNT / 预期 $EXPECT"
if [ -n "$FAILED_ARCH" ]; then
  echo "[警告] 失败架构:$FAILED_ARCH"
  echo "===== 失败详情 (每架构末 15 行) ====="
  for N in $FAILED_ARCH; do
    echo "--- $N ---"
    tail -15 "$LOGDIR/$N.log" 2>/dev/null
  done
fi

# 保留编译日志到输出目录, 便于事后排查
cp -r "$LOGDIR" "$OUT_DIR/buildlogs" 2>/dev/null

echo "[信息] 产物校验和:"
( cd "$OUT_DIR" && sha256sum XrayR-linux-* 2>/dev/null | tee SHA256SUMS.txt )

# 清理工作区与编译缓存 (避免占用编译机资源)
SAVED_OUT="$(cd "$OUT_DIR" 2>/dev/null && pwd)"
cd /tmp || cd /
rm -rf "$WORK"
if [ "$KEEP_CACHE" != "1" ]; then
  go clean -cache 2>/dev/null
fi
echo "[信息] 已清理工作区与编译缓存"

# 主力架构 (amd64/arm64) 必须成功; 冷门架构失败只告警, 不阻断发布
MUSTFAIL=0
for MUST in amd64 arm64; do
  if [ ! -s "$SAVED_OUT/XrayR-linux-$MUST" ]; then
    echo "[错误] 主力架构 $MUST 产物缺失, 视为构建失败"
    MUSTFAIL=1
  fi
done
if [ $MUSTFAIL -ne 0 ]; then
  exit 1
fi
if [ $FAIL -ne 0 ]; then
  echo "[提示] 部分冷门架构未产出, 主力架构正常, 可继续发布"
fi
echo "BUILD_OK"
