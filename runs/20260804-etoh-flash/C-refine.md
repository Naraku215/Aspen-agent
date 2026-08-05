# C 阶段产物 — 乙醇-水单级闪蒸全流程建模（L1，C 阶段直接搭全流程）

- run-id：20260804-etoh-flash
- 阶段：C（L1 流程，A→C→E，B/D 已裁；B 阶段的 **BIP 核查** 与 **物料闭合校核** 下沉至本阶段）
- 依据：`A-plan.md` v1（6 条假设全按默认值采纳，用户已确认）
- 模型文件：`D:\Projects\aspen-agent\runs\20260804-etoh-flash\model.apw`（保存态 = 基准工况 H1 VFRAC=0.30）
- 报告快照：`D:\Projects\aspen-agent\runs\20260804-etoh-flash\model-report.rep`
- Aspen 版本：Aspen Plus 41.0 OLE 服务（V15 引擎）
- 单位集：SI（K / Pa / kmol·sec / kg·sec）
- 物性方法：NRTL-RK（回读确认）
- 最终状态：**H1 BLKSTAT=0、F1 BLKSTAT=0**（全部收敛），物料闭合偏差 **0.000%**

---

## 1. 执行日志（按 A-plan §10 的 9 个编号步骤）

> 每条 = 做了什么 / 参数值 / 返回状态。写操作按发生顺序记录，含全部失败尝试。

### 步骤 1 初始化环境

| # | 操作 | 参数 | 返回 |
|---|---|---|---|
| 1.1 | `status()` | — | `{"connected":true,"app":"Aspen Plus 41.0 OLE 服务","engine":"stopped","ready":false}` |
| 1.2 | `new_simulation()` | — | `New blank simulation created.`（0 组分、PENG-ROB、空拓扑） |
| 1.3 | `set_unit_set("SI")` | SI | `Unit set changed to SI (K / Pa / mol/sec)` |
| 1.4 | `reinit_and_run()` | — | `Simulation reinitialized and run completed.` |

固定三连按 `mcp-playbook.md` §1.2 执行完毕，无 `Cannot create Blocks node`。

### 步骤 2 加组分 + 定物性

| # | 操作 | 参数 | 返回 |
|---|---|---|---|
| 2.1 | `add_component("ETHANOL")` | — | `Component 'ETHANOL' added, alias=C2H6O-2, dbname=ETHANOL.` |
| 2.2 | `add_component("WATER")` | — | `Component 'WATER' added, alias=H2O, dbname=WATER.` |
| 2.3 | `list_components()` | — | `["WATER","ETHANOL"]` |
| 2.4 | `set_property_method("NRTL-RK")` | — | `Property method set to 'NRTL-RK'.` |
| 2.5 | `get_property_method()` | — | `NRTL-RK` |

**标签核对结论**：实际标签 `ETHANOL` / `WATER`，均未截断，与 A-plan §3 预期一致。
后续全部组成设置使用这两个标签（`pitfalls.md` B-2 已规避）。
Aspen 分子量：ETHANOL 46.069、WATER 18.015（由 FEED MW=23.8165 反核对一致）。

### 步骤 3 BIP 核查

见 §3 专节。结论：**数据库回归值（非 UNIFAC 估算）**，但数值本身未能程序化读出，
已按 `engineering-rules.md` §1.3 格式记录未确认项。

### 步骤 4 建进料流股 FEED

**第一次尝试（失败，已排除）**

| # | 操作 | 参数 | 返回 |
|---|---|---|---|
| 4.1 | `add_stream("FEED")` | — | `Stream 'FEED' added` |
| 4.2 | `set_stream_param("FEED","TEMP",298.15)` | 298.15 K | `Stream 'FEED' TEMP = 298.15 (unit set: SI)` |
| 4.3 | `set_stream_param("FEED","PRES",101325)` | 101325 Pa | `Stream 'FEED' PRES = 101325.0 (unit set: SI)` |
| 4.4 | `set_stream_composition_batch("FEED",{"ETHANOL":0.40,"WATER":0.60},basis="MASS-FRAC",total_flow=0.27778)` | A-plan SI 列原值 | `Stream 'FEED' (MASS-FRAC): ETHANOL=0.4, WATER=0.6` |

跑 `reinit_and_run()` 后 **所有结果为 null**，`H1 BLKSTAT=None`。
`explore("Data\Streams\FEED\Input")` 抽查发现：

- `BASIS\MIXED = "MOLE-FLOW"`（**未被切到 MASS-FRAC**）
- `FLOWBASE\MIXED = "MOLE"`
- `FLOW\MIXED\ETHANOL = 0.4`、`FLOW\MIXED\WATER = 0.6`（写进去了）
- `TOTFLOW\MIXED = null`（**total_flow 参数被静默丢弃**）→ 总流量未定义 → 无结果

即 `set_stream_composition_batch` 的 `basis` 与 `total_flow` 两个参数**均未落到 COM 树**，
返回消息只是回显入参。这是本轮最大的坑，详见 §6 与 §7。

**修复过程中的失败尝试（全部保留原始返回，用于归因）**

