---
name: aspen-workflow
description: Aspen Plus 自动建模系统的编排 SOP。主 agent 用它把一次建模任务切成 A-E 五个阶段，按复杂度裁剪，逐阶段派发 subagent、判门禁、管预算、写报告与接管包。当用户要求做流程模拟、建 Aspen 模型、或推进某个 run 时使用。
---

# aspen-workflow — 编排 SOP

**这个 skill 给主 agent（编排者）用。** subagent 不需要读它。

铁律：**主 agent 不调用任何 aspen-plus MCP 工具。** 要看模型状态就派 subagent 回执。

---

## 0. 开局四步

```
1  确定 run-id：<yyyyMMdd>-<短名>，如 20260804-etoh-flash
2  跑 scripts\new-run.ps1 -RunId <id>   → 建 runs\<id>\ 与 state.json
3  把用户给的需求/资料原文写入 runs\<id>\00-brief.md
   若用户提到了 background\ 里的文件，在 00-brief.md 中列出其绝对路径
4  进入 A 阶段
```

若用户说"继续上次的"：读 `runs\<id>\state.json` 的 `phase` 与 `gate`，从那里接。
**不要重跑已通过门禁的阶段。**

---

## 1. 五阶段状态机

```
        ┌──────────────────────────────────────────┐
        ↓                                          │
A 定义 ──→ [人工确认] ──→ B 骨架 ──→ C 严格化 ──→ D 达标 ──→ E 交付
  ↑                          │          │          │
  └── NEEDS_DESIGN_CHANGE ───┴──────────┴──────────┘
      （≤2 次，超限出 HANDOVER）
```

| 阶段 | 派给 | 产物 | 出口门禁（主 agent 判） |
|---|---|---|---|
| A 定义 | `aspen-designer` | `A-plan.md` | 方案无留白 + **人工确认** |
| B 骨架 | `aspen-modeler` | `B-skeleton.md` | 物料闭合 ≤±0.5%；BIP 核查已记录；指标可达性初判已给 |
| C 严格化 | `aspen-modeler` | `C-refine.md` | 全部 block BLKSTAT=0；含归因表 |
| D 达标 | `aspen-modeler` | `D-spec.md` | 指标达标，或给出量化的不可达结论 |
| E 交付 | `aspen-checker` + 主 agent | `E-review.md` → `REPORT.md` / `HANDOVER.md` | 12 条校核全部有量化结果 |

### 复杂度裁剪

| 级别 | 判据 | 走 |
|---|---|---|
| L1 | ≤3 模块、无循环、无反应 | A → C → E（C 阶段直接搭全流程，不做 B、不做 D） |
| L2 | 有塔或反应，无循环 | A → B → C → D → E |
| L3 | 有循环 / 多区 / 电解质 / 固体 | 全阶段；B 强制断环，C 强制逐区严格化 |

级别由 designer 在 A 阶段判定并写入 `A-plan.md`；主 agent 抄进 `state.json.level`。
**L1 无指标要求时可跳过 D**；有指标就得走 D，与级别无关。

---

## 2. 迭代预算（硬上限）

| 项 | 上限 |
|---|---|
| B 阶段返工 | 2 轮 |
| C 阶段收敛修复 | 5 轮 |
| D 阶段达标调参 | 4 轮 |
| 跨阶段回退（→A 改设计） | 2 次 |

每次派发前先读 `state.json.iter`，**超限即停止，直接进 E 阶段出 `HANDOVER.md`**。
不允许"再试一次就好"。

---

## 3. 派发 prompt 模板

subagent **不继承对话历史**。每次派发都必须自包含。固定五段：

```
【任务】<一句话：本次要完成的阶段目标>

【路径】
  仓库根        D:\Projects\aspen-agent
  本 run 目录   D:\Projects\aspen-agent\runs\<run-id>
  模型文件      <state.json.apw_path，或"尚未创建，你负责 new_simulation + save 到此路径">
  必读产物      <上游阶段的产物文件绝对路径，逐个列出>

【上下文】
  <上一阶段回执中的原始报错文本、关键参数值，整段复制。不要写"如前所述"。>

【本阶段要求】
  <引用 SKILL 中该阶段的要求，或直接列出待办>

【产出】
  1. 写入 <产物文件绝对路径>
  2. 结束前 save() 到 <apw_path>
  3. 回复最后一行必须是：STATUS: <DONE|DONE_WITH_CONCERNS|NEEDS_INPUT|NEEDS_DESIGN_CHANGE|BLOCKED>
     并在回复中给出 ≤300 字的结论摘要（不要粘贴 COM 树、不要粘贴完整报错列表 ——
     那些写进产物文件即可）
```

**并行禁令**：任何触碰 aspen-plus 的派发严格串行，一次只派一个。

---

## 4. 逐阶段派发要点

### A 阶段 → aspen-designer

