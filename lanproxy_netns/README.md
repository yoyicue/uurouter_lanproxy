# lanproxy-netns

面向 **Mac mini 旁路由** 的 HTTP 代理方案。  
OpenWrt 才能跑 UU 加速器，而 Switch 只支持 **HTTP 代理**。  
lanproxy-netns 把代理进程放进独立的 network namespace，使其在网络中表现为一台 LAN 设备，从而命中 UU 的 `PREROUTING` 规则。

---

## 模式选择

| 模式 | 配置复杂度 | TCP 加速 | UDP 加速 | 适合场景 |
|------|-----------|----------|----------|----------|
| **lanproxy 代理** | 低 | ✓ | ✗ | 下载/更新/eShop/HTTP API |
| **网关模式** | 高 | ✓ | ✓ | 实时对战/低延迟 |

> lanproxy 只代理 TCP，UDP 的实时联机流量通常不会加速。  
> 主要玩实时对战时建议用网关模式。

---

## Mac mini 快速开始

前置条件：OpenWrt 已在 Mac mini 虚拟机中运行，并安装 UU 插件。  
参考：`docs/utm_openwrt_uu_switch.md`

1) 在 Mac 上构建：

```bash
cd lanproxy_netns
./build.sh
```

2) 部署到 OpenWrt，Apple Silicon 通常用 `arm64`/`aarch64`：

```bash
./deploy.sh 192.168.1.250 arm64
```

3) 编辑 OpenWrt 配置：

```sh
vi /etc/lanproxy/config
# 建议至少改三项
NS_ADDR="192.168.1.252/24"
NS_GW="192.168.1.250"
ALLOW_CLIENTS="<SWITCH_IP>/32"
```

4) 启动并设为开机自启：

```sh
/etc/init.d/lanproxy start
/etc/init.d/lanproxy enable
```

5) 在 Switch 设置代理：

```
代理地址: 192.168.1.252
端口: 8888
```

6) 在 UU App 中为 `192.168.1.252` 开启加速。

---

## 工作原理

```
Switch -> lanproxy netns -> veth -> br-lan -> PREROUTING -> UU 加速 -> WAN
```

代理进程运行在 **独立 netns** 中，出站流量走 `br-lan`，因此会被 UU 的 `PREROUTING` 规则命中。

---

## 性能对比

同一台 OpenWrt 做 5 轮对比、每轮 8 秒、取中位数。  
日期：2026-02-04

- lanproxy，HTTP 代理路径：`eth0 rx 54.30 Mbps`，`tun164 rx 54.14 Mbps`
- 直接 UU，网关路径：`eth0 rx 54.20 Mbps`，`tun164 rx 54.19 Mbps`
- 差异：`<0.2%`，基本同级

复现脚本与步骤：`scripts/uu_ifrate.sh`、`docs/perf_lanproxy_vs_direct.md`。

---

## 识别与 DHCP 指纹

OpenWrt 关闭 DHCP 时，UU App 可能识别不稳定。  
建议让 netns 设备走 `NS_PROTO=dhcp` 并伪装 Switch 指纹，详见：

- `docs/lanproxy_success.md`

---

## OpenWrt 文件位置

```
/usr/bin/lanproxy
/etc/init.d/lanproxy
/etc/lanproxy/config
/etc/lanproxy/netns.sh
/etc/lanproxy/uu-lease.sh
/etc/lanproxy/udhcpc.script
```

---

## 验证与排查

```sh
/etc/lanproxy/netns.sh status
ip netns exec lanproxy ss -tlnp | grep 8888
nft list tables | grep XU_ACC_DEVICE_192.168.1.252
```

完整排查清单见：`docs/lanproxy_success.md`
