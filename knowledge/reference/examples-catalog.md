# Aspen 官方案例库索引

位置：`D:\Program Files\AspenTech\Aspen Plus V15.0\GUI\Examples\`
共 24 个分类、215 个 `.bkp`（Aspen Plus V15.0）。

**定位**：这是**可选建模方法**的素材来源，不是本系统的默认路径。默认从零新建
（`new_simulation`）。只在下列情形才检索案例库：

- 遇到不熟悉的**物性体系**（电解质、聚合物、固体、PVT 调优）
- 遇到不熟悉的**单元操作组合**（速率法吸收塔、多级冷剂、结晶+干燥串联）
- 需要一个**可信的参照基准**来判断自己的结果是否离谱

用法见 `.qoder/skills/aspen-modeling-methods/SKILL.md` 的"案例库逆向提取配方"一节。

---

## 分类与数量

| 分类 | .bkp | 适用场景 |
|---|---|---|
| Getting Started | 20 | 基础流程、闪蒸、原油、电解质入门。**最适合验证 MCP 能否打开 .bkp** |
| Carbon Capture | 43 | 全套 ELECNRTL 速率法胺吸收模型（MEA / MDEA / DEA / DGA / DIPA / AMP / PZ / NH3 / NaOH / K2CO3 及混合胺） |
| PVT Experiments | 30 | PR 模型调优、闪蒸实验拟合（上游油气） |
| Solids Modeling | 22 | 干燥、粉碎、流化床、造粒、结晶 |
| Batch Modeling | 17 | 间歇精馏、反应精馏、溶剂置换 |
| Polymers | 13 | PP / PS / PMMA / 乳液聚合 / 聚合物数据回归 |
| Bulk Chemicals | 12 | 异丙苯、甲醇合成（多种工艺路线）、乙二醇、三效蒸发 |
| Upstream | 9 | 结垢模型（各类盐体系） |
| Biofuel and Biochemicals | 8 | 生物柴油、热解 RYIELD、厌氧消化、SAF |
| Hydrogen | 8 | 碱性电解槽、氨分解、H2 深冷、混合冷剂预冷、甲烷热解 |
| Metals and Minerals | 5 | 高炉、酸再生、正极材料、NMP 溶剂回收 |
| Fertilizers | 4 | 磷酸铵、硫酸、结晶+干燥 |
| Power | 4 | IGCC、NGCC 联合循环、热电联产 |
| How To | 4 | Hierarchy 分层建模、数据拟合、DRS |
| Chemapp | 3 | 冶金相平衡 |
| Energy Analysis | 3 | 乙烯装置/异丙苯装置能量分析基准 |
| Pharmaceuticals | 3 | 溶剂、青霉素、哺乳动物细胞培养 |
| Energy | 2 | 碳氢反应、常压蒸馏 CDU |
| Midstream | 2 | TEG 脱水、NGL 回收 |
| Safety | 2 | 泄放（PRD） |
| Plant Data | 1 | 装置数据（C2SEO） |
| EDR / Hybrid Models / Natural Resource Efficiency | 0 | 无 .bkp（其他格式或空） |

---

## 高价值定位表

按"我要做什么" → "先看哪个案例"。

| 需求 | 案例 |
|---|---|
| 最简闪蒸/入门验证 | `Getting Started\flash.bkp` |
| 电解质体系入门 | `Getting Started\elec1.bkp`、`elec2.bkp` |
| 原油常减压 | `Getting Started\crude.bkp`、`preflash.bkp`、`vacuum.bkp`；`Energy\cdu.bkp` |
| 胺法脱碳（速率法） | `Carbon Capture\ELECNRTL_Rate_Based_MEA_Model.bkp`（其余按胺种替换） |
| 混合胺 | `..._MEA+MDEA_Model.bkp`、`..._PZ+MDEA_Model.bkp`、`..._DEA+MDEA_Model.bkp` |
| 苛性碱/碳酸钾吸收 | `..._NaOH_Model.bkp`、`..._K2CO3_Model.bkp` |
| 反应 + 分离 + 循环全流程范式 | `Bulk Chemicals\cumene.bkp`（异丙苯，教科书级）；`Energy Analysis\2.1 Cumene Plant Base Case Model.bkp` |
| 甲醇合成（多路线对比） | `Bulk Chemicals\methanol synthesis - ici syntex quench reactor process.bkp`、`...lurgi two stage process.bkp` |
| 乙二醇全厂 | `Bulk Chemicals\Ethylene Glycol Plant Example.bkp` |
| 蒸发浓缩 | `Bulk Chemicals\Triple-Effect Evaporator.bkp`；`Metals and Minerals\Caustic Evaporators.bkp` |
| 三相/液液分相 | `Batch Modeling\3phase.bkp`、`Bulk Chemicals\3phase.bkp` |
| 共沸/共沸精馏 | `Batch Modeling\Azeotrope.bkp` |
| 反应精馏 | `Batch Modeling\ReactiveDistillation.bkp` |
| 间歇过程 | `Batch Modeling\Multistep.bkp`、`SolventSwap.bkp` |
| 天然气脱水（TEG） | `Midstream\teg.bkp` |
| NGL 回收 | `Midstream\ngl.bkp` |
| 深冷 / 混合冷剂 | `Hydrogen\H2 cryogenic process.bkp`、`Single mixed refrigerant (SMR) PRICO precooling.bkp`、`Cascade mixed refrigerant (CMR) precooling.bkp` |
| 电解槽 | `Hydrogen\Industrial Scale Alkaline Electrolyzer.bkp` |
| 气化 / IGCC | `Power\igcc.bkp` |
| 燃机联合循环 | `Power\Natural Gas Combined Cycle (NGCC) Power Plant.bkp` |
| RYIELD 用法（热解/气化） | `Biofuel and Biochemicals\HTL RYIELD.bkp`、`Softwood biomass ... pyrolysis with RYIELD.bkp` |
| 固体干燥 | `Solids Modeling\1 Belt Dryer Base Case.bkp`、`Contact Dryer TPA Example.bkp` |
| 结晶 + 干燥 | `Fertilizers\CrystallizationAndDrying.bkp` |
| 流化床反应器 | `Solids Modeling\Fluidized bed reactor demo.bkp`、`CFB_Example.bkp` |
| 聚合物 | `Polymers\polypro.bkp`（PP）、`ps.bkp`（PS）、`pmma.bkp` |
| 分层建模（Hierarchy） | `How To\Hierarchy.bkp` —— 大流程分区的官方做法 |
| 数据回归 / 参数拟合 | `How To\datafit1.bkp`；`Bulk Chemicals\methanol synthesis-data regression.bkp` |
| 安全泄放 | `Safety\PRRELIEF.bkp` |
| 硫酸 | `Fertilizers\Aspen_Plus_H2SO4_Model.bkp` |
| 结垢/水化学 | `Upstream\Aspen_Plus_Scaling_Model*.bkp` |

---

## 未验证事项

- `open_file()` 能否直接打开 `.bkp`（而非 `.apw`）**尚未实测**。
  首次使用案例检索时用 `Getting Started\flash.bkp` 做一次验证，结果回写到本文件。
- 若不能直接打开：退化路径是人工在 GUI 里打开并另存为 `.apw`，或仅把案例当**文献参照**
  （从文件名与分类推断配方，不打开）。
- 打开官方案例后**禁止在原路径保存**（Program Files 目录，且会污染安装）。
  必须 `save("D:\Projects\aspen-agent\runs\<run-id>\from-example.apw")` 另存。
