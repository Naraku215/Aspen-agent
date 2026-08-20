# Aspen Agent 系统修复与优化方案（2026-08-20）

来源：SOEC 甲醇集成案例（runs/20260819-soec-meoh）复盘。诊断结论均有源码取证或实测确证。
本文是完整方案的存档；"已做"标记为本次已落地，"遗留"为后续轮次待办。

---

## 一、诊断结论（确证）

### 问题 1：modeler 因 token 耗尽 / 用户暂停 / 断网突然停止
现有系统**无法妥善处理**。六缺口：
1. 铁律 8（只写 state.json 不重写）对崩溃无效——进程没了，内存状态全丢
2. state.json 的 `phase` 粒度太粗（S1-S9），S5/S7 批量阶段断在哪不知道
3. state.json 是"声明"非"事实"——续跑只读 phase，不与模型实际状态对账，可能对着空文件盲填
4. 只在 S9-PAUSED 才 save，中间崩溃全丢
5. 主 agent 无"subagent 未返回"分支，无从处置
6. 无降级条款（后经用户决策：**主 agent 永不插手建模**，此条废止）

### 问题 2：PFD 布局混乱
机制性根因（.bkp 实测）：`GRAPHICS_BACKUP → PFS V 5.00 → PFSVData` 段中多个块坐标
`At 0.000000 0.000000`（SOEC、H2COOL1、PUMP1、FLASH2、FLASH3 等全叠原点）。
`add_block` 从不设坐标，Aspen 默认放原点。COM 数据树不暴露坐标
（`Data\Flowsheet\Section\GLOBAL\Input\PARAMSTRING` 全 null，无 `Data\Graphics`）。
可行路径：离线编辑 `.bkp` 的 `PFSVData` 段（BLOCK 的 `At`/`Label At`），再导入。
**已做**：`scripts/relayout-pfd.ps1` + 验证（含用户目视）。

实测踩出的 bkp 图形编辑三条规矩：
1. `SIZE x1 x2 y1 y2` 行是打开时显示的画布窗口；新布局超出窗口则 PFD 看似空白 →
   必须按 bbox+margin 扩窗。
2. 把 STREAM 记录航点清零会让 Aspen 拒掉整个 PFSVData 段（连方块都空白）；正解是
   **整条删除 STREAM 记录**并同步减 `# of PFS Objects`（LEGEND 也占一个计数，解析器
   须把 LEGEND 当记录边界，否则尾部 VIEWPORT/PAGESETUP 被连删）。删后 Aspen 载入时
   按拓扑自动重画连线，实测通过。
3. MCP 拉起的 Aspen 实例窗口隐藏（进程在、任务栏无窗），须 user32 `ShowWindowAsync`
   恢复前台（`scripts/show-aspen-window.ps1`）。

### 问题 3：设置-固体下自动生成名为 0 的 PSD 网格
实验确证（两次隔离实验）：
- 节点路径是 `Data\Setup\Stream-Class\Subs-Attr`（GUI"设置→固体"）；`PSD` 子节点是
  Aspen 出厂自带模板（无害）；名为 `0` 的子节点是污染。
- 元凶：`fill_trivial_params` 的 `_TRIVIAL_PARAMS` 给 **PSD id 引用类参数写 0**
  （`PSDID`/`OV_PSDID`）。单变量复验：全新模拟只执行
  `set_value("\Data\Blocks\F1\Input\OV_PSDID", 0)`，节点 `0` 当即出现。
- 网格定义类键（`INTERVAL`/`LOWER`/`UPPER`/`CUMFRAC` 等）写 0 同样污染网格定义。
- 危害：纯气液流程不影响计算，但污染模型树；未来含固流程会与真实网格冲突。
- **已做**：从 `_TRIVIAL_PARAMS` 移除 id 引用类 + 网格定义类共 19 键（见第二节 1.1）。

### 问题 4：RYIELD 产率规定需要 insert row，无 MCP 工具
根因：`set_value` 走 `FindNode`，只能给已存在节点赋值；产率表行不存在时无从建行。
技术上 MCP 源码已有 4 处 `InsertRow` 用法（components.py:71、reactions.py 等）。
- **已做**：新增通用工具 `add_table_row(path, label)`（tables.py）。
- **遗留**：`set_yield_table` 专用工具（用户决策：不做，用 add_table_row + set_value 两步）。

### 问题 5：本次案例更多问题（复盘清单）
1. **纯度天花板**：COL1 固定 `D:F=0.5` 使 D=55.1 kmol/h > 进塔甲醇 54.5 kmol/h，
   塔顶被迫夹带杂质，纯度锁死 99.0 wt%；RR 2→4 组成一个数字不变、再沸器 2.54→4.42 MW
   白涨。正解：Design Spec（纯度）+ Vary。**已做**（skill 条文 3.5）。
