# aspen-agent

通过 Agent 编排在 Aspen Plus 中完成流程模拟：从工艺需求出发，产出 **设计方案（design.md）→ 模拟文件（model.apw/.bkp）→ 模拟报告（report.md）** 三件产物。

本仓库的内容是系统定义（角色、流程、判据、参考文档、辅助脚本），不是独立可运行的应用。运行需要三样外部条件：Qoder、本机 Aspen Plus（V15.0，通过 COM 接口自动化）、`aspen-plus` MCP 服务（源码在本仓库之外）。

## 架构

三个专职 subagent 由主 agent 编排，**只有 modeler 可以写模拟文件**：

| 角色 | 定义 | Aspen 权限 | 产物 |
| --- | --- | --- | --- |
| `aspen-designer` | 读需求出设计方案，模糊处先问用户，问了仍不足才查知识库 | 无（刻意剥夺，强制先想清楚） | `design.md` |
| `aspen-modeler` | 按确认后的 design.md 搭模型、运行、保存，卡住就停下等人工 | 读写（唯一写者） | `model.apw` / `model.bkp` / `state.json` |
| `aspen-analyzer` | 收敛后采样、核查物料衡算与指标、必要时单变量扫描，写报告 | 只读 + sensitivity | `report.md` |

```
00-brief.md ──> designer ──> design.md ──用户确认──> modeler ──收敛──> analyzer ──> report.md
                     │                              │
                 NEEDS_INPUT                  PAUSED / 人工检修 / 续跑
```

MCP 是唯一的 Aspen 通道：主 agent 不直接调用 aspen-plus 工具；designer 没有 MCP 权限；analyzer 禁用一切写操作。

## 建模状态机（S1–S9）

modeler 按状态推进，每步有明确过关判据，失败先写 `state.last_error` 再停下，**绝不推倒重建**（禁用 `new_simulation`）：

| 阶段 | 内容 | 关键判据 |
| --- | --- | --- |
| S1 | 新建模拟、显示 GUI、关闭自动刷新 | `status()` 连接正常 |
| S2 | 单位集 | `get_unit_set()` 返回 SI |
| S3 | 加组分 | 数量、标签与 design.md 一致（>8 字符标签会被截断） |
| S4 | 物性方法 + BIP 核查 | 关键二元对参数非零；缺失的用 UNIFAC 估算，写进 note 不许沉默 |
| S5 | 建模块 | 数量与 design.md 一致 |
| S6 | 连线 | 无断开进料 / 连接不完整警告 |
| S7 | 填参数 | 先设规定选项，再填值，最后 `validate_block`；循环物流写 tear 初值 |
| S8 | 完整性检查 | `Engine.Ready = true`，无 Critical 缺口；连续 3 轮补不干净 → PAUSED |
| S9 | 运行 | 全块 BLKSTAT=0 + 关键流股结果量级与预期区间相符；不满足立即 PAUSED |

**S6 后的 PFD 排布交接（LAYOUT_READY）**：拓扑完成后 save + close_file 释放文件，主 agent 用 `scripts/relayout-pfd.ps1` 离线排布（块数 <5 自动跳过），再重派 modeler 从 S7 续跑并做加载验证。排布失败不阻塞建模。

**单位约定**：参数按“工程值 + unit”原样传给 MCP（如 `TEMP 30 C`），换算由工具完成；不带 unit 的值按 SI 解释。无量纲量（回流比、分率、塔板数）不传 unit。

**收敛 ≠ 正确**：缺 BIP、压力倒挂、共沸约束都可能让模拟“全绿”却错——designer 须提前点出可达性上限，modeler 在 S4 核查 BIP，analyzer 做物料衡算复核。

## Run 结构与产物

`scripts/new-run.ps1` 创建一次任务的工作目录（设计/报告/状态文件随流程逐步生成，不会一次建齐）：

```
runs/<YYYYMMDD-名称>/
├── 00-brief.md     任务需求（模板 templates/00-brief.md，需人工填写）
├── design.md       设计方案（designer）
├── report.md       模拟报告（analyzer）
├── state.json      状态机进度，续跑的唯一依据
├── journal.md      编排日志（主 agent 追加）
└── sim/            model.apw / model.bkp + Aspen 伴生文件（.gitignore 排除）
```

## 使用

1. 克隆并在 Qoder 中打开，按上述“外部条件”准备好环境。
2. 创建任务并填写需求：

   ```powershell
   .\scripts\new-run.ps1 -Name "gas-flash"   # 生成 runs/<今天日期>-gas-flash/
   # 编辑 runs/<今天日期>-gas-flash/00-brief.md
   ```

   `new-run.ps1` 硬编码了根路径 `D:\Projects\aspen-agent`，克隆到其他位置需先改脚本。
3. 在 Qoder 对话中给出任务目录绝对路径，走“设计 → 确认 → 建模 → 收敛确认 → 分析”流程；收敛后系统会停下等你确认再分析。

**续跑**：任意一步中断（PAUSED / 人工检修后），再次派发时给同一 run 目录并注明“续跑”。modeler 会读 `state.json`、重开模型、与已声明产物做轻量对账（块数 / 组分 / 物性方法），不一致以模型为准，然后从断点继续。

## 边界

- **单实例**：一个 COM 会话对应一个打开的文件，不支持多任务并行建模。
- **收敛策略**：调参须用户授权，预算 ≤3 次、每次只动一个参数；改拓扑/物性方法须交回 designer，不在运行期改动。
- **不支持**：Design Spec / Calculator / Optimization / Hierarchy（设计层直接排除）；分析层只提供 ≤8 点的单变量扫描，不是优化器。
- **已知坑**：save 到已存在的 apw 会弹覆盖对话框、模态阻塞 COM（超 1 分钟即判中招停机）；`open_file` 路径须用反斜杠；参数名不统一（`visible` 用 `show`、`connect` 用 `source_block`）须按 schema 调用。细节见 `.qoder/agents/aspen-modeler.md` 与 `.qoder/skills/aspen-build-refs/SKILL.md`。

## 知识库

| 目录 | 内容 |
| --- | --- |
| `knowledge/blocks/` | Aspen 单元操作模块参考卡片（含 advanced 与总索引） |
| `knowledge/reference/` | 案例与工程经验（如 V15 碳捕集/绿氢分析、单位机制改造纪要） |
| `background/` | 原始工艺资料入口 |

## 参考

- [编排规则与权限边界](AGENTS.md)
- [需求模板](templates/00-brief.md)
- [模块参考索引](knowledge/blocks/index.md)
