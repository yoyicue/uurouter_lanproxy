# UU 代理流量失败原因深度分析

**日期**: 2026-02-01
**状态**: 根本原因已确认

---

## 1. 问题现象

lanproxy 代理架构正确，流量经过 PREROUTING 并被打上 fwmark，也成功进入了 tun163 隧道，但请求始终失败（SYN_SENT [UNREPLIED]）。

---

## 2. 根本原因

**UU 隧道有服务端白名单机制，只处理已注册设备的流量。**

### 2.1 证据对比

| 设备 | 源 IP | conntrack 目标 | 状态 |
|------|-------|----------------|------|
| Switch | 192.168.1.100 | 163.163.0.3 (UU 服务器) | ✅ ESTABLISHED |
| Proxy | 192.168.1.252 | 104.18.26.120 (真实目标) | ❌ SYN_SENT [UNREPLIED] |

### 2.2 关键发现

```
Switch connections:
src=192.168.1.100 dst=163.163.0.3 sport=50625 dport=443 [ASSURED] ESTABLISHED

Proxy connections:
src=192.168.1.252 dst=104.18.26.120 sport=36276 dport=443 [UNREPLIED] SYN_SENT
```

- **Switch 流量**：被 UU 隧道内部 DNAT 到 UU 代理服务器 (163.163.x.x)
- **Proxy 流量**：直接透传到真实目标，UU 未做任何处理

---

## 3. UU 完整加速机制

```
┌─────────────────────────────────────────────────────────────────┐
│                    UU 加速流量路径                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. APP 注册设备                                                │
│     • 用户在 UU APP 添加设备 (IP: 192.168.1.100)               │
│     • UU 服务端记录该设备 IP 到白名单                           │
│                                                                 │
│  2. 路由器端规则创建                                            │
│     • 创建设备专用 nftables 表:                                 │
│       XU_ACC_DEVICE_192.168.1.100_mangle                       │
│       XU_ACC_DEVICE_192.168.1.100_filter                       │
│     • 给设备流量打 fwmark (0x163)                               │
│     • 创建策略路由: fwmark 0x163 → lookup table 163            │
│     • 路由表 163: default via 172.19.163.1 dev tun163          │
│                                                                 │
│  3. 流量进入隧道                                                │
│     Switch (192.168.1.100) → fwmark → 策略路由 → tun163        │
│                                                                 │
│  4. 隧道内部处理 (关键!)                                        │
│     • UU 服务端检查源 IP 是否在白名单                           │
│     • ✅ 在白名单: DNAT 到 UU 代理服务器 (163.163.x.x)         │
│     • ❌ 不在白名单: 直接透传 (无法获得加速)                    │
│                                                                 │
│  5. UU 代理服务器转发                                           │
│     • 接收来自隧道的流量                                        │
│     • 转发到真实目标服务器                                      │
│     • 返回响应给客户端                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. 代理流量失败的原因

```
┌─────────────────────────────────────────────────────────────────┐
│                    代理流量路径 (失败)                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Switch → lanproxy:8888 → netns 发起连接                        │
│                ↓                                                │
│  流量进入 br-lan (源 IP: 192.168.1.252)                        │
│                ↓                                                │
│  PREROUTING: fwmark 设置 ✅ (packets 22, bytes 1914)           │
│                ↓                                                │
│  策略路由: lookup table 163 ✅                                  │
│                ↓                                                │
│  进入 tun163 ✅ (oifname tun163 packets 14)                    │
│                ↓                                                │
│  UU 隧道检查源 IP: 192.168.1.252                               │
│                ↓                                                │
│  ❌ 192.168.1.252 不在白名单!                                   │
│                ↓                                                │
│  流量直接透传到真实目标 (104.18.26.120)                         │
│  源 IP 是私有地址，响应无法路由回来                             │
│                ↓                                                │
│  连接超时 (SYN_SENT [UNREPLIED])                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 5. 技术细节

### 5.1 UU 创建的设备规则

```nft
# 为 Switch (192.168.1.100) 创建的规则
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

### 5.2 策略路由

```bash
# Switch 的策略路由
32761: from 192.168.1.100 lookup 179
32762: from 192.168.1.100 fwmark 0x163 lookup 163

# 我们为 Proxy 添加的策略路由 (无效)
32760: from 192.168.1.252 fwmark 0x163 lookup 163
```

### 5.3 路由表

```bash
# 路由表 163 - 默认走 tun163
default via 172.19.163.1 dev tun163

# 路由表 179 - 游戏服务器特定路由
1.178.1.0/24 via 172.19.163.1 dev tun163
1.178.4.0/24 via 172.19.163.1 dev tun163
...
```

---

## 6. 为什么我们的方案不能工作

| 尝试的方案 | 结果 | 原因 |
|------------|------|------|
| DNAT 到 60000 端口 | ❌ | 60000 不是数据转发端口，UU 用 TUN 隧道 |
| 打 fwmark + 策略路由 | ❌ | 流量进入隧道，但被 UU 服务端丢弃 |
| 添加 filter 规则 | ❌ | 只解决本地转发，不解决隧道白名单 |

**核心限制**: UU 服务端只处理已注册设备 IP 的流量，无法通过本地配置绕过。

---

## 7. 可能的解决方案

### 方案 A: 让 UU APP 添加代理 IP (需要 UU 支持)

- 在 UU APP 中添加 192.168.1.252 作为设备
- UU 服务端会将该 IP 加入白名单
- **问题**: APP 可能只识别游戏主机，不支持手动添加任意 IP

### 方案 B: SNAT 伪装成 Switch IP

```nft
# 在流量进入 tun163 前，把源 IP 改成 Switch IP
nft add rule ip nat POSTROUTING oifname tun163 ip saddr 192.168.1.252 \
    snat to 192.168.1.100
```

- **优点**: 不需要 UU 服务端支持
- **问题**: 可能与 Switch 真实流量冲突

### 方案 C: 使用网关模式 (推荐)

- Switch 直接将网关设置为 OpenWrt (192.168.1.250)
- 不使用代理，流量直接走 UU 加速
- **优点**: 简单可靠，UU 原生支持
- **缺点**: Switch 需要手动配置网关

### 方案 D: 逆向 UU 协议 (复杂)

- 分析 UU APP 与服务端的通信协议
- 模拟 APP 请求，将代理 IP 注册到 UU 服务端
- **复杂度**: 非常高，需要破解加密协议

---

## 8. 结论

**代理模式不可行的根本原因是 UU 服务端的白名单机制。**

流量在本地正确配置后能够进入 tun163 隧道，但 UU 服务端只会处理已通过 APP 注册的设备 IP 的流量。未注册的 IP (如 192.168.1.252) 会被直接透传，无法获得加速。

**推荐方案**: 使用网关模式 (方案 C)，让 Switch 直接将网关设置为 OpenWrt，这是 UU 原生支持的方式。

---

## 附录: 验证命令

```bash
# 检查设备注册
nft list tables | grep XU_ACC_DEVICE

# 检查 fwmark 计数
nft list table ip XU_ACC_PROXY_mangle

# 检查 tun163 流量
nft list table ip XU_ACC_PROXY_filter | grep tun163

# 检查 conntrack
cat /proc/net/nf_conntrack | grep -E '192.168.1.252|192.168.1.100' | grep -v udp

# 对比目标地址
# Switch: dst=163.163.x.x (UU 服务器) = 加速生效
# Proxy:  dst=104.18.x.x (真实目标) = 加速未生效
```
