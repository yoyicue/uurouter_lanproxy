# UU 设备识别机制分析

**日期**: 2026-02-01
**来源**: uuplugin 二进制逆向分析 (strings + 关键词提取)

---

## 1. 核心结论

**Switch (192.168.1.100) 是由 OpenWrt 上的 uuplugin 本地识别的，然后上报到 UU 云端。**

识别流程：
1. **uuplugin 本地探测**：通过专用探测模块，结合 DHCP、mDNS、MAC OUI 等多种信号
2. **上报云端**：通过 protobuf 消息告诉 UU 服务器
3. **APP 展示**：UU APP 从云端拉取设备列表
4. **用户操作**：点击"加速"后，云端同时下发本地规则和更新服务端白名单

---

## 2. 源码模块

从二进制中提取的关键源文件：

| 模块 | 功能 |
|------|------|
| `device_discover.cpp` | 设备发现主模块 |
| `device_discover_common.cpp` | 通用发现逻辑 |
| `device_discover_env.cpp` | 环境检测 |
| `switch_probe.cpp` | **Switch 专用探测** |
| `ps4_probe.cpp` | **PS4 专用探测** |
| `xbox_probe.cpp` | **Xbox 专用探测** |
| `dhcp_record.cpp` | DHCP 记录处理 |
| `mdns_task.cpp` | mDNS 服务发现 |

---

## 3. DHCP 识别 (Option 12/60)

### 3.1 租约文件读取

uuplugin 会读取以下租约文件来发现设备：

```
/etc/config/dhcpd.leases
/tmp/dhcp.leases
/tmp/var/lib/misc/dnsmasq.leases
```

### 3.2 DHCP 包捕获

| 配置键 | 说明 | 示例值 |
|--------|------|--------|
| `dhcp_hostname` | Option 12 主机名 | "NintendoSwitch" |
| `dhcp_vendor_id` | Option 60 厂商类 | "MSFT 5.0", "android-dhcp-..." |
| `dhcp_have_hostname` | 是否有主机名 | - |
| `dhcp_have_vender_id` | 是否有厂商类 | - |
| `dhcp_ttl` | DHCP 记录 TTL | - |
| `dhcp_received` | DHCP 接收标记 | - |

### 3.3 过滤器

| 配置键 | 说明 |
|--------|------|
| `dhcp_hostname_filter` | 主机名过滤规则 |
| `dhcp_vendor_filter` | 厂商类过滤规则 |
| `android_dhcp_vendorid_kw` | Android 厂商类关键词 |

---

## 4. mDNS 识别 (Bonjour/Zeroconf)

uuplugin 通过 mDNS 发现局域网设备服务：

| 配置键 | 说明 |
|--------|------|
| `mdns_ps_hostname_prefix` | PlayStation 主机名前缀 |
| `mdns_ps_service_chk` | PlayStation 服务检测 |
| `mdns_device_service` | 设备服务发现 |
| `mdns_query_names` | mDNS 查询名称列表 |
| `mdns_model` | 设备型号 |
| `mdns_txt_model_prefix` | TXT 记录型号前缀 |
| `mdns_service_contain` | 服务名包含检测 |

---

## 5. MAC OUI 识别

| 配置/文件 | 说明 |
|-----------|------|
| `/jffs/oui_sample.txt` | OUI 数据库文件 |
| `UU_DEVICE_MAC` | 设备 MAC 地址 |
| `console_stage_vendor` | 厂商阶段判断 |
| `sn_no_mac_prefix` | 序列号不含 MAC 前缀标记 |

### Nintendo Switch 已知 OUI

```
98:41:5C - Nintendo Co.,Ltd
7C:BB:8A - Nintendo Co.,Ltd
00:1F:32 - Nintendo Co.,Ltd
E8:4E:CE - Nintendo Co.,Ltd
```

---

## 6. 设备类型判断

### 6.1 类型探测变量

| 变量 | 说明 |
|------|------|
| `may_be_switch` | Switch 可能性判断 |
| `may_be_ps4` | PS4 可能性判断 |
| `may_be_xboxone` | Xbox One 可能性判断 |
| `last_console_type` | 上次识别的主机类型 |
| `console_device_block_reason` | 主机设备阻止原因 |

### 6.2 Switch 专用配置

| 配置键 | 说明 |
|--------|------|
| `switch_hostname_blacklist` | Switch 误判过滤黑名单 |
| `switch_federation_detect` | Switch 联邦检测 |
| `switch_federation_detect_timeout` | 联邦检测超时 |
| `switch_addition_servers` | Switch 额外服务器 |
| `switch_cn_addition_servers` | Switch 国服额外服务器 |
| `switch_hybrid_proxy` | Switch 混合代理 |
| `switch_cn` | Switch 国服标记 |
| `stable_switch_cn_type` | 稳定国服类型 |

### 6.3 其他主机配置

| 配置键 | 说明 |
|--------|------|
| `non_console_p2p_acc_all_udp` | 非主机 P2P 全 UDP 加速 |
| `non_console_p2p_detect` | 非主机 P2P 检测 |
| `non_console_p2p_src_port` | 非主机 P2P 源端口 |
| `non_console_p2p_dst_port` | 非主机 P2P 目标端口 |

---

## 7. 云端通信

