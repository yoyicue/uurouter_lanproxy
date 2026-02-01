# UU Switch 设备识别逻辑详解

**日期**: 2026-02-01
**来源**: uuplugin 二进制逆向分析

---

## 1. 识别流程概览

```
┌─────────────────────────────────────────────────────────────────┐
│                Switch 识别多层检测流程                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Layer 1: DHCP 指纹识别 (dhcp_record.cpp)                       │
│     ├─ Option 12: hostname = "NintendoSwitch"                  │
│     ├─ Option 60: vendor_id 检测                                │
│     └─ 结果 → dhcp_hostname_filter 匹配                         │
│                         ↓                                       │
│  Layer 2: MAC OUI 识别 (arp.cpp, arp_task.cpp)                  │
│     ├─ 读取 /proc/net/arp                                       │
│     ├─ 匹配 /jffs/oui_sample.txt 数据库                         │
│     └─ Nintendo OUI: 98:41:5C, 7C:BB:8A, 00:1F:32, E8:4E:CE    │
│                         ↓                                       │
│  Layer 3: mDNS 服务发现 (mdns_task.cpp)                         │
│     ├─ 监听 5353 端口                                           │
│     ├─ mdns_device_service 服务发现                             │
│     └─ mdns_model 型号匹配                                      │
│                         ↓                                       │
│  Layer 4: DNS 行为检测                                          │
│     ├─ first_dns 首个 DNS 查询分析                              │
│     ├─ detect_domains 检测域名列表                              │
│     ├─ danger_domains 危险域名检测                              │
│     └─ 匹配 Nintendo 服务器域名模式                             │
│                         ↓                                       │
│  Layer 5: P2P/联邦检测 (switch_probe.cpp)                       │
│     ├─ switch_federation_detect 联邦模式检测                    │
│     ├─ switch_federation_detect_timeout 超时判断                │
│     └─ P2P 端口模式: non_console_p2p_src/dst_port              │
│                         ↓                                       │
│  Layer 6: 综合判断                                              │
│     ├─ may_be_switch = true                                    │
│     ├─ 排除 switch_hostname_blacklist 误判                      │
│     └─ 设置 last_console_type = "switch"                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Layer 1: DHCP 指纹识别

### 2.1 数据来源

```cpp
// dhcp_record.cpp - DHCP 记录处理

// 读取租约文件
/etc/config/dhcpd.leases
/tmp/dhcp.leases
/tmp/var/lib/misc/dnsmasq.leases

// 或者直接抓包 (use_libpcap)
libpcap -> br-lan -> DHCP packets
```

### 2.2 关键字段

| 配置键 | DHCP Option | Switch 典型值 |
|--------|-------------|---------------|
| `dhcp_hostname` | Option 12 | "NintendoSwitch" |
| `dhcp_vendor_id` | Option 60 | (可能为空或特定值) |
| `dhcp_have_hostname` | - | true |
| `dhcp_have_vender_id` | - | 取决于 Switch 版本 |

### 2.3 过滤规则

```
dhcp_hostname_filter  <- 匹配 "Nintendo" 关键词
dhcp_vendor_filter    <- 厂商类过滤
```

---

## 3. Layer 2: MAC OUI 识别

### 3.1 数据来源

```cpp
// arp.cpp, arp_task.cpp - ARP 表监控

// 读取 ARP 表
/proc/net/arp
/proc/rtl865x/arp  (部分路由器)

