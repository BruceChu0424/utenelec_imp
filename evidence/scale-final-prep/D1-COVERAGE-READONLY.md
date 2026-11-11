# D1/D3调用覆盖只读复核

参考源码 **518008bae71d386b50ce07fd28c7a5b375d75699**，不是最终验收。已按frontend-design及现有Uten组件/完整资格合同只读核对，没有改产品、跑UI/Native/PG或提升WPF状态。

## 十主档与排序

公共注册/权限/投影入口：`server/.../application/port/MasterReportExportPort.java`十report，`report:export`权限及`master_<report>`投影scope。后台 `MasterReportExportSource.read`回到原业务service；普通导出和后台作业共用原筛选、角色字段掩码、来源与Source mapper，不另建“导出全部”旁路。

| report | 原service的export排序合同 | 后台传参 | WPF已有原生输出关系 |
|---|---|---|---|
| goods | GoodsService.export(filter,sort,order)，保原stock特殊排序 | sort/order原样传入 | 有GoodsWorkspace读取候选，无此主档输出消费者；不算完整迁移 |
| client | ClientService.export(filter,sort,order) | 同左；缺省excludeLegacyFinanceStub与controller一致 | 未迁移 |
| supplier | SupplierService.export(filter,sort,order)，保原loss特殊排序 | 同左 | 未迁移 |
| account | AccountService.export(filter,sort,order) | 同左 | W7-BIZ-020 todo |
| currency | CurrencyService.export(filter,sort,order) | 同左 | W7-BIZ-024 todo |
| mould | MouldService.export(filter,sort,order) | 同左，原list相同TableSort | W7-BIZ-031 todo，无模具写/输出壳 |
| color | ColorService.export(filter)，原合同无sort/order | 不虚构排序服务 | W7-BIZ-023 todo |
| unit | UnitService.export(filter)，原合同无sort/order | 同左 | UnitsWorkspaceView → UnitPrintWindow/UnitExportWindow → `master/unit`，实际适用 |
| warehouse | WarehouseService.export(filter)，原合同无sort/order | 同左 | W7-BIZ-038 todo |
| settlement_method | ReferenceMethodService.exportSettlementAdmin(filter)，原合同无sort/order | 同左 | W7-BIZ-035 todo |

六类支持排序并非允许任意字段；沿各service白名单/业务差异。TableSort.resolve对合法字段加稳定id次序。模具明确支持`tqty`；缺省code ASC/id ASC，不能把不支持的code DESC当成原合法反例。原687秒造数旧夹具误用排序的失败日志保留，不改写成已证实产品排序缺陷。

Flutter路径：`mould_category_page.dart`的loadPage/loadComplete均传q.sort/q.order；`master_entity_detail_pane.dart`同一捕获查询供列表、exportQuery和完整print snapshot；`master_export_job.dart`冻结filter/selectedIds/sort/order；`ReportExportJobRequest.create`把sort/order放到作业顶层。现有Master完整资格入口在范围确认/print/export持续复查owner、读修订与查询；逐批展示不能产生输出资格。实际UI仍须最终候选重跑，静态调用相同不代替交互。

模具`mouldType`保留屏幕/打印占位，定义exportable=false；公共master_data_table_view/uten_export_button过滤导出列。服务端未知字段仍拒绝，不能只靠客户端剔除。D1最终需真账号分别普通下载、打印内下载Excel、仅两行与批量选中，真实重开XLSX逐身份/过滤/套数，首AU-01626/1.125，列中无mouldType；非法列403另保原件。结算三字段defaultDueDays/fixedDayOfMonth/monthsAhead、仓库remark/真实workshopDepartmentName需比实际值。

## 共同选择门槛与保留差异

- `MasterExportSelection`规范UUID、非空、去重、禁止zero UUID、16MiB原JSON/估算预算；无50,000固定行数门槛。`MasterSelectionPredicate`≤1024沿原IN，更大用单typed UUID[]的ANY，交集仍在授权原list specification中。`requireComplete`发现缺失/不属当前过滤权限即拒绝，close恢复Scope。
- `TableColumnProjection`在复制前调用同一个ExportSelectionBudget；`ExportRowSelection`再次验证行预算/相同schema，按真实服务端身份及精确numeric匹配、不改写输出单元格，重复/缺失/隐藏字段/漂移拒绝，中断checkpoint保留。不是把50,000换成新行数常量。
- 16MiB仅是输出body/内存预算；原列数160、单selector字段320、key/text长度及授权验证保留。导入和业务写批上限不扩大。
- WPF UnitExportBudget RequestBytes=16MiB，仅Unit导出及permission-checked单作业原回执许可使用更大请求/响应/票据空间；一般mutation/read预算不改。UnitExportService冻结原query/projection/selectedIds，验证UUID/去重/UTF8总量，sort/order为null符合Unit原服务合同。未知提交仍原ID/原意图/原票据，旧server不支持selected协议不得退化成全部。
- UnitsWorkspaceView仅接受CompleteAsync的完整owner/query；同查询重读失败保留原已接受完整结果，身份/权限失效退休；OpenPrint/OpenExport再次检查CanAct、column snapshot及owner。大选择响应性历史原红和修后本机证据另由Root/WPF组保留，不能拿它冒称50001真数据库XLSX。

## 最终命令分组与计数

原23命令由run-final-d3.ps1固定，详见PENDING-FREEZE.md。D1下列补充命令可在最终同SHA另列，**不并入/重复相加原23**，当前只准备未执行：

```powershell
# 所有路径/build/TMP换成新的独立D1目录，正常fresh构建，UTEN_RUN_DB_TESTS=true。
mvn.cmd -o -B -ntp -f <final-worktree>/server/pom.xml `
  -Duten.build.directory=<new-D1-build> -Duten.test.tmpdir=<new-D1-tmp> `
  -Duten.test.jvm.heap.args=-Xmx3g -DforkCount=1 -DreuseForks=true `
  '-Dtest=MasterDirectoryExportPostgresTest#allTenActualCallersPreserveTheirOriginalRowsFiltersMasksAndExportOnlyPermission+repairedAccountCallerPreservesEveryOriginalAssertion+expandedSettlementAndWarehouseHeadersExportTheirAuthoritativeValues+mouldWorkbookKeepsAll1626RowsAndExactSelectedScopeWithoutTheDisplayPlaceholder' test
```

预期10参数调用+account原断言1+结算/仓真实值1+模具实际workbook/unknown列1，共13；实际最终XML说了算，不把其它未选方法、私有文件或ordinary Web写成已通过。WPF最终命令入口为 `tool/company_feedback_wpf_export/run.py`，待最终SHA用新run-tag按原x86/x64驱动重建/运行；此处未启动。

台账只读快照：373任务、history.jsonl 524行，status/owner/DoD/dependencies/nativeTargets及notes/evidence没有改；精确Git blob与保护字段digest在wpf-readonly-reference.json。Unit与Goods整体仍in_progress，其余十主档相关入口todo；不推定Win7真机、完整ERP、公司访问者或正式双包已支持。
