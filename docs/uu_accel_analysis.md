# UU 路由器加速逻辑（OpenWrt）- 分析笔记

日期：2026-02-01

本文基于下述本地文件及对 `uuplugin` 二进制的静态分析（未运行）总结 UU 路由加速插件的端到端逻辑。

**分析文件：**
- `install.sh` (UU 官方安装脚本)
- `uuplugin_monitor.sh`（通过 monitor API 下载）
- `uuplugin` 二进制 (各架构版本)
- `uu.conf` 配置文件

---

## 1) 高层架构

- `install.sh` 是安装/引导脚本，**不实现加速**。
- `uuplugin_monitor.sh` 是**守护/管理**脚本：下载/更新 `uuplugin`，管理启动，以及处理卸载/更新标记。
- 实际的加速逻辑在 **`uuplugin` 二进制** 内。

总体流程：
```
install.sh
  -> 下载 uuplugin_monitor.sh
  -> 写入 uuplugin_monitor.config（router/model）
  -> 启动 monitor

uuplugin_monitor.sh（循环）
  -> 下载 uu.tar.gz（uuplugin + config + xtables-nft-multi）
  -> 解压出 uuplugin
  -> 用配置启动 uuplugin
  -> 处理更新/卸载标记
```

---

## 2) install.sh 逻辑（OpenWrt 路径）

- 路由类型 `openwrt` 设置：
  - `INSTALL_DIR=/usr/sbin/uu/`
  - `MONITOR_FILE=/usr/sbin/uu/uuplugin_monitor.sh`
  - `MONITOR_CONFIG=/usr/sbin/uu/uuplugin_monitor.config`
- 通过以下接口下载卸载和监控脚本：
  - `router.uu.163.com/api/script/uninstall?type=openwrt`
  - `router.uu.163.com/api/script/monitor?type=openwrt`
- 写入 `uuplugin_monitor.config`：
  - `router=openwrt`
  - `model=<model>`
- 启动 monitor 并轮询 `/var/run/uuplugin.pid` 验证 `uuplugin` 运行。
- 通过 `/etc/rc.d/S99uuplugin` 设置开机自启（OpenWrt init 脚本）。

**重要:** `install.sh` 仅负责部署 `uuplugin_monitor.sh`，真实加速逻辑在 `uuplugin`。

---

## 3) uuplugin_monitor.sh 逻辑（守护）

### 3.1 启动与参数
- 从 `uuplugin_monitor.config` 读取 `router=` 与 `model=`。
- 在 OpenWrt 下设定：
  - `PLUGIN_DIR=/usr/sbin/uu`
  - `RUNNING_DIR=/tmp/uu`
  - `PLUGIN_TAR=uu.tar.gz`, `PLUGIN_EXE=uuplugin`, `PLUGIN_CONF=uu.conf`
- 解析 `PLUGIN_DIR` 的挂载点以检测可用空间。

### 3.2 下载 URL 选择
- 基础 API：`DOWNLOAD_URL=router.uu.163.com/api/plugin?type=`
- OpenWrt 使用 **HTTP**，按 `model` 子串选择：
  - 包含 `arm` -> `openwrt-arm`
  - 包含 `aarch64` -> `openwrt-aarch64`
  - 包含 `mipseb` -> `openwrt-mipseb`
  - 包含 `mipsel` 或 `mips` -> `openwrt-mipsel`
  - 包含 `x86_64` -> `openwrt-x86_64`

API 返回格式：
```
<url>,<md5>,...
```
仅使用前两个字段。

### 3.3 目录与标记文件
- 运行目录：`/tmp/uu/`
  - `uuplugin`（解压出的二进制）
  - `uu.conf`（配置）
  - `uu.tar.gz`（下载包）
  - 标记：`uu.update`, `uu.uninstall`
- 持久备份：
  - `/usr/sbin/uu/uu.tar.gz`
  - `/usr/sbin/uu/uu.tar.gz.md5`
- PID 文件：
  - `/var/run/uuplugin.pid`

