# XrayR Release

XrayR 自动构建发布仓库。

## 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/sdars/xrayr-release/main/install.sh)
```

## 一键升级

```bash
bash <(curl -sL https://raw.githubusercontent.com/sdars/xrayr-release/main/install.sh) upgrade
```

## 卸载

```bash
bash <(curl -sL https://raw.githubusercontent.com/sdars/xrayr-release/main/install.sh) uninstall
```

## 管理

安装后使用 `xrayr` 命令打开交互式管理面板。

## 支持架构

共 15 种, 覆盖主流服务器、ARM 单板机、国产平台与路由器:

| 资产名 | 说明 | 常见 `uname -m` |
| --- | --- | --- |
| `XrayR-linux-amd64` | 64 位 x86 (Intel/AMD) | `x86_64` |
| `XrayR-linux-386` | 32 位 x86 | `i386` `i686` |
| `XrayR-linux-arm64` | 64 位 ARM | `aarch64` `arm64` |
| `XrayR-linux-armv7` | 32 位 ARM (VFPv3+, 树莓派 2/3) | `armv7l` |
| `XrayR-linux-armv6` | 32 位 ARM (VFPv2, 树莓派 1/Zero) | `armv6l` |
| `XrayR-linux-armv5` | 32 位 ARM (软浮点, 最通用) | `armv5tel` |
| `XrayR-linux-mips` | MIPS 大端 (软浮点) | `mips` |
| `XrayR-linux-mipsle` | MIPS 小端 (软浮点, 常见路由器) | `mips` `mipsel` |
| `XrayR-linux-mips64` | MIPS64 大端 | `mips64` |
| `XrayR-linux-mips64le` | MIPS64 小端 | `mips64` `mips64el` |
| `XrayR-linux-riscv64` | 64 位 RISC-V | `riscv64` |
| `XrayR-linux-loong64` | 龙芯 LoongArch 64 位 | `loongarch64` |
| `XrayR-linux-ppc64` | PowerPC 64 位大端 | `ppc64` |
| `XrayR-linux-ppc64le` | PowerPC 64 位小端 | `ppc64le` |
| `XrayR-linux-s390x` | IBM Z (s390x) | `s390x` |

安装脚本自动识别架构, 包括:

- 64 位内核 + 32 位用户态 (如部分树莓派系统) 会正确选 32 位包
- ARM 会读 `/proc/cpuinfo` 的浮点特性自动决定 armv5 / armv6 / armv7
- MIPS 会读 ELF 字节判断大小端

自动识别失败时可手动指定:

```bash
XRAYR_ARCH=mipsle bash <(curl -sL https://raw.githubusercontent.com/sdars/xrayr-release/main/install.sh)
```

## 支持的发行版与 init 系统

不依赖 systemd, 自动适配:

| init 系统 | 典型发行版 |
| --- | --- |
| systemd | Debian / Ubuntu / CentOS / RHEL / Fedora / openSUSE / Arch |
| OpenRC | Alpine / Gentoo / Devuan |
| SysVinit | 老版 Debian / Slackware / 部分容器环境 |
| procd | OpenWrt / LEDE |
| 无 (裸进程) | 极简容器, 用 `cron @reboot` 自启 |

包管理器支持 14 种: `apt` `dnf` `yum` `apk` `pacman` `zypper` `opkg` `xbps`
`emerge` `swupd` `eopkg` `urpmi` `slackpkg` `nix`。

C 运行库同时支持 glibc 与 musl (二进制为纯静态 `CGO_ENABLED=0`, 无 libc 依赖)。

## 校验产物

release 内附 `SHA256SUMS.txt`:

```bash
curl -fsSLO https://github.com/sdars/xrayr-release/releases/latest/download/SHA256SUMS.txt
sha256sum -c SHA256SUMS.txt --ignore-missing
```
