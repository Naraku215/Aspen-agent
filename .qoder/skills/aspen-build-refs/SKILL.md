---
name: aspen-build-refs
description: modeler 动手建模时的操作参考：门槛判据输出读法、参数语义与常见错误、不收敛调整经验、已知坑。状态机流程在 aspen-modeler agent 文件里，本 skill 不复述，只提供动手时查的细节。
---

# 建模操作参考

状态机流程（S1–S9 / TUNE / PAUSED）在 aspen-modeler agent 里，这里不复述。
本 skill 只在动手时查，分7块：判据读法、规定选项速查、参数语义、调参经验、已知坑、MCP调用依赖参照、PFD重排。


## 1. 门槛判据输出读法

### find_incomplete_inputs()
输出分三组：
- **Critical**：必须清零。逐条对应到 block/stream，补参数
- **Mode-irrelevant**：当前计算模式用不到，**忽略**
- **Optional**：可选项，除非 design.md 明确要求否则忽略

过关 = Critical 清零。**先跑 fill_trivial_params()** 再查，能自动填掉一批噪声。

### validate_block(name)
- `Engine.Ready` = true → 该块过关
- false → 按 missing diagnostics 提示补缺
GUI 红框 ≈ Engine.Ready=false 的块。

### simulation_warnings()
run 前必调。重点看两类：
- 压力不匹配 → 对照 design.md 压力剖面
- 断开进料 / 端口未连 → 回连接步骤补

### block_status()
BLKSTAT=0 正常；非零 → `diagnose([块名或错误码])` 定位。

### diagnose([keywords])
两块输出：各块实时状态（BLKSTAT/PER_ERROR）+ 知识库命中。
只摘块名与错误码关键词写进 state.note，不整段粘。

## 2. 规定选项速查表

| Block 类型 | mode_param | 有效值 | 每个模式需要的参数 |
|---|---|---|---|
| Flash2 | SPEC_OPT | TP / PD / TEMP / PRES / VFRAC / DUTY | TP: TEMP+PRES; PD: PRES+DUTY |
| Compr | OPT_SPEC | PRES / TEMP / DUTY | PRES: PRES+SEFF; TEMP: TEMP+SEFF |
| Heater | SPEC_OPT | TP / PD / TEMP / PRES / VFRAC | TP: TEMP+PRES; PD: PRES+DUTY |
| RadFrac | （无 mode_param，用 set_column_specs） | — | — |

> **Heater 热负荷模式是 PD 不是 DUTY**（2026-08-22 实测：`SPEC_OPT="DUTY"` 被 Aspen 拒绝，
> `"PD"` 有效——压力+热负荷模式，需同时填 PRES 与 DUTY）。

**常见错误**：
- 只填参数值不设规定选项 → Aspen 报“输入不完整”
- 规定选项设错 → Aspen 用错误的参数组合计算，结果全错
- **塔纯度禁用固定 D:F 表达**：本案例 `D:F=0.5` 锁死纯度在 99.0 wt%，
  RR 2→4 组成一个数字未变、再沸器 2.54→4.42 MW 白涨。正解 Design Spec
  （纯度）+ Vary（RR 或 D:F），建行用 `add_table_row` + `set_value`（见 §3）

**速查表外的块**（反应器/Pump/Valve/HeatX/Extract/DSTWU/固体/电解槽等）：
先 Read `knowledge/blocks/<类型>.md`（如 rplug.md / heatx.md / electrolyzer.md），
端口表、输入路径、规定选项有效值、设置步骤都在里面；总目录见
`knowledge/blocks/index.md`，物流 BASIS 语义见 `knowledge/blocks/streams.md`。

## 3. 参数语义与常见错误

- **“规定”选项不会因填了参数而自动完成**，要逐个落：
  - 塔（顺序不能颠倒）：set_column_stages → set_condenser_type + set_reboiler_type
    → set_feed_stage + set_product_stage → set_column_pressure → set_column_specs
  - 分流器：configure_fsplit
  - 固体 / PSD 场景：set_param 到相应节点，节点不确定先 explore 找
