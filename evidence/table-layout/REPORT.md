# 冷读性能：表格布局和列缓存半包

产品提交 `49fe8d2a2ec69860e7eb63fd282d461cd976fe26`，只修改 `MasterDataTableView.dart` 和新建三项 Widget 交互/计数测试。基线 `42b7bf76ffb18bd89dae332f9be08b30fc1a696a`；独立工作树 `D:/Projects/uten_imp_worktrees/feedback-table-layout-20261110`，分支 `uimp/feedback-table-layout-20261110`。根任务的 controller 单飞队列与 `valuesRevision` 提交 `c60a2b5fc5be34ba18c05639a9e41b7b42789c0c` 在本树 cherry-pick 为 `b39eebfea`，仅用作真实依赖编译回归；UI 产品提交不重复修改 controller。

## 原失败与合法对照

`logs/private-flutter-baseline-frames.log` 为修改 table 前的有效反例：真实 `PagedReadWindowSession` 连续前缀 50→100→200→400→800→1626，每批仍执行扩展 values 读取。在已完成最初 50 行后计数，实际 `widthCells=3988`，新增只有 1576 行；列索引重建 10 次。断言期望 1576，原失败保留。相同 key 的全新列闭包改变显示值，以及真实持久化单元格/definition 更新的两个合法对照均通过。

第一轮 `baseline.log` 使用 pumpAndSettle 等待尚未完成的逐批加载动画，三个夹具均超时；这是夹具等待错误，不计作产品性能反例。改为逐批实际泵 24 帧（16ms/帧），最终完整结果后再 settle，得到上述有效红例。没有降低计数或业务断言，原错误日志照留。

`candidate.log`：三项全部通过；原计数变为 `widthCells=1576`，恰为真实新增行，`indexBuilds=0`。values 端点没有跳过，完整表格 1626 行仍在。其余两项验证新闭包即时显示并量宽，真实扩展字段长值和新定义名称继续发布、量宽。

## 维护入口和保留合同

`_refreshPlatformPresentation` 为表格内部唯一的 schema/layout/真实扩展值发布判断入口：

- schema 使用真实授权代次、priceVisible、服务端/本地表格模式和完整 projection definition（包含公式依赖）判断；真实变化才失效平台列缓存。
- 个人 layout、查询生命周期、默认列/别名、临时前导列、列菜单能力及真实非空揭示字段变化才重应用布局。行追加和 loading 首尾不再无条件清索引、重应用布局或设 widthsDirty。
- 原 `_columns` 对 `widget.columns` 实例的检查继续保留，当前闭包继续即时生效；没有按同名 key 保存旧闭包。度量字段/定义真实变化才清文本度量；新数据沿用原时间/单元格预算续量，已手调宽度照留。
- controller 的 `valuesRevision` 表示真实接受/保存/草稿/权限清值，loading 通知不计作值变化。有扩展列时真值更新仍可涉及旧前缀任一行，继续预算扫描并利用已量文本缓存；纯系统列无需因此重扫系统列宽。`selected=[]` 的正确 persisted cells 发现未删，读取由根任务 controller 负责。

共享 Flutter 表格的 Web/现有桌面/移动调用方统一使用此入口；WPF 为另一原生实现，本提交不修改或宣称其界面性能通过。业务排序、筛选、精度、原始输入、草稿、未知提交、权限 mask 和输出身份合同保持。

## 验证

| 日志 | 实际结果 |
| --- | --- |
| `private-flutter-regression.log` | 19 文件，137 通过，0 失败/跳过。 |
| `private-flutter-analyze.log` | 两个修改文件，No issues found。 |
| `private-flutter-candidate.log` | 原三项交互/计数反例及合法对照 3/3；1576/0 指标。 |

19 文件覆盖原量宽缓存与时间预算、富输入量宽、拖宽草稿、列显示/隐藏/菜单/搜索/前导列、local work、混合颜色 cell scope、平台价格权限撤回/历史/持久化 CAS/计算列/草稿/恢复/删除、查询返回、逐批选择和 controller 单飞/代次。完整命令存于每个 `private-flutter-*.json`，共享 SDK 前后原输入哈希相同，`sdk_unchanged=true`。本地 Widget 合成服务证据不能写成真 HTTP/Windows 冷读取已过一秒。

## 同最终候选复跑

`rerun.ps1` 只执行本组 Widget 回归和静态检查，使用项目私有 Flutter 工具，按新 RunName 留日志、拒绝覆写旧日志：

```powershell
pwsh -File evidence/table-layout/rerun.ps1 -WorkspaceRoot <整合候选工作树> -RunName <最终SHA短码>
```

最终同 SHA 的 Windows/Web 真冷读首 50 出现、完整结束和交互响应须分别实测并保留日志，不能用本组计数推定时延过线。根任务另将新验证人做独立复核，当前报告为实施者自己的公共层/调用方证据。没有合并 main、推送、部署或正式打包。