### 3.4 主循环
每轮执行：
1. `check_backtar_file` - 确认备份 tar 存在；需要时下载并校验。
2. `check_plugin_file` - 若缺少二进制或 tar，则下载。
3. `check_acc` - 处理运行/升级/卸载情形。

若 `uuplugin` 运行，则休眠 60s；否则休眠 5s。

### 3.5 更新 / 卸载逻辑
- **卸载标记** (`/tmp/uu/uu.uninstall`):
  - 下载卸载脚本并执行。
- **更新标记** (`/tmp/uu/uu.update`):
  - 下载新 `uu.tar.gz`，解压并启动新 `uuplugin`。
  - 若 5s 内启动失败则回滚。
  - 若空间允许，将 tar 复制到持久备份。

---

## 4) 插件包内容（uu.tar.gz）

每个 OpenWrt 包包含：
- `uuplugin`（主二进制）
- `uu.conf`（基础配置：`log_level` 与 `version`）
- `xtables-nft-multi`（iptables/nft 辅助）

x86_64 示例配置：
```
log_level=info
version=v12.1.4
```

---

## 5) 观察到的 OpenWrt 下载端点（示例快照）

以下为 2026-02-01 从 API 获取的版本 `v12.1.4`（可能随时间变化）：

- `openwrt-arm`:
  - `http://uurouter.gdl.netease.com/uuplugin/openwrt-arm/v12.1.4/uu.tar.gz?...`
- `openwrt-aarch64`:
  - `http://uurouter.gdl.netease.com/uuplugin/openwrt-aarch64/v12.1.4/uu.tar.gz?...`
- `openwrt-mipseb`:
  - `https://uurouter.gdl.netease.com/uuplugin/openwrt-mipseb/v12.1.4/uu.tar.gz?...`
- `openwrt-mipsel`:
  - `http://uurouter.gdl.netease.com/uuplugin/openwrt-mipsel/v12.1.4/uu.tar.gz?...`
- `openwrt-x86_64`:
  - `http://uurouter.gdl.netease.com/uuplugin/openwrt-x86_64/v12.1.4/uu.tar.gz?...`

支持架构：
- `openwrt-{arm,aarch64,mipseb,mipsel,x86_64}`

---

## 6) uuplugin 静态分析（基于 strings）

### 6.1 网络基础
可见 TUN/TPROXY 与策略路由线索：
- `/dev/net/tun`, `modprobe tun`, `insmod tun`
- `TPROXY`, `tproxy_bridge`, `tproxy_config`, `tun2proxy`
- `iptables`, `xtables-nft-multi`, `iptables -t nat`, `-w`
- `UU_ROUTE_DEFAULT_TABLE`, `UU_ROUTE_FWMARK_TABLE`, `UU_DEVICE_FWMARK`

### 6.2 DNS/DHCP/MDNS 相关
- `dns_sniffer`, `resolve_dns`, `dns_ttl`
- `/tmp/var/lib/misc/dnsmasq.leases`
- `mdns_*`（设备服务发现）

### 6.3 传输加速
- UDP/TCP 双通道：
  - `udp_dual_channel`, `udp_over_tcp`, `auto_switch_to_tcp`
- MSS/MTU 调优：
  - `tun_mtu`, `tcp_sent_mss`, `tcp_syn_increase_mss`
- KCP 支持：
  - `ikcp_*`, `use_kcp_bridge`, `support_kcp`

### 6.4 代理/隧道栈
- `socks4`, `socks5`, `http_proxy`, `https_proxy`, `sniproxy`
- `buildin_http_server`（内置 HTTP 服务）

### 6.5 设备与环境变量
发现的环境变量：
- `UU_DEVICE_IP`, `UU_DEVICE_MAC`, `UU_DEVICE_TYPE`, `UU_DEVICE_LINK_TYPE`
- `UU_LAN_IP`, `UU_WAN_IP`, `UU_LAN_NAME`
- `UU_SN`, `UU_MODEL`, `UU_VENDOR`, `UU_FIRMWARE_VERSION`
- `UU_TUN_NAME`, `UU_TUN_IP`