- **先连端口再填参数**：连接错了，参数校验结果无意义
- 组分标签 > 8 字符被截断，用 list_components 核对实际标签
- 先设单位制再添加组分，加完组分 reinit，否则部分模块节点不生成
- **物流组成 BASIS 三条**：
  - 分数基准（MOLE-FRAC / MASS-FRAC）必须同时给 total_flow，否则组成无意义
  - 改 BASIS 只改变 Aspen 对已有值的解释，不会换算已有数值
  - 读流量用 `get_stream_composition_info(..., basis="MOLEFLOW")`，
    读分数用 `basis="MOLEFRAC"`（详见 knowledge/blocks/streams.md）
- **塔纯度指标用 Design Spec，不用固定 D:F**：design.md 要求塔顶/塔底纯度时，
  建 Design Spec（纯度）+ Vary（RR 或 D:F），让 Aspen 自己求回流比；
  固定 D:F 会锁死纯度且 RR 改动无效果（见 §2 常见错误）。
  建行用 `add_table_row(path, label)` + `set_value` 两步：Design Spec/Vary
  表节点在 `\Data\FlowsheetingOptions\DesignSpec\...`（行结构不确定先 explore）

## 4. 调参经验（用户指示检修后按序排查）

1. **规定冲突 / 不可达**（纯度规定超共沸上限等）→ 对照 design.md 可达性，
   确实不可达 → PAUSED，别硬调
2. **初值差**（塔温 / 组成剖面离解远）→ 给 estimate，或先放松 spec 再逐步收紧
3. **压力倒挂** → 查节点压力剖面
4. **参数超物理范围**（负流量 / 温标错）→ 查最近改过的参数

**单变量纪律**：一次只改一个地方 → reinit_and_run() → 看 block_status。
好转继续，恶化改回。多参同调无法归因。

## 5. 已知坑

- `.rep` 数 MB，只 Grep 抽行，整份 Read 会爆上下文
- BIP 静默取 0 也能“收敛”但结果全错 —— S4 PROPERTY 的 BIP 核查必须做
- 不收敛时**绝不 new_simulation 重来**：重建会丢全部已填参数，等于白干
- **save() 挂起陷阱**：往已存在的路径 save 可能挂起超时（覆盖确认/文件锁）。
  挂起 → 换新文件名保存，或先删旧文件再 save
- **多 AspenPlus 进程干扰**：多实例并存会让 COM 调用挂起/超时；操作前确认
  只有一个实例。Dispatch 可能绑错实例 → 先 `open_file` 绑定正确文档再操作
- **run_script 不可用**：输出不可捕获、脚本静默失败；批量操作用单条消息并行多个
  MCP 调用替代
- **单位写错的典型症状**：FEED FLASH FAILURE 警告、塔顶温度离谱（如 200 K
  而非 351 K）的“假收敛”（BLKSTAT=1 但物理完全错）。发现即回查 SI 值
- **块参数单位换算走已知映射表**：块 Input 节点 `.UnitString` 为空，
  `set_param`/`set_value` 带 unit 时对映射表内参数（TEMP/TEMP1/TEMP2/PRES/PRES1/
  PRES2/P_OUT/DUTY/DP_STAGE）按已知内部单位（K/N/SQM/W）换算；表外参数带 unit
  会**静默不换算**（无量纲参数这是预期行为，有单位参数则需改传 SI 值或手工换算）；
  `set_param` 对映射表内参数直接用，HeatX 冷侧用 TEMP1/PRES1（第二股流用 TEMP2/PRES2）
- **`add_side_duty` 的 duty 带 unit 参数**：`add_side_duty("C1", 5, -500, unit="kW")`
  换算为 W 存储；不带 unit 时值按 SI（W）处理，不要再按 kW 传裸值
- **`set_column_specs` 的 rr+d / rr+b 组合在 `ALGORITHM=STANDARD` 下被拒**：
  只能 `set_param` 单独改 `BASIS_RR` / `D:F`；要自动求回流比请走 Design Spec
  （见 §3）
