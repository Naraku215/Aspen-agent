# MCP Playbook — aspen-plus 工具面实战手册

面向 `aspen-modeler` / `aspen-checker`。只写**实测过的硬约束**和**能力缺口的绕行路径**，
工具的表面语义看工具签名即可，不在这里重复。

MCP 服务源码：`D:\mcp-servers\aspen-mcp`

---

## 1. 硬约束（违反必错，且往往是静默错）

### 1.1 一切写入都是内部 SI 单位

所有 `set_*` / `set_value` 直接写 COM 树节点，Aspen 内部节点存的是**内部 SI**，
不是 GUI 显示单位。传未换算的值 → 要么 `FEED FLASH FAILURE`，要么**静默算出错结果**。

| 量 | 人给的 | 必须转成 | 换算 |
|---|---|---|---|
| 温度 | °C | K | +273.15 |
| 压力 | bar / kPa / MPa | Pa | ×1e5 / ×1e3 / ×1e6 |
| 摩尔流 | kmol/hr | kmol/sec | ÷3600 |
| 质量流 | kg/hr | kg/sec | ÷3600 |
| 体积流 | m³/hr | m³/sec | ÷3600 |
| 热负荷 | kW / MW | W | ×1e3 / ×1e6 |
| 长度/直径 | mm | m | ÷1000 |
| 体积 | L | m³ | ÷1000 |

**本系统的防线不是"记住换算"，而是流程设计**：`A-plan.md` 里所有参数以
"工程单位 | SI 值"双列给出，由 designer 一次算完；modeler **只读 SI 列，不做换算**。
任何 modeler 现场做的单位换算都是流程漏洞。

`set_value(path, value, unit=...)` 有 unit 参数，但不要依赖它 —— 用 SI 值 + 不传 unit 最稳。

### 1.2 建模前必须 `set_unit_set("SI")` + `reinit_and_run()`

```
new_simulation() → set_unit_set("SI") → reinit_and_run() → 才能 add_block / add_stream
```

跳过 → `Cannot create Blocks node`，或 block 建出来 type 为空、无法运行。
这是 COM 节点树的初始化动作，不是可选的礼节。

### 1.3 组分必须先于流股

`add_component()` 全部完成后才能 `add_stream()` / 设组成。

组分标签 **超过 8 字符会被截断**（PROPYLENE → PROPYLEN）。
加完组分**必须 `list_components()` 核对实际标签**，后续所有组成设置用实际标签。

### 1.4 RADFRAC 规格必须恰好 2 个

`set_column_specs()` 只接受 `rr` / `d` / `b` / `br` 中的**恰好两个**。给 1 个或 3 个都报错。
`d` / `b` 单位是 kmol/sec。

### 1.5 组成用批量接口

`set_stream_composition_batch()` 一次调用完成，不要循环调 `set_stream_composition()`。
后者多次调用有覆盖/残留风险，且慢。

```
set_stream_composition_batch("FEED", {"WATER":0.0167,"ETHANOL":0.0111}, basis="MOLE-FLOW")
set_stream_composition_batch("FEED", {"WATER":0.6,"ETHANOL":0.4}, basis="MOLE-FRAC", total_flow=0.02778)
```

### 1.6 改完参数用 `reinit_and_run()`，不要用 `run()`

`run()` 会带上一次的残留结果做初值。参数改动后残留初值常导致假收敛或诡异发散。
例外：**故意做初值传递时用 `run()`**（见 modeling-methods 的初值传递手法）。

### 1.7 Aspen 是单实例

一个 COM 会话只有一个打开的文件。**禁止并行派发任何触碰 aspen-plus 的 subagent。**
交棒前必须 `save()`。

---

## 2. 建模顺序模板（COM 节点依赖决定的固定次序）

```
1  new_simulation()  或  open_file(path)
2  set_unit_set("SI")
3  reinit_and_run()                    ← 初始化节点树
4  add_component() × N  →  list_components() 核对标签
5  set_property_method(...)
6  add_reaction_set / add_reaction     ← 若有反应，须早于反应器参数
7  add_block() × N                     ← 先全部建块
8  add_stream() / connect() / connect_port()   ← 再连线
9  set_stream_param / set_stream_composition_batch   ← 进料条件
10 set_param / set_column_* / configure_fsplit      ← 模块参数
11 fill_trivial_params() → find_incomplete_inputs() → simulation_warnings()
12 reinit_and_run()
13 block_status() 逐块 + get_stream() 抽查
14 save()
```

连接优先用 `connect(src, dst)`；多出口/需指定端口时用
`connect_port(block, "V(OUT)", "VAPOR")`。端口名先 `list_block_ports(block)` 查实。

---

## 3. 常见 block 关键规格与端口速查

