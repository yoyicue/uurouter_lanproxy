# UU Router - Nintendo Switch 加速方案

通过 UTM + OpenWrt + UU加速器 为 Nintendo Switch 实现游戏加速。

## 方案

| 方案 | 说明 | 状态 |
|------|------|------|
| **网关模式** | Switch 网关设为 OpenWrt，UU 原生支持 | 推荐 |
| **代理模式** | Switch 通过 HTTP 代理，lanproxy-netns 实现 | 已验证 |

## 快速开始

### 网关模式 (最简单)

1. 在 UTM 中运行 OpenWrt 虚拟机
2. 安装 UU 加速器插件
3. Switch 网关设为 OpenWrt LAN IP

详见: [docs/utm_openwrt_uu_switch.md](docs/utm_openwrt_uu_switch.md)

### 代理模式 (lanproxy-netns)

适用于需要 HTTP 代理的场景：

1. 部署 lanproxy-netns 到 OpenWrt
2. Switch 设置代理为 lanproxy IP:8888
3. UU APP 中为代理设备开启加速

详见: [lanproxy_netns/README.md](lanproxy_netns/README.md) | [成功配置](docs/lanproxy_success.md)

## 目录结构

```
├── docs/                    # 文档
│   ├── utm_openwrt_uu_switch.md   # 主部署文档
│   ├── lanproxy_success.md        # 代理方案成功配置
│   └── uu_*.md                    # UU 分析文档
├── lanproxy_netns/          # HTTP 代理 (netns 方案)
│   ├── main.go              # 代理源码
│   ├── build.sh             # 编译脚本
│   └── deploy.sh            # 部署脚本
└── scripts/                 # 辅助脚本
```

## 文档索引

| 文档 | 内容 |
|------|------|
| [utm_openwrt_uu_switch.md](docs/utm_openwrt_uu_switch.md) | 完整部署指南 |
| [lanproxy_success.md](docs/lanproxy_success.md) | 代理方案成功配置与验证 |
| [uu_device_identification.md](docs/uu_device_identification.md) | UU 设备识别机制 |
| [uu_switch_detection_logic.md](docs/uu_switch_detection_logic.md) | Switch 检测逻辑 |
| [uu_accel_analysis.md](docs/uu_accel_analysis.md) | uuplugin 分析 |

## 网络拓扑

```
[Nintendo Switch] ──(代理/网关)──> [OpenWrt + UU] ──> [互联网]
                                        │
                                   TUN 隧道加速
                                        │
                                   [UU 服务器]
```

## 环境要求

- macOS + UTM (或其他虚拟化方案)
- OpenWrt ARM64 镜像
- UU 加速器 APP + 路由器插件
- Nintendo Switch + 有线网卡

## License

MIT