| # | 尝试 | 返回 / 结果 |
|---|---|---|
| 4.5 | `set_value(BASIS\MIXED,"MASS-FRAC")` + `set_value(FLOWBASE\MIXED,"MASS")` + `set_value(TOTFLOW\MIXED,0.27778)` → `reinit_and_run()` | `H1 BLKSTAT=0`，但 `FEED RES_MASSFLOW = 6.61574987 kg/s`、`RES_MOLEFLOW = 0.27778 kmol/s`。→ **0.27778 被当成 kmol/sec**（`TOTFLOW` 节点 unit 恒为 `kmol/sec`，`FLOWBASE=MASS` 不被引擎采纳）。组成正确（`mole_frac_liq` ETHANOL=0.206790 / WATER=0.793210，与 40/60 wt% 换算一致），说明 `BASIS=MASS-FRAC` 生效、只有总流量基准不生效。 |
| 4.6 | `set_value(TOTFLOW\MIXED, 0.27778, unit="kg/sec")` → `reinit_and_run()` | `RES_MASSFLOW` 仍 `6.61574987`。unit 参数无效（与 `mcp-playbook.md` §1.1「不要依赖 unit 参数」一致）。 |
| 4.7 | `set_stream_param("FEED","TOTAL",0.27778,basis="MASS")` | 原文：`Warning: could not set BASIS: OK`。跑后 `RES_MASSFLOW` 仍 `6.61574987`。 |
| 4.8 | 改走 MASS-FLOW：`set_stream_composition_batch(...,basis="MASS-FLOW")` + `set_value(BASIS\MIXED,"MASS-FLOW")` + `set_value(TOTFLOW\MIXED,0)` → `reinit_and_run()` | 原文：`H1  BLKSTAT=2 (not converged)  PER_ERROR=1  PROPSTAT=0  BLKMSG=ZERO FEED TO BLOCK`。→ 证明 **TOTFLOW 一旦有值就覆盖组分流量**。 |
| 4.9 | `set_value(TOTFLOW\MIXED, 0.27778)`（保持 BASIS=MASS-FLOW）→ `reinit_and_run()` | `RES_MASSFLOW` 仍 `6.61574987`。确认 TOTFLOW 永远按 kmol/sec 解释。 |
| 4.10 | 试图把 TOTFLOW 清空：`set_value(TOTFLOW\MIXED, "null")` | 原文：`2 validation errors for call[set_value] value.str Input should be a valid string ... value.float Input should be a valid number` |
| 4.11 | 试图把 TOTFLOW 清空：`set_value(TOTFLOW\MIXED, " ")` | 原文：`Error: (-2147352567, '发生意外。', (2004, 'Aspen Plus 41.0 OLE 服务', '所提供参数的类型无效。', None, 0, 0), None)` |

**结论**：`TOTFLOW` 一旦写入即无法通过 MCP 置空 → 只能重建流股。

**最终成功做法（保留）**

| # | 操作 | 参数 | 返回 |
|---|---|---|---|
| 4.12 | `disconnect("FEED")` | — | `Stream 'FEED' disconnected from H1:F(IN), and removed` |
| 4.13 | `add_stream("FEED")` | — | `Stream 'FEED' added` |
| 4.14 | `connect_port("H1","F(IN)","FEED")` | — | `Stream 'FEED' connected to H1:F(IN)` |
| 4.15 | `set_stream_param("FEED","TEMP",298.15)` | **298.15 K**（A-plan SI 列） | OK |
| 4.16 | `set_stream_param("FEED","PRES",101325)` | **101325 Pa**（A-plan SI 列） | OK |
| 4.17 | `set_stream_composition_batch("FEED",{"ETHANOL":0.111112,"WATER":0.166668},basis="MASS-FLOW")` | 见下方**偏离声明** | `Stream 'FEED' (MASS-FLOW): ETHANOL=0.111112, WATER=0.166668` |
| 4.18 | `set_value(\Data\Streams\FEED\Input\BASIS\MIXED,"MASS-FLOW")` | — | OK |
| 4.19 | `set_value(\Data\Streams\FEED\Input\FLOWBASE\MIXED,"MASS")` | — | OK |
| 4.20 | `get_value(\Data\Streams\FEED\Input\TOTFLOW\MIXED)` | — | `None`（确认未污染） |
| 4.21 | `reinit_and_run()` | — | `H1 BLKSTAT=0 (OK) PER_ERROR=0 PROPSTAT=0` |

> **偏离声明（必须让 designer / checker 看到）**
> A-plan §6「进料流股」给的 SI 值是「总质量流 0.27778 kg/s + 质量分率 0.40/0.60」。
> 由于 MCP 的 `MASS-FRAC + total_flow` 通路在本环境不可用（4.4–4.11 六次失败），
> 我改用等价的 **组分质量流** 输入：
> `ETHANOL = 0.40 × 0.27778 = 0.111112 kg/s`、`WATER = 0.60 × 0.27778 = 0.166668 kg/s`。
> 这两个数是 **A-plan SI 列两个已给数值的乘积**，**不含任何单位换算**（未做 /3600、+273.15 之类），
> 因此不触发「modeler 不得现场换算」铁律；但它确实是 A-plan 未直接列出的数，故在此显式声明。
> **建议 A-plan 下一版在进料表中直接补一行「组分质量流（SI）」**，彻底消除这个缺口。
> 回代验证（下表）证明输入完全等价于 A-plan 的意图。

**步骤 4 核对结果（A-plan 要求的三项）**

| 核对项 | A-plan 期望 | Aspen 实际 | 判定 |
|---|---|---|---|
| FEED FLASH FAILURE | 无 | 无（`PER_ERROR=0`、`PROPSTAT=0`，报告文件无 WARNING/ERROR） | ✅ |
| 进料全液 | VFRAC = 0 | `RES_VFRAC = 0.0`，`comptype = "LIQUID"` | ✅ |
| 总质量流 | 0.27778 kg/s（1000 kg/h） | `RES_MASSFLOW = 0.27778 kg/s` = 1000.008 kg/h | ✅ |
| 质量分率（回代验证） | 0.40 / 0.60 | `MASSFRAC ETHANOL = 0.4`、`WATER = 0.6`（精确） | ✅ |
| 摩尔流（A-plan 核对值 41.99 kmol/h） | 41.99 kmol/h | `RES_MOLEFLOW = 0.0116633382 kmol/s` = **41.988 kmol/h** | ✅ |
| 摩尔分率（A-plan 核对值 0.207/0.793） | 0.207 / 0.793 | ETHANOL **0.206790** / WATER **0.793210** | ✅ |
| 平均分子量 | — | 23.8165 | — |
| T / P | 298.15 K / 101325 Pa | 298.15 K / 101325.0 Pa | ✅ |

### 步骤 5 建 H1（HEATER）

