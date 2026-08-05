---
name: aspen-modeling-methods
description: 真实流程模拟的建模手法合集 —— 分区与断环闭环、简化模块跑物料平衡、逐区严格化与初值传递、规格驱动的三条路径、分层排障 SOP、官方案例库逆向提取配方。当在 Aspen Plus 中搭建流程、修收敛、让指标达标时使用。
---

# aspen-modeling-methods — 建模手法

**给 `aspen-modeler` / `aspen-checker` 用。** 这里是"怎么做"，
工具约束看 `knowledge/mcp-playbook.md`，工程判据看 `knowledge/engineering-rules.md`，
已知陷阱看 `knowledge/pitfalls.md`。

贯穿全篇的一条原则：**每次只引入一个新的不确定性。**
收敛失败时能立刻归因，是长程任务不打转的唯一办法。

---

## 方法 1：分区（Zoning）

把流程按**功能**切成区，每区是一个可独立验证的单元。典型切法：

```
反应区   →  分离区   →  精制区   →  循环/回收区   →  公用工程
```

切分判据：
- 区与区之间只有少量物流穿过（界面窄）
- 每区内部有明确的工艺目标（转化、分离、纯化）
- 循环流股**跨区**时，把它当作区的边界条件（先给固定值）

分区结果由 designer 在 `A-plan.md` 中给出，modeler 照此顺序建。
Aspen 的 Hierarchy 功能是官方分区做法（`How To\Hierarchy.bkp`），
但 MCP 无 Hierarchy 工具，本系统的分区是**建模顺序上的分区**，不是文件结构上的分区。

---

## 方法 2：断环 / 闭环（L3 强制）

循环是收敛失败的头号来源，且会把"结构错"和"循环发散"混在一起。

### 断环（B 阶段）

1. 从 `A-plan.md` 拿循环流股的**估算组成与流量**（designer 按物料平衡算）
2. 把循环流股**建成一条独立进料**，不连回上游
3. 循环的下游出口连到一个"虚拟去处"（不连，作为产物流股即可）
4. 跑通全流程 → 得到无循环状态下的完整物料平衡

此时得到的收益：拓扑对不对、进料条件合不合理、每个模块能不能单独收敛，全部验证完了。

### 闭环（C 阶段最后一步）

1. 断开虚拟进料，把循环流股真正连回上游
2. **必须** `list_tear_streams()` —— Aspen 自动选的撕裂点未必是你以为的那条
3. 对返回的每条 tear 流股 `set_tear_estimate(name, temp=, pres=, total_flow=)`，
   值取**断环阶段实际算出来的结果**（这是断环最大的红利）
4. `reinit_and_run()`
5. 若 WEGSTEIN DIVERGENCE：
   - 先检查 tear 估值是否物理合理（不能为 0、不能与实际差一个数量级）
   - 再检查回路内是否有互锁规格（两个模块都在定同一个量）
   - 再考虑简化回路（临时把回路内的严格塔换回 SEP，收敛后再换回）

### 循环必查项
闭环收敛后**立刻**读循环流股组成，看惰性/微量组分是否无界累积。
若某组分摩尔分数异常高（如 N2 > 30%），说明流程缺 purge 支路 →
返回 `NEEDS_DESIGN_CHANGE`，不要靠调参掩盖。

---

## 方法 3：简化模块跑物料平衡（B 阶段主体）

目的：用**最便宜的模块**把全局物料平衡跑通，验证方案自洽。

| 真实设备 | B 阶段替身 | 怎么给参数 |
|---|---|---|
| 精馏塔 | SEP | 按 `A-plan.md` 的目标分离效果给分割率 |
| 精馏塔（想同时估塔参数） | DSTWU | 给轻/重关键组分回收率 + 回流比 → 读出 Nmin/Rmin/N |
| 吸收塔 | SEP | 给吸收率 |
| 动力学反应器 | RSTOIC | 给转化率（`set_value("\Data\Blocks\R1\Input\FRAC", 0.8)`） |
| 复杂反应（裂解/气化） | RYIELD | 给产物收率分布 |
| 换热器 | HEATER | 给出口温度或负荷 |

**DSTWU 的双重价值**：它既是 B 阶段的替身，又是 C 阶段 RADFRAC 的参数来源。
先跑 DSTWU 拿到 Nmin / Rmin / 推荐 N / 推荐进料级，
再按 `N ≈ 2×Nmin`、`R ≈ 1.2~1.3×Rmin` 配 RADFRAC 的初始规格。
这一步能省掉 C 阶段大量瞎试。

