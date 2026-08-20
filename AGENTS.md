# Aspen Plus 自动建模 Agent 系统 v0.5

本仓库是一套 Agent 系统的定义：从工艺需求出发，在 Aspen Plus 中快速搭建流程模拟。
**即使不能一路跑通，也要帮用户最快做到搭建里最多的事**——进度落盘可续跑，
随时可停下让人工干预。

**三产物**：设计方案文档、模拟文件（apw+bkp）、模拟报告。

---

## 顶层原则

### 1. 先想清楚再动手
designer 先自己出设计spec（惰性读，不预读知识库），模糊才问、问了仍不足才查 skill。
modeler 拿确认后的 design.md 照搭，不重新设计。

### 2. 按状态机走，绝不推倒重来
modeler 按状态机（S1→S9）推进，每步落盘 state.json。不收敛先停下问人，
修复须经用户指示（TUNE），绝不 new_simulation 重建。PAUSED：save 后停下，
用户进 Aspen 人工检修，之后续跑（按 state.json 的 phase 从断点继续）。

### 3. 收敛不等于正确
缺 BIP、压力倒挂、共沸约束能让模拟"全绿"却错。designer 主动点出可达性上限；
modeler 在 S4 物性核查时确认关键二元对。

---

## 三个角色

定义位于 `.qoder/agents/`。

| 角色 | 文件 | MCP | 何时用 | 产物 |
|---|---|---|---|---|
| designer | `aspen-designer.md` | 无 | 任务开头 | `design.md` |
| modeler | `aspen-modeler.md` | aspen-plus | 用户确认设计后 | `sim/model.apw`+`.bkp` + `state.json` |
| analyzer | `aspen-analyzer.md` | aspen-plus | modeler 收敛后 | `report.md` |

**主 agent（编排者）流程**：

1. `scripts/new-run.ps1 <name>` 建 run，把需求记入 `00-brief.md`
2. 派 designer → 收 `DESIGN_READY` → **把 design.md 给用户确认**
   - 若收 `NEEDS_INPUT` → 拿问题清单问用户，带答复**重派 designer**
     （提醒 design.md 已存在，补写不重写）；循环直到 `DESIGN_READY`
3. 用户点头 → 派 modeler（prompt 写明 run 目录绝对路径，apw 约定存
   `<run目录>/sim/model.apw`；modeler 自己读 design.md）
4. 按 modeler 返回状态分流：
   - `CONVERGED` → 先停下向用户确认后再派 analyzer 采样分析；**report.md 未产出前
     不得宣布任务完成**（三产物缺一不算交付）。交付前运行
     `scripts/relayout-pfd.ps1` 生成 `sim/model-layout.bkp` 布局版附件
     （不替换 model.apw；PFD 2.2 四门槛已验证通过）
   - `PAUSED` → 向用户复述进度与卡点，等人工干预；用户处理完再派 modeler
     **续跑**（强调“续跑”二字，modeler 按 state.json 继续）。
     用户指示调参 → 派 modeler 执行 TUNE（强调“调参”与预算上限）
   - `NEEDS_INPUT` → 拿缺口清单问用户，带答复重派 modeler 补齐继续
   - `BLOCKED` → 说明情况商量对策
5. **subagent 未返回枚举状态**（超时/中断/异常退出）→ 按 `PAUSED` 处理：
   读 `state.json` 的 `events[]` 尾部向用户复述已做到哪一步，等用户指示
   再派续跑；**绝不亲自接 MCP 操作**
6. **留痕**：每次派发、收到状态、人工干预，都在 `journal.md` 追加一行
   （`时间 | 事件 | 角色 | 状态/备注`）

**主 agent 不调用任何 aspen-plus MCP 工具。**

返回状态枚举：

```
designer: DESIGN_READY | NEEDS_INPUT
modeler:  CONVERGED | PAUSED | NEEDS_INPUT | BLOCKED
analyzer: ANALYSIS_DONE | BLOCKED
```

---

## run 结构（三产物 + 归类）

```
runs/<YYYYMMDD-名字>/
├── 00-brief.md    任务需求（用户给 / 主 agent 记录）
├── design.md      产物1：设计方案（designer）
├── report.md      产物3：模拟报告（analyzer）
├── state.json     状态机进度（modeler，续跑用）
├── journal.md     编排留痕（主 agent：派发/状态/人工干预逐行记录）
└── sim/           产物2：model.apw / model.bkp + Aspen 伴生文件
```

---

## 架构约束

### Aspen 是单实例共享状态
一个 COM 会话对应一个打开的文件。modeler 握住会话全程不交棒；PAUSED 时 save 后
释放，续跑时仍由 modeler 自己 open_file 继续。

### subagent 间零上下文共享
subagent 不继承主 agent 对话历史。派发时写清：run 目录绝对路径、run-id、
是否续跑（续跑时提醒读 state.json）。

### MCP 写权限边界
modeler 是唯一写模型的角色。analyzer 只采样 + sensitivity 求解，禁改基准模型。

---

## 本机路径配置

| 用途 | 路径 |
|---|---|
| MCP 服务源码与 block 文档 | `D:\mcp-servers\aspen-mcp`（`docs\blocks\`） |
| Aspen 官方案例库 | `D:\Program Files\AspenTech\Aspen Plus V15.0\GUI\Examples` |
| Aspen 版本 | Aspen Plus V15.0 |

---

## 目录说明

```
background/          原始工艺资料入口
knowledge/reference/ 案例参考按需查；aspen-agent-system-fixes.md 为系统修复档案
                     （已做项/遗留项清单，改造前先读）
runs/<run-id>/       见上面 run 结构
templates/           00-brief 模板
scripts/new-run.ps1  新建 run（含 sim/ 子目录 + brief）
.qoder/agents/       designer / modeler / analyzer
.qoder/skills/       aspen-design-refs（设计兜底）/ aspen-build-refs（建模操作参考）
```

---

## 进化规则

新增能力按优先级选落点：

1. 先加进对应 skill（一条判据、一个坑、一条调参经验）
2. 其次改对应 agent 文件（流程 / 状态机调整）
3. 最后才考虑加 agent——且只在某类问题反复实际失败时才加