| # | 操作 | 参数 | 返回 |
|---|---|---|---|
| 5.1 | `add_block("H1","HEATER")` | — | `Block 'H1' (type=HEATER) added` |
| 5.2 | `connect_port("H1","F(IN)","FEED")` | — | OK |
| 5.3 | `add_stream("HOT")` + `connect_port("H1","P(OUT)","HOT")` | — | OK |
| 5.4 | `set_param("H1","PRES",101325)` | **101325 Pa** | `Set H1.PRES = 101325.0 (unit set: SI)` |
| 5.5 | `set_param("H1","VFRAC",0.3)` | **0.30** | `Set H1.VFRAC = 0.3 (unit set: SI)` |
| 5.6 | `reinit_and_run()` | — | `H1 BLKSTAT=0 (OK)` **但结果错**：`HOT RES_TEMP=298.15`、`RES_VFRAC=0.0`、`QCALC=0.0` |

**第二个坑**：`get_block("H1")` 显示 `PRES=101325.0`、`VFRAC=0.3` 都写进去了，
但 `SPEC_OPT = "TP"`（HEATER 的 Flash Type 选择器仍是「温度/压力」）。
TEMP 为 null，于是引擎退化为 duty=0 的等焓等压计算 → 出口 = 进料。
这是 **「BLKSTAT=0 的错误结果」**（`pitfalls.md` B-1 同类型的静默错），
只靠 BLKSTAT 完全看不出来，必须核对 `HOT` 的 VFRAC。

| # | 修复 | 参数 | 返回 |
|---|---|---|---|
| 5.7 | `set_value("\Data\Blocks\H1\Input\SPEC_OPT","PV")` | PV = Pressure / Vapor-fraction | `Set \Data\Blocks\H1\Input\SPEC_OPT = PV` |
| 5.8 | `reinit_and_run()` | — | `H1 BLKSTAT=0 (OK) PER_ERROR=0 PROPSTAT=0` |

**步骤 5 核对结果**

| 核对项 | A-plan 期望 | Aspen 实际 | 判定 |
|---|---|---|---|
| H1 收敛 | BLKSTAT=0 | 0 | ✅ |
| HOT 两相、摩尔汽化分率 | ≈0.30 | `RES_VFRAC = 0.3`（精确命中规格） | ✅ |
| H1 出口温度 | ≈84 °C | `RES_TEMP = 359.284717 K` = **86.13 °C**（偏高 2.1 K） | ✅ 量级一致 |
| H1 热负荷 | ≈0.2 MW（200 kW） | `QCALC = 205038.18 W` = **205.04 kW** | ✅ 偏差 +2.5% |

数量级完全对得上，**无需回查单位/组成**。

### 步骤 6 建 F1（FLASH2）并接产品

| # | 操作 | 参数 | 返回 |
|---|---|---|---|
| 6.1 | `add_block("F1","FLASH2")` | — | `Block 'F1' (type=FLASH2) added` |
| 6.2 | `list_block_ports("F1")` | — | `F(IN), HS(IN), V(OUT), L(OUT), WD(OUT), HS(OUT)` 全空 |
| 6.3 | `connect_port("F1","F(IN)","HOT")` | — | OK |
| 6.4 | `add_stream("VAPOR")` / `add_stream("LIQUID")` | — | OK |
| 6.5 | `connect_port("F1","V(OUT)","VAPOR")` | — | OK |
| 6.6 | `connect_port("F1","L(OUT)","LIQUID")` | — | OK |
| 6.7 | `set_param("F1","PRES",101325)` | **101325 Pa** | `Set F1.PRES = 101325.0` |
| 6.8 | `set_param("F1","DUTY",0)` | **0 W** | `Set F1.DUTY = 0.0` |
| 6.9 | `get_value("\Data\Blocks\F1\Input\SPEC_OPT")` | — | `TP` ← 同 H1 的坑，**预防性核查** |
| 6.10 | `set_value("\Data\Blocks\F1\Input\SPEC_OPT","PQ")` | PQ = Pressure / Duty | `Set ... = PQ` |
| 6.11 | `reinit_and_run()` | — | `F1 BLKSTAT=0 (OK)` / `H1 BLKSTAT=0 (OK)` |
| 6.12 | `flowsheet_topology()` | — | `(feed)--[FEED]-->H1 --[HOT]--> F1 --[VAPOR]-->(product) / --[LIQUID]-->(product)`，无悬空 |

**步骤 6 核对结果（基准工况 VFRAC=0.30）**

| 核对项 | A-plan 期望 | Aspen 实际 | 判定 |
|---|---|---|---|
| F1 收敛 | BLKSTAT=0 | 0 | ✅ |
| 富集方向 | VAPOR 富乙醇 / LIQUID 富水 | VAPOR 44.83 mol% EtOH vs FEED 20.68 vs LIQUID 10.33 | ✅ 方向正确 |
| VAPOR 乙醇摩尔分率 | ≈44 mol%（±5） | **44.83 mol%** | ✅ 偏差 +0.83 |
| VAPOR 乙醇质量分率 | ≈67 wt% | **67.51 wt%** | ✅ |
| **硬判据：< 89.4 mol% 共沸上限** | 必须 < 89.4 | **44.83 mol%**（全扫描最高点 51.90 mol% @VFRAC=0.10） | ✅ **通过，无需切 UNIQUAC-RK** |
| LIQUID 乙醇摩尔分率 | ≈10.7 mol%（±3） | **10.33 mol%** | ✅ 偏差 −0.37 |
| LIQUID 乙醇质量分率 | ≈23.5 wt% | **22.75 wt%** | ✅ |
| VAPOR 流量 | ≈383 kg/h（±10%） | **385.35 kg/h** | ✅ 偏差 +0.6% |
| LIQUID 流量 | ≈617 kg/h（±10%） | **614.66 kg/h** | ✅ 偏差 −0.4% |
| 气液同温同压（绝热相分离） | 与 HOT 同 T/P | 两股均 359.2847 K / 101325 Pa | ✅ |

### 步骤 7 物料平衡闭合校核 → 见 §4

### 步骤 8 VFRAC 扫描 → 见 §5

### 步骤 9 保存

