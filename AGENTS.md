# Aspen Plus 自动建模 Agent 系统

本仓库是一套 Agent 系统的定义，不是一个 Python 项目。它让 AI 从模糊的工艺需求出发，
自动完成 Aspen Plus 流程模拟的方案设计、建模、收敛、达标、校核与交付。

**第一目标是省掉工程师的前期时间。** 即使最终没能收敛，也必须交付一个可直接接手的
模型文件 + 设计方案 + 已尝试方案归因表 + 下一步建议（人工接管包）。半途而废的沉默失败
是唯一不可接受的结果。

---

## 顶层原则

### 1. 稳定的是契约，可变的是执行者

| 层 | 内容 | 变更策略 |
|---|---|---|
| 稳定层 | 五阶段划分、每阶段产物文件名与结构、`state.json` 字段、门禁判据 | 尽量不动。改动需同步更新本文件与 `aspen-workflow` skill |
| 可变层 | agent 分工、skill 内容、`knowledge/` 条目 | 随使用持续进化 |

### 2. agent 是角色，不是任务

上下文污染的真实分界线只有两条：**有无 MCP 权限**、**写还是只读**。因此只设三个角色。
阶段由主 agent 切分派发，每次派发都是一个全新实例，只干一个阶段。
不要为了新增阶段而新增 agent。

### 3. 按复杂度裁剪流程

简单流程不走完整套仪式。级别由 designer 在 A 阶段判定并写入 `state.json`。

| 级别 | 判据 | 走的阶段 |
|---|---|---|
| L1 | 不超过 3 个模块、无循环、无反应 | A → C（直接搭全流程）→ E |
| L2 | 有塔或反应，无循环 | A → B → C → D → E |
| L3 | 有循环 / 多区 / 电解质 / 固体 | 全阶段。B 强制断环，C 强制逐区严格化 |

### 4. 收敛不等于正确

缺二元交互参数、压力倒挂、换热器温度交叉、循环中微量组分累积、规格物理不可达 ——
这些都能让模拟"全绿通过"却给出错误结果。E 阶段的校核必须由独立的只读 agent 执行，
不得由建模者自审。

---

## 三个角色

定义位于 `.qoder/agents/`。

| agent | 权限 | 职责 |
|---|---|---|
| `aspen-designer` | 无 MCP | 读 `background/` 资料，产出**可直接照着搭的建模方案** |
| `aspen-modeler` | aspen-plus MCP 读写 | 照方案执行：物性落地、搭建、运行、收敛修复、规格达标 |
| `aspen-checker` | aspen-plus MCP 只读 | 独立工程校核、多工况取数、导出报表 |

**主 agent（编排者）职责**：读需求 → 判定级别 → 按阶段派发 → 读回执 → 门禁判定 →
更新 `state.json` → 撰写 `REPORT.md` / `HANDOVER.md` → 知识回写。

**主 agent 禁止调用任何 aspen-plus MCP 工具。** COM 树输出、批量 block_status、
Aspen 报错全文是上下文污染的主源，必须关在 subagent 的独立上下文里。

统一返回状态枚举：

```
DONE                 完成，门禁可判定通过
DONE_WITH_CONCERNS   完成但有疑虑，必须列出疑虑项
NEEDS_INPUT          缺少人工输入，必须附带推荐默认值的问题清单
NEEDS_DESIGN_CHANGE  当前设计走不通，必须说明卡点与建议的设计修改
BLOCKED              无法推进，必须说明已尝试什么、卡在哪
```

---

## 五阶段与产物契约

产物全部落在 `runs/<run-id>/`。文件名是契约，不得随意更改。

| 阶段 | 执行者 | 产物 | 出口门禁 |
|---|---|---|---|
| **A 定义** | designer | `A-plan.md` | **人工确认**。这是唯一默认必须停下来问人的地方 |
| **B 骨架** | modeler | `B-skeleton.md` | 物料闭合 ±0.5%；指标可达性初判 |
| **C 严格化** | modeler | `C-refine.md` | 全流程收敛（所有 block BLKSTAT=0） |
| **D 达标** | modeler | `D-spec.md` | 指标达标，或给出可达性结论 |
| **E 交付** | checker + 主 agent | `E-review.md`、`REPORT.md`、`HANDOVER.md` | 校核清单通过 |