B 阶段出口必须给出：
- 物料平衡表（Σ入 vs Σ出，闭合 %）
- 每个产品流股的关键组分含量 → **指标可达性初判**
- BIP 核查记录（哪些确认了、哪些没确认、影响是什么）

---

## 方法 4：逐区严格化与初值传递（C 阶段主体）

### 顺序
一轮只换**一个区**（L1 可以一次搭完全流程，因为只有 ≤3 个模块）。
换完立刻 `reinit_and_run()` + 逐块 `block_status()`，通过了再动下一区。

### 替换配方

| 从 | 到 | 初值来源 |
|---|---|---|
| SEP | RADFRAC | 用 SEP 的分离结果反推需要的 rr / d；用 DSTWU 结果定 N 与进料级 |
| DSTWU | RADFRAC | 直接抄 N、进料级、rr；`d` 用 DSTWU 的馏出量（记得 ÷3600 转 kmol/sec） |
| RSTOIC | RCSTR / RPLUG | 用 RSTOIC 的出口 T/P/组成作反应器操作条件；先定温运行再改定热 |
| HEATER | HEATX | 用 HEATER 的 duty 作 HEATX 的 duty 起点，再切到 UA 或 LMTD 规格 |

### 初值传递（关键技巧）
`reinit_and_run()` 会清空结果冷启动。所以：

- **换结构 / 换规格后** → `reinit_and_run()`（避免残留初值造成假收敛）
- **小步推进已收敛的模型** → `run()`（继承上一轮结果作初值，收敛快得多）

D 阶段小步逼近规格时尤其要用 `run()`。这两条容易记混，见 `pitfalls.md` C-2。

### 严格塔第一次跑不通的处理顺序
1. 规格是否恰好 2 个？是否互相矛盾（rr 太小 + d 太大）？
2. 进料级是否在中部？（不要放 1 级或 N 级）
3. 塔压是否与进料压匹配（进料压应 ≥ 该级压力）
4. 塔板数是否够（近沸点体系需要更多）
5. 冷凝器类型是否与塔顶实际相态一致（有不凝气必须 PARTIAL-V）
6. 以上都对才怀疑物性方法

---

## 方法 5：规格驱动（D 阶段）—— 三条路径

MCP **没有** Design Spec / Calculator / Optimization 工具。所以"给定指标反求参数"要绕行。

### 第 0 步（不可跳过）：判可达性上限

在调任何参数之前，先回答"这个指标物理上能不能到"：

| 指标类型 | 上限来源 | 怎么判 |
|---|---|---|
| 精馏纯度 | 共沸组成 | 查文献或用 FLASH2 做 T-x 扫描找共沸点。乙醇-水常压共沸 ~89.4 mol% |
| 精馏难度 | 相对挥发度 α | α < 1.05 时普通精馏不可行 |
| 反应转化率 | 平衡转化率 | 用 REQUIL 或 RGIBBS 在同 T/P 下跑一次，得平衡上限 |
| 回收率 | 分离级数极限 | DSTWU 给 Nmin，若要求的回收率使 Nmin 荒谬（>100）则不可达 |
| 冷却温度 | 公用工程温位 | CW 32/42 °C 无法把物流冷到 35 °C 以下 |

**不可达 → 立刻返回 `NEEDS_DESIGN_CHANGE`**，并给出替代工艺建议
（共沸精馏 / 变压精馏 / 分子筛 / 膜 / 多级反应器 + 中间分离 / 换冷剂）。
不要继续调参 —— 这是 D 阶段最重要的判断。

### 路径 ①：sensitivity 扫描 + 插值（首选，无副作用）

```
1  选一个设计变量（如 RADFRAC 的 rr）
2  sensitivity("C1","RR",[1.5,2.0,2.5,3.0], targets=["DIST:ETHANOL"], title="...")
3  看目标随变量的单调关系，线性/对数插值出达标所需的值
4  set_column_specs("C1", rr=<插值值>, d=<原值>) → run()
5  验证。差距 <允差 即达标；否则用新点再插一次（最多 2 次）
```
优点：不写任何持久规格，失败无残留。**默认走这条。**

### 路径 ②：set_value 写塔内规格

