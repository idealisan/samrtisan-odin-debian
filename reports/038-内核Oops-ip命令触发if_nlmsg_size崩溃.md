# 038 — 内核 Oops：`ip` 命令触发 `if_nlmsg_size` 崩溃，进而损坏系统

日期：2026-09-05　状态：**已定位触发路径，根因待修**（已两次导致系统无法启动）

---

## 一、现象（不只是 USB 问题）

这一连串看起来不相干的故障，**其实是一个根因**：

| 现象 | 出现时机 |
|---|---|
| 拔掉 OTG 设备再连回电脑，**USB 网卡不恢复** | 每次插拔 OTG 之后 |
| **SSH 新连接建不起来**（旧会话还活着，端口能连，握手卡在 banner） | 插拔若干次之后 |
| **系统损坏、重启卡在 lk2nd 菜单**，必须重刷 | 已发生**两次** |
| 移动硬盘插着会掉电（`OTG regulator failure`） | 与上面同源的次生现象 |

## 二、决定性证据：用户从屏幕拍到的 Oops

```
CPU: 7  UID: 0  PID: 11561  Comm: ip   Not tainted 6.19.5-postmarketos-qcom-msm8953 #1 PREEMPT
Hardware name: Smartisan U2 Pro (ODIN) (DT)

pc : if_nlmsg_size+0x1b8/0x290
lr : rtnl_getlink+0x1f4/0x490

Call trace:
  if_nlmsg_size+0x1b8/0x290 (P)
  rtnl_getlink+0x1f4/0x490
  rtnetlink_rcu_msg+0x130/0x3a8
  netlink_rcu_skb+0x68/0x140
  rtnetlink_rcu+0x20/0x38
  netlink_unicast+0x33x/0x3b8
  netlink_sendmsg+0x170/0x3b8
  _sys_sendmsg+0x12c/0x2b8
  ...
  el0t_64_sync+0x198/0x1a0
Code: d50323bf d65f03c0 f9403001 b4000601 (f9404021)
---[ end trace ]---
pstore: backend (ramoops) writing error (-28)
```

### 三个关键读数

1. **`Comm: ip`** —— 崩溃是 **`ip` 命令**触发的，不是内核自己。
2. **`if_nlmsg_size` ← `rtnl_getlink`** —— 走的是 netlink 的
   **RTM_GETLINK**（查询网卡列表）。`ip link` / `ip addr` 都会走这条路。
3. **`pstore: ramoops writing error (-28)`** —— `-28` 是 `ENOSPC`，
   **崩溃转储存不下**。这条既是后果，也是后续定位的最大障碍（见第五节）。

## 三、因果链

```
插拔 OTG 设备
  │
  ├─ udev 规则 99-odin-usb-role.rules
  │    （udc add/remove、typec change、extcon change 都触发）
  │
  └─ odin-usb-gadget.service / odin-usb-gadget.timer（每 30s 看门狗）
       └─ odin-usb-role.sh
            ├─ ip link set usb0 down/up
            ├─ ip link set usb0 address ...
            ├─ ip addr add 172.16.42.1/24 dev usb0
            └─ ip -4 -o addr show usb0        ← 就是这些 ip 调用
                 └─ netlink RTM_GETLINK
                      └─ 内核 Oops（if_nlmsg_size）
                           ├─ 脚本当场中断 ⇒ gadget 没重建 ⇒ **USB 网卡不恢复**
                           ├─ 内核状态受损 ⇒ **sshd 不再响应新连接**
                           └─ 反复 Oops 后文件系统损坏 ⇒ **无法启动，必须重刷**

（另有 30 秒一次的看门狗不断重复触发，等于反复在同一个雷点上踩。）
```

`odin-usb-role.sh` 里 `ip` 的调用点（都是 `apply_device()` 内）：建 gadget 后
`ip link set usb0 up`、`ip addr add`；MAC 重设时 `ip link set usb0 down/address/up`；
等地址时 `ip -4 -o addr show usb0`；末尾再 `ip link up` + `ip addr add`。