| # | 操作 | 返回 |
|---|---|---|
| 9.1 | 恢复 `set_param("H1","VFRAC",0.3)` → `reinit_and_run()` | `F1 BLKSTAT=0` / `H1 BLKSTAT=0`；`VAPOR MOLEFRAC ETHANOL = 0.448307941`、`RES_MASSFLOW = 0.107041465` —— 与首次基准结果**逐位一致**，扫描无残留污染 |
| 9.2 | `block_status("H1")` | `{"blkstat":0,"per_error":0,"propstat":0,"b_k":1,"status":"ok (converged)"}` |
| 9.3 | `block_status("F1")` | `{"blkstat":0,"per_error":0,"propstat":0,"b_k":1,"status":"ok (converged)"}` |
| 9.4 | `save("D:\Projects\aspen-agent\runs\20260804-etoh-flash\model.apw")` | `Saved to D:\Projects\aspen-agent\runs\20260804-etoh-flash\model.apw` |
| 9.5 | `export_report_file(".\model-report.rep")` | `Report exported`（用于 §3 BIP 与 §4 闭合的独立佐证；**未整份读入**，仅 Grep 抽取） |

保存态 = **基准工况 H1 VFRAC=0.30**，符合任务要求。

---

## 2. 最终模型配置摘要（交棒 E 阶段 checker）

| 项 | 值 |
|---|---|
| 组分 | WATER, ETHANOL（Aspen 标签，未截断；alias H2O / C2H6O-2） |
| 物性方法 | NRTL-RK（报告文件确认：`PROPERTY OPTION SET: NRTL-RK  RENON (NRTL) / REDLICH-KWONG`） |
| 单位集 | SI |
| 拓扑 | `(feed) FEED → H1(HEATER) → HOT → F1(FLASH2) → VAPOR / LIQUID` |
| FEED | TEMP=298.15 K；PRES=101325 Pa；BASIS=MASS-FLOW；ETHANOL=0.111112 kg/s、WATER=0.166668 kg/s；TOTFLOW=（未设） |
| H1 | SPEC_OPT=**PV**；PRES=101325 Pa；VFRAC=0.30 |
| F1 | SPEC_OPT=**PQ**；PRES=101325 Pa；DUTY=0 W |
| 压力剖面 | FEED / HOT / VAPOR / LIQUID / F1 全部 101325 Pa，单调无倒挂（与 A-plan §7 一致） |
| 反应 / 循环 / 固体 / 电解质 | 均无 |
| 塔模块 | **无**（用户明确排除精馏塔，本阶段未建任何塔） |

---

## 3. BIP 核查结论（A-plan §10 步骤 3 下沉项）

### 3.1 已确认项

`explore("Data\Properties\Parameters")` 返回的 `Binary Interaction` 下存在以下参数集：
`ANDKIJ-1, ANDMIJ-1, HENRY-1, MLQKIJ-1, MUKIJ-1, MULIJ-1, **NRTL-1**, RKTKIJ-1`。
即 **NRTL-1 二元参数集已自动生成**（NRTL-RK 方法所需的活度系数参数集存在，不是空缺）。

`explore("Data\Properties\Parameters\Binary Interaction\NRTL-1")` 读到的来源标志位：

| 节点 | 值 | 含义 |
|---|---|---|
| `Input\ESTIMATE` | **"NO"** | **未启用物性估算**（即未走 UNIFAC 估算路径） |
| `CC Nodes\ISUSER` | **0** | 非用户手工录入 |
| `CC Nodes\ACCESSDB` | 1 | 允许访问数据库 |
| `CC Nodes\ENTDB` | 1 | 已从数据库取参 |
| `CC Nodes\LBVLE` | **1** | **已加载二元 VLE 参数**（Binary VLE loaded） |
| `CC Nodes\LBLLE` | 0 | 未加载 LLE 参数（二元乙醇-水常压无液液分相，正确） |
| `CC Nodes\LOADDECH` | 0 | 未从 DECHEMA 加载 |
| `Input\NEL` | 12 | 12 个参数位（aij, aji, bij, bji, cij, dij, eij, eji, fij, fji, Tlower, Tupper） |
| `Input\LABEL1..12` | aij / aji / bij / bji / cij / dij / eij / eji / fij / fji / Tlower / Tupper | 标准 NRTL 参数标签，`TUNITLABEL="K"` |

**结论 1（来源判定）**：`ESTIMATE="NO"` + `LBVLE=1` + `ISUSER=0` 三者联合表明，
ETHANOL/WATER 的 NRTL 参数来自 **Aspen 内置数据库的回归值（APV VLE 二元参数库）**，
**不是 UNIFAC 估算值**。→ **A-plan §11 假设 #6 成立**，结论不必因 BIP 降级。

### 3.2 功能性交叉验证（比标志位更硬的证据）

用模型算出的汽液平衡对与常压乙醇-水公开 VLE 数据对比（同一平衡级，1 atm）：

| 液相乙醇 x (mol) | 文献 T (°C) | 模型 T (°C) | 文献 y (mol) | 模型 y (mol) | 说明 |
|---|---|---|---|---|---|
| 0.1033 | ≈86.5 | **86.13** | ≈0.448 | **0.4483** | VFRAC=0.30 工况的平衡对 |
| 0.1721 | ≈83.8 | **83.59** | ≈0.516 | **0.5190** | VFRAC=0.10 工况的平衡对 |

两点的 T 与 y 均与常压乙醇-水实测 VLE 高度吻合（T 偏差 <0.4 K，y 偏差 <0.004）。
**这排除了「BIP 缺失被静默取 0」和「BIP 为粗估值」两种失效模式**
（若 BIP 取 0，乙醇-水会被算成近理想溶液，y 会显著偏低且无共沸；实际结果与文献一致）。

另外，全扫描区间气相乙醇 **35.50 ~ 51.90 mol%**，全部远低于 89.4 mol% 共沸上限，
且随 VFRAC 单调变化、无越界，符合活度系数模型对该体系的正确物理行为
（`pitfalls.md` B-4 描述的「EOS 把共沸体系算成易分离」现象**未出现**）。

### 3.3 未确认项（按 `engineering-rules.md` §1.3 格式记录，不沉默略过）

