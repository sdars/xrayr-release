#!/bin/bash
# build-release.sh - 编译 XrayR 发布二进制 (自动应用 xray-core 上游 bug 补丁)
#
# 用途: 在编译机上执行, 产出 linux-amd64 / linux-arm64 双架构二进制。
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
FAIL=0
for ARCH in amd64 arm64; do
  echo "[信息] 编译 linux-$ARCH ..."
  GOOS=linux GOARCH=$ARCH go build -trimpath -ldflags "-s -w" \
    -o "$OUT_DIR/XrayR-linux-$ARCH" .
  if [ $? -ne 0 ]; then
    echo "[错误] linux-$ARCH 编译失败"
    FAIL=1
  else
    echo "[成功] $OUT_DIR/XrayR-linux-$ARCH"
  fi
done

echo "[信息] 产物校验和:"
sha256sum "$OUT_DIR"/XrayR-linux-* 2>/dev/null

# 清理工作区与编译缓存 (避免占用编译机资源)
cd /tmp || cd /
rm -rf "$WORK"
if [ "$KEEP_CACHE" != "1" ]; then
  go clean -cache 2>/dev/null
fi
echo "[信息] 已清理工作区与编译缓存"

if [ $FAIL -ne 0 ]; then
  exit 1
fi
echo "BUILD_OK"
