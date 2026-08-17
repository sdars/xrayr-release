#!/bin/bash
# 修复 xray-core freedom UDP 出站空指针崩溃 (SIGSEGV)
#
# 根因链 (v1.260327.0 实测):
#   proxy/freedom/freedom.go  net.ResolveUDPAddr 成功但返回空 IP (len=0)
#                             net.IPAddress([]) 打印 "invalid IP format: []" 并返回 nil
#                             该 nil 被存入 b.UDP.Address
#   common/net/destination.go RawNetAddr() 中 d.Address.Family() 解引用 nil -> SIGSEGV
#
# 触发条件: UDP 流量 + freedom 出站配置 domainStrategy=UseIPv4/UseIPv6,
#           且目标域名解析不出对应族的地址 (如 AAAA-only 或 NXDOMAIN)。
#
# 修复 (纯防御性判空, 不改变正常路径行为):
#   1. RawNetAddr 入口判 d.Address == nil -> 返回 nil, 调用方已有 nil 检查会安全丢包
#   2. freedom UDP: ResolveUDPAddr 返回空 IP 时直接丢包
#   3. freedom UDP: LookupForIP 返回空列表时不再取 ips[0] (避免 dice.Roll(0))
#
# 用法: bash patch-xray-udp-nil.sh <xray-core源码目录>
# 幂等: 已打过补丁会跳过。匹配失败返回非 0, 供上层中止编译。

MODDIR="$1"
if [ -z "$MODDIR" ] || [ ! -d "$MODDIR" ]; then
  echo "用法: $0 <xray-core源码目录>"
  exit 1
fi

DEST="$MODDIR/common/net/destination.go"
FREE="$MODDIR/proxy/freedom/freedom.go"

for f in "$DEST" "$FREE"; do
  if [ ! -f "$f" ]; then
    echo "[错误] 缺少文件: $f"
    exit 1
  fi
  chmod u+w "$f" 2>/dev/null
  if [ ! -f "$f.orig" ]; then cp "$f" "$f.orig"; fi
done

export XR_DEST="$DEST"
export XR_FREE="$FREE"

python3 <<"PYEOF"
import os, re, sys

dest = os.environ["XR_DEST"]
free = os.environ["XR_FREE"]
applied = 0
skipped = 0

# ---------- 补丁1: destination.go RawNetAddr 入口判空 ----------
s = open(dest).read()
if "XRAYR_NILGUARD" in s:
    print("  [跳过] destination.go 已打补丁")
    skipped += 1
else:
    # 用正则匹配函数签名, 不依赖后续缩进
    pat = re.compile(r"(func \(d Destination\) RawNetAddr\(\) net\.Addr \{\n)")
    m = pat.search(s)
    if not m:
        print("  [失败] 未找到 RawNetAddr 函数定义")
        sys.exit(2)
    guard = (
        "\t// XRAYR_NILGUARD: 上游解析失败时 Address 可能为 nil,\n"
        "\t// 直接 d.Address.Family() 会 SIGSEGV。返回 nil 交由调用方丢包。\n"
        "\tif d.Address == nil {\n"
        "\t\treturn nil\n"
        "\t}\n"
    )
    s = s[:m.end(1)] + guard + s[m.end(1):]
    open(dest, "w").write(s)
    print("  [成功] destination.go 插入 nil 判空")
    applied += 1

# ---------- 补丁2/3: freedom.go UDP 空 IP 保护 ----------
f = open(free).read()
if "XRAYR_NILGUARD" in f:
    print("  [跳过] freedom.go 已打补丁")
    skipped += 1
else:
    orig = f

    # 补丁2: ip = net.IPAddress(udpAddr.IP) 之前插入空 IP 检查
    # 用正则捕获该行的实际缩进, 兼容上游缩进变化
    p2 = re.compile(r"(?P<ind>[\t ]+)ip = net\.IPAddress\(udpAddr\.IP\)")
    m2 = p2.search(f)
    if not m2:
        print("  [失败] 未找到 ip = net.IPAddress(udpAddr.IP)")
        sys.exit(2)
    ind = m2.group("ind")
    ins = (
        ind + "// XRAYR_NILGUARD: ResolveUDPAddr 可能成功但 IP 为空,\n"
        + ind + "// net.IPAddress([]) 返回 nil, 后续 RawNetAddr 会 SIGSEGV。\n"
        + ind + "if len(udpAddr.IP) == 0 {\n"
        + ind + "\tb.Release()\n"
        + ind + "\tcontinue\n"
        + ind + "}\n"
    )
    f = f[:m2.start()] + ins + f[m2.start():]
    print("  [成功] freedom.go 插入空 IP 丢包保护")

    # 补丁3: LookupForIP 空结果保护 -> } else { 改成 } else if len(ips) > 0 {
    p3 = re.compile(
        r"\}\s*else\s*\{(\s*\n[\t ]*)ip = net\.IPAddress\(ips\[dice\.Roll\(len\(ips\)\)\]\)"
    )
    m3 = p3.search(f)
    if m3:
        f = f[:m3.start()] + "} else if len(ips) > 0 {" + f[m3.start(1):]
        print("  [成功] freedom.go 加固 LookupForIP 空结果分支")
    else:
        print("  [提示] LookupForIP 分支未匹配 (非致命, 上游可能已修)")

    if f != orig:
        open(free, "w").write(f)
        applied += 1

print("PATCH_APPLIED=%d PATCH_SKIPPED=%d" % (applied, skipped))
PYEOF

PRC=$?
if [ $PRC -ne 0 ]; then
  echo "[错误] 补丁应用失败 (RC=$PRC)"
  echo "       上游代码可能已变动, 需人工核对本脚本的匹配规则"
  exit $PRC
fi

echo "[信息] 补丁标记确认:"
grep -c XRAYR_NILGUARD "$DEST" "$FREE"

# 语法自检 (若编译机有 gofmt)
if command -v gofmt > /dev/null 2>&1; then
  for f in "$DEST" "$FREE"; do
    if ! gofmt -l "$f" > /dev/null 2>&1; then
      echo "[警告] gofmt 检查异常: $f"
    fi
  done
  echo "[信息] gofmt 语法自检完成"
fi

echo "DONE_PATCH"
