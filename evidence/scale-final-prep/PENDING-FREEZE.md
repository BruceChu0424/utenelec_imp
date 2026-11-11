# D3最终候选重跑准备：未启动验收

本准备基线为 `518008bae71d386b50ce07fd28c7a5b375d75699`，**不是最终冻结SHA**。独立分支/树为 `uimp/feedback-scale-final-prep-20261111` / `D:/Projects/uten_imp_worktrees/feedback-scale-final-prep-20261111`。实际main复核为 `d5200b6bf68aae203542c3828ddc0d6498be2870`，且是518祖先；没有修改main或产品。

Root仍在收尾UI；只有收到明确最终冻结SHA后才创建新执行工作树、run-tag并执行。当前仅检查脚本语法与默认plan-only行为，没有Maven、PG、物理成表或验收启动，也未创建runs目录。

## 冻结后原命令

先从冻结SHA创建独立只读源码工作树（以下占位符不可直接执行，不使用Root live树）：

```powershell
git worktree add -b uimp/feedback-scale-final-<tag> D:/Projects/uten_imp_worktrees/feedback-scale-final-<tag> <FROZEN_40_SHA>
& D:/Projects/uten_imp_worktrees/feedback-scale-final-prep-20261111/evidence/scale-final-prep/run-final-d3.ps1 `
  -WorkspaceRoot D:/Projects/uten_imp_worktrees/feedback-scale-final-<tag> `
  -ExpectedRevision <FROZEN_40_SHA> -RunTag <fresh-tag> -Execute
```

脚本缺省只输出计划，不执行。实际执行必须显式Execute、完整40位SHA、源码HEAD相同、相关源码无未提交/未跟踪变化、输出目录从未存在。新fresh Maven/build/TMP/probes/日志均在本准备树的新runs/tag，PostgreSQL由原测试新建non-reused Testcontainers及动态端口；不使用28630/26630、不触Root live classes。单fork，测试heap3g/Maven1800m/物理2304m，正常`mvn test`重编译，禁止旧overlay/class目录签最终。

原23选择器和Maven参数在run-final-d3.ps1中固定；正常构建后按当前冻结POM新生成依赖classpath，不复用旧deps。物理Java helper从同一冻结Git blob逐字节落盘，用本轮fresh main classes生成，再SAX逐行重开。

## 23原例与必保事实

`original-23-inventory.json`来自实际7b旧轮XML逐case清单，防止漏用例/重叠计数。下一轮封存器确认原23全在，新增case另列；任何失败、异常、跳过、缺尾回执或退出255都不能签通过。

| 原组 | 数量 | 必须保留的实际验证 |
|---|---:|---|
| MasterDirectory指定两例 | 2 | 1626反套数/首1.125及两行1.125/2.125；真50002中唯一选50001、另1匹配未选、逐code/精确tqty顺序，missing/撤权/取消/Scope清理；实际50001 XLSX逐行SAX重开 |
| CompleteExportScale指定例 | 1 | 正常V897造真100000再完整升级；独立SQL count/min/max/sum，1.2345/123450.0000；fetch1000独立有序hash与Source相同；1000批、逐code/金额与managed实体边界 |
| ExportRowSelectionTest | 12 | 原精确数字/文字身份、去重/缺失/漂移、隐藏字段、极端数值、中断与后续操作不污染 |
| ExportSelectionBudgetTest | 3 | 真50001同类selector、UUID规范/去重/缺失；超实际字节/估算内存预算拒绝 |
| MasterExportSelectionAspectTest | 1 | 原controller选中Scope绑定及异常清理 |
| ReportExportQueue指定四例 | 4 | 取消确认前slot保留/不发布；原identity/request/expiry不可变；回滚无半提交；RR实际文件与下载撤权 |

物理补充不混入23：**1048600实际数据行、2sheet、R0至R1048599每行SAX**；实际页后取消不发布半成品、临时目录0。100k真业务源与百万合成成表分别判定，不拼成百万行业务/浏览器链。

新轮必须分别记录造数、初次迁移、升级、独立SQL、Source、成表、重读毫秒，不与旧轮配平、不把旧机器耗时当合同。保独立SQL有序hash、全部XLSX实际路径/字节/raw SHA、六份XML/完整stdout/退出码、环境、源起止与关键源码Git blob SHA。大小和取消/失败清理按原合同，不扩大导入/业务写入批次。

封存器只在原23全部通过、Maven/物理exit0、源起止相同、实际文件摘要相符、取消清理0时输出passed；否则保留failed-or-incomplete及全部原件。源指纹为Git blob原字节，日志/XML/下载按实际原始文件字节；属性文件为这些原件禁用换行转换。

## 历史与重启边界

上一轮实际7b原23+百万文件不重标。`historical-evidence-preservation.json`逐文件复核原manifest的32份原始证据，全部存在，字节/SHA一致；原毫秒和文件没有覆盖。

Root明确更正：本次重启实际观察的exit255是Docker元状态中 `uten-feedback-final-20261110`、`uten-feedback-b-legacy-prep-20261111`，**不是已证实scale自有容器或本轮测试退出255**。Root保留并恢复原数据/log/classes；此处不制造scale的255指针，不用旧通过或库恢复冒认新的完整运行。新轮仍fresh独立PG。将来本轮若发生真实255/缺尾，一律保中断原件并用新tag完整重跑。

当前仅准备，不推送、部署、正式包或公司库操作。实际运行和最终报告等Root明确冻结后followup。