### 6.6 观察到的域名（非完整）
- `log.uu.163.com`
- `rglg.uu.netease.com`
- `gw.router.uu.163.com`

---

## 7) 推测的加速机制（基于静态迹象）

该二进制可能实现多层加速管线：

1. **透明拦截**
   - 创建 TUN 接口并用 TPROXY/iptables/nft 导流。
   - 应用 fwmark + 策略路由表分流加速流量。

2. **流量分类**
   - DNS 嗅探与 MDNS/DHCP 设备识别。
   - 依据域名/IP/端口模式决定加速策略。

3. **传输优化**
   - UDP/TCP 双通道，自动回退（UDP over TCP）。
   - 可选 KCP 提升 UDP 可靠性。
   - MSS/MTU 调整与 TCP 栈优化。

4. **代理/隧道路径**
   - 本地代理栈（SOCKS/HTTP/SNI）用于特定流量。
   - 与加速端点的握手/认证流程。

**说明:** 上述为 strings 静态推断；完整行为需运行期跟踪验证。

---

## 8) 关键结论

- `install.sh` 与 `uuplugin_monitor.sh` 仅负责**部署与守护**。
- **实际加速完全在 `uuplugin` 内实现**。
- `uuplugin` 大量使用 **TUN/TPROXY + iptables/nft + 策略路由**。
- 具备 **DNS/MDNS/DHCP 识别** 与 **UDP/TCP 传输优化**，并可选 **KCP**。

---

## 9) 配置键完整列表（268 项）

从 `uuplugin_x86_64_config_keys.txt` 提取的运行时配置参数：

### 9.1 TPROXY/透明代理
```
allow_tun_tproxy          bind_tproxy               tproxy_config
tproxy_server             tproxy_reconnect          tproxy_rtt
find_best_tproxy          get_best_tproxy_addr      set_broadcast_tproxy_best_path
match_tproxy_region_block add_to_tproxy_whitelist   load_tproxy_whitelist_domain
debug_tproxy_config       urn_tproxy_limit          detect_main_flow_rtt_by_tproxy
```

### 9.2 代理协议栈
```
http_proxy                https_proxy_run           socks4
socks4a                   socks5                    socks5h
sniproxy_head_encrypt_port                          sniproxy_head_no_encrypt_port
switch_hybrid_proxy       handle_dst_sniproxy       update_sniproxy
all_proxy                 no_proxy                  proxy_hosts
```

### 9.3 TUN/tun2proxy
```
config_tun                init_tun                  tun_mtu
tun_setup                 tun_read                  tun_write
tun_add_route             tun_clear_route           tun0
tun2proxy_run             tun2proxy_enable_dual_stack
tun2proxy_use_kcp_bridge  tun2proxy_use_pure_grp    tun2proxy_filter_rule
use_tun2sysock            use_tun2sysock_v2         tun2sysock_*
```

### 9.4 设备检测
```
dhcp_hostname             dhcp_hostname_filter      dhcp_have_hostname
dhcp_vendor_id            dhcp_vendor_filter        dhcp_ttl
dhcp_received             dhcp_have_vender_id
mdns_device_service       mdns_model                mdns_query_names
mdns_ps_hostname_prefix   mdns_ps_service_chk       mdns_txt_model_prefix
mdns_service_contain      device_on_connect_dns_rule
device_require_chk_nat    device2router
```

### 9.5 TCP 优化
```
tcp_sent_mss              tcp_sent_mss_v2           tcp_syn_increase_mss
tcp_syn_decrease_mss      tcp_syn_mod               tcp_sack
tcp_allow_fragment        tcp_encrypt               tcp_ttl
tcp_blackhole_port        tcp_whitelist             tcp_whitelists
tcp_channel               tcp_channel_timeout       tcp_link_advanced
tcp_exclude_dev           tcp_exclude_model         tcp_socket_close_reset
delay_tcp                 ban_private_tcp           clean_tcp_channel
auto_switch_to_tcp        auto_switch_to_tcp_ratio  switch_to_tcp
```

