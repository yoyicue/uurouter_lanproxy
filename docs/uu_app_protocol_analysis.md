# UU APP 通信协议分析

日期: 2026-02-01

## 1) 概述

UU 路由器插件 (`uuplugin`) 使用 **Google Protocol Buffers (protobuf)** 与 UU APP 通信。

---

## 2) 网络端口

| 端口 | 协议 | 用途 |
|------|------|------|
| 16363/TCP | protobuf | 管理/状态接口 |
| 14554/TCP | protobuf | APP 主通信端口 |
| 60000/TCP | 隧道 | 加速流量入口 (DNAT 目标) |
| 39292/UDP | MDNS | 设备发现广播 |
| 5353/UDP | MDNS | 标准 MDNS 查询 |

---

## 3) Protobuf 消息类型

从二进制提取的消息定义 (`uu_router_messages.proto`):

### 3.1 核心消息

```protobuf
// 连接管理
message ConnectRequest { ... }
message ConnectReply { ... }
message DisconnectReply { ... }

// 上线/状态
message Online {
  message Server { ... }
}
message OnlineReply {
  message Server { ... }
  message Status { ... }
}

// 设备
message Device {
  message LinkType { ... }  // WLAN/LAN 等
}
message MacList {
  message Mac { ... }
  message Precision { ... }
}

// 加速控制
message Acc {
  message Route { ... }
  message Server { ... }
  message ServerType { ... }
  message SniIpKey { ... }
  message LocalTcpRealIpExtra { ... }
}
message AccReply {
  message Status { ... }
}
message StopAccReply {
  message Status { ... }
}

// 用户绑定
message BoundUser {
  message SniIpKey { ... }
  message DeviceRecord { ... }
  message AutoDeviceRecord { ... }
  message MeshDeviceRecord { ... }
}
message BoundUserReply { ... }
message CheckBound {
  message DomainIP { ... }
}
message CheckBoundReply { ... }

// 服务器延迟
message ServerPing {
  message Server { ... }
}
message ServerPingReply {
  message Server { ... }
}
message LatencyStat {
  message Type { ... }
  message LatencyInfo { ... }
}
message GamingServerLatency {
  message Type { ... }
  message LatencyInfo { ... }
}
message FenceModeLatency {
  message GameServer { ... }
}

// 系统
message Upgrade {
  message CMD { ... }
}
message Uninstall {
  message CMD { ... }
}
message LogCtrl {
  message LogType { ... }
  message LogLevel { ... }
}
message UserMessage {
  message MsgType { ... }
}
message Time { ... }
message Timestamp { ... }

// 其他
message WolReply { ... }        // Wake on LAN
message StartRtmpReply { ... }  // RTMP 直播
message StopRtmpReply { ... }
```

---

## 4) 设备发现机制

### 4.1 MDNS 查询

UU 主动发送 MDNS 查询来发现设备:

```
_xboxda._tcp.local        - Xbox 设备
_googlecast._tcp.local    - Google Cast
_airplay._tcp.local       - Apple 设备
_spotify-connect._tcp     - Spotify
_services._dns-sd._udp    - 服务发现
Apple-Vision-Pro.local    - 特定设备名
```

### 4.2 DHCP 租约读取

UU 读取以下文件获取设备信息:
- `/tmp/dhcp.leases`
- `/tmp/var/lib/misc/dnsmasq.leases`

字段: `dhcp_hostname`, `client-hostname`

### 4.3 设备类型检测

UU 使用多种方法检测设备类型:

```c
// 设备类型标记
may_be_switch    // Nintendo Switch
may_be_ps4       // PlayStation 4
may_be_xboxone   // Xbox One
may_be_android   // Android
may_be_apple     // Apple
may_be_windows   // Windows

// 检测方法
dns_ttl          // DNS 响应 TTL 分析
tcp_ttl          // TCP 包 TTL 分析 (不同 OS 有不同默认值)
dhcp_hostname    // DHCP 主机名匹配
```

### 4.4 探测代码

```
switch_probe.cpp   - Switch 探测
ps4_probe.cpp      - PS4 探测
xbox_probe.cpp     - Xbox 探测
```

---

## 5) 加速流量处理

### 5.1 nftables 规则

UU 创建 DNAT 规则将流量重定向到本地端口:

```
table inet {
  chain PREROUTING {
    iifname "br-lan" ip daddr <target_ip> tcp dport 443 dnat to 192.168.1.250:60000
    iifname "br-lan" ip daddr <target_ip> tcp dport 80 dnat to 192.168.1.250:60000
  }
}
```

### 5.2 流量识别

- 基于设备 IP/MAC
- 基于目标域名/IP
- 基于端口 (游戏服务器端口)

---

## 6) Switch 特定配置

```
switch_cn                        - Switch 国服
switch_cn_addition_servers       - 国服附加服务器
switch_addition_servers          - 其他服务器
switch_federation_detect         - 联机检测
switch_federation_detect_timeout - 检测超时
switch_hostname_blacklist        - 主机名黑名单
switch_hybrid_proxy              - 混合代理模式
```

---

## 7) 待分析

1. **APP 通信抓包**: 需要用 UU APP 连接路由器时抓取 14554 端口流量
2. **protobuf 解码**: 获取完整的 .proto 文件或通过逆向工程重建
3. **设备添加 API**: 确认是否可以通过 API 手动添加设备

---

## 8) 测试环境状态

```bash
# 抓包命令 (在 OpenWrt 上运行)
tcpdump -i any -s 0 -w /tmp/uu_app_traffic.pcap "port 14554 or port 16363"

# 查看捕获
tcpdump -r /tmp/uu_app_traffic.pcap -X
```

后台抓包已启动，等待 APP 连接...