## 四、崩溃点分析

`if_nlmsg_size()`（net/core/rtnetlink.c:1270）里会解引用 `dev` 往下取东西的有四个：

```c
+ rtnl_vfinfo_size(dev, ext_filter_mask)      /* IFLA_VFINFO_LIST */
+ rtnl_port_size(dev, ext_filter_mask)        /* IFLA_VF_PORTS + IFLA_PORT_SELF */
+ rtnl_link_get_size(dev)                     /* IFLA_LINKINFO */
+ rtnl_link_get_af_size(dev, ext_filter_mask) /* IFLA_AF_SPEC */
```

崩溃指令 `f9404021`（`ldr x1, [x1, #0x80]`）是**从对象 +0x80 处取指针**，
再结合下一次访问就炸 —— 典型的**对象处于过渡态/已被释放**。

时机上完全吻合：OTG 插拔时 usb0（NCM gadget 网卡）正在创建或销毁，
此刻 `ip` 去遍历网卡列表就会撞上。

**这是主线 6.19 在 NCM gadget 快速增删场景下的竞态问题。**

## 五、为什么难进一步定位

`pstore: ramoops writing error (-28)` —— ramoops 预留空间不够，
Oops 存不下来，只能靠人眼从屏幕上拍。**下一次必须先把这条修掉**，
否则每轮崩溃都拿不到完整转储。

## 六、修法候选（按建议顺序）

| # | 做法 | 评价 |
|---|---|---|
| **1** | **加大 ramoops 预留区**，保证崩溃转储能落盘 | **诊断前提**，先做这个，否则后面都是盲修 |
| **2** | 脚本层：给 `ip` 调用加保护 —— 失败重试、
        在 usb0 稳定前不调用、用 `ip -o` 减少遍历 | 缓解，不是根治（内核 bug 还在，只是少撞） |
| **3** | 内核层：定位竞态点并修（重点看 `rtnl_link_get_size` /
        `rtnl_link_get_af_size` 对 gadget 网卡的处理） | 根治，但需要先拿到完整转储 |
| **4** | 换 gadget 类型（NCM → ECM / RNDIS）试试是否还崩 | 有价值的对照实验，成本不高 |
| **5** | 看门狗间隔从 30s 调大 | 降低撞雷频率，纯缓解 |

## 七、当前状态

- 已用 **v0.9.5 正式 CI 制品**重刷（lk2nd + userdata，SHA256 校验通过）
- 系统恢复正常：`lk2nd=23.1-odin`、`role=device`、`usb0=172.16.42.1/24`、
  UDC=`7000000.usb`、根 `/dev/mmcblk0p57`

## 八、这轮顺带确认的另一件事（与 Oops 无关，但也是真缺口）

原厂设备树 `msm8953.dtsi:2060` 有：

```dts
vbus_dwc3-supply = <&smbcharger_charger_otg>;
```

**我们设备树的 `&usb3` 没有对应属性**，所以 `smbcharger-otg-vbus` 这个 regulator
处于 `state=enabled users=0` 的悬挂状态（主线 `smbchg_otg_switch()` 只写一个
`OTG_EN_BIT`，且驱动从未写过 `SMBCHG_OTG_OTG_CFG`(0x1f1) —— 那个寄存器只定义了地址）。
后果是 VBUS 的生命周期没人管、`otg-fail` 通知没人接。

> 注：主线 `smbchg_otg_enable()` 里有 `WARN_ON_ONCE(chip->role_sw)`，
> 说明主线设计上"用了 role switch 就不该再用 vbus-supply"。所以补这条
> 会触发一次 WARN（不影响功能），需要在"符合主线设计"和"VBUS 有正式消费者"
> 之间权衡。**待 Oops 修完后再处理。**