| # | 未确认项 | 尝试过的路径与原始返回 | 对本 run 结论的影响 | 建议人工核查位置 |
|---|---|---|---|---|
| BIP-1 | ETHANOL/WATER NRTL 的**具体数值** aij/aji/bij/bji/α | ① `explore("Data\Properties\Parameters\Binary Interaction\NRTL-1\Input\VAL1")` → `{"name":"VAL1","value":null,"children":[{"name":"NRTL","value":null}]}`；② `explore(...\Input\VAL1\NRTL)` → `{"name":"NRTL","value":null,"unit":""}`（无组分对子节点）；③ `get_value("...\Input\VAL1\NRTL\ETHANOL WATER")` → `Node not found`；④ `export_report_file` + Grep `NRTL|BINARY|VLE-|Source` → 报告仅含 `PROPERTY OPTION SET: NRTL-RK RENON (NRTL) / REDLICH-KWONG`，**不含二元参数表** | **无实质影响**：来源标志位（§3.1）与功能性 VLE 验证（§3.2）已双重确认参数为数据库回归值且数值正确。数值本身读不到，只影响「能否在报告里逐位列出 aij/bij」这一形式要求。 | Aspen GUI：`Properties → Parameters → Binary Interaction → NRTL-1`，查 `Source` 列应为 `APV**  VLE-IG` 或 `VLE-RK`（而非 `R-PCES`/`UNIFAC`） |
| BIP-2 | 参数的**温度适用区间** Tlower / Tupper | 同上，`LABEL11/LABEL12` 标签存在但 `VAL11/VAL12` 值为 null | 本 run 全部工况 T ∈ [356.7, 362.6] K，落在乙醇-水常压 VLE 回归数据的典型区间（~340–373 K）内，**外推风险极低** | 同上界面，看 `Tlower/Tupper` 两列 |
| BIP-3 | 气相缔合修正 | 未启用（A-plan §4 明确不需要 HOC/维里） | 常压下影响可忽略（A-plan 已判定）；若后续把压力提高到数 bar 需重评 | — |

**MCP 能力缺口备注**：`mcp-playbook.md` §5 已记录「无 BIP 读写工具」。本轮实测补充：
`explore` 能读到 **参数集是否存在 + 来源标志位（ESTIMATE / ISUSER / LBVLE / ENTDB）**，
但 **读不到 VAL1..VAL12 的组分对数值**（父节点与 `NRTL` 子节点均返回 null，无组分对索引子节点）。
建议把「来源标志位法 + 功能性 VLE 交叉验证」写进 playbook 作为 BIP 核查的标准替代手法。

---

## 4. 物料平衡闭合校核（A-plan §10 步骤 7 下沉项 / §9 指标 #5）

基准工况 VFRAC=0.30。全部数值取自 Aspen COM 节点
（`\Data\Streams\{N}\Output\MASSFLOW\MIXED\{comp}` 与 `RES_MASSFLOW`，单位 kg/s），
kg/h 列 = kg/s × 3600（仅为报告可读性，不参与判定）。

### 4.1 总质量闭合

| 项 | kg/s | kg/h |
|---|---|---|
| Σ入 = FEED | 0.27778000 | 1000.008 |
| 出 = VAPOR | 0.10704147 | 385.349 |
| 出 = LIQUID | 0.17073854 | 614.659 |
| **Σ出** | **0.27778000** | **1000.008** |
| 绝对偏差 | 0.00000000 | 0.000 |
| **相对偏差** | **0.000 %** | — |

### 4.2 组分质量闭合

| 组分 | 入 FEED (kg/s) | 出 VAPOR (kg/s) | 出 LIQUID (kg/s) | Σ出 (kg/s) | 偏差 (kg/s) | 相对偏差 |
|---|---|---|---|---|---|---|
| ETHANOL | 0.111112000 | 0.0722652848 | 0.0388467152 | 0.1111120000 | 0.0 | **0.000 %** |
| WATER | 0.166668000 | 0.0347761799 | 0.1318918200 | 0.1666679999 | −1e-10 | **0.000 %** |
| **合计** | 0.277780000 | 0.1070414647 | 0.1707385352 | 0.2777799999 | −1e-10 | **0.000 %** |

工程单位对照（×3600）：ETHANOL 入 400.003 kg/h → 出 260.155 + 139.848 = **400.003 kg/h**；
WATER 入 600.005 kg/h → 出 125.194 + 474.811 = **600.005 kg/h**。
（A-plan 名义值 400 / 600 kg/h；+0.0008% 的差来自 A-plan SI 列 0.27778 对 1000/3600 的四舍五入，非模型误差。）

### 4.3 摩尔闭合

| 项 | kmol/s | kmol/h |
|---|---|---|
| FEED | 0.0116633382 | 41.988 |
| VAPOR | 0.0034990015 | 12.596 |
| LIQUID | 0.0081643368 | 29.392 |
| Σ出 | 0.0116633383 | 41.988 |
| 相对偏差 | **0.000 %** | — |

摩尔汽化分率核对：0.0034990015 / 0.0116633382 = **0.300000** = H1 VFRAC 规格，精确命中。

### 4.4 Aspen 自算平衡（独立佐证，取自 `model-report.rep`）

```
BLOCK: F1  MODEL: FLASH2      TOTAL BALANCE
   MOLE(KMOL/SEC)   0.116633E-01 → 0.116633E-01   RELATIVE DIFF. 0.148733E-15
   MASS(KG/SEC  )   0.277780     → 0.277780       RELATIVE DIFF. 0.00000
BLOCK: H1  MODEL: HEATER      TOTAL BALANCE
   MOLE(KMOL/SEC)   0.116633E-01 → 0.116633E-01   RELATIVE DIFF. 0.00000
   MASS(KG/SEC  )   0.277780     → 0.277780       RELATIVE DIFF. 0.00000
```

**门禁判定**：要求 ≤ ±0.5%，实际 **0.000%**（Aspen 自算相对差 1.5e-16 ~ 0，机器精度级）。
总质量、分组分质量、摩尔三项全部闭合。**✅ 通过**（`pitfalls.md` B-5 已规避：拓扑无悬空流股）。

---

## 5. VFRAC 扫描结果表（A-plan §10 步骤 8 / §6 扫描表 — 核心交付）

固定：F1 PRES=101325 Pa、DUTY=0 W；FEED 298.15 K / 101325 Pa / 0.27778 kg/s / 40 wt% 乙醇。
仅改 H1 VFRAC。**每点均 `reinit_and_run()`**（遵 `mcp-playbook.md` §1.6 / `pitfalls.md` C-2：改规格必 reinit）。
**5 个扫描点 + 基准复现点，H1 与 F1 全部 BLKSTAT=0，无一次未收敛。**