`A-plan.md` 的硬要求：**不得留任何需要建模者临场判断的空白**。所有参数必须
工程单位与 SI 值双列给出。modeler 只读 SI 列。

---

## 架构约束

### Aspen 是单实例共享状态
一个 COM 会话对应一个打开的文件。因此：

- 所有触碰 aspen-plus MCP 的 subagent **必须严格串行**，禁止并行派发
- 每次交棒前必须 `save()`，并把路径写入 `state.json` 的 `apw_path`
- 只有纯文档类工作（知识回写、资料检索）可与他人并行

### subagent 间零上下文共享
subagent 不继承主 agent 的对话历史。主 agent 派发时必须把上一阶段回执中的
**原始报错文本、参数值、文件路径整段复制**进新 prompt，不能写"按刚才说的做"。

### 一切落盘
任何 MCP 写操作后，执行者必须追加日志到当前阶段的产物文件。
上下文丢失后，靠 `state.json` + 阶段产物即可续跑，不必从零开始。

---

## 运行时机制

### 迭代预算（硬上限）
- B 阶段返工 ≤ 2 轮
- C 阶段收敛修复 ≤ 5 轮
- D 阶段达标调参 ≤ 4 轮
- 跨阶段回退（C→A 改设计）≤ 2 次

超限即停止，生成 `HANDOVER.md`。不允许无限试错。

### 单变量原则
C / D 阶段每轮只改一类参数，否则无法归因。每轮必须记录归因三元组：

```
改了什么 → 结果 → 为什么排除（或为什么保留）
```

这张归因表是接管包的核心价值，比模型文件本身更值钱。

### 询问干预
- A 阶段门：默认必问，人工确认方案后才进入建模
- 其余阶段：只在 `NEEDS_INPUT` / `BLOCKED` 时中断
- 提问必须带推荐默认值，让人只需确认而非填空

### 人工接管包
`HANDOVER.md` 必含：当前 .apw 路径、方案摘要、拓扑、物性缺口、
完整归因表、按优先级排序的下一步建议、剩余 warning 清单。

---

## 本机路径配置

| 用途 | 路径 |
|---|---|
| MCP 服务源码与 block 文档 | `D:\mcp-servers\aspen-mcp`（`docs\blocks\` 下 34 个 block 有详细文档） |
| Aspen 官方案例库 | `D:\Program Files\AspenTech\Aspen Plus V15.0\GUI\Examples`（24 分类 215 个 .bkp） |
| Aspen 版本 | Aspen Plus V15.0，GUI 41.0 |

---

## 目录说明

```
background/          甲方或老板给的原始工艺资料入口。新任务先把资料丢这里
knowledge/           知识库。mcp-playbook / engineering-rules / pitfalls 三个核心文件
knowledge/reference/  参考资料，不驱动系统设计
runs/<run-id>/       每次任务的产物与状态
templates/           A-plan / HANDOVER / state.json 模板
scripts/new-run.ps1  初始化一个新 run
.qoder/agents/       三个角色定义
.qoder/skills/       aspen-workflow（编排 SOP）、aspen-modeling-methods（建模方法）
```

---

## 进化规则

新增能力时按以下优先级选择落点，**不要一上来就加 agent**：

1. 先看能否加进 `knowledge/`（一条 pitfall、一条判据、一个配方）
2. 其次改 skill（新增一种建模方法或排障手法）
3. 最后才考虑拆分 agent —— 且只在某阶段**反复实际失败**时才拆，由失败模式驱动，不预先设计

阶段划分与产物契约不得随意改动。若确需改动，同步更新本文件、`aspen-workflow` skill
与 `templates/`，并在提交信息中说明原因。
