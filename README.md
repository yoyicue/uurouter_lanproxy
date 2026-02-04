# UU Router - Mac mini 旁路由 + UU 加速器 + Nintendo Switch

适用于 **Mac mini、NUC 等软路由场景**，通过虚拟机运行 OpenWrt + UU加速器，为 Nintendo Switch 实现游戏加速。

## 适用场景

- 没有支持 UU 的硬件路由器，但有 Mac mini / NUC / 小主机等常开设备
- 想使用 UU 加速器，但不想购买额外的路由器硬件
- 已有复杂网络环境（主路由不可替换），需要旁路网关方案

## 工作原理

```
[Nintendo Switch]
       │
       ▼ (网关指向 OpenWrt)
[OpenWrt 虚拟机] ← UU 加速器插件
       │
       ▼ (TUN 隧道)
[UU 服务器] → 游戏服务器
```

在 Mac mini 等设备上通过 UTM/VMware/Proxmox 运行 OpenWrt 虚拟机，安装 UU 加速器插件，Switch 将网关指向 OpenWrt 即可享受加速。

## 加速方案

| 方案 | 说明 | 状态 |
|------|------|------|
| **网关模式** | Switch 网关设为 OpenWrt，UU 原生支持 | 推荐 |
| **代理模式** | Switch 通过 HTTP 代理，lanproxy-netns 实现 | 已验证 |

> 代理模式只加速 TCP，UDP（实时联机）不会走代理。  
> 如果你主要玩实时对战，优先选择网关模式。

## 快速开始

### 网关模式（推荐）

1. 在虚拟化平台（UTM/VMware/Proxmox）中运行 OpenWrt
2. 配置 OpenWrt 为旁路网关（与主网络同网段）
3. 安装 UU 加速器插件
4. Switch 网关指向 OpenWrt LAN IP

详见: [docs/utm_openwrt_uu_switch.md](docs/utm_openwrt_uu_switch.md)

### 代理模式（lanproxy-netns）

适用于需要 HTTP 代理的场景：

1. 部署 lanproxy-netns 到 OpenWrt
2. Switch 设置代理为 lanproxy IP:8888
3. UU App 中为代理设备开启加速

详见: [lanproxy_netns/README.md](lanproxy_netns/README.md) | [成功配置](docs/lanproxy_success.md)
性能对比与复现: [docs/perf_lanproxy_vs_direct.md](docs/perf_lanproxy_vs_direct.md)

## 环境要求

| 组件 | 说明 |
|------|------|
| 宿主机 | Mac mini / NUC / 小主机等常开设备 |
| 虚拟化 | UTM (macOS) / VMware / Proxmox / QEMU |
| OpenWrt | ARM64 或 x86_64 镜像 |
| UU 加速器 | 手机 APP + 路由器插件 |
| Switch | 建议使用有线网卡 |

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
└── scripts/                 # OpenWrt 辅助脚本
```

## 文档索引

| 文档 | 内容 |
|------|------|
| [utm_openwrt_uu_switch.md](docs/utm_openwrt_uu_switch.md) | 完整部署指南 |
| [lanproxy_success.md](docs/lanproxy_success.md) | 代理方案成功配置与验证 |
| [perf_lanproxy_vs_direct.md](docs/perf_lanproxy_vs_direct.md) | lanproxy vs 直连性能对比 |
| [uu_device_identification.md](docs/uu_device_identification.md) | UU 设备识别机制 |
| [uu_switch_detection_logic.md](docs/uu_switch_detection_logic.md) | Switch 检测逻辑 |
| [uu_accel_analysis.md](docs/uu_accel_analysis.md) | uuplugin 分析 |

## License

MIT