### 5.1 交付主表

| 点 | H1 VFRAC | 闪蒸温度 (K) | 闪蒸温度 (°C) | H1 duty (kW) | VAPOR 质量流 (kg/h) | VAPOR 乙醇 (mol%) | VAPOR 乙醇 (wt%) | LIQUID 质量流 (kg/h) | LIQUID 乙醇 (mol%) | LIQUID 乙醇 (wt%) |
|---|---|---|---|---|---|---|---|---|---|---|
| P1 | 0.10 | 356.7357 | 83.59 | 107.86 | 136.77 | **51.90** | **73.40** | 863.23 | 17.21 | 34.71 |
| P2 | 0.20 | 357.8250 | 84.67 | 156.18 | 266.40 | **48.86** | **70.96** | 733.61 | 13.63 | 28.76 |
| **P3（基准）** | **0.30** | **359.2847** | **86.13** | **205.04** | **385.35** | **44.83** | **67.51** | **614.66** | **10.33** | **22.75** |
| P4 | 0.40 | 360.9597 | 87.81 | 254.21 | 491.71 | **40.14** | **63.17** | 508.29 | 7.70 | 17.59 |
| P5 | 0.50 | 362.5723 | 89.42 | 303.35 | 587.32 | **35.50** | **58.47** | 412.69 | 5.85 | 13.72 |

原始 SI 值（供 checker 复核，kg/s；kg/h = ×3600）：

| 点 | VAPOR kg/s | LIQUID kg/s | Σ kg/s | 闭合 | H1 QCALC (W) | VAPOR y_EtOH | VAPOR wt_EtOH | LIQUID x_EtOH | LIQUID wt_EtOH |
|---|---|---|---|---|---|---|---|---|---|
| P1 | 0.0379926267 | 0.239787373 | 0.277780000 | 0.000% | 107860.931 | 0.518972211 | 0.733967477 | 0.172102770 | 0.347085197 |
| P2 | 0.0739993602 | 0.203780640 | 0.277780000 | 0.000% | 156181.629 | 0.488625479 | 0.709594389 | 0.136330772 | 0.287576235 |
| P3 | 0.1070414650 | 0.170738535 | 0.277780000 | 0.000% | 205038.180 | 0.448307941 | 0.675114872 | 0.103281902 | 0.227521661 |
| P4 | 0.1365870420 | 0.141192958 | 0.277780000 | 0.000% | 254212.462 | 0.401433694 | 0.631678862 | 0.077027061 | 0.175878832 |
| P5 | 0.1631431620 | 0.114636838 | 0.277780000 | 0.000% | 303354.015 | 0.355036203 | 0.584663257 | 0.058543225 | 0.137200116 |

**每一个扫描点的总质量闭合均为 0.000%。**

### 5.2 趋势与预期值对比

| 点 | A-plan 预期气相乙醇 | 实际 | 差（mol%） | 允差 ±5 mol% |
|---|---|---|---|---|
| P1 | ≈49–50 mol% | 51.90 | +2.4（对 49.5） | ✅ |
| P2 | ≈47 mol% | 48.86 | +1.9 | ✅ |
| P3 | ≈44 mol% | 44.83 | +0.8 | ✅ |
| P4 | ≈41 mol% | 40.14 | −0.9 | ✅ |
| P5 | ≈38 mol% | 35.50 | −2.5 | ✅ |

**趋势结论（一句话）**：VFRAC 由 0.10 → 0.50，气相量由 137 → 587 kg/h **单调上升**，
气相乙醇由 51.90 → 35.50 mol%（73.40 → 58.47 wt%）**单调下降**，
闪蒸温度由 83.59 → 89.42 °C 单调上升，加热负荷由 108 → 303 kW 单调上升 ——
**「越蒸越多、越蒸越稀」，与 A-plan §6 的趋势规律完全一致，无非单调点、无反常。**

### 5.3 可达性复核（对照 A-plan §9）

- 全扫描区间气相乙醇 **35.50 ~ 51.90 mol%**，A-plan 预判区间「38–50 mol%」，
  实际略宽（低端更低、高端更高），但**量级完全一致**。
- **硬判据通过**：最高点 51.90 mol% ≪ **89.4 mol% 常压共沸上限**，
  也低于 A-plan 给的「泡点极限约 53 mol%」——且 P1（VFRAC=0.10）已接近该泡点极限，
  说明模型在物理上自洽（VFRAC→0 时应趋近 53 mol%）。
- **未出现 ≥89 mol% 的越界结果 → 无需按 A-plan §4 切换 UNIQUAC-RK / WILSON。**
- 用户问题「能富集到多少」的答案：**单级常压闪蒸气相乙醇最高约 52 mol%（73 wt%）**，
  且此时气相量仅 137 kg/h（占进料 13.7%）；要兼顾产量则更稀。想更高必须多级精馏。
- 温位校核（供 E 阶段）：最高闪蒸温度 89.42 °C + ΔTmin 8 K = 97.4 °C < LP 蒸汽 144 °C，
  **全扫描区间 LP 蒸汽均可行**。

---

## 6. 归因表（每轮一行，含全部失败尝试）

