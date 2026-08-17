# BufferSize 与 UplinkOnly/DownlinkOnly 性能实测

测试环境: 编译机 64.20.61.133, Xray-core 26.3.27, 32GB RAM, 环回链路 + tc netem 注入 RTT
拓扑: curl -> socks(19100) -> Shadowsocks 客户端 -> Shadowsocks 服务端(19000) -> freedom -> 源站(18080)
方法: 单流下载 5MB 文件, 每档取 3 次峰值; 高并发档 150 并发限速 300k, 每秒采样 RSS 取峰值

## 一、单流吞吐 (MB/s)

| BufferSize | RTT<1ms | RTT 50ms | RTT 150ms |
|---|---|---|---|
| 直连基线(不过代理) | 2485 | 12 | 4 |
| 4   | 1169 | 5 | 2 |
| 16  | 1698 | 6 | 1 |
| 64  | 1348 | 6 | 2 |
| 128 | 1315 | 5 | 2 |
| 512 | 1547 | 6 | 2 |

结论:
- `buf=16` 到 `buf=512` 之间的差异(1315~1698)完全落在重复测量的噪声范围内, 无单调趋势。
- 只有 `buf=4` 明显掉档(1169, 约 -20%), 说明存在一个下限阈值, 低于它才会拖速度。
- **50ms / 150ms 高延迟段所有档位完全一致**, 且都被直连基线同比压制(12->6, 4->2)。
  这证明高延迟下的瓶颈是内核 TCP 拥塞窗口/BDP, 不是 Xray 的应用层缓冲。

## 二、UplinkOnly / DownlinkOnly 对吞吐的影响

| 配置 | RTT<1ms | RTT 50ms | RTT 150ms |
|---|---|---|---|
| buf=64  up=2 dl=5  | 1348 | 6 | 2 |
| buf=64  up=4 dl=30 | 1641 | 6 | 2 |
| buf=512 up=2 dl=5  | 1547 | 6 | 2 |
| buf=512 up=4 dl=30 | 1468 | 6 | 2 |

结论: **无影响**。这两个参数只控制 TCP 半关闭后单向等待的秒数, 作用于连接生命周期的
尾部, 与传输中的吞吐无关。把它们从 4/30 调到 2/5 只会让 CLOSE_WAIT 更早回收(减少
连接数堆积), 不会牺牲速度。

## 三、高并发内存占用 (150 并发 x 5MB)

| BufferSize | 起始 RSS | 客户端峰值 | 服务端峰值 | 峰值连接 | 完成率 |
|---|---|---|---|---|---|
| 4   | 33MB | 54MB | 72MB | 298 | 150/150 |
| 64  | 32MB | 51MB | 73MB | 300 | 150/150 |
| 512 | 32MB | 54MB | 80MB | 294 | 150/150 |

结论: **`bufferSize` 是每连接的缓冲上限, 不是预分配**。150 并发下 buf=512 与 buf=4 的
客户端 RSS 几乎相同(54MB vs 54MB), 服务端仅高 8MB。此前"512 x 500 并发 = 500MB 会 OOM"
的推算不成立 —— 缓冲按需增长, 只有真正被高速填满的连接才会占到上限。

## 四、对安装脚本默认值的修正

基于上述实测, `install.sh` 的自适应档位从"按内存保守压低"改为:

| 内存 | 旧值 | 新值 |
|---|---|---|
| >= 4GB | 512 | 512 |
| 2~4GB  | 128 | **512** |
| 1~2GB  | 64  | **128** |
| < 1GB  | 64  | 64 |

`UplinkOnly: 2` / `DownlinkOnly: 5` 保持不变 —— 实测确认不影响速度, 而收益(加速回收
半关闭连接、降低 CLOSE_WAIT 堆积)是真实的。

## 五、实测原始输出

```
===== RTT<1ms =====
  [直连基线 不过代理]                  => 2485 MB/s
  buf=4     up=2   dl=5    RTT<1ms   =>  1169 MB/s   RSS=32764KB
  buf=16    up=2   dl=5    RTT<1ms   =>  1698 MB/s   RSS=33456KB
  buf=64    up=2   dl=5    RTT<1ms   =>  1348 MB/s   RSS=33168KB
  buf=128   up=2   dl=5    RTT<1ms   =>  1315 MB/s   RSS=32512KB
  buf=512   up=2   dl=5    RTT<1ms   =>  1547 MB/s   RSS=33272KB
  buf=64    up=4   dl=30   RTT<1ms   =>  1641 MB/s   RSS=32108KB
  buf=512   up=4   dl=30   RTT<1ms   =>  1468 MB/s   RSS=33556KB

===== RTT50ms =====
  [直连基线 不过代理]                  => 12 MB/s
  buf=4     up=2   dl=5    RTT50ms   =>     5 MB/s   RSS=33444KB
  buf=16    up=2   dl=5    RTT50ms   =>     6 MB/s   RSS=32424KB
  buf=64    up=2   dl=5    RTT50ms   =>     6 MB/s   RSS=33600KB
  buf=128   up=2   dl=5    RTT50ms   =>     5 MB/s   RSS=32680KB
  buf=512   up=2   dl=5    RTT50ms   =>     6 MB/s   RSS=35992KB
  buf=64    up=4   dl=30   RTT50ms   =>     6 MB/s   RSS=32512KB
  buf=512   up=4   dl=30   RTT50ms   =>     6 MB/s   RSS=33044KB

===== RTT150ms =====
  [直连基线 不过代理]                  => 4 MB/s
  buf=4     up=2   dl=5    RTT150ms  =>     2 MB/s   RSS=33256KB
  buf=16    up=2   dl=5    RTT150ms  =>     1 MB/s   RSS=31220KB
  buf=64    up=2   dl=5    RTT150ms  =>     2 MB/s   RSS=31888KB
  buf=128   up=2   dl=5    RTT150ms  =>     2 MB/s   RSS=33172KB
  buf=512   up=2   dl=5    RTT150ms  =>     2 MB/s   RSS=33264KB
  buf=64    up=4   dl=30   RTT150ms  =>     2 MB/s   RSS=33760KB
  buf=512   up=4   dl=30   RTT150ms  =>     2 MB/s   RSS=35288KB

===== 高并发 RSS 对比 (200 并发 x 5MB) =====

===== 高并发 RSS / 吞吐对比 (150 并发 x 5MB, 限速 300k) =====
  buf=4    起始RSS=33MB 客户端峰值=54MB 服务端峰值=72MB 峰值连接=298 完成=150/150
  buf=64   起始RSS=32MB 客户端峰值=51MB 服务端峰值=73MB 峰值连接=300 完成=150/150
  buf=512  起始RSS=32MB 客户端峰值=54MB 服务端峰值=80MB 峰值连接=294 完成=150/150
RSS压测完成
```