### 9.6 UDP 优化
```
udp_over_tcp              udp_dual_channel          udp_header_extend_size
udp_whitelist             udp_whitelists            udp_src_port_ranges
udp_dst_port_ranges       udp_broadcast_whitelist   udp_broadcast_unbound_drop
udp_p2p_rule_create       udp_p2p_rule_clean        udp_derangement_monitor
delay_udp                 clean_up_delayed_udp      use_udp
acc_all_udp               non_console_p2p_acc_all_udp
```

### 9.7 DNAT/路由
```
dnat_mode_init            dnat_tcp_readable         dnat_tcp_server_start
create_dnat_tcp_server    edge_update_dnat          non_uubox_dnat_mode
config_dnat_mode_without_ipset                      config_mark_route_table
init_route_policy         iptables_dnat_return      iptables_nat_chk
```

---

## 10) iptables 命令模板

从二进制提取的 iptables 命令格式，用于设备加速：

### 10.1 NAT PREROUTING（流量重定向）
```bash
# 设备流量 DNAT 到本地代理
-t nat -I PREROUTING -i %s -s %s -d %s -p tcp -j DNAT --to-destination %s:%d

# DNS 重定向
-t nat -I PREROUTING -i %s -s %s -p udp --dport 53 -j DNAT --to-destination %s

# 按目标 IP 重定向
-t nat -I PREROUTING -i %s -p tcp -d %s --dport %d -j DNAT --to-destination %s:%d
```

### 10.2 MANGLE（标记流量）
```bash
# TCP 端口范围标记
-t mangle -I PREROUTING -i %s -s %s -p tcp --dport %d:%d -j MARK --set-mark %s

# UDP 端口范围标记
-t mangle -I PREROUTING -i %s -s %s -p udp --dport %d:%d -j MARK --set-mark %s
-t mangle -I PREROUTING -i %s -s %s -p udp --sport %d:%d -j MARK --set-mark %s
```

### 10.3 FILTER（访问控制）
```bash
# 阻止设备 DNS 查询（强制使用 UU DNS）
-t filter -I %s -i %s -m mac --mac-source %s -p udp -m udp --dport 53 -j DROP
-t filter -I %s -i %s -s %s -p udp -m udp --dport 53 -j DROP

# 阻止 SSDP（防止发现）
-t filter -I INPUT -i %s -p udp -s %s --dport 1900 -j DROP
```

---

## 11) 设备检测机制详解

### 11.1 检测方法优先级
```
1. DHCP hostname 匹配
2. DHCP vendor ID 匹配
3. MDNS 服务类型匹配
4. DNS TTL 分析
5. TCP TTL 分析（不同 OS 有不同默认值）
```

### 11.2 设备类型标记
```c
may_be_switch     // Nintendo Switch
may_be_ps4        // PlayStation 4/5
may_be_xboxone    // Xbox One/Series
may_be_android    // Android 设备
may_be_apple      // Apple 设备
may_be_windows    // Windows PC
```

### 11.3 Switch 特有配置
```
switch_cn                        // 国服
switch_cn_addition_servers       // 国服附加服务器
switch_addition_servers          // 海外服务器
switch_federation_detect         // 联机检测
switch_federation_detect_timeout // 检测超时
switch_hostname_blacklist        // 主机名黑名单
switch_hybrid_proxy              // 混合代理模式
switch_probe.cpp                 // 探测代码
```

### 11.4 MDNS 查询的服务类型
UU 主动查询这些服务来发现游戏设备：
```
_xboxda._tcp.local          // Xbox
_googlecast._tcp.local      // Chromecast/Shield
_airplay._tcp.local         // Apple TV
_spotify-connect._tcp.local // Spotify
_services._dns-sd._udp      // 服务枚举
```

---

## 12) APP 通信协议

