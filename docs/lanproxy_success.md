# lanproxy-netns + UU 加速成功配置

日期: 2026-02-01
状态: **已验证成功**

---

## 1. 方案概述

通过 network namespace + veth 将 HTTP 代理作为"虚拟 LAN 设备"接入 br-lan，使代理流量被 UU 识别并加速。

**核心优势**: Switch 通过 HTTP 代理连接，代理出站流量享受 UU 加速。

---

## 2. 网络拓扑

```
Nintendo Switch (192.168.1.100)
    │
    │ HTTP CONNECT (代理请求)
    ▼
lanproxy netns (192.168.1.252:8888)
    │ MAC: 98:41:5C:AA:BB:CC (Nintendo OUI)
    │
    ▼
veth-lpx ←──→ veth-lpx-br ←──→ br-lan
                                  │
                                  ▼
                    UU nftables (XU_ACC_DEVICE_192.168.1.252_*)
                                  │
                                  ▼ fwmark 0x164 → 策略路由
                                  │
                              tun164 (UU 隧道)
                                  │
                                  ▼
                        Nintendo 服务器 (54.x.x.x)
```

---

## 3. 关键配置

### 3.1 lanproxy 配置 (/etc/lanproxy/config)

```bash
# 网络命名空间
NS_NAME="lanproxy"
NS_ADDR="192.168.1.252/24"
NS_GW="192.168.1.250"

# 代理设置
LISTEN="0.0.0.0:8888"
ALLOW_CLIENTS="192.168.1.100/32"  # 只允许 Switch

# Nintendo OUI (帮助 UU 识别为游戏设备)
UU_LEASE_MAC="98:41:5C:AA:BB:CC"

# DHCP 指纹 (帮助 UU 识别为 Switch)
DHCP_HOSTNAME="NintendoSwitch"
```

### 3.2 Switch 网络设置

| 设置项 | 值 |
|--------|-----|
| IP 地址 | 自动 (DHCP) 或手动 |
| 代理服务器 | 192.168.1.252 |
| 代理端口 | 8888 |

---

## 4. UU 加速生效证据

### 4.1 UU 为代理设备创建的规则

```bash
# nftables 设备表
nft list tables | grep 192.168.1.252
# 输出:
# table ip XU_ACC_DEVICE_192.168.1.252_filter
# table ip XU_ACC_DEVICE_192.168.1.252_mangle
# table ip XU_ACC_DEVICE_192.168.1.252_nat
```

### 4.2 策略路由

```bash
ip rule show | grep 192.168.1.252
# 输出:
# 32758: from 192.168.1.252 lookup 180        # 游戏服务器路由表
# 32759: from 192.168.1.252 fwmark 0x164 lookup 164  # tun164 隧道
# 32760: from 192.168.1.252 fwmark 0x163 lookup 163  # tun163 隧道
```

### 4.3 TUN 隧道

```bash
ip link show | grep tun
# 输出:
# tun163: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP>
# tun164: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP>
```

### 4.4 实际流量 (netns 内)

```bash
ip netns exec lanproxy netstat -an | grep ESTABLISHED
# 输出示例:
# 192.168.1.252:8888  192.168.1.100:xxxxx  ESTABLISHED  # Switch → 代理
# 192.168.1.252:xxxxx 163.163.0.x:443      ESTABLISHED  # 代理 → UU隧道
# 192.168.1.252:xxxxx 54.172.156.65:443    ESTABLISHED  # 代理 → Nintendo
```

**关键指标**: 连接到 `163.163.0.x` 表示流量正在通过 UU 隧道。

---

## 5. 验证命令清单

```bash
# 1. 检查 lanproxy 状态
ssh root@192.168.1.250 "logread | grep lanproxy | tail -5"

# 2. 检查代理监听
ssh root@192.168.1.250 "ip netns exec lanproxy netstat -tlnp | grep 8888"

# 3. 检查 netns 网络
ssh root@192.168.1.250 "ip netns exec lanproxy ip addr show veth-lpx"

# 4. 检查活跃连接
ssh root@192.168.1.250 "ip netns exec lanproxy netstat -an | grep ESTABLISHED"

# 5. 检查 UU 设备规则
ssh root@192.168.1.250 "nft list tables | grep XU_ACC_DEVICE"

# 6. 检查策略路由
ssh root@192.168.1.250 "ip rule show | grep 192.168.1.252"

# 7. 检查 TUN 隧道
ssh root@192.168.1.250 "ip link show | grep tun"

# 8. 从 Mac 测试代理
curl -x http://192.168.1.252:8888 https://example.com -I
```

---

## 6. 为什么这个方案有效

### 6.1 UU 设备识别

UU 通过以下方式识别 lanproxy 为游戏设备：

1. **MAC OUI**: `98:41:5C` 是 Nintendo 官方 OUI
2. **DHCP hostname**: `NintendoSwitch`
3. **流量特征**: 访问 Nintendo 服务器 (*.nintendo.net)

### 6.2 流量路径

```
传统代理 (不工作):
  OpenWrt 本机进程 → OUTPUT chain → WAN
  (不经过 PREROUTING，UU 规则不匹配)

lanproxy-netns (工作):
  netns 进程 → veth → br-lan → PREROUTING chain → UU 规则匹配
  (作为"LAN 设备"，触发 iifname "br-lan" 规则)
```

### 6.3 UU 加速机制

```
1. UU APP 为设备 192.168.1.252 开启加速
2. uuplugin 创建:
   - nftables: XU_ACC_DEVICE_192.168.1.252_*
   - 策略路由: from 192.168.1.252 fwmark 0x164 lookup 164
   - TUN 隧道: tun164
3. 匹配的流量被标记 fwmark 0x164，路由到 tun164
4. 流量通过 UU 服务器加速转发
```

---

## 7. 故障排除

| 问题 | 检查 | 解决 |
|------|------|------|
| Switch 连不上代理 | `ALLOW_CLIENTS` 是否包含 Switch IP | 更新配置并重启 lanproxy |
| 代理不监听 | `netstat -tlnp \| grep 8888` | 检查 lanproxy 进程日志 |
| UU 不加速 | `nft list tables \| grep 192.168.1.252` | 在 UU APP 中为设备开启加速 |
| 设备不出现在 APP | `WRITE_UU_LEASE=1` | 使用 Nintendo OUI + DHCP hostname |

---

## 8. 文件位置

| 文件 | 位置 |
|------|------|
| 配置文件 | `/etc/lanproxy/config` |
| 代理程序 | `/usr/bin/lanproxy` |
| init 脚本 | `/etc/init.d/lanproxy` |
| netns 脚本 | `/etc/lanproxy/netns.sh` |
| lease 脚本 | `/etc/lanproxy/uu-lease.sh` |

---

## 9. 相关文档

| 文档 | 内容 |
|------|------|
| [lanproxy_netns/README.md](../lanproxy_netns/README.md) | 部署指南 |
| [uu_device_identification.md](uu_device_identification.md) | UU 设备识别机制 |
| [uu_switch_detection_logic.md](uu_switch_detection_logic.md) | Switch 检测逻辑 |
| [utm_openwrt_uu_switch.md](utm_openwrt_uu_switch.md) | 完整部署文档 |