| 轮次 | 改了什么 | 结果（BLKSTAT / 关键数值 / 原始报错） | 结论 |
|---|---|---|---|
| C-1 | 初始化三连 `new_simulation` → `set_unit_set("SI")` → `reinit_and_run` | 无报错；节点树可用 | **保留**。`pitfalls.md` B-3 已规避 |
| C-2 | 加 ETHANOL / WATER，`set_property_method("NRTL-RK")` | `list_components()` = `["WATER","ETHANOL"]`（未截断）；`get_property_method()` = `NRTL-RK` | **保留**。标签核对完成 |
| C-3 | FEED 用 `set_stream_composition_batch(basis="MASS-FRAC", total_flow=0.27778)` | 全部结果 null，`H1 BLKSTAT=None`；抽查 `BASIS=MOLE-FLOW`、`TOTFLOW=null` | **排除**。MCP 该工具的 `basis` / `total_flow` 参数未落到 COM 树（返回消息只回显入参）。**不能信任其返回消息，必须 get_value 回读** |
| C-4 | `set_value` 强写 `BASIS=MASS-FRAC` + `FLOWBASE=MASS` + `TOTFLOW=0.27778` | `BLKSTAT=0` 但 `FEED RES_MASSFLOW=6.6157 kg/s`（0.27778 被当 kmol/s，差 23.8 倍 = MW） | **排除**。`TOTFLOW` 节点 unit 恒 `kmol/sec`，`FLOWBASE=MASS` 不被引擎采纳。**这是典型「BLKSTAT=0 的错误结果」，只看状态位查不出** |
| C-5 | `set_value(TOTFLOW, 0.27778, unit="kg/sec")` | `RES_MASSFLOW` 仍 6.6157 | **排除**。`unit` 参数无效，印证 playbook §1.1「不要依赖 unit 参数」 |
| C-6 | `set_stream_param("FEED","TOTAL",0.27778,basis="MASS")` | 原文 `Warning: could not set BASIS: OK`；`RES_MASSFLOW` 仍 6.6157 | **排除**。工具的 `basis` 参数同样不生效 |
| C-7 | 改 MASS-FLOW 组分流 + `TOTFLOW=0` | `H1 BLKSTAT=2 PER_ERROR=1 BLKMSG=ZERO FEED TO BLOCK` | **排除**，但**信息量最大**：证明 `TOTFLOW` 有值时会覆盖组分流量 → 必须让 TOTFLOW 为 null |
| C-8 | 试图置空 TOTFLOW（`"null"` / `" "`） | `2 validation errors for call[set_value]` / `Error: (-2147352567, '发生意外。', (2004, 'Aspen Plus 41.0 OLE 服务', '所提供参数的类型无效。', None, 0, 0), None)` | **排除**。MCP 无法把已写入的数值节点置空 → 唯一出路是重建流股 |
| C-9 | `disconnect("FEED")` 重建流股；`BASIS=MASS-FLOW` + 组分质量流 0.111112 / 0.166668 kg/s；TOTFLOW 保持 null | `H1 BLKSTAT=0`；`RES_MASSFLOW=0.27778 kg/s`、`RES_MOLEFLOW=0.0116633 kmol/s`（41.988 kmol/h）、`MASSFRAC` 精确 0.4/0.6、`x_EtOH=0.206790`、VFRAC=0、LIQUID | **保留**。与 A-plan 摩尔核对值（41.99 kmol/h、0.207/0.793）逐项吻合。见 §1 步骤 4 的偏离声明 |
| C-10 | H1 只设 `PRES=101325` + `VFRAC=0.30`（未动 SPEC_OPT） | `H1 BLKSTAT=0`，但 `HOT RES_TEMP=298.15`、`RES_VFRAC=0.0`、`QCALC=0` —— 出口 = 进料 | **排除**。根因：`SPEC_OPT` 仍为默认 `"TP"`，TEMP 为 null → 退化成 duty=0 等焓计算。**第二个「BLKSTAT=0 的错误结果」** |
| C-11 | `set_value("\Data\Blocks\H1\Input\SPEC_OPT","PV")` | `H1 BLKSTAT=0`；`HOT VFRAC=0.300`、`T=359.2847 K (86.13 °C)`、`QCALC=205038 W (205.04 kW)` | **保留**。与 A-plan 预期（≈84 °C、≈200 kW）量级一致，无需回查单位 |
| C-12 | 建 F1（FLASH2）+ `PRES=101325` + `DUTY=0`；**预防性**先 `get_value(SPEC_OPT)` 得 `TP` → 改 `PQ` | `F1 BLKSTAT=0` / `H1 BLKSTAT=0`；VAPOR 44.83 mol% EtOH / 385.35 kg/h，LIQUID 10.33 mol% / 614.66 kg/h | **保留**。吸取 C-10 教训一次到位，未产生失败轮次 |
| C-13 | 物料闭合校核（读组分质量流 + 报告文件交叉） | 总质量 / ETHANOL / WATER / 摩尔四项闭合均 **0.000%**；Aspen 自算 RELATIVE DIFF = 0 ~ 1.5e-16 | **保留**。门禁 ≤±0.5% ✅ |
| C-14 | VFRAC 扫描 0.10 / 0.20 / 0.30 / 0.40 / 0.50，每点 `reinit_and_run()` | 5 点 × 2 块 = 10 个 BLKSTAT 全 0；气相乙醇 51.90 → 35.50 mol% 单调降；气相量 137 → 587 kg/h 单调升；每点闭合 0.000% | **保留**。趋势与 A-plan §6 一致，全部落在 ±5 mol% 允差内 |
| C-15 | 恢复 `VFRAC=0.30` → `reinit_and_run()` → `save()` | `y_EtOH=0.448307941`、`VAPOR=0.107041465 kg/s`，与 C-12 首次基准**逐位一致**；`Saved to ...\model.apw` | **保留**。扫描无残留污染，保存态确为基准工况 |

**单变量纪律说明**：C-3~C-9 全部只动「进料流量基准」这一件事；C-10~C-11 只动「H1 规格选择器」；
C-12 只动「新增 F1 及其规格」；C-14 只动「H1 VFRAC」。每轮改完立即 `reinit_and_run()` + 读关键数值。
未出现一次「同时改两类参数」。

---

## 7. 剩余 warning 清单与未决项

### 7.1 `simulation_warnings()` 返回（最终态）

```
["Pressure mismatch: Stream 'HOT' enters 'F1' at 1 bar, block expects ~101325.0 bar",
 "Pressure mismatch: Stream 'FEED' enters 'H1' at 1 bar, block expects ~101325.0 bar"]
```