2. **设计阶段无物料衡算上限自检**：200 kmol/h 水 → 180 H2 → 甲醇理论上限 60 kmol/h，
   任务目标 39 偏低、实测 55.1 属正常而非超标。**遗留**（3.4）。
3. **全局单一物性方法**：PSRK 对甲醇泡点偏差 +15K（80.17 vs 64.7°C）；应分段物性。
   **遗留**。
4. **溶解 CO2**：甲醇产品 0.54 mol% CO2 无脱除路径，designer 可达性检查漏了溶解气类。
   **遗留**（3.4）。
5. **S9 判据过严**：BLKSTAT=1 `MASS IMBALANCE`（FSPLIT1，实测三流股完全平衡，是 tear
   残差假警报）与 BLKSTAT=2 `YIELDS NORMALIZED`（SOEC，良性）两次逼 PAUSED。
   **遗留**（3.3 S9 白名单）。
6. **analyzer 一次没跑**，三产物只交付 2 个（report.md 缺失）。**已做**（3.6 收尾检查）。

### MCP 稳定性缺陷（本次确证，修复遗留）
- **`open_file` 报 2041"无法打开文件"**：已有文档载入时 `InitFromFile` 必失败；
  实测 `close_file` → `open_file` 即成功。**遗留**（1.3：tool_open_file 自动先 close 重试）。
- **`explore` 等树操作 E_NOINTERFACE 全面失效**：`bridge/windows.py` 的 `_is_dead()`
  只测 `_doc.Name`，文档未载入时它照样返回正常 → 永不重连；且 E_NOINTERFACE
  (-2147467262) 不在 `_CONNECTION_LOST_CODES`。**遗留**（1.2）。
- **`new_simulation` 静默说谎**：`InitNew()` 抛异常时兜底 `reinit()`，仍返回
  "New blank simulation created"。**遗留**（1.4）。
- **单位换算注册表语义错**：`units.py` 假设 `node.UnitString` 是内部 SI，实际返回
  当前 Unit-Set 显示单位（ENG 集下温度节点返回 F）→ 带 unit 必报
  `No unit conversion registered for C -> F`。**已做**（3.2 文档版绕行：
  METCBAR + 不带 unit 直传）；**遗留**（units.py 根修）。
- `list_tear_streams` 偶发空返回；`save()` 往已存在路径可能挂起（skill 已知坑已有）。

---

## 二、完整修复计划与状态

### MCP 侧（D:\mcp-servers\aspen-mcp，回退点 HEAD=19f5e6e）

| 编号 | 内容 | 状态 |
|---|---|---|
| 1.1 | fix_trivial.py 移除 PSD id 引用类 + 网格定义类 19 键，保留纯统计量键 | **已做** |
| 1.2 | _is_dead 深度探测 + E_NOINTERFACE 入 _CONNECTION_LOST_CODES | 遗留 |
| 1.3 | tool_open_file 自动 close 后重试 | 遗留 |
| 1.4 | new_simulation 失败时诚实报错，禁止 reinit 冒充新建 | 遗留 |
| 1.5 | 通用建表行工具 add_table_row(path, label) | **已做** |
| 1.5b | set_yield_table 专用工具 | 遗留（用户决策不做） |
| 1.6 | units.py 根修（不依赖显示单位换算） | 遗留 |

### PFD 侧（d:\Projects\aspen-agent）

| 编号 | 内容 | 状态 |
|---|---|---|
| 2.1 | scripts/relayout-pfd.ps1：解析 PFSVData → 拓扑分层重排 At/Label → 扩 SIZE 画布 → 删 STREAM 记录（Aspen 载入自动重画连线）→ 输出 model-relayout.bkp | **已做** |
| 2.2 | 验证：原四门槛（载入/无重叠/拓扑/重算）漏"坐标在画布内"与目视，旧版实测空白；补扩窗+删 STREAM 方案后用户目视通过（方块整齐+连线自动重画）。教训：PFD 验证必须含画布内检查+目视 | **已做** |

### AGENT 侧（.qoder/ + AGENTS.md）

