# Aspen-agent

面向 Aspen Plus 的流程模拟 Agent 系统，通过 Qoder 协调设计、建模和分析三个角色，将工艺需求逐步转为设计方案、模拟文件和分析报告。

项目强调可确认、可暂停、可续跑：即使不能一次完成模拟，也保留已完成的模型与进度，方便人工介入。

> 本仓库提供 Agent 定义、操作参考和辅助脚本，不包含 Aspen Plus 或连接 Aspen 的 MCP 服务，也不是克隆后即可运行的独立应用。

## 工作流程

| 角色 | 职责 | 主要产物 |
| --- | --- | --- |
| `aspen-designer` | 根据需求设计流程，说明假设、约束和可达性 | `design.md` |
| `aspen-modeler` | 按确认后的方案搭建、运行并保存模型 | `sim/model.apw`、`sim/model.bkp`、`state.json` |
| `aspen-analyzer` | 采样结果、核查物料衡算与指标，必要时做单变量扫描 | `report.md` |

```text
工艺需求 → 设计方案 → 用户确认 → 建模与运行 → 用户确认 → 结果分析
                                  ↓
                            暂停 / 人工干预 / 续跑
```

建模按状态机逐步推进；不收敛时保存并暂停，调参需要用户授权，不从头重建。流程图排布由辅助脚本在拓扑完成后离线处理，失败不阻塞后续建模。

## 环境要求

- **Windows + Aspen Plus**：项目面向 Aspen Plus V15.0，需可用的安装、许可和 COM 自动化接口；其他版本兼容性未验证。
- **Qoder**：用于加载 `.qoder/agents/` 和 `.qoder/skills/` 中的角色与技能，并在本机配置可用的模型。
- **`aspen-plus` MCP 服务**：连接 Agent 与 Aspen 的外部工具服务，需单独安装并接入 Qoder；其源码不在本仓库。
- **PowerShell**：用于创建任务目录、离线排布和窗口辅助操作。

本仓库尚未提供外部 MCP 服务的完整安装与启动配置；开始建模前，请先确认 Qoder 能连接该服务并操作本机 Aspen。

## 开始使用

1. 克隆仓库，在 Qoder 中打开项目，并准备上述环境：

   ```powershell
   git clone git@github.com:Naraku215/Aspen-agent.git
   ```

2. 创建任务目录。当前 `scripts/new-run.ps1` 将项目根路径固定为 `D:\Projects\aspen-agent`；若克隆到其他位置，需先自行调整该脚本的路径。然后在项目根目录执行：

   ```powershell
   .\scripts\new-run.ps1 -Name "gas-flash"
   ```

3. 编辑生成的 `runs/<日期>-gas-flash/00-brief.md`，替换模板示例，填写进料、目标指标、操作条件与约束。
4. 在 Qoder 对话中提供任务目录的绝对路径，例如：

   > 请读取这个任务目录的需求，先生成设计方案并给我确认，再开始建模；模拟收敛后，先征得我确认再分析。

5. 需要续跑时，提供同一个任务目录，说明已完成的人工修改，并明确要求“读取 `state.json` 续跑，不要重新建模”。

## 目录结构

```text
.qoder/agents/       三个角色的职责与执行流程
.qoder/skills/       设计与建模操作参考
background/         原始工艺资料
knowledge/blocks/   Aspen 模块参考卡片
knowledge/reference/ 案例与工程经验
runs/               每次任务的需求、设计、进度、日志和报告
scripts/            任务初始化、PFD 流程图排布、窗口辅助脚本
templates/          工艺需求模板
AGENTS.md           主 Agent 编排规则与权限边界
```

## 产物与边界

- 每次任务保存在 `runs/<YYYYMMDD-名称>/`；设计、模型、报告随流程逐步生成，不会在初始化时全部创建。
- Aspen 会话是单实例共享状态，不应让多个建模任务同时操作；只有建模角色可以写模型，分析角色不得修改基准模型。
- **收敛不等于正确**：物性方法、二元交互参数（BIP）、压力关系及分离极限仍需核查；不保证任意流程都能自动收敛。
- `.apw`、`.bkp` 等模拟文件默认被 Git 忽略，需另行备份或交付；设计、报告与进度文档可以纳入版本管理。上传前仍应检查其他备份、临时文件和敏感工艺资料。

## 进一步阅读

- [编排规则与断点续跑](AGENTS.md)
- [工艺需求模板](templates/00-brief.md)
- [Aspen 模块参考索引](knowledge/blocks/index.md)
