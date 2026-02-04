# lanproxy-netns

面向 **Mac mini 旁路由** 的最小侵入式方案：  
OpenWrt 只能跑 UU 加速器，而 Switch 只支持 **HTTP 代理**。  
lanproxy-netns 把代理进程放进独立的 network namespace，让它在网络上“看起来像一台 LAN 设备”，从而命中 UU 的 `PREROUTING` 加速规则。

---

## 先选模式（很重要）

| 模式 | 配置复杂度 | TCP 加速 | UDP 加速 | 适合场景 |
|------|-----------|----------|----------|----------|
| **lanproxy（仅设代理）** | 低 | ✓ | ✗ | 下载/更新/eShop/HTTP API |
| **网关模式（Switch 指向 OpenWrt）** | 高 | ✓ | ✓ | 实时对战/低延迟 |

> lanproxy 只代理 TCP，**UDP（多数实时联机）不会加速**。  
> 如果你主要玩实时对战，建议用网关模式。

---

## Mac mini 友好 Quickstart

前置：OpenWrt 已在 Mac mini 虚拟机中运行，并安装 UU 插件。  
参考：`docs/utm_openwrt_uu_switch.md`

1) 构建（在 Mac 上）：

```bash
cd lanproxy_netns
./build.sh
```

2) 部署到 OpenWrt（Apple Silicon 一般是 `arm64` / `aarch64`）：

```bash
./deploy.sh 192.168.1.250 arm64
```

3) 编辑配置（OpenWrt 上）：

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

5) Switch 设置代理：

```
代理地址: 192.168.1.252
端口: 8888
```

6) UU App 中为 `192.168.1.252` 这台“代理设备”开启加速。

---

## 这是怎么工作的

```
Switch -> lanproxy(netns) -> veth -> br-lan -> PREROUTING -> UU 加速 -> WAN
```

代理进程在 **独立 netns** 中，出站流量走 `br-lan`，因此会被 UU 的 `PREROUTING` 规则命中。

---

## 性能对比（稳定样本）

同一台 OpenWrt 做 5 轮对比、每轮 8 秒、取中位数（2026-02-04）：

- lanproxy（HTTP 代理路径）：`eth0 rx 54.30 Mbps`，`tun164 rx 54.14 Mbps`
- 直接 UU（二进制/网关路径，无代理）：`eth0 rx 54.20 Mbps`，`tun164 rx 54.19 Mbps`
- 差异：`<0.2%`（可视为同级）

复现脚本与步骤：`scripts/uu_ifrate.sh`、`docs/perf_lanproxy_vs_direct.md`。

---

## 高级配置（Switch 识别 + DHCP 指纹）

如果 OpenWrt 关闭了 DHCP，UU App 的设备识别可能不稳定。  
建议让 netns 设备走 `NS_PROTO=dhcp` 并伪装 Switch 指纹，详见：

- `docs/lanproxy_success.md`

---

## 目录与文件（OpenWrt 上）

```
/usr/bin/lanproxy
/etc/init.d/lanproxy
/etc/lanproxy/config
/etc/lanproxy/netns.sh
/etc/lanproxy/uu-lease.sh
/etc/lanproxy/udhcpc.script
```

---

## 验证与排查（简版）

```sh
/etc/lanproxy/netns.sh status
ip netns exec lanproxy ss -tlnp | grep 8888
nft list tables | grep XU_ACC_DEVICE_192.168.1.252
```

完整排查清单见：`docs/lanproxy_success.md`