| Type | 关键规格（SI） | 端口 |
|---|---|---|
| MIXER | PRES（可选，缺省取最低入口压） | 多 F(IN)，单 P(OUT) |
| HEATER | TEMP/PRES/DUTY/VFRAC **任选 2** | F(IN), P(OUT) |
| FLASH2 | TEMP/PRES/VFRAC/DUTY **任选 2** | F(IN), V(OUT), L(OUT) |
| FLASH3 | TEMP, PRES | F(IN), V(OUT), L1(OUT), L2(OUT) |
| FSPLIT | 每出口分率（`configure_fsplit`） | F(IN), 多 P(OUT) |
| PUMP | PRES 或 DUTY | F(IN), P(OUT) |
| COMPR | PRES 或 PRATIO | F(IN), P(OUT) |
| VALVE | PRES（出口压） | F(IN), P(OUT) |
| HEATX | duty / UA / LMTD 之一 | 热 F(IN)/P(OUT)，冷 F(IN)/P(OUT) |
| DSTWU | 短切塔：回流比或塔板数 + 轻/重关键组分回收率 | F(IN), 顶/底 |
| RADFRAC | 见 §1.4 与下方序列 | F(IN) 按级，产品按级 |
| RSTOIC | TEMP, PRES, 化学计量, 转化率 | F(IN), P(OUT) |
| RGIBBS | TEMP 或 DUTY, PRES。**不需要 RXN_ID** | F(IN), P(OUT) |
| REQUIL | TEMP, PRES, RXN_ID（EQUILIBRIUM 集） | F(IN), P(OUT) |
| RCSTR | RXN_ID, TEMP 或 DUTY, PRES, VOLUME(m³) | F(IN), P(OUT) |
| RPLUG | RXN_ID, TEMP 或 DUTY, PRES, LENGTH(m), DIAM(m) | F(IN), P(OUT) |
| RYIELD | TEMP, PRES, 收率分布 | F(IN), P(OUT) |

RADFRAC 完整配置序列（顺序不可乱）：

```
set_condenser_type("C1","TOTAL")        # TOTAL / PARTIAL-V / NONE
set_reboiler_type("C1","KETTLE")        # KETTLE / THERMOSIPHON / NONE
set_column_stages("C1", N)              # N 含冷凝器(1)与再沸器(N)
set_column_pressure("C1", top_pres_Pa, dp_stage=...)
set_feed_stage("C1","FEED", k)          # 每条进料一次
set_product_stage("C1","DIST",1,phase="L")
set_product_stage("C1","BOTS",N,phase="L")
set_column_specs("C1", rr=2.0, d=0.00556)   # 恰好 2 个
add_side_duty("C1", stage, duty_W)      # 可选，负值=冷却
```

反应系统：

```
add_reaction_set("R-1","POWERLAW")      # 或 "EQUILIBRIUM"
add_reaction("R-1", 1, reactants={"H2":2,"N2":1}, products={"NH3":2}, phase="V")
set_param("R1","RXN_ID","R-1")          # RPLUG/RCSTR/REQUIL 需要；RGIBBS 不需要
```

RSTOIC 转化率没有专用工具，走 COM：
`set_value("\Data\Blocks\R1\Input\FRAC", 0.8)`
POWERLAW 动力学参数（A、E、n）同样多数要 `set_value()` 落到具体节点，
路径先用 `deep_probe("R1")` 或 `explore("Data\Blocks\R1\Input")` 探明。

---

## 4. 外部 block 文档（现成金矿，不要重写）

