# UTM + OpenWrt + UU加速器 + Nintendo Switch 加速方案

本文档描述如何使用以下组件为 Nintendo Switch 实现游戏加速：
- UTM (macOS 免费虚拟化软件)
- OpenWrt (虚拟机内运行的路由系统)
- UU加速器路由器插件 (uuplugin)

---

## 0) 核心思路

UU加速器只有在 OpenWrt 作为 Switch 的**网关**时才能工作。
有两种部署方式：

| 方式 | OpenWrt LAN IP | Switch 网关 | 复杂度 |
|------|----------------|-------------|--------|
| **A: 旁路网关 (推荐)** | 与主网络同网段 | OpenWrt IP (手动设置) | 简单 |
| B: 独立子网 | 独立网段 | OpenWrt IP (DHCP自动) | 需要配置VLAN |

---

## 1) 网络拓扑 (示例)

### 方式 A: 旁路网关

```
[互联网]
    |
[主路由器] (192.168.1.1) ← DHCP 服务器
    |
[交换机] ← 192.168.1.0/24 网络
    |
    +-- [Mac 主网卡] ← Mac 主网络连接
    |
    +-- [Mac USB网卡] (192.168.1.x) ← 桥接到 UTM
    |         |
    |    [UTM 虚拟机: OpenWrt]
    |         |- eth0 (WAN): DHCP 或静态 IP
    |         |- eth1 (LAN): 192.168.1.250
    |                ↑
    |           UU加速器在此运行
    |
    +-- [Nintendo Switch] (网关=192.168.1.250)
```

### 流量路径

```
Switch (网关=OpenWrt)
    ↓
OpenWrt br-lan ← UU 拦截游戏流量
    ↓
OpenWrt WAN
    ↓
主路由器 → 互联网
```

---

## 2) 硬件需求

- Mac (Apple Silicon 或 Intel)
- USB 网卡 (用于桥接到 OpenWrt LAN)
- Nintendo Switch + 有线网卡 (推荐)

---

## 3) UTM 虚拟机配置

### 3.1 虚拟机设置

- 类型: 虚拟化 (ARM64 for Apple Silicon, x86_64 for Intel)
- 操作系统: Linux
- CPU: 2 核心
- 内存: 512MB - 1GB
- 存储: OpenWrt 镜像

### 3.2 网络适配器

| 网卡 | 模式 | 桥接到 | OpenWrt 接口 | 用途 |
|------|------|--------|--------------|------|
| 网卡 1 | 桥接 | 主网卡 | eth0 (WAN) | 上网出口 |
| 网卡 2 | 桥接 | USB网卡 | eth1 (LAN) | Switch 连接 |

---

## 4) OpenWrt 配置 (旁路网关模式)

### 4.1 网络设置

```bash
# 设置 LAN 为主网络同网段 (旁路网关模式)
# 选择一个未被占用的 IP
uci set network.lan.ipaddr='192.168.1.250'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.proto='static'

# WAN 保持 DHCP
uci set network.wan.proto='dhcp'

uci commit network
/etc/init.d/network restart
```

### 4.2 关闭 DHCP (重要!)

OpenWrt 不能运行 DHCP 服务器，避免与主路由器冲突：

```bash
uci set dhcp.lan.ignore='1'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

### 4.3 验证配置

```bash
# 检查接口
ip addr show br-lan

# 检查 DHCP 已关闭
uci show dhcp.lan.ignore

# 测试连通性
ping -c 2 192.168.1.1    # 主路由器
ping -c 2 8.8.8.8        # 互联网
```

---

## 5) macOS 配置

### 5.1 USB 网卡

设置为同网段静态 IP：

```bash
# 替换 "USB 10/100 LAN" 为你的网卡名称
networksetup -setmanual "USB 10/100 LAN" 192.168.1.251 255.255.255.0
```

或通过系统设置手动配置 IP。

### 5.2 验证桥接连通性

```bash
ping -c 2 192.168.1.250   # 应能访问 OpenWrt
```

---

## 6) UU 加速器安装

### 6.1 安装 UU 插件

```bash
# SSH 到 OpenWrt 并安装
ssh root@<OPENWRT_IP>

# 下载并运行安装脚本
wget -O /tmp/install.sh https://router.uu.163.com/api/script/install
sh /tmp/install.sh openwrt <架构>
# 架构: aarch64 (ARM64), x86_64 等
```

### 6.2 验证 UU 状态

```bash
# 检查进程
ps | grep uuplugin

