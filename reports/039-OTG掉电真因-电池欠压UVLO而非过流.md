# 039 — OTG 掉电真因：不是过流、不是竞态，是**电池欠压（UVLO）**

日期：2026-09-05　状态：**真因已确定**；修复方向见文末

---

## 一、结论先行

困扰很久的 `OTG regulator failure` —— 移动硬盘插上一会儿就掉 —— **不是过流、不是内核竞态、
不是 gadget 配置问题，而是电池电压跌到了 OTG 的欠压锁定（UVLO）阈值以下。**

## 二、决定性证据：原厂驱动里的注释

`ext/smartisan-kernel/drivers/power/qpnp-smbcharger.c`（这台机器原厂真正用的充电驱动）：

```c
/**
 * otg_fail_handler() - called when the usb otg fails
 * (when vbat < OTG UVLO threshold)          ← 就是这一句
 */
static irqreturn_t otg_fail_handler(int irq, void *_chip)
{
	pr_smb(PR_INTERRUPT, "triggered\n");
	return IRQ_HANDLED;
}
```

主线 `drivers/power/supply/qcom-smbchg.c` 里同一个中断的映射：

```c
{ "otg-fail", smbchg_handle_otg_fail },
{ "otg-oc",   smbchg_handle_otg_oc   },      ← 注意：过流是**另一个**中断
```

主线的 `otg-fail` handler 只做两件事：`dev_err("OTG regulator failure")` +
`regulator_notifier_call_chain(..., REGULATOR_EVENT_FAIL, ...)`。

**关键**：`otg-fail`（欠压）与 `otg-oc`（过流）是**两个不同的中断**。我们全程只见过
`OTG regulator failure`，**从未出现过 `OTG over-current`** —— 这本身就是"不是过流"的直接证据。

## 三、这个解释能覆盖所有实测现象

| 实测 | 欠压解释 |
|---|---|
| **持续 I/O 只撑 41 秒**（每 10s 读 8MB） | 放电电流大 → 电池电压跌得快 → 更快跌破 UVLO |
| **空载能撑 65~300 秒** | 放电电流小 → 电压跌得慢 |
| **间隔不固定**（41s / 65s / 300s） | 取决于当时的电池电压与放电电流，不是定时器 |
| 电池 63% / **3.695V**、放电 -386mA 时出问题 | 电压已经偏低，OTG boost 一拉载就更不够 |
| **iPhone 充电稳定，SSD 不稳** | 前者是轻载，后者是重载 |
| 主线/原厂对此都"只记录不处理" | 因为软件无法凭空造出电压，这是硬件约束 |

补充：主线 `qcom-smbchg.c` 里 `smbchg_handle_otg_fail()` 只发通知不重试；
而 `smbchg_handle_otg_oc()`（过流）才有重试逻辑（`reset_otg_on_oc`）。
原厂的 `otg_oc_handler()` 同样有重试（针对 PMI8994 的 inrush 硬件 bug），
但 `otg_fail_handler()` 什么都不做 —— 两边的态度一致：**欠压无解，过流可重试。**

## 四、修正此前几个错误判断

1. ❌ 「一读就掉，所以是负载问题」—— 反过来：**不读能撑更久，越读掉得越快**。
   原判断方向错了，实测（41s vs 65~300s）已经推翻。
2. ❌ 「固定 5 分钟定时器」—— 只是两次巧合（300s、300s），第三次 65s 就否掉了。
3. ❌ 「禁用 UAS 可降峰值」—— 即便有效也是 workaround，用户明确要求用标准机制，已放弃。

## 五、为什么"提高供电能力"做不到

- OTG 的 5V 由 PMIC 内部 boost 从电池升上来。输入（电池）电压不够，输出就维持不住。
- 主线驱动**从未写过** `SMBCHG_OTG_OTG_CFG`(0x1f1)（只定义了地址），
  电流限制/UVLO 阈值等都没配过 —— 但也**不该**去动：降低 UVLO 阈值属于超规格使用，
  会让电池过放、系统不稳。
- 原厂对此也只是记录，不做处理。

## 六、正确（正常机制）的修复方向

原则：遵循硬件规范，而不是绕过它。

1. **治本（操作层面）**：接大电流 OTG 设备（2.5" SATA SSD 这类）时保证电池电量充足。
   待验证：充电到 80%+ 后是否稳定 —— 这是唯一还需要做一次的实测。

2. **软件层面（符合规范、非 workaround）**：
   - OTG 启用前/时检查电池电量与电压，**低于安全阈值就明确告警**，
     而不是让设备枚举成功后**静默掉电**。静默掉电对数据安全是灾难（写到一半断开）。
   - 把 `otg-fail` 明确上报给用户态可见的地方（现在只有 `dev_err`，用户看不到原因）。

3. **数据安全层面**：电量不足时避免启用大电流 OTG，宁可拒绝也不要中途掉电。

## 七、附带成果（同一轮排查）

- **内核 Oops（reports/038）已解决**：`ip` 命令撞 `rtnl_getlink` 的竞态。
  脚本改用 sysfs/`proc/net/dev` 判断状态、消除 netlink 轮询后，
  **pstore 全程为空 = 从未崩溃**，系统不再被搞坏（此前已两次导致无法启动）。
- **ramoops 1 MB → 2 MB**，崩溃转储不再因 `ENOSPC` 丢失。
- **gadget function 类型可配**（`ODIN_GADGET_FN=ncm/ecm/rndis`，默认 ncm 行为不变），
  配合 `/etc/odin/usb-role.env`（该 env 机制此前只在注释里承诺过、实际未实现，已补上）。
- 拔掉 OTG 后 USB 网卡能自动恢复（PC 侧 `en36` 拿到 `172.16.42.2`）。

## 八、遗留问题（与本主题独立）

`usb0` 的 sysfs 节点在拔插后会变成**悬空符号链接**（`gadget.0/net/` 被注销，
但 netlink 里设备还在、`state UP`、地址在、网络通）。脚本已改用 `/proc/net/dev`
规避误判（原来按 sysfs 判会误认为"网卡不存在"而跳过配置）。
这个"设备还在但 sysfs 目录先注销"的成因仍未查清，需要内核侧跟进。
