# lanproxy vs 直接 UU（二进制/网关模式）性能实测

目标：在同一台 OpenWrt 上，对比两种模式下 **UU 隧道(tun*) 实际吞吐** 的差异。

- **lanproxy 模式**：Switch 只配 HTTP 代理 → 真实出站源 IP 是 `lanproxy netns` 的 IP（默认 `192.168.1.252`）
- **直接 UU 模式**：Switch 网关指向 OpenWrt → 真实出站源 IP 是 Switch 自己的 IP（例如 `192.168.1.100`）

> 注意：lanproxy 方案只代理 TCP（HTTP/HTTPS）。UDP（多数实时联机流量）不会走代理，因此“游戏延迟/联机体验”对比时两者差异会非常大；本文只对比可控的 **下载/HTTP(TCP) 吞吐**。

---

## 0) 准备

1) 确保 UU 插件已运行，且在 UU App 里能对目标设备开启加速（会生成 `tun163/tun164...`）。
2) 把采样脚本拷到 OpenWrt（任选一种方式）：

```sh
# 方式 A：scp（推荐）
scp scripts/uu_ifrate.sh root@192.168.1.250:/tmp/uu_ifrate.sh
ssh root@192.168.1.250 "chmod +x /tmp/uu_ifrate.sh"
```

脚本说明：`scripts/uu_ifrate.sh` 会在指定时长内采样 `/proc/net/dev`，输出接口平均 Mbps；也支持 `--src-ip` 自动找出该 IP 对应的 UU `tun*` 接口（需要 OpenWrt 上有 `ip` 命令，通常是 `opkg install ip-full`）。

---

## 1) lanproxy 模式（代理）

前置条件：
- Switch 代理指向 `192.168.1.252:8888`
- UU App 对 **`192.168.1.252` 这台“代理设备”** 开启加速

操作：
1) 在 Switch 开始一个持续下载（eShop 下载/更新均可）
2) 立刻在 OpenWrt 执行（采样 10 秒）：

```sh
sh /tmp/uu_ifrate.sh --src-ip 192.168.1.252 -d 10
```

---

## 2) 直接 UU 模式（网关）

前置条件：
- Switch 网关指向 OpenWrt（旁路网关/主路由都行，关键是 Switch 出站要走 OpenWrt）
- UU App 对 **Switch 的 IP（例如 `192.168.1.100`）** 开启加速

操作：
1) 在 Switch 开始同样的持续下载
2) 立刻在 OpenWrt 执行（采样 10 秒）：

```sh
sh /tmp/uu_ifrate.sh --src-ip 192.168.1.100 -d 10
```

---

## 3) 如何读结果 / 建议的对比方式

- 每个模式至少跑 **3 次**（尽量选择相同时间段/相同下载源），取中位数
- 只看 `TOTAL` 的 `total_Mbps`（脚本会把该 IP 对应的 `tun*` 合并统计）
- 如果你发现两种模式都很慢，通常瓶颈在 **UU 服务器侧/链路质量**，不是 lanproxy

参考：同一台 OpenWrt 上做 5 轮对比、每轮 8 秒采样、取中位数（2026-02-04）：
- lanproxy（HTTP 代理路径）：`eth0 rx 54.30 Mbps`，`tun164 rx 54.14 Mbps`
- 直接 UU（二进制/网关路径，无代理）：`eth0 rx 54.20 Mbps`，`tun164 rx 54.19 Mbps`
- 差异：`<0.2%`（可视为同级）