RADFRAC 支持塔内规格（Column Specifications），可用 `set_value` 写。
路径需先 `deep_probe("C1")` / `explore("Data\Blocks\C1\Input")` 探明。
**未实测**，实测结果必须回写到 `mcp-playbook.md` §5。

### 路径 ③：COM 构造外层 Design Spec

尝试在 `\Data\Flowsheeting Options\Design-Spec` 下构造节点。
**风险最高、未实测。最多尝试 2 次**，失败即返回 `NEEDS_INPUT`，
在产物文件中记录尝试过的路径与报错原文。

### 多指标时先数自由度
RADFRAC 只有 2 个规格位。目标数 > 自由度 → 必须增加设计变量（加板、改压、加侧线），
这是**设计变更**，返回 designer，不要在 D 阶段硬调。

---

## 方法 6：分层排障 SOP

失败时按层级从便宜到贵地排查，**不要一上来就 deep_probe**。

```
层 0  是不是超时不是发散？
      → batch_refresh(off) + run_async() + 轮询 status()

层 1  输入完整性（最便宜）
      → fill_trivial_params() → find_incomplete_inputs()（只修 Critical）
      → simulation_warnings()

层 2  单位与量级
      → 逐个核对 A-plan 的 SI 列 vs 实际写入值（get_value 抽查）
      → 出现 0 K / 0 Pa / 流量 0 → 必是单位或组成问题

层 3  拓扑
      → flowsheet_topology() 查悬空流股
      → list_block_ports(每块) 查端口连对没

层 4  单块可行性
      → validate_block(name)
      → 把出问题的块单独看：get_block(name) 读它的规格与输出
      → 规格是否矛盾（FLASH SPECIFICATION INCONSISTENT）

层 5  物性
      → get_property_method() 确认方法
      → 用一个 FLASH2 在关键 T/P 下做单点闪蒸，看相态是否合理
      → explore("Data\Properties\Parameters") 查 BIP

层 6  循环
      → list_tear_streams() → set_tear_estimate() → reinit_and_run()
      → 仍发散则临时简化回路

层 7  知识检索
      → diagnose([报错关键词])
      → search_convergence_knowledge([关键词])

层 8  原始节点（最后手段）
      → deep_probe(block) / explore(路径) / get_value(具体节点)

层 9  交人工
      → generate_input_summary(路径) + export_report_file(路径)
      → 写进 HANDOVER.md 的归因表
```

**每一层的结论都要写进当前阶段产物文件的归因表**：`改了什么 → 结果 → 为什么排除`。

---

## 方法 7（可选）：官方案例库逆向提取配方

**默认不用。** 只在遇到陌生物性体系或陌生单元操作组合时用。

素材：`D:\Program Files\AspenTech\Aspen Plus V15.0\GUI\Examples\`
（24 分类 215 个 `.bkp`）。定位表见 `knowledge/reference/examples-catalog.md`。

### 步骤

```
1  查 examples-catalog.md 的定位表，选 1 个最接近的案例
2  open_file("<案例 .bkp 绝对路径>")
   ⚠ 首次使用先验证 open_file 能否吃 .bkp（用 Getting Started\flash.bkp 试）
   ⚠ 绝对不要 save 回原路径 —— 必须 save 到 runs\<run-id>\from-example.apw
3  逆向提取"配方"（只提取，不修改）：
   - list_components()            → 组分体系（含离子/固体组分怎么建的）
   - get_property_method()        → 物性方法
   - list_reaction_sets()         → 反应集类型与反应式
   - flowsheet_topology()         → 拓扑范式
   - list_all_blocks() + get_block(关键块)  → 模块选型与规格量级
   - explore("Data\Properties\Parameters")  → BIP 来源
4  把配方写进当前阶段产物文件的"参照案例"一节，注明案例文件名
5  close_file() → 回到自己的模型继续建
```

### 用它做什么
- **抄物性配置**：电解质体系的离子组分生成、Chemistry 定义，自己摸索代价极高
- **抄拓扑范式**：如"反应 → 闪蒸 → 两塔 → 循环 + purge"的标准骨架
- **做量级参照**：自己算出的回流比/能耗/塔板数与案例差一个数量级 → 先怀疑自己

### 不要做什么
- 不要把案例直接改成用户的流程（组分/规模/目标都不同，改起来比新建更贵）
- 不要因为案例里有某个模块就照搬（案例常为演示某功能而刻意复杂）