### 12.1 端口分配
| 端口 | 协议 | 用途 |
|------|------|------|
| 16363/TCP | protobuf | 管理/状态 |
| 14554/TCP | protobuf | APP 主通信 |
| 60000/TCP | 隧道 | 加速流量 |
| 39292/UDP | MDNS | 设备发现 |

### 12.2 Protobuf 消息类型
```protobuf
// 连接
message ConnectRequest { }
message ConnectReply { }
message DisconnectReply { }

// 设备
message Device { LinkType link_type; }
message MacList { Mac mac; Precision precision; }

// 加速
message Acc { Route route; Server server; ServerType type; }
message AccReply { Status status; }
message StopAccReply { Status status; }

// 用户
message BoundUser { DeviceRecord device; }
message CheckBound { DomainIP domain_ip; }

// 系统
message Online { Server server; }
message OnlineReply { Server server; Status status; }
message ServerPing { Server server; }
message Upgrade { CMD cmd; }
message Uninstall { CMD cmd; }
```

---

## 13) 后续分析方向

### 已完成
- [x] monitor.sh 逻辑分析
- [x] 配置键提取（268 项）
- [x] iptables 命令模板提取
- [x] protobuf 消息类型识别
- [x] 设备检测机制分析

### 待完成
- [ ] 抓取 APP ↔ 路由器 protobuf 通信
- [ ] 重建完整 .proto 文件
- [ ] 运行时规则跟踪（需真实 Switch）
- [ ] 加速服务器协议分析

---

## 14) 核心日志分析（运行时行为）

从 `uuplugin_x86_64_strings_keywords.txt` 提取的关键日志格式：

### 14.1 设备流量处理
```
[%s:%d] [%s] device history domain %s match list %d, add %d ip dnat to %s:%d
[%s:%d] [%s] device history domain %s match list %d, add %d ip to route
[%s:%d] [%s] add route rule device:%s net:%s/%d
```

### 14.2 TCP 通道
```
[%s:%d] [%s] new tcp channel (via %s): cid %d, peer = %s:%u, is_http = %s
[%s:%d] [%s] tcp channel %d handshake success, peer = %s:%d
[%s:%d] [%s] tcp channel %d match whitelist, http(s) request via proxy to %s
[%s:%d] [%s] tcp channel %d match blacklist, http(s) request via direct to %s
```

### 14.3 TPROXY 桥接
```
[%s:%d] [%s] new tproxy bridge %u, tproxy(%s) %s-%s:%d, local port %d, line %d
[%s:%d] [%s] tproxy bridge %u connected
[%s:%d] [%s] tproxy bridge %u auth success
[%s:%d] [%s] tproxy auth: support_kcp: %d support_pure_grp %d
```

### 14.4 UDP 通道
```
[%s:%d] [%s] new udp channel v%d (via %s): cid = %d, addr = %s:%d
[%s:%d] [%s] game_server_allow_ping %d, udp packet to %s:%u is delayed
```

### 14.5 DNS 处理
```
[%s:%d] [%s] DNS answer %d qname %s qtype %d ttl %d ip %s hit route table
[%s:%d] [%s] DNS answer (name %s ip %s) match white domain
[%s:%d] [%s] DNS answer (name %s ip %s) match resolve domain
```

### 14.6 路由策略
```
[%s:%d] [%s] route_policy_%d ip:%s bound to tproxy bridge %u line:%d addr:%s:%u
[%s:%d] [%s] route_policy_%d proto:%s update_best_route: bound to tproxy bridge %u
```

### 14.7 TTL 检测
```
[%s:%d] [%s] detect dst:%s:%d ttl:%d
[%s:%d] [%s] device %s tcp ttl is %d, not a known initial ttl, this is a nat device
```

---

## 15) 关键发现总结

### 15.1 流量拦截机制
```
1. iptables DNAT 规则按设备 IP 重定向流量到本地端口
2. DNS 查询被拦截并分析，匹配的域名加入路由表
3. 使用 fwmark 标记流量，配合策略路由分流
```

