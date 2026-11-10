# 仓库与品质截图反馈验证

范围：图 1、3、10、11、13，并补图 7 涉及的仓库/品质空表。源码位于 `uimp/screenshot-feedback-20261110`；未发布、未打包上传。

## 根因与实现

| 原图 | 根因/修改 | 保留边界 |
|---|---|---|
| 1 | 返回任务中心会刷新本人仓库范围；刷新期 `confirmedMyWarehouseScope` 返回空，连带把已确认的分类徽章投影为空。仅展示投影在同身份/权限/服务器/读取修订下沿用刷新前快照；确认撤权、失败或身份边界后撤下。 | 命令入口仍要求当前确认的仓库范围；不以旧展示数授权写入。 |
| 3 | 任务表删除来源单据、往来方列；销售等非领料分类删除生产工单列，生产领料/全部任务保留相关工单入口。数量使用公共 `emphasized` 红色粗体。出库库位号由精确行货品的 `goods.stock_place` 带回，表头说明其为货品资料参考库位，实际出库仍须核对。 | 服务端来源、客户、生产链仍保留；删除列不删除溯源事实。库位搜索/排序/导出同步。已删除列的旧搜索不继续作为隐藏条件。 |
| 10 | 入库任务中心此前按归属份额逐行展开，正常/计划公共/实际超产因此拆成多行。登记与最终点收均按真实 `output_lot_id` 及仓、货品、颜色、单位合成物理批；无批号的历史行保持独立。 | 份额不合并落账、不改变库存归属；行带完整来源/库存明细 ID。登记按 `lotIds` 办理；点收展开本批全部 `documentItemIds`，不只处理代表行。详情仍能展开全部真实份额。 |
| 11 | 已有不确定进度协议正确，但公共 `_SweepBar` 的短条没有高度，实际布局为 0，高度为 6 的轨道可见、扫动短条不可见。唯一组件加 `heightFactor: 1`。 | IQC 整份报告单事务、单 HTTP，不伪造逐单完成百分比。等待显示扫动条与已用时间；失败后保留原报告及原幂等键重试。 |
| 13 | 领料预览原合同只有待申请量，未返回实存参考。服务端同一预览查询增加精确仓/货/色实存量及库存基本单位；客户端单独列显示完整十进制。 | 实存含预留，不冒充可领量，不限制申请；不把库存参考放入提交指纹。单位缺失/计量待核返回未知而不是 0；筛选来源后库存值保留。 |
| 7 | IQC 批量审批和成品批量点收在无行时绕过表格。改为保留原列及空表；IQC 无选中行时禁提交。 | 无行不会扩大写入范围，也不构造来源或可办理数据。 |

## 已完成的 Flutter 验证

- 9 套扩展回归 244 项通过：`warehouse-flutter-244.log`。覆盖大于 2000 行完整读取/打印、滚动不请求、切来源/身份/仓库/服务器后迟到结果退休、草稿恢复、取消返回、原请求重试、产成品整批登记与权限边界。
- `same-owner scope refresh keeps badges across rapid rechecks and confirmed removal`：连续 5 次范围重查不清徽章；授权闸门在重查期仍关闭；确认仓库从范围移除后撤下徽章。
- `selected merged output lot defaults and submits the entire 20000 plus 1000 physical quantity`：选择物理批进入登记，默认实收及提交均为 21000，提交按批号，不按代表份额 ID。
- `merged final-count row opens both physical source items under the original document`：最终点收页同时收到正常、超产两份明细 ID 及同一原单号；见 `build/warehouse-feedback-count-route-v3.log`。
- 修改涉及的 13 个 Dart 源码/测试入口静态分析：`build/warehouse-feedback-analyze-final.log`，`No issues found!`。
- IQC 缺陷先红：`warehouse-iqc-band-before.log` 断言扫动条实际高度得到 `0.0`。修后同一延迟/超时/重试测试通过：`warehouse-iqc-band-after.log`。校验短条高度大于 0、800ms 与 3800ms 位置不同、无假百分比、无等待重放。

渲染证据：

- 修前：[仅有轨道](warehouse-iqc-before-invisible-band.png)
- 修后：[800ms](warehouse-iqc-after-0800ms.png)、[3800ms](warehouse-iqc-after-3800ms.png)

以上为实际 Flutter 页/公共组件渲染、受控合成数据及延迟响应；不作为公司业务数据 UAT 或 Win7 真机验收。根会话另做运行时整合检查。

## 服务端与多端状态

最新版服务端 9 套 94 项通过，0 失败、0 错误、0 跳过，`BUILD SUCCESS`；逐套回执见 [warehouse-backend-receipt.json](warehouse-backend-receipt.json)，完整本地日志为 `build/warehouse-feedback-db-latest.log`。已核对编译类包含最新 FINAL_COUNT 聚合及完整明细 ID；首轮编译期间的旧类结果未用作最终证据。两类迁移夹具均实际从空库完成 1067 个迁移到 V1128。

真实链路 `WorkshopPublicSurplusEndToEndTest#handoffLotOf1100IsOneInboundOneCountTaskOneNoticeAndShortCountTrimsActualSurplusFirst` 已通过：从合法正常/超产报工，任务中心同批一行，到两份全登记、同键无重复、FQC 后仍一行、实际点收 1060 并保留超产余量 40。精确仓货色库存、缺失基本单位返回未知及库存参考不进入业务提交指纹也在本轮真 PostgreSQL 用例中通过。

原生 Flutter 运行补充已完成：独立 `integration_test/warehouse_feedback_runtime_test.dart` 在真实 Windows 引擎运行 5 场景全部通过，Debug 构建 33.6 秒、场景运行 16 秒，回执 [warehouse-native-five-pass.log](warehouse-native-five-pass.log)。覆盖 IQC 延迟/超时原报告重试、徽章连续 5 次重查及确认撤权、20000+1000 整批默认实收并提交 21000、最终点收同时携带两份明细 ID、精确库存基本单位与来源筛选保留。

保留真实引擎暴露的两处夹具失败及修正：

- IQC 网络 gate 曾在外层测试 error Zone 创建，真实引擎下错误完成外逸并污染后续测试；改为在请求 Zone 创建/完成，未放宽生产异常处理、原子性或重试合同。[原失败节选](warehouse-native-iqc-before.log)、[独立修后通过](warehouse-native-iqc-isolated-pass.log)。
- 成品登记夹具在异步 API 回调中用 `flutter_test.expect`，与 live `pumpAndSettle` 的 guard 冲突；改用 `expectSync`，仍严格校验原 reportIds。加载等待以实际表格到达为准，边界为 5 秒，不用“没有待绘制帧”推定 IO 已完成。[原失败与定位栈](warehouse-native-arrival-before.log)。定位时的临时生产诊断已全部撤销，该生产页没有本次差异。

以上原生结果仍是合成夹具的真实 Flutter 引擎验证，不等于公司业务数据 UAT 或 Win7/WPF 真机业务验收。

Web/现有 Flutter 桌面/移动共用修改后的 Dart 实现。WPF 相关业务入口尚未迁移，以下项目维持 `todo`，不提高完成状态、不开放占位写入口：`W7-BIZ-104`（领料汇总）、`W7-BIZ-130`（品质批量审批）、`W7-BIZ-182`（成品入库任务）、`W7-BIZ-194`（入库任务中心）、`W7-BIZ-197`（出库任务中心）、`W7-BIZ-210`（仓库任务中心）。WPF 公共 `UtenBusyDialog` 使用显式 `Height=4` 的原生 ProgressBar，不受此次 Flutter 短条零高度问题影响。