`D:\mcp-servers\aspen-mcp\docs\blocks\` 下每个 block 有 `<name>.md` 与 `<name>-advanced.md`
两份，含端口定义、输入/输出 COM 路径、配置步骤、已知 gotchas。**遇到不熟的 block 先 Read 这里**，
比 `explore` 试探快一个数量级。`common-advanced.md` 是跨 block 的通用节点约定。

**已有文档（35 组）**：ccd, cffilter, cfuge, classifier, common, compr, consep, crusher,
crystallizer, cyclone, decanter, distl, dryer, dstwu, electrolyzer, esp, extract, fabfl,
filter, flash2, flash3, fluidbed, fsplit, granulator, heater, heatx, mixer, pump, radfrac,
rcstr, requil, rgibbs, rplug, rstoic, ryield

**无文档，需 fallback**：sep, sep2, valve, mheatx, hxflux, mcompr, multifrac, petrofrac,
scfrac, rbatch, dupl, mult, pipe/pipeline, sswitch, selector 等。

fallback 路径：
```
add_block("B1","SEP") → list_block_ports("B1") → deep_probe("B1")
→ explore("Data\Blocks\B1\Input") → 逐个 get_value 确认节点名
```
探明后**把结论回写到本文件 §3**，下次就不用再探。

---

## 5. 能力缺口与绕行

| 缺口 | 影响 | 绕行 |
|---|---|---|
| **无 Design Spec / Calculator / Optimization 工具** | 无法直接下"塔顶纯度 99.5%"这类规格 | ① `sensitivity` 扫描 + 插值逼近（最稳，无副作用）② `set_value` 写 RadFrac 塔内规格节点 ③ COM 直接构造 `\Data\Flowsheeting Options\Design-Spec` 节点（未实测，风险最高） |
| **无 BIP（二元交互参数）读写工具** | 无法程序化确认 BIP 完备性 | `explore("Data\Properties\Parameters")` 尝试列举；读不全则在产物中**明确列出关键二元对 + 标注"未程序化确认"**，交人工在 GUI 核查。**不允许沉默略过** |
| **无 Convergence 设置工具**（Wegstein/Broyden、迭代上限） | 循环收敛参数不可调 | 靠 `set_tear_estimate` 给好初值 + 简化回路；必要时 `set_value` 探 `\Data\Convergence` 节点 |
| **无 Sequence / 计算顺序工具** | 不能强制指定块计算次序 | 用拓扑设计和分区建模规避 |
| **无 Property Analysis（T-xy/残差曲线）** | 不能直接算共沸点/相平衡曲线 | 用单个 FLASH2 做逐点闪蒸扫描代替（`sensitivity`），或从官方案例库找同体系案例 |
| **无 EO / 灵敏度以外的优化** | 不做优化 | 明确写进 `A-plan.md` 的能力边界，不承诺 |
| `run()` **30 秒超时** | 大循环/大塔可能超时 | `run_async()` + 轮询 `status()`；或先 `batch_refresh(off)` 关 GUI 刷新提速 |

**规则**：动用 ③ 类未实测绕行前，必须在产物文件中记录"尝试的 COM 路径 + 结果"，
成功则回写到本文件，失败则升级为 `NEEDS_INPUT`，不要连续盲试超过 2 次。

---

## 6. 诊断工具的正确用法顺序

诊断不是乱试，有信息量递增的顺序：

```
1  block_status(每个块)          → BLKSTAT: 0 正常 / 2 未收敛 / 3 错误；读 BLKMSG 原文
2  simulation_warnings()         → 压力不匹配、进料未连、常见配置错
3  find_incomplete_inputs()      → 按严重度列缺失输入。只修 Critical
4  fill_trivial_params()         → 填安全缺省（在 3 之前调也可）
5  diagnose([关键词])            → 状态 + 知识库联合检索
6  search_convergence_knowledge([关键词])  → 只查知识库
7  flowsheet_topology()          → 全局连接图，查断链
8  list_tear_streams()           → 循环撕裂点（有循环时）
9  validate_block(name)          → 单块可运行性预检（加块后立刻用）
10 deep_probe(name) / explore()  → 最后手段：看原始节点
11 export_report_file(path) / generate_input_summary(path)  → 交人工前的快照
```

**先 1-3，再 5-8，最后才 10。** 直接跳到 `deep_probe` 会淹没上下文。

`export_report_file()` 输出 `.rep` 可能很大 —— **不要整份读进上下文**，
用 Grep 按关键词抽取。

---

## 7. 结果读取

```
get_stream("PRODUCT")              # T, P, vfrac, 摩尔/质量流, 组成 —— 首选
get_block("C1")                    # 规格 + 输出结果
get_stream_composition_info(name)  # 组成元数据
get_value("\Data\Streams\S1\Output\RES_TEMP")   # 单点精确取值
```

常用 COM 路径（返回值恒为内部 SI）：

```
\Data\Streams\{N}\Input\TEMP | PRES
\Data\Streams\{N}\Output\RES_TEMP | RES_PRES | RES_MOLEFLOW | RES_MASSFLOW | RES_VFRAC
\Data\Blocks\{N}\Input\TEMP | PRES | DUTY | FRAC
\Data\Blocks\{N}\Output\OUT_TEMP | OUT_PRES
\Data\Properties\Specifications
\Data\Properties\Parameters
```

`sensitivity()` 的 `values` 与 feed 覆盖参数**同样是 SI**：

```
sensitivity("H1","TEMP",[373.15,423.15,473.15],
            targets=["PRODUCT:TEMP","PRODUCT:VFRAC"], title="...")
```

---

## 8. 工具清单（按用途分组，共 75 个）

**会话**：status, probe, open_file, new_simulation, save, close_file, visible, run_script
**执行**：run, run_async, reinit, reinit_and_run, stop_simulation, batch_refresh
**单位与物性**：set_unit_set, get_unit_set, set_property_method, get_property_method,
list_components, add_component, remove_component, explore
**建流程**：add_block, remove_block, add_stream, remove_stream, connect, connect_port,
disconnect, list_all_blocks, list_all_streams, list_block_ports, flowsheet_topology
**设参数**：set_param, get_block, set_stream_param, set_stream_composition,
set_stream_composition_batch, get_stream, get_stream_composition_info, set_value, get_value,
configure_fsplit, add_side_duty, remove_side_duty
**塔配置**：set_condenser_type, set_reboiler_type, set_column_stages, set_column_pressure,
set_feed_stage, set_product_stage, set_column_specs
**反应**：add_reaction_set, remove_reaction_set, add_reaction, remove_reaction, list_reaction_sets
**循环**：list_tear_streams, set_tear_estimate
**诊断**：block_status, validate_block, simulation_warnings, fill_trivial_params,
find_incomplete_inputs, diagnose, search_convergence_knowledge, deep_probe, generate_input_summary
**分析与导出**：sensitivity, export_report_file
**公用工程**：add_utility, list_utilities, get_utility, remove_utility, batch_add_utilities