| 编号 | 内容 | 状态 |
|---|---|---|
| 3.1 | state.json 升级（apw_path/unit_set/property_method/last_verified_at/events[]/step_index）+ 每 S 阶段 save + S5/S7 每 5 写操作追加 events + 续跑轻量对账（list_all_blocks+list_components+get_property_method，<1K token）+ 主 agent 无返回按 PAUSED 处理；降级条款删除（主 agent 不插手为硬约束） | **已做** |
| 3.2 | 单位约定改写：S2 set_unit_set('METCBAR') 后不带 unit 直传工程原值；design-refs 第 7 节、build-refs 已知坑同步 | **已做** |
| 3.3 | S9 过关判据白名单（MASS IMBALANCE tear 残差假警报 / YIELDS NORMALIZED 放行并记 report） | 遗留 |
| 3.4 | designer 自检：物料衡算上限手算 + 可达性检查补溶解气/惰性组分 | 遗留 |
| 3.5 | 塔纯度禁用固定 D:F，改用 Design Spec+Vary；set_column_specs rr+d/rr+b 被拒已知坑 | **已做** |
| 3.6 | run 结构加 journal.md + CONVERGED 后必须派 analyzer（report.md 缺失不得宣布完成）+ 目录说明 | **已做** |

### 回归验证（runs/20260819-soec-meoh 基线，只读）
1. 空白模拟 + FLASH2 + fill → Subs-Attr 只有 PSD 无 0：**通过**（fill 填 31 键，无 CUMFRAC/OV_PSDID 等 PSD 系键；explore Subs-Attr 只剩 PSD 一个子树）
2. find_incomplete_inputs Critical 分组不恶化：**通过**（无 Critical 组；CUMFRAC 等仍列在 Other optional，那是 COM 自带节点非 fill 填入，符合预期）
3. add_table_row 在临时空白模拟验证：**通过（带两条已知局限）**。工具已注册（51404 消除），RYIELD MOLE_YIELD 带标签建行成功（row0=WATER/row1=HYDROGEN）。局限：① 同标签重复添加报 AE_UNKERR 而非 "already exists"（该类表 GetLabel 恒报错致幂等扫描失效；且表按组分数自动展开后 InsertRow 被锁，只能先齐组分再建行）；② 建完行后按 docstring 用 set_value 标签路径（...\MOLE_YIELD\WATER\MIXED）填单元格不通——FindNode 无法穿透表格行（Path not found），表格单元格须 Elements(label) 逐层走，现有工具均不支持，见遗留清单
4. model-relayout.bkp：**已做，通过**。首版过载入/无重叠/拓扑/重算四门槛但目视空白
   （块搬出 SIZE 画布 + 清零 STREAM 致整段被拒）；修复（SIZE 扩窗 + 删 STREAM 记录、
   计数同步减、LEGEND 作记录边界）后目视通过：方块整齐、连线由 Aspen 按拓扑自动重画
5. 结论见本文状态列（runs 目录不提交）

---

## 三、遗留清单（后续轮次）

- [ ] MCP 1.2：`_is_dead()` 深度探测 `RootModel("").Elements("Data")`；`_CONNECTION_LOST_CODES`
      加 `-2147467262`；注意新建 Dispatch 后未载入文档时 RootModel 本就失败，深度探测
      只用于 call() 重试判定，不可在 _connect() 里当连接失败判据
- [ ] MCP 1.3：tool_open_file 捕获 2041 → close_file → 重试一次
- [ ] MCP 1.4：new_simulation 失败诚实报错，禁止 reinit 冒充
- [ ] units.py 根修：convert_value 不依赖显示单位；或注册显示单位对；或改用 Aspen 引擎转换
- [ ] 3.3 S9 白名单：BLKSTAT=1 MASS IMBALANCE（实测流股加和平衡才放行，必须写 report.md）；
      BLKSTAT=2 YIELDS NORMALIZED（report.md 标注归一化前后产率）
- [ ] 3.4 designer 自检：产量指标必附一步元素守恒手算；可达性检查补溶解气/惰性组分
- [ ] **表格单元格写入工具**（回归 3 发现：set_value 的 FindNode 穿不透表格行，add_table_row 建行后填不了值；
      需 set_table_cell(path, row_label, col_label, value) 用 Elements(label) 逐层走；顺带修 add_table_row
      幂等分支的 AE_UNKERR 与 docstring 误导路径）；set_yield_table 专用工具可视其后置
- [ ] 分段物性方法（合成回路 PSRK / 精馏段 NRTL-RK，block 级 OPSETNAME）
- [ ] 设计阶段溶解气脱除路径（闪蒸/汽提）

## 四、硬约束（用户决策，长期有效）

- 主 agent 不插手建模：只编排派发，永不代执行 designer/modeler/analyzer 角色，
  不调用任何 aspen-plus MCP 工具。subagent 通道不可用时按 BLOCKED/PAUSED 处置并告知用户。
- runs/ 下案例产物不进 git。
- 所有项目 Git 远程操作统一 SSH（本文件无关，仅为完整性记录）。