### 7.1 Protobuf 消息

```protobuf
// 设备相关消息
uu_router_messages.Device
uu_router_messages.Device.LinkType
uu_router_messages.DeviceList
uu_router_messages.BoundUser.DeviceRecord
uu_router_messages.BoundUser.AutoDeviceRecord
uu_router_messages.BoundUser.MeshDeviceRecord
```

### 7.2 环境变量

| 变量 | 说明 |
|------|------|
| `UU_DEVICE_IP` | 设备 IP 地址 |
| `UU_DEVICE_MAC` | 设备 MAC 地址 |
| `UU_DEVICE_TYPE` | 设备类型 |
| `UU_DEVICE_LINK_TYPE` | 设备链接类型 |
| `UU_DEVICE_FWMARK` | 设备 fwmark 标记 |

### 7.3 服务器地址

```
gw.router.uu.163.com        # 网关服务器
router.uu.163.com/api/plugin # 插件下载
```

---

## 8. 本地规则创建

当用户在 APP 点击"加速"后：

### 8.1 nftables 表

```nft
# 为每个加速设备创建专用表
table ip XU_ACC_DEVICE_192.168.1.100_mangle {
    chain PREROUTING {
        iifname "br-lan" ip saddr 192.168.1.100 udp dport 1025-65535
            meta mark set 0x00000163
        iifname "br-lan" ip saddr 192.168.1.100 udp dport 53
            meta mark set 0x00000163
    }
}

table ip XU_ACC_DEVICE_192.168.1.100_filter {
    chain FORWARD {
        oifname "tun163" accept
        iifname "tun163" accept
    }
}
```

### 8.2 策略路由

```bash
# fwmark 路由规则
ip rule add from 192.168.1.100 fwmark 0x163 lookup 163

# 路由表 163
default via 172.19.163.1 dev tun163
```

---

## 9. 为什么 lanproxy 不被识别为 Switch

lanproxy (192.168.1.252) 虽然模拟了 DHCP 指纹，但可能缺少以下信号：

1. **真实 mDNS 服务**：Switch 会广播特定的 mDNS 服务
2. **流量模式**：Switch 的网络行为特征（DNS 查询模式、连接目标等）
3. **MAC OUI**：MAC 地址前缀不是 Nintendo 的 OUI
4. **持续性**：DHCP 指纹只在请求时发送，uuplugin 可能需要持续观察

即使本地识别成功，服务端白名单也需要同步更新才能真正加速。

---

## 10. 完整识别流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                    UU 设备识别完整流程                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐                                                │
│  │ 新设备上线   │                                                │
│  └──────┬──────┘                                                │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────┐            │
│  │ uuplugin 本地探测                                │            │
│  │  • DHCP: hostname + vendor_id                   │            │
│  │  • mDNS: 服务发现                                │            │
│  │  • MAC OUI: 厂商识别                             │            │
│  │  • 流量特征: 行为分析                            │            │
│  └──────────────────────┬──────────────────────────┘            │
│                         ▼                                       │
│  ┌─────────────────────────────────────────────────┐            │
│  │ 设备类型判断                                     │            │
│  │  switch_probe.cpp → may_be_switch               │            │
│  │  ps4_probe.cpp    → may_be_ps4                  │            │
│  │  xbox_probe.cpp   → may_be_xboxone              │            │
│  └──────────────────────┬──────────────────────────┘            │
│                         ▼                                       │
│  ┌─────────────────────────────────────────────────┐            │
│  │ Protobuf 上报云端                                │            │
│  │  → gw.router.uu.163.com                         │            │
│  │  → uu_router_messages.Device                    │            │
│  └──────────────────────┬──────────────────────────┘            │
│                         ▼                                       │
│  ┌─────────────────────────────────────────────────┐            │
│  │ UU APP 展示设备列表                              │            │
│  │  用户选择设备 → 点击"加速"                       │            │
│  └──────────────────────┬──────────────────────────┘            │
│                         ▼                                       │
│  ┌─────────────────────────────────────────────────┐            │
│  │ 双向规则下发                                     │            │
│  │  • 云端 → uuplugin: 创建 nftables 规则          │            │
│  │    (XU_ACC_DEVICE_<IP>_mangle/filter)           │            │
│  │  • 云端 → 隧道服务器: IP 加入白名单              │            │
│  └──────────────────────┬──────────────────────────┘            │
│                         ▼                                       │
│  ┌─────────────────────────────────────────────────┐            │
│  │ 加速生效                                         │            │
│  │  流量: 设备 → fwmark → tun163 → UU 服务器       │            │
│  └─────────────────────────────────────────────────┘            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 附录: 验证命令

```bash
# 查看 uuplugin 读取的 DHCP 租约
cat /tmp/dhcp.leases
cat /tmp/var/lib/misc/dnsmasq.leases

# 查看已识别设备的 nftables 表
nft list tables | grep XU_ACC_DEVICE

# 查看设备专用规则
nft list table ip XU_ACC_DEVICE_192.168.1.100_mangle

# 监控 DHCP 请求
tcpdump -i br-lan -n -vvv 'port 67 or port 68'

# 监控 mDNS
tcpdump -i br-lan -n 'port 5353'

# 查看 uuplugin 日志
logread | grep -i uuplugin
```