- **COM 错误分级与自愈**（先对照再决定要不要 PAUSED）：
  - “服务器出现异常情况” → COM 状态脏，先 `close_file()` → `open_file(apw_path)`
    自愈重跑，能解决绝大多数稳定性问题；自愈失败才 PAUSED
  - “发生意外” → 参数/操作型错误，可直接重试，COM 状态不受影响
  - “远程过程调用失败” → Aspen 未运行，提示用户检查 Aspen 进程
  - “对象没有连接到服务器” → MCP 插件会话失效，需用户重启 MCP，记 last_error 后 BLOCKED
- **删块/删流顺序**：先 `remove_block`（连接自动断裂），再 `disconnect` 清孤儿物流；
  反过来先拔光物流再删块 → 块变孤立，Aspen 内部校验不过，COM 服务器崩溃不可恢复
- **反应体系三条**（RStoic/RPlug/RCSTR/电解槽等带反应的案例）：
  - `add_reaction` 写 COEF/COEF1 计量表**有时静默失败**：写后必须读回验证
    （`get_value` 查 `COEF\1` 下组分与系数非空），空则用 `set_value` 手动补填
  - RXN_ID 表分配反应集：**先清空已有行再添加**；该表不支持 SetLabel，
    直接用 `#0`/`#1` 索引路径赋值（如 `RXN_ID\#0` = "R-1"）
  - RPlug 温度模式用 `T-SPEC`（指定温度剖面要配 TEMP），`CONSTANT-T` 实际无效

## 6. MCP 调用依赖参照表

每个 S 阶段内哪些调用可并行、哪些必须串行。铁律 9 的判断依据。

### 可并行（无依赖）
- S1 过关后：visible + batch_refresh + status（都是独立操作，只需模拟已存在）
- S3：add_component × N（多组分互相独立）
- S4 reinit 后：explore(BIP) + get_property_method（都是读）
- S6：add_stream × N（多流股互相独立）
- S6：connect + list_block_ports（写连接与读端口名互不依赖）
- S6：connect_port × N（多端口连接互相独立，但都依赖 list_block_ports 输出）
- S8：find_incomplete_inputs + status + simulation_warnings（都是读）
- S9 run 后：status + block_status + get_stream × N（都是读）

### 必须串行（有依赖或高频出错）
- new_simulation → 一切（必须先建模拟）
- set_unit_set → get_unit_set（写后验证）
- add_component → list_components → reinit（加后验证，验后重建）
- set_property_method → reinit（设后重建）
- reinit → explore(BIP)（BIP 节点结构在 reinit 后稳定）
- **S7 全部串行**：SPEC_OPT → set_param(TEMP) → set_param(PRES) →
  set_stream_param(TEMP) → set_stream_param(PRES) → set_stream_param(FLOW) →
  set_stream_composition_batch → fill_trivial_params → validate_block
  （参数设置高频出错，逐个执行确保正确）
- reinit_and_run → 读取结果（跑后才能读）

## 7. PFD 重排脚本（relayout-pfd.ps1）

**S6 过关后**由主 agent 跑（modeler 已 save + close_file 交棒，返回 LAYOUT_READY）：
`scripts/relayout-pfd.ps1 -BkpPath <run>/sim/model.bkp -DrawStreams
-OutPath <run>/sim/model-relayout.tmp.bkp`，成功后原位覆盖 model.bkp，
S7 起在排布好的模型上继续（用户全程可观察）。要点：
- 纯离线重写 bkp 第一个 PFSVData 图形段，**不碰模型数据**，输入文件只读
- 原位覆盖两步走：脚本输出临时文件（OutPath 禁止等于输入），再
  `Move-Item` 覆盖 model.bkp；覆盖前备份原图为 `model.bkp.orig`（仅首次）
- 块数 <5 自动跳过（输出 `SKIP:` 且 exit 0）——排布非阻塞，跳过/失败都直接
  重派 modeler 从 S7 继续
- S7+ 只写数据层不碰图形段，在排布版文件上继续建模无影响
- 块间流股走统一网格 + A* 通道（不穿模块、不重合），
  端口流股（feed/product）删除记录交 Aspen 原生箭头——自画端口线效果差，别改回
- 航点格式（≥7 点骨架、固定码序）在 V15 往返验证过；怀疑 Aspen 拒收新格式时，
  用“另存临时 bkp + grep 航点”往返法客观判定，别靠目视猜
- modeler 无 Bash，不在建模会话里跑此脚本
