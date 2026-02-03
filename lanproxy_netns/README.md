# lanproxy-netns

## 为什么需要这个？(Why)

**问题**：Nintendo Switch 不支持 SOCKS 代理，只支持 HTTP 代理。而 UU 加速器的工作原理是通过 nftables 在 `PREROUTING` 链拦截来自 `br-lan` 的流量进行加速。

如果直接在 OpenWrt 上运行 HTTP 代理：

```
Switch  --->  OpenWrt 代理进程  --->  OUTPUT 链  --->  WAN
                                      ↑
                                 不经过 PREROUTING，UU 规则不生效
```

代理进程的出站流量走的是 `OUTPUT` 链（本机进程），而不是 `PREROUTING`（外部设备），所以 UU 的加速规则完全不会命中。

## 这是什么？(What)

**解决方案**：把代理进程放进一个独立的 network namespace，通过 veth pair 接入 `br-lan`，让它在网络层面表现得像一台独立的 LAN 设备。

```
Switch  --->  OpenWrt 代理进程(netns)  --->  veth  --->  br-lan  --->  PREROUTING  --->  UU 加速  --->  WAN
              192.168.1.252                                            ↑
                                                                  现在能命中 UU 规则了
```

lanproxy-netns 是一个轻量级 HTTP/HTTPS 代理，专为这个场景设计：

- **network namespace 隔离**：代理进程的网络栈与主机隔离，出站流量走 `br-lan`
- **veth pair 桥接**：netns 通过虚拟网卡对接入 LAN 网桥，获得真实 LAN IP
- **DHCP 指纹伪装**：可模拟 Switch 的 DHCP 特征，让 UU APP 识别为 Switch 设备
- **访问控制**：可限制只允许特定 IP（如你的 Switch）使用代理

## TCP vs UDP：这个方案的取舍

**设计初衷**：无侵入式加速。

- 不改变现有网络拓扑——OpenWrt 可以是旁路设备，不必做主路由
- 不修改 Switch 网络配置——保持 DHCP 自动获取，网关指向原路由
- 只需设置 HTTP 代理——填个地址和端口，随时可开可关

**代价**：HTTP 代理只能处理 TCP 流量。

```
Switch 网络行为：
├── 走 HTTP 代理的流量（TCP）
│   └── eShop、系统更新、游戏 API 请求
│   └── → lanproxy → UU 加速 ✓
│
└── 直接发出的流量（不走代理）
    └── 游戏实时数据、P2P 联机（UDP 为主）
    └── → 原网关直接出去 → 不经过 OpenWrt → 无法加速 ✗
```

**这是一个明确的取舍**：

| 方案 | 配置复杂度 | TCP 加速 | UDP 加速 |
|------|-----------|----------|----------|
| lanproxy（仅设代理） | 低 | ✓ | ✗ |
| 改 Switch 网关指向 OpenWrt | 高 | ✓ | ✓ |

如果你的游戏主要依赖 UDP（大多数实时对战游戏），且对延迟敏感，可能需要考虑修改 Switch 网关。但如果主要是下载游戏、访问 eShop、或者游戏的 TCP API 请求，lanproxy 方案已经够用。

### 实测性能对比

在同一台 OpenWrt 设备上，同时下载游戏的场景下实测：

```
lanproxy（用户态代理）:  ~10 Mbps
UU 二进制（内核转发）:   ~11 Mbps
差异:                    ~10%
```

虽然 lanproxy 存在理论上的额外开销（用户态中转、TCP-over-TCP），但实测表明瓶颈在 UU 隧道服务端带宽，而非代理本身。两种方案的下载速度几乎一致。

> 测试方法：通过 `/proc/net/dev` 采样 veth/tun 接口流量，取 10 秒平均值。

---

## 0) 前置条件

- OpenWrt 内核启用 network namespace / veth（一般默认有）
- `ip` 命令支持 `ip netns`（通常需要 `opkg install ip-full` 或对应的 iproute2 包）
- uuplugin 已安装且 APP 能正常连上路由器（14554/16363）

---

## 1) 目录与文件（部署到 OpenWrt）

部署后在 OpenWrt 上应是：

```
/usr/bin/lanproxy
/etc/init.d/lanproxy
/etc/lanproxy/config
/etc/lanproxy/netns.sh
/etc/lanproxy/uu-lease.sh
/etc/lanproxy/udhcpc.script
```

---

## 2) 配置（/etc/lanproxy/config）

关键参数：

- `NS_PROTO`：`static` 或 `dhcp`
- `NS_ADDR`：netns 里的“代理设备 IP”，必须是 LAN 里未占用的地址（默认 `192.168.1.252/24`）
- `NS_GW`：OpenWrt 的 br-lan IP（默认 `192.168.1.250`）
- `LISTEN`：代理监听（默认 `0.0.0.0:8888`，在 netns 内）
- `ALLOW_CLIENTS`：强烈建议锁到 Switch IP（例如 `192.168.1.100/32`）

可选参数（用于 UU 设备发现）：