// OUI 数据库
/jffs/oui_sample.txt
```

### 3.2 Nintendo 已知 OUI

| OUI 前缀 | 厂商 |
|----------|------|
| `98:41:5C` | Nintendo Co.,Ltd |
| `7C:BB:8A` | Nintendo Co.,Ltd |
| `00:1F:32` | Nintendo Co.,Ltd |
| `E8:4E:CE` | Nintendo Co.,Ltd |
| `DC:68:EB` | Nintendo Co.,Ltd |
| `40:F4:07` | Nintendo Co.,Ltd |
| `A4:C0:E1` | Nintendo Co.,Ltd |

### 3.3 识别逻辑

```
1. 从 ARP 表获取设备 MAC
2. 提取前 3 字节 (OUI)
3. 匹配 oui_sample.txt 中的 Nintendo 条目
4. 设置 console_stage_vendor = "Nintendo"
```

---

## 4. Layer 3: mDNS 服务发现

### 4.1 配置键

| 配置键 | 说明 |
|--------|------|
| `mdns_device_service` | 设备服务名称 |
| `mdns_model` | 设备型号 |
| `mdns_query_names` | mDNS 查询名称列表 |
| `mdns_service_contain` | 服务名包含检测 |
| `mdns_txt_model_prefix` | TXT 记录型号前缀 |

### 4.2 PlayStation 特定 (对比参考)

```
mdns_ps_hostname_prefix  <- PlayStation 主机名前缀
mdns_ps_service_chk      <- PlayStation 服务检测
```

### 4.3 检测方式

```
1. 监听 UDP 5353 端口 (mDNS multicast)
2. 解析 mDNS 响应中的服务类型
3. 检查 TXT 记录中的型号信息
4. Switch 可能广播特定服务 (待抓包确认)
```

---

## 5. Layer 4: DNS 行为检测

### 5.1 配置键

| 配置键 | 说明 |
|--------|------|
| `first_dns` | 首个 DNS 查询 |
| `first_several_dns_contain` | 前几个 DNS 包含检测 |
| `detect_domains` | 检测域名列表 |
| `danger_domains` | 危险域名列表 |
| `detect_timeout` | 检测超时 |

### 5.2 Nintendo 典型域名

```
*.nintendo.net
*.nintendo.com
*.nintendowifi.net
conntest.nintendowifi.net     <- 连接测试
ctest.cdn.nintendo.net        <- CDN 测试
*.eshop.nintendo.net          <- eShop
*.npns.srv.nintendo.net       <- 推送服务
```

### 5.3 检测逻辑

```
1. 拦截设备 DNS 查询
2. 匹配 detect_domains 列表
3. 如果命中 Nintendo 域名 -> 标记 may_be_switch
```

### 5.4 相关日志

```
[switch danger domain detect timeout, reset state]
[danger domain %s match detect %d/%d]
[enable danger domain]
[extend danger domain effective time]
```

---

## 6. Layer 5: P2P/联邦检测

### 6.1 Switch 在线特征

Nintendo Switch Online (NSO) 使用 P2P 技术进行多人游戏。

### 6.2 配置键

| 配置键 | 说明 |
|--------|------|
| `switch_federation_detect` | 联邦模式检测开关 |
| `switch_federation_detect_timeout` | 检测超时时间 |
| `switch_federation_effective_timeout` | 生效超时时间 |
| `non_console_p2p_detect` | 非主机 P2P 检测 |
| `non_console_p2p_src_port` | P2P 源端口范围 |
| `non_console_p2p_dst_port` | P2P 目标端口范围 |

### 6.3 检测逻辑

```
1. 监控 UDP 流量模式
2. 检测 P2P 特征端口 (Switch 典型使用 UDP 高端口)
3. 识别联邦模式握手
4. 设置 is_p2p = true
```

---

## 7. Layer 6: 综合判断

### 7.1 判断变量

| 变量 | 说明 |
|------|------|
| `may_be_switch` | Switch 可能性标记 |
| `may_be_ps4` | PS4 可能性标记 |
| `may_be_xboxone` | Xbox One 可能性标记 |
| `last_console_type` | 最终确定的主机类型 |
| `console_stage_vendor` | 主机厂商阶段 |

### 7.2 黑名单过滤

```
switch_hostname_blacklist  <- 过滤误判的主机名
```

某些设备可能误报为 Switch (如某些安卓设备用 "Switch" 作为 hostname)，通过黑名单排除。

### 7.3 最终判断流程

```cpp
// switch_probe.cpp 伪代码

