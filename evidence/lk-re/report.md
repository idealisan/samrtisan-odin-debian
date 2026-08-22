# 原厂 emmc_appsboot.mbn 面板选择逻辑逆向报告

日期：2026-08-22
目标：`Pro_user_V4.2.5/SEKSA-mol%odin-rom-4.1.0-odin-user-20180523-005028-32g/emmc_appsboot.mbn`
（ELF 封装，e_entry=0x8F600000，唯一 PT_LOAD 段：file off 0x8000 → VA 0x8F600000，size 0x9E188）

## 一、结论摘要

1. **原厂 LK 的面板自动识别是 GPIO 电平检测，不是 DSI read-id。**
   选择函数（~0x8F601BF0–0x8F602570）在无面板名覆盖时读取两个 TLMM GPIO 的输入电平
   三分批次；所有面板的 `mipi->signature` 一律写 **0xFFFF**（禁用哨兵），即 DSI 签名
   自动探测从未启用。此前怀疑依据的字符串 `"Read ID cmd status failed"` 实际属于
   `qpic_nand.c`（NAND 读 ID），与面板无关。
2. **GPIO 检测映射**（helper @0x8F603F10：addr=gpio*0x1000+0x1000000，读 [addr+4]&1，
   即 TLMM pin-region IN 寄存器 bit0）：

   | GPIO91(0x5b) | GPIO92(0x5c) | 选定面板 | panel_id 枚举 |
   |---|---|---|---|
   | 1 | 1 | qcom,mdss_dsi_nt36672_1080p_video | 7 |
   | 1 | 0 | qcom,mdss_dsi_ft8716_1080p_video | 5 |
   | 0 | 任意 | qcom,mdss_dsi_sharp_ft8716_1080p_video | 6 |

3. **R69006 cmd/video 不在 GPIO 检测路径内**——只能通过 `panel_name_to_id` 名字覆盖到达
   （表基址 0x8F670F70，首项 "truly_1080p_video"，共 8 项；跳转表 7 个有效分支）。
4. 因此 **README 中“默认面板=R69006 cmd 与原厂行为一致”的说法是错误的**：
   原厂默认走 GPIO 三选一，sharp_ft8716 为兜底分支。
5. 分支代码证据：
   - 覆盖入口 `bl 0x8F62EC80`（panel_name_to_id，r0=表,r1=8,r2=name）
     @0x8F601C68–78；失败打印 "Not able to search the panel:%s"
     （串@0x8F65637C，经 movw@0x8F601CE0 引用）
   - GPIO 读：`mov r0,#0x5c; bl 0x8F603F10`→r8、`mov r0,#0x5b; bl 0x8F603F10`→r0
     @0x8F601EBC–ECC
   - 三分逻辑 @0x8F601ED0–EEC、0x8F60246C–47C：
     `(g92==1 && g91==1)`→nt36672块@0x8F602494（id=7 存于 0x8F602488–90）；
     否则若 g91==1→ft8716块@0x8F602380（id=5）；否则默认→sharp块@0x8F601EF0（id=6）
   - 全部 8 处 `[r5,#0x290]`（signature）赋值均为 0xFFFF：
     0x8F601E9C / 01FD0 / 02114 / 021E4 / 022B0 / 02378 / 02464 / 025560
6. 面板配置结构体（首字段=node_id 字符串指针）：
   sharp@0x8F670D9C、r69006_video@0x8F670EF8、nt36672@0x8F6712F0、
   ft8716@0x8F6716A4、r69006_cmd@0x8F671CE4。

## 二、对本移植的修正意义

- 我们 lk2nd 补丁（0001/0002）当前默认 R69006 cmd —— 与原厂真实行为不符；
  非 R69006 批次会黑屏，而其中三个批次原厂本可自动区分。
- **#7 正确实现方案**：在 lk2nd 的 odin oem_panel_select 中复刻上述 GPIO 检测
  （TLMM 91/92 输入电平三分），保留 lk2nd 既有的名字覆盖机制作为手动救援；
  R69006 仅作显式选择项/最后回退。
- “反编译原厂提取各面板 DCS 签名值”不可行——数据不存在于固件中。

## 三、置信度与不确定点

- GPIO 检测三分逻辑、signature 全 0xFFFF、覆盖表存在：**高**（直接反汇编证据）。
- helper 即 gpio_get（IN 寄存器）：**高**（寻址公式与 msm TLMM v4 pin-region 布局吻合，
  [region+4]=IN）。GPIO 编号 91/92 按 TLMM 标准 n*0x1000 布局推得：**较高**。
- 选择函数的 hw_id 门控细节（0x8F610240 返回值的语义、位掩码 0x00100081/0x02000400
  对 ODIN 实际取值的判定）：**中**，未完全展开；不影响主结论。
- 未发现 fastboot 面板设置命令（oem 表中无 panel 相关命令）：**高**。

## 四、中间产物清单

- `lk_code.bin` 代码段提取（647,560B = 0x9E188）
- `dump_arm_ann.txt` / `dump_thumb_full.txt` 全段反汇编（llvm-objdump 双模式）
- `literal_map.json` / `literal_pool_xrefs.json` 字面量池映射与交叉引用
- 本报告 + `signatures.txt`