- `WRITE_UU_LEASE=1`：写入本地 lease 文件，帮助 uuplugin/APP 列出该“设备”
- `UU_LEASE_MAC` / `UU_LEASE_HOSTNAME`：用于 lease 展示与设备归属

---

## 2.1) 你这种场景的关键点（OpenWrt DHCP 关闭 + APP 按 Switch 加速）

当 OpenWrt 关闭 DHCP 时，uuplugin/APP 往往依赖：

- 抓到的 DHCP 请求（hostname/vendor-class）来给设备“打标签”（Switch/PS/Xbox）
- ARP/流量特征来补充识别

所以只做一个“静态 IP 的 netns 设备”可能会出现：

- APP 里能看到设备，但类型不是 Switch（无法用 Switch 规则加速）

推荐做法：让 netns 设备走 `NS_PROTO=dhcp`，在启动时发出 DHCP 指纹（hostname/vendor-class），并通过 `NS_GW` 强制网关仍然指向 OpenWrt（不会走主路由直出）。

生产环境建议：

1) `UU_LEASE_MAC` 设成“看起来像 Switch 的 OUI”，但不要和真实 Switch MAC 冲突：
   - 取真实 Switch MAC 的前三段（OUI），后三段随便改一组
   - 如何拿到真实 Switch MAC（任选其一）：
     - Switch 网络信息页查看
     - 在 OpenWrt 上看 ARP（Switch 在线时）：`cat /proc/net/arp | grep <SWITCH_IP>`
2) 在你的主路由（上游 DHCP 服务器）里给 `UU_LEASE_MAC` 做 DHCP 绑定，固定给 `NS_ADDR`（如 `192.168.1.252`）
   - 这一步是生产环境强烈推荐：避免 IP 漂移导致 APP 侧设备变化/加速失效
3) 抓一次真实 Switch 的 DHCP 指纹，然后把同样的值填到 `DHCP_HOSTNAME`/`DHCP_VENDORCLASS`
   - OpenWrt 上抓包（在 Switch 重新连网/重启网卡时观察最明显）：

```sh
tcpdump -i br-lan -n -vvv -s0 'port 67 or port 68'
```

看 `Option 12`(hostname) / `Option 60`(vendor class)。

---

## 2.2) 推荐配置模板（按 Switch 识别 + IP 固定）

在 `/etc/lanproxy/config` 里建议按你的环境改成类似：

```sh
# 让 netns 设备发 DHCP 指纹给 uuplugin 识别
NS_PROTO="dhcp"

# 强制 netns 默认路由走 OpenWrt（而不是上游 DHCP 下发的网关）
NS_GW="192.168.1.250"

# 固定 IP 的方式：在上游 DHCP 绑定 UU_LEASE_MAC -> 192.168.1.252
DHCP_REQUEST_IP="192.168.1.252"

# 从抓包里抄真实 Switch 的 Option 12 / Option 60
DHCP_HOSTNAME="NintendoSwitch"
DHCP_VENDORCLASS="xxx"

# MAC 使用 Nintendo OUI（98:41:5C），后三段随机防冲突
UU_LEASE_MAC="98:41:5C:AA:BB:CC"

# 代理只允许 Switch 使用（强烈建议，替换为你的 Switch IP）
ALLOW_CLIENTS="<SWITCH_IP>/32"
```

`WRITE_UU_LEASE=1` 可以保持开启作为兜底：在旁路网关/外置 DHCP 场景，uuplugin 可能读不到租约文件；写入本地 lease 有助于“设备出现”，但 **Switch 类型识别优先还是靠 DHCP 指纹/流量特征**。

---

## 3) 部署步骤

建议按下面顺序做（更贴近生产流程）：

1) 先定好三件事：
   - `NS_ADDR` (如 `192.168.1.252`) 是否会与其他设备 IP 冲突
   - `UU_LEASE_MAC`（建议取真实 Switch OUI，但必须避免 MAC 冲突）
   - 上游 DHCP 里为 `UU_LEASE_MAC` 做 IP 绑定（建议绑定 `192.168.1.252`）

2) 抓真实 Switch DHCP 指纹（Option 12/60），并写入 `/etc/lanproxy/config`（见上节模板）。

3) 编译（本机）：

```bash
cd lanproxy_netns
./build.sh
```

4) 部署到 OpenWrt（示例 amd64，按你的 OpenWrt 架构改）：

```bash
./deploy.sh 192.168.1.250 amd64
```

5) OpenWrt 启动并开机自启：

```sh
/etc/init.d/lanproxy start
/etc/init.d/lanproxy enable
```

6) Switch 设置代理：

- Proxy IP：`NS_ADDR` 对应的 IP（静态模式）或 DHCP 绑定的 IP（推荐固定 `192.168.1.252`）
- Proxy Port：`8888`

7) UU APP 侧：

- 确认能看到该“设备”（OpenWrt 不是 DHCP 服务器时，`NS_PROTO=dhcp` + 绑定 IP 最关键）
- 确认该设备类型为 Switch，再对该设备开启加速（选择 Switch/游戏配置）

---

## 4) 验证

OpenWrt 上检查 netns 是否就绪：