必须在 prompt 里给：`00-brief.md` 路径、`background\` 目录路径、
`knowledge\engineering-rules.md` 路径。

回执后主 agent 自查 `A-plan.md`：
- 每个参数是否**单一确定值**且有 `工程单位 | SI 值` 双列？有留白就打回。
- 是否有关键二元对清单？
- 是否有完整压力剖面？
- 是否判定了复杂度级别？
- 指标是否量化（量 + 数值 + 基准 + 允差）？

然后 **必问人工**：把方案要点压缩成 ≤15 行摘要 + 列出 designer 的假设项，
用 AskUserQuestion 请用户确认或修正。这是唯一默认必须停下来的地方。

### B 阶段 → aspen-modeler

prompt 里给：`A-plan.md` 路径、`knowledge\mcp-playbook.md`、`knowledge\pitfalls.md`。
L3 时明确写"**本次断开循环**，循环流股用 A-plan 给的假进料值替代"。

门禁判定看 `B-skeleton.md` 里的物料平衡表。**闭合超 ±0.5% 就打回**，
并把 modeler 给的不闭合数字原样写进下一轮 prompt。

### C 阶段 → aspen-modeler

prompt 里必须写清：**本轮只做一件事**。例如
"本轮只把 SEP-1 替换为 RADFRAC C1，其余不动"。
L3 且分区多时，一个区一次派发，每次派发都是新实例。

最后一轮才接回循环，prompt 里明确"先 `list_tear_streams()` 再 `set_tear_estimate()`"。

### D 阶段 → aspen-modeler

prompt 第一条要求固定是：**先判可达性上限，再调参**。
（共沸组成 / 相对挥发度 / 平衡转化率 —— 不可达就直接返回 NEEDS_DESIGN_CHANGE。）

绕行优先级写进 prompt：① sensitivity 插值 ② set_value 塔内规格 ③ COM Design-Spec（≤2 次）。

### E 阶段 → aspen-checker

prompt 里给：`A-plan.md`（目标）、`D-spec.md`（结果）、`apw_path`、
`knowledge\engineering-rules.md`（12 条判据）。

明确写：**你是只读角色。禁止调用任何 set_* / add_* / remove_* / run / reinit / save。**
若发现必须改模型才能取到某个数，返回 `NEEDS_INPUT` 说明要什么数，由主 agent 另派 modeler 取。

多工况取数也在这里：用 `sensitivity` 或 modeler 另派（若需改参数则派 modeler）。

---

## 5. 回执处理表

| STATUS | 主 agent 动作 |
|---|---|
| `DONE` | 判门禁 → 通过则 `state.json.phase` 前进；不通过按同阶段重派（计入预算） |
| `DONE_WITH_CONCERNS` | 记录疑虑到 `state.json.blockers`；判断疑虑是否影响门禁。影响则重派或回退，不影响则前进但**必须写进最终报告** |
| `NEEDS_INPUT` | 用 AskUserQuestion 问人。问题必须带推荐默认值 |
| `NEEDS_DESIGN_CHANGE` | 回退到 A 阶段，`state.json.rollback += 1`。派 designer 时把卡点原文整段复制进去 |
| `BLOCKED` | 不重试同一路径。若还有预算，换路径重派；无预算则进 E 出 HANDOVER |

**每次回执后立刻更新 `state.json`**，这是上下文丢失后的唯一续跑依据。

---

## 6. state.json 契约

```json
{
  "run_id": "20260804-etoh-flash",
  "title": "乙醇-水闪蒸",
  "level": "L1",
  "phase": "C",
  "gate": "pending",
  "iter": { "B": 0, "C": 1, "D": 0 },
  "rollback": 0,
  "apw_path": "D:\\Projects\\aspen-agent\\runs\\20260804-etoh-flash\\model.apw",
  "artifacts": ["00-brief.md", "A-plan.md"],
  "blockers": [],
  "pending": [],
  "updated": "2026-08-04T12:00:00"
}
```

- `gate`：`pending` | `passed` | `failed`
- `blockers`：DONE_WITH_CONCERNS 的疑虑项与 BLOCKED 的卡点，字符串数组
- `pending`：等待人工回答的问题

---

## 7. 交付物写法

### REPORT.md（成功时）
1. 任务与模拟目的（一句话）
2. 最终流程拓扑（文本框图）
3. 关键物流表：T / P / 相态 / 流量 / 关键组分（工程单位，供人阅读）
4. 关键设备参数表
5. 指标达成情况：`目标 | 实际 | 差距%`
6. 12 条校核结果（逐条量化，引用 `E-review.md`）
7. **结论可用性分级 A/B/C/D**（见 `engineering-rules.md` §7）及理由
8. 遗留 warning 与假设清单

### HANDOVER.md（未成功时 —— 本系统的核心价值）
1. 当前模型文件绝对路径 + 打开后应看到的状态
2. 方案摘要（从 `A-plan.md` 压缩）
3. 拓扑与已完成到哪一步
4. **完整归因表**：改了什么 → 结果 → 为什么排除。合并 B/C/D 各阶段的表
5. 物性缺口（BIP 未确认项）
6. **按优先级排序的下一步建议**，每条给出"预计工作量 + 判断依据"
7. 剩余 warning 全文
8. 已排除的路径清单（避免接手人重走）

**任何非成功结局都必须产出 HANDOVER.md。** 只回一句"未收敛"是不可接受的。

---

## 8. 知识回写（每个 run 结束必做）

从本次 run 中提取，追加到知识库：

| 发现 | 写到 |
|---|---|
| 新的 block 端口/COM 节点路径 | `knowledge\mcp-playbook.md` §3 或 §4 |
| 某个绕行路径实测成功/失败 | `knowledge\mcp-playbook.md` §5 |
| 新踩的坑 | `knowledge\pitfalls.md` 对应阶段末尾，注明日期与 run-id |
| 新的工程判据/常识区间 | `knowledge\engineering-rules.md` |

按 `AGENTS.md` 的进化规则：**先加 knowledge，其次改 skill，最后才动 agent。**