| # | Warning | 判定 | 依据 |
|---|---|---|---|
| W-1 | 上述两条 "Pressure mismatch ... at 1 bar, block expects ~101325.0 bar" | **误报（MCP 工具单位比较 bug）** | 该工具把流股压力换算成 bar（1.01325 bar）后，直接与块的**内部 SI 值 101325** 比较，还把单位标成 bar。逐点回读确认：FEED / HOT / VAPOR / LIQUID 的 `RES_PRES` 与 H1 / F1 的 `Input\PRES` **全为 101325 Pa**，剖面全等压、无倒挂（`pitfalls.md` C-7 已规避）。`model-report.rep` 全文 Grep `warning\|error\|severe` → **0 命中**，Aspen 自身未报任何压力问题。**建议回写到 `mcp-playbook.md`：`simulation_warnings` 的压力比较为已知误报源。** |

### 7.2 建模过程中出现、已消解的 warning

| # | Warning 原文 | 出现时机 | 现状 |
|---|---|---|---|
| W-2 | `Unconnected stream 'FEED' has TEMP set but no destination` | FEED 已 `connect_port` 到 H1:F(IN) 之后仍报 | **已消解 / 误报**。`list_block_ports("H1")` 显示 `F(IN) -> [FEED]`，`flowsheet_topology()` 显示 `(feed) --[FEED]--> H1`。最终态该 warning 已不再出现 |
| W-3 | `validate_block("H1")` 返回 `Block type = `（空）、`Engine.Ready = False`；`get_block("H1")` 的 `"type":""` | 全程 | **表象问题，不影响功能**。`list_all_blocks()`、`add_block` 返回 `type=HEATER`、端口解析、`model-report.rep` 均确认 `BLOCK: H1  MODEL: HEATER`、`BLOCK: F1  MODEL: FLASH2`。判定为 MCP 读 type 节点的取值路径问题，非模型缺陷 |

### 7.3 `find_incomplete_inputs()` 返回（最终态）

F1 与 H1 各返回一批条目，**全部归在 `.. Other optional params ..` 类别下**
（F1: 146 项、H1: 100 项，均为 AUTO_COMPS / BOUND_TYPE / CHEMISTRY / DEGSUB / DEGSUP / DELT /
DERIV_METHOD / DPPARM / DUTY / ENABLED / EO_* 之类的可选项与 EO/电解质/UI 基础设施节点）。
**Critical 类别为空 → 无必填项缺失。**

> 说明：本轮**故意未调用 `fill_trivial_params()`**。理由：H1 与 F1 的规格由
> `SPEC_OPT` + 2 个数值节点精确定义（H1: PRES+VFRAC / F1: PRES+DUTY），
> 而该工具会给「active-but-unset」参数填缺省值，存在把 `DUTY`（H1）或 `TEMP`（F1）
> 填成 0 从而**制造第三个规格、把已收敛的模型改坏**的风险。
> 由于 Critical 项本来就为空、模型已全收敛，跳过该步骤是净收益。**此为主动决策，非遗漏。**

### 7.4 未决项 / 交棒提醒

| # | 未决项 | 影响 | 建议 |
|---|---|---|---|
| U-1 | ETHANOL/WATER NRTL 的 aij/bij 具体数值未程序化读出（BIP-1、BIP-2） | 无实质影响（来源标志位 + VLE 功能验证已双重确认）；仅形式上无法逐位列出 | 若要把结论升到 B 级，人工在 GUI `Properties → Parameters → Binary Interaction → NRTL-1` 截图 `Source` 列 |
| U-2 | A-plan 进料表缺「组分质量流（SI）」一行，导致 modeler 需做 `0.40 × 0.27778` 的乘法 | 本次已显式声明并回代验证（MASSFRAC 精确 0.4/0.6），无误 | 建议 A-plan 下一版补该行，彻底消除现场计算 |
| U-3 | `SPEC_OPT` 必须显式设置（H1→`PV`、F1→`PQ`），`set_param` 写 PRES/VFRAC/DUTY **不会**自动切换 Flash Type | 若后续有人改规格组合（如改成 TEMP+PRES）而忘记同步 SPEC_OPT，会静默算出错结果 | **强烈建议回写 `mcp-playbook.md` §3**：HEATER / FLASH2 设完 2 个规格后必须 `get_value("\Data\Blocks\{N}\Input\SPEC_OPT")` 核对，并按组合改成 `TP` / `PV` / `PQ` / `TV` / `TQ` / `VQ`。同时建议新增 `pitfalls.md` C-8 条目 |
| U-4 | 结论强度仍为 A-plan §「结论强度声明」的 **C 级（仅趋势参考）** | 单级、无产品硬指标 | 交 E 阶段 checker 按 `engineering-rules.md` §4 的 12 条复核后定级 |
| U-5 | `model-report.rep` 已生成在 run 目录 | 供 checker Grep 用；`pitfalls.md` E-5 提醒**不要整份 Read** | 保留 |

---

## 8. 交棒 E 阶段（checker）要点

1. 模型文件：`D:\Projects\aspen-agent\runs\20260804-etoh-flash\model.apw`，保存态 = **基准工况 VFRAC=0.30**。
   开局先 `status()` 确认打开的就是这个文件（`pitfalls.md` X-5）。
2. 两块全 `BLKSTAT=0`、`PER_ERROR=0`、`PROPSTAT=0`。
3. 物料闭合 **0.000%**（§4），Aspen 自算 RELATIVE DIFF ≈ 0，已达 B 阶段门禁。
4. **重点复核 3 处非常规写入**（均为 `set_value` 绕行，不是 A-plan 原文的接法）：
   `H1.SPEC_OPT="PV"`、`F1.SPEC_OPT="PQ"`、`FEED.BASIS="MASS-FLOW"` + 组分质量流。
5. **重点复核偏离项**：进料用组分质量流 0.111112 / 0.166668 kg/s 代替
   「MASS-FRAC 0.40/0.60 + 总流 0.27778 kg/s」（理由与回代验证见 §1 步骤 4）。
6. 压力剖面全 101325 Pa；`simulation_warnings` 的两条压力告警为**工具误报**（§7.1），不要照抄进报告。
7. 温位：最高闪蒸温度 89.42 °C（VFRAC=0.50）+ ΔTmin 8 K = 97.4 °C < LP 蒸汽 144 °C，可行。
8. 共沸硬判据：气相乙醇全区间 35.50–51.90 mol%，**全部 < 89.4 mol%**，物性行为正确。
9. 无循环、无反应、无 purge 议题（E 阶段第 9 条校核不适用）。