```sh
/etc/lanproxy/netns.sh status
ip netns exec lanproxy ip addr
```

检查代理是否监听（在 netns 内）：

```sh
ip netns exec lanproxy ss -tlnp | grep 8888
```

检查 udhcpc 是否拿到地址（NS_PROTO=dhcp）：

```sh
ip netns exec lanproxy ip -4 -o addr show
cat /tmp/lanproxy.udhcpc.log 2>/dev/null | tail -n 50
```

从任意 LAN 机器测试：

```bash
curl -x http://192.168.1.252:8888 https://example.com -I
```

验证 UU 数据面是否被命中（加速开启后）：

```sh
nft list ruleset | grep -E 'XU_ACC_MAIN|60000' -n
tcpdump -i lo -n 'port 60000' -c 10
```

---

## 5) 常见问题

1) `ip: can't find device` / `ip netns` 不存在
- 安装 `ip-full`（或你的固件对应的 iproute2 完整包）
- 安装 `kmod-veth`（veth 内核模块）

2) 代理可用但 UU 没加速
- 先确认 UU APP 里"给这个 netns IP 的设备"点了加速
- 检查 UU 是否为该设备创建了规则：`nft list tables | grep XU_ACC_DEVICE`
- 检查策略路由：`ip rule show | grep 192.168.1.252`

3) 设备在 UU APP 不出现
- 旁路网关/外置 DHCP 时，uuplugin 看不到上游 DHCP 租约；启用 `WRITE_UU_LEASE=1` 并设置 `UU_LEASE_HOSTNAME`
- **使用 Nintendo OUI**：设置 `UU_LEASE_MAC="98:41:5C:AA:BB:CC"`（默认值）

4) 设备出现了，但不是 Switch（无法按 Switch 加速）
- 优先检查 `NS_PROTO=dhcp` 是否生效：`ip netns exec lanproxy ip -4 -o addr show`
- 重新抓包确认真实 Switch 的 DHCP 指纹（Option 12/60），并确保 `DHCP_HOSTNAME`/`DHCP_VENDORCLASS` 填写完全一致
- **使用 Nintendo OUI 作为 MAC 地址**：uuplugin 会通过 MAC OUI 识别设备厂商
- 如果上游 DHCP 没有绑定，IP 漂移会导致 APP 侧设备变化，建议加上绑定

---

## 6) Nintendo OUI 与设备识别

uuplugin 通过多层逻辑识别 Switch：

1. **DHCP hostname**：Option 12 = "NintendoSwitch"
2. **MAC OUI**：Nintendo 的 OUI 前缀（98:41:5C, 7C:BB:8A 等）
3. **mDNS 服务发现**
4. **DNS 行为检测**：查询 *.nintendo.net 等域名
5. **P2P 流量模式**

默认配置使用 `98:41:5C:AA:BB:CC`（Nintendo OUI），配合 `DHCP_HOSTNAME=NintendoSwitch`，可以让 uuplugin 识别为 Switch 设备。

### Nintendo 已知 OUI

| OUI | 厂商 |
|-----|------|
| 98:41:5C | Nintendo Co.,Ltd |
| 7C:BB:8A | Nintendo Co.,Ltd |
| 00:1F:32 | Nintendo Co.,Ltd |
| E8:4E:CE | Nintendo Co.,Ltd |
| DC:68:EB | Nintendo Co.,Ltd |
| 40:F4:07 | Nintendo Co.,Ltd |
| A4:C0:E1 | Nintendo Co.,Ltd |

---

## 7) 技术实现

### 超时处理

代理使用动态 deadline 机制：每次读写操作都会刷新超时计时器。这确保了：

- 大文件下载不会因为固定超时而中断（只要数据持续流动就不会超时）
- 空闲连接在 30 秒无活动后自动关闭
- CONNECT 隧道（HTTPS）和普通 HTTP 请求都支持

### HTTP 代理

- 支持 HTTP/1.1 keep-alive 复用连接
- CONNECT 方法用于 HTTPS 隧道
- 正确解析和转发 HTTP 响应头

### 错误处理

- netns.sh DHCP 超时会返回错误状态码
- init 脚本检查 netns 返回值，失败时阻止服务启动
- 详细日志输出到 syslog（`logread | grep lanproxy`）

---

## 8) UU 加速机制

当 UU APP 为设备开启加速后，uuplugin 会：

1. 创建设备专用 nftables 表：`XU_ACC_DEVICE_<IP>_mangle/filter/nat`
2. 创建专用 TUN 隧道：`tun16x`
3. 配置策略路由：
   - `from <IP> lookup <table>` - 游戏服务器路由
   - `from <IP> fwmark 0x16x lookup 16x` - 标记流量走隧道

### 验证命令

```sh
# 检查设备表
nft list tables | grep XU_ACC_DEVICE

# 检查规则详情
nft list table ip XU_ACC_DEVICE_192.168.1.252_mangle

# 检查策略路由
ip rule show | grep 192.168.1.252

# 检查路由表（游戏服务器）
ip route show table 180 | head -20

# 检查 TUN 隧道
ip link show | grep tun
```