# 检查激活状态
cat /tmp/uu/activate_status

# 检查监听端口
netstat -tlnp | grep uu
```

---

## 7) Nintendo Switch 配置

### 7.1 网络设置

1. 设置 → 互联网 → 互联网设置
2. 选择连接 → 更改设置
3. IP 地址设置: **自动** 或 **手动**
4. **网关: `<OPENWRT_LAN_IP>`** (手动设置 - 这是关键!)
5. DNS 设置: 主路由器 IP 或公共 DNS

### 7.2 验证

- Switch 应通过连接测试
- UU 手机 APP 应能检测到 Switch

---

## 8) Surge 配置 (可选)

如果 Mac 上使用 Surge，添加绕过规则防止干扰：

```ini
[General]
# 排除公网 IP，让 hairpin NAT 正常工作
tun-excluded-routes = <YOUR_PUBLIC_IP>/32
```

---

## 9) 验证清单

| 检查项 | 命令/操作 | 预期结果 |
|--------|----------|----------|
| OpenWrt LAN IP | `ip addr show br-lan` | 配置的 IP |
| OpenWrt DHCP | `uci show dhcp.lan.ignore` | '1' (已关闭) |
| OpenWrt → 主路由 | `ping <主路由IP>` | 成功 |
| OpenWrt → 互联网 | `ping 8.8.8.8` | 成功 |
| Mac → OpenWrt | `ping <OpenWrt IP>` | 成功 |
| UU 进程 | `ps \| grep uuplugin` | 运行中 |
| Switch 连接测试 | Switch 设置 | 通过 |

---

## 10) 常见问题与解决方案

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| Switch 无法获取 IP | DHCP 冲突 | 关闭 OpenWrt DHCP |
| OpenWrt 无法访问 | 桥接错误 | 检查 UTM 网卡桥接设置 |
| UU 不加速 | 网关设置错误 | 将 Switch 网关设为 OpenWrt IP |
| Surge 干扰 | TUN 路由 | 添加 tun-excluded-routes |

---

## 11) 备选方案: 独立子网

如果需要 OpenWrt 使用独立子网并提供 DHCP：

```bash
# OpenWrt LAN: 192.168.50.1，启用 DHCP
uci set network.lan.ipaddr='192.168.50.1'
uci set dhcp.lan.ignore='0'
uci commit
/etc/init.d/network restart
```

**注意:** 此方式需要配置 VLAN 或双网卡，操作相对复杂。

---

## 12) OpenWrt 必要组件

高版本 OpenWrt (22.03+) 使用 nftables，需要额外配置。

### 12.1 必要内核模块

```bash
opkg install kmod-tun kmod-veth ip-full
```

### 12.2 防火墙配置

**重要**: OpenWrt 高版本固件 (22.03+) 需要进行 nftables 兼容操作才能正常使用 UU 加速。

```bash
uci add firewall zone
uci set firewall.@zone[-1].name='UU'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].device='tun16+'
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='UU'
uci commit firewall
/etc/init.d/firewall reload
```

---

## 13) 高级方案: lanproxy-netns (HTTP 代理 + UU 加速)

如果需要让 Switch 通过 HTTP 代理使用 UU 加速，参见 `lanproxy_netns/` 目录。

**核心思路**: 在 network namespace 中运行 HTTP 代理，通过 veth 接入 br-lan，使代理流量被 UU 识别。

**关键配置**:
- 使用 Nintendo OUI 作为 MAC 地址
- DHCP hostname 设为 `NintendoSwitch`
- UU 会为该设备创建专用 TUN 隧道

详见: [lanproxy_netns/README.md](../lanproxy_netns/README.md)

---

## 14) 相关文档

| 文档 | 内容 |
|------|------|
| [lanproxy_success.md](lanproxy_success.md) | **代理方案成功配置与验证** |
| [uu_proxy_analysis.md](uu_proxy_analysis.md) | 代理流量失败根本原因分析 |
| [uu_device_identification.md](uu_device_identification.md) | UU 设备识别机制详解 |
| [uu_switch_detection_logic.md](uu_switch_detection_logic.md) | Switch 多层检测逻辑 |
| [uu_accel_analysis.md](uu_accel_analysis.md) | uuplugin 静态分析 |
| [lanproxy_netns/README.md](../lanproxy_netns/README.md) | HTTP 代理 + UU 加速方案 |