### 15.2 加速路径选择
```
1. direct     - 直连（不加速）
2. proxy      - 通过代理服务器
3. tproxy     - 通过透明代理桥接（主要加速方式）
```

### 15.3 设备识别方法
```
1. DHCP hostname 匹配 "Nintendo Switch" 等
2. MDNS 服务发现 (_xboxda._tcp 等)
3. TCP/IP 包 TTL 分析（不同 OS 默认 TTL 不同）
   - Windows: 128
   - Linux/Android: 64
   - Switch: 待确认
4. DNS 查询域名模式匹配
```

### 15.4 Switch 特殊处理
```
switch_cn                  - 国服特殊处理
switch_federation_detect   - 联机检测
switch_hostname_blacklist  - 主机名黑名单
switch_hybrid_proxy        - 混合代理模式
```

---

## 16) UU 插件文件结构

```
# OpenWrt 上安装后的结构
/usr/sbin/uu/
├── uuplugin                           # 主二进制
├── uu.conf                            # 基础配置
└── xtables-nft-multi                  # nftables 兼容层

/tmp/uu/
├── activate_status                    # 激活状态
├── uu.pid                             # 进程 PID
└── ...

# 分析用文件结构 (本地)
uu_artifacts/  # (已加入 .gitignore)
├── uuplugin_monitor.sh                # 守护脚本
├── uuplugin_openwrt-<arch>/           # 各架构版本
│   ├── uuplugin                       # 主二进制 (~5MB)
│   └── uu.conf                        # 基础配置
    └── xtables-nft-multi                  # iptables/nft 工具
```

---

## 17) 运行时验证结果 (2026-02-01)

### 17.1 TUN 隧道机制

通过实际运行验证，UU 使用 **TUN 隧道** 而非 port 60000 进行加速：

```bash
# 每个加速设备创建专用 TUN
tun163 - Switch (192.168.1.100)
tun164 - lanproxy (192.168.1.252)

# 策略路由
ip rule add from 192.168.1.100 fwmark 0x163 lookup 163
ip route show table 163
# default via 172.19.163.1 dev tun163
```

### 17.2 服务端白名单机制

**关键发现**: UU 服务端有 IP 白名单，只处理已注册设备的流量。

证据 (conntrack 对比):
```
# Switch: 目标被 DNAT 到 UU 服务器
src=192.168.1.100 dst=163.163.0.3 → ESTABLISHED ✅

# 未注册设备: 直接透传到真实目标
src=192.168.1.252 dst=104.18.26.120 → SYN_SENT [UNREPLIED] ❌
```

### 17.3 Nintendo OUI 识别

使用 Nintendo OUI 可以帮助 uuplugin 识别设备：

| OUI | 厂商 |
|-----|------|
| 98:41:5C | Nintendo Co.,Ltd |
| 7C:BB:8A | Nintendo Co.,Ltd |
| E8:4E:CE | Nintendo Co.,Ltd |

配置示例:
```bash
UU_LEASE_MAC="98:41:5C:AA:BB:CC"
DHCP_HOSTNAME="NintendoSwitch"
```

### 17.4 设备规则创建验证

当 UU APP 为设备开启加速后，uuplugin 创建：

```bash
# nftables 表
nft list tables | grep XU_ACC_DEVICE
# table ip XU_ACC_DEVICE_192.168.1.252_filter
# table ip XU_ACC_DEVICE_192.168.1.252_mangle
# table ip XU_ACC_DEVICE_192.168.1.252_nat

# 游戏服务器路由 (5236 条)
ip route show table 180 | wc -l
# 5236
```

---

## 18) 相关文档

| 文档 | 内容 |
|------|------|
| [uu_proxy_analysis.md](uu_proxy_analysis.md) | 代理流量失败根本原因 |
| [uu_device_identification.md](uu_device_identification.md) | 设备识别机制详解 |
| [uu_switch_detection_logic.md](uu_switch_detection_logic.md) | Switch 多层检测逻辑 |
| [lanproxy_netns/README.md](../lanproxy_netns/README.md) | HTTP 代理 + UU 加速方案 |
