# 代理 + UU 加速方案分析

日期: 2026-02-01
状态: **已更新** - 发现根本原因

---

## 1. 最终结论

**HTTP 代理流量无法直接使用 UU 加速**，原因是 UU 服务端有 IP 白名单机制。

详细分析见: [uu_proxy_analysis.md](uu_proxy_analysis.md)

---

## 2. UU 加速机制 (修正)

### 2.1 实际机制 (TUN 隧道)

```
设备流量 → fwmark 0x163 → 策略路由 → tun163 → UU 服务器
                                         ↓
                              服务端检查源 IP 是否在白名单
                                         ↓
                              ✅ 在白名单: DNAT 到代理服务器
                              ❌ 不在白名单: 直接透传 (无加速)
```

**注意**: 早期分析中的 "port 60000" 并非数据转发端口，而是控制/管理端口。

### 2.2 nftables 规则结构

```nft
# 为每个加速设备创建专用表
table ip XU_ACC_DEVICE_<IP>_mangle {
    chain PREROUTING {
        iifname "br-lan" ip saddr <IP> udp dport 1025-65535 meta mark set 0x163
    }
}

# 策略路由
ip rule add from <IP> fwmark 0x163 lookup 163

# 路由表 163
default via 172.19.163.1 dev tun163
```

---

## 3. 代理方案尝试记录

| 方案 | 结果 | 原因 |
|------|------|------|
| DNAT 到 60000 | ❌ | 60000 不是数据转发端口 |
| fwmark + 策略路由 | ❌ | 服务端白名单拒绝未注册 IP |
| lanproxy-netns | ✅ **成功** | 使用 Nintendo OUI，UU 创建专用隧道 tun164 |

---

## 4. lanproxy-netns 方案

**状态**: ✅ **已验证成功** (2026-02-01)

```
lanproxy (192.168.1.252, MAC 98:41:5C:AA:BB:CC)
    ↓
UU 识别为 Nintendo 设备
    ↓
创建 XU_ACC_DEVICE_192.168.1.252_* 规则
    ↓
创建专用隧道 tun164
    ↓
游戏服务器路由指向 tun164
    ↓
Switch 流量通过代理 → UU 隧道加速
```

**验证结果**: Switch 通过代理连接，流量经 tun164 到达 Nintendo 服务器 (54.x.x.x)。
详见: [lanproxy_success.md](lanproxy_success.md)

---

## 5. 推荐方案

### 方案 A: 网关模式 (最简单)

Switch 直接将网关设为 OpenWrt:
- 设置 → 互联网 → 网关: 192.168.1.250
- UU 原生支持，无需额外配置

### 方案 B: lanproxy-netns (代理模式)

适用于需要代理的场景:
- 参见 [lanproxy_netns/README.md](../lanproxy_netns/README.md)
- 使用 Nintendo OUI 帮助 UU 识别设备
- 需要在 UU APP 中为代理设备开启加速

---

## 6. 相关文档

- [uu_proxy_analysis.md](uu_proxy_analysis.md) - 根本原因分析
- [uu_device_identification.md](uu_device_identification.md) - 设备识别机制
- [uu_switch_detection_logic.md](uu_switch_detection_logic.md) - Switch 检测逻辑
- [lanproxy_netns/README.md](../lanproxy_netns/README.md) - 代理方案详解