bool is_switch(Device& dev) {
    // 1. DHCP hostname 检测
    if (dev.dhcp_hostname.contains("Nintendo")) {
        dev.may_be_switch = true;
    }

    // 2. MAC OUI 检测
    if (is_nintendo_oui(dev.mac)) {
        dev.console_stage_vendor = "Nintendo";
        dev.may_be_switch = true;
    }

    // 3. DNS 行为检测
    if (dev.dns_queries.match(nintendo_domains)) {
        dev.may_be_switch = true;
    }

    // 4. P2P 模式检测
    if (dev.has_switch_federation_traffic) {
        dev.may_be_switch = true;
    }

    // 5. 黑名单过滤
    if (switch_hostname_blacklist.contains(dev.hostname)) {
        dev.may_be_switch = false;
    }

    // 6. 最终判断
    if (dev.may_be_switch) {
        dev.last_console_type = "switch";
        return true;
    }

    return false;
}
```

---

## 8. Switch 专用配置

识别为 Switch 后，uuplugin 会加载 Switch 专用配置：

| 配置键 | 说明 |
|--------|------|
| `switch_addition_servers` | Switch 额外服务器列表 |
| `switch_cn_addition_servers` | Switch 国服额外服务器 |
| `switch_hybrid_proxy` | Switch 混合代理模式 |
| `switch_cn` | Switch 国服标记 |
| `stable_switch_cn_type` | 稳定国服类型 |
| `feature_switch` | Switch 功能开关 |

---

## 9. 为什么 lanproxy 难以被识别为 Switch

| 检测层 | Switch 真机 | lanproxy 模拟 | 差距 |
|--------|-------------|---------------|------|
| DHCP hostname | "NintendoSwitch" | "NintendoSwitch" ✓ | 可以模拟 |
| DHCP vendor | 原生值 | 可能不完整 | 需抓包确认 |
| MAC OUI | Nintendo OUI | 自定义 MAC | ❌ 无法完美模拟 |
| mDNS 服务 | Switch 原生服务 | 无 | ❌ 需要额外实现 |
| DNS 行为 | Nintendo 域名查询 | 代理转发的各种域名 | ❌ 行为不一致 |
| P2P 模式 | Switch 联邦流量 | HTTP 代理流量 | ❌ 完全不同 |

### 关键差距

1. **MAC OUI**: 即使改了 MAC，OUI 数据库可能不匹配
2. **mDNS 服务**: Switch 会广播特定服务，lanproxy 不会
3. **DNS 行为**: 代理流量的 DNS 查询模式与 Switch 不同
4. **P2P 流量**: Switch 游戏使用 P2P，代理使用 HTTP CONNECT

---

## 10. 验证命令

```bash
# 在 OpenWrt 上抓 Switch DHCP 指纹
tcpdump -i br-lan -n -vvv 'port 67 or port 68' -w /tmp/switch_dhcp.pcap

# 查看 ARP 表
cat /proc/net/arp

# 抓 mDNS 流量
tcpdump -i br-lan -n 'port 5353' -w /tmp/switch_mdns.pcap

# 抓 Switch DNS 查询
tcpdump -i br-lan -n 'port 53 and host 192.168.1.100' -w /tmp/switch_dns.pcap

# 查看 uuplugin 识别结果
nft list tables | grep XU_ACC_DEVICE
```

---

## 11. 结论

Switch 识别是一个**多层综合判断**过程：

1. **入门级**: DHCP hostname 包含 "Nintendo"
2. **加强级**: MAC OUI 匹配 Nintendo
3. **确认级**: DNS 查询 Nintendo 域名
4. **最终级**: 检测到 Switch 联邦/P2P 流量模式

lanproxy 即使模拟了 DHCP 指纹，也很难通过后续的 MAC OUI、mDNS、DNS 行为、P2P 模式检测。

**最佳方案**: 使用网关模式，让真实 Switch 流量直接走 UU 加速。
