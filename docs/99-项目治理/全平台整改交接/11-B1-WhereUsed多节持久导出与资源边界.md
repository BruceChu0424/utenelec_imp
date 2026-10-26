> 2026-10-26 最终本地组合候选编号说明（覆盖本文旧编号的当前状态，历史回执保原事实）：main 未提交 V936 explicit permissions 与 V937 verified employee identity aliases 保其原字节；B1 六份 SQL 仅在隔离整合候选中保原字节顺移为 V938 export jobs、V939 read scope/export stamp、V940 master read、V941 audit reader、V942 native、V943 purchase print。原实施树保旧编号供已冻结 classes 收件。最终组合使用新 target/私有 DB 验证，旧日志里的 V936～V941 不改写为新编号，也不自动视为最终组合证据。

# B1 WhereUsed 多节持久导出与资源边界

本轮只完成本地 ERP B1，完成后停止。官网、B2～B5、全平台联合验收由本轮范围排除；未提交、push、打包发布、部署、激活服务器或改共享业务库。

## 公共入口与完整调用

`DocumentPageSink` 定义Header/Section/Page（页≤200、单文件≤16节、节≤160列、恰好一个primary），以及同一个 `RowBudget`（每节原50,000行）。`StreamingDocumentWriter` 统一begin/accept/primaryRowCount/rowCount/onCheckpoint/finish/close。`XlsxExportService.openDocumentStream` 和 `TabularPdfExportService.openDocumentStream` 实现同一合同；兼容 `buildDocument` / `build` 也走同一writer，不保两套格式器。Root通用Worker的TaskWriter分派普通表与document，job行进度只用primaryRowCount，不能把证据分表行数混进主行。

WhereUsed唯一业务适配入口为 `WhereUsedExportService.streamDocument` / 内部emit，兼容document()走同一emit collector。原 `ProductionWhereUsedQueryService.whereUsed` 与导出 `whereUsedExportPage` 共用原查询/参数/排序/DTO；只有第一页取metadata。流式桥显式要求真实active/readOnly/RR及Document sink、独立production_where_used:view+export；无goods:view/production_report:view/export额外门槛。主查询复用已验证的ReportExportCursor，同一真实快照读取；稳定产品UUID尾序、每批校验columns/page/total/行数，不容许半页提前结束。

权限差异保留有明确权威：原main与本轮 `ProductionWhereUsedQueryService` 都只有EntityManager；其goods/BOM条件是is_deleted/auto_created与有效关系等业务事实，没有GoodsDataViewPolicy、owner/keeper谓词或goods RLS。材料picker原注释与Controller明确这是WhereUsed自己的投影，不扩大到主档权限。故任务/HTTP使用production的FEATURE版本机制，不能为了共用强套master_goods owner stamp。该hash仍含全部当前功能权限、realm、session/版本，独立where_used:view/export撤回会在受理/检查点/下载复核中退役；普通goods归属变化原来也不改变这族查询，不伪装成权限撤回。

原五节完整保留：组件使用产品、当前组装依据、新生产需求依据、旧生产快照依据、委外需求与历史依据。各页按原证据条件分流，节之间不混加数量/单位；原文、来源计数、历史数量、时间、人员、单位和完整元数据保留。空可选节仅最终省略，primary保留。新增Decimal Exact bridge兼容隐藏行字段与unattributed metadata，前端说明优先精确文本。

根任务已接domain=where_used/report=where-used、format=xlsx|pdf及原materialGoodsId/source/dateFrom/dateTo条件、持久Source/Worker/API和格式专有前端按钮。用户密码只用于下载保护，不入任务持久参数。大结果不经过plan报告平面data sheet，也不套个人plan列配置。

## 共用资源与失败合同

- `ExportTemporaryBudget` 是唯一临时/输出预算：worker副本256MiB、压缩/spool/PDFBox临时总预算512MiB、磁盘保留2GiB；有限private目录、全路径清理尝试、聚合异常、取消/checkpoint。`ExportCellValues` 共用精确数、日期、布尔和单位，超过15位/非有限double/下溢以原精确文本保存，超Excel单元长度明确失败，禁止悄悄丢位。
- XLSX同一StreamingWorkbook维护多节；POI5.5.1关闭/删除空sheet后dispose重复flush的WARN根因用关闭顺序处理，未屏蔽logger。失败后禁止finish；所有已知文件均尝试清理，不能首个异常跳过后续。
- PDF采用private JSONL逐批spool、BigDecimal/BigInteger精确回读及disk-only PDFBox cache；全节宽度通过有界重读求出，原自然面板、身份列重复、中文字体、页头/页尾保持。原60,000cells/250pages边界保留；已知主行最低预算读前拒绝，逐批及版式/写出期间检查取消。不会把50,000行List或byte[]当流式。
- 同步HTTP共享 `LegacyExportBudget`，WhereUsed主行≤500，超过明确转持久任务，不能静默前500。自然BOM等已有独立对象规则由根任务另录。每节50k是原ExportDocument合同，两writer都用同一个RowBudget，未知count也不能绕过。
- PDF protect(Path,Path,password)以独立download scratch处理，source≤256MiB、128字符上限及原密码/加密合同保留；不改原artifact。Root下载lease/reaper与document spool名称分离，不能把下载中scratch当孤儿清理。

同公共writer已承接Root实际成本document源。独立复核新小同步桥确认原投影、digest、密码、500/50k分责；发现工厂失败漏raw FD及静默吞cleanup两条失败路径已由owner修复并补8unit。旧3参artifactOutput委托可选maxBytes同一预算，新小同步32MiB，worker仍原256MiB；最终候选须补共用writer回归，不能拿旧62绿冒充新helper。

## 真实定向证据

`WhereUsedExportWorkerPostgresTest` 9/9、MVC2/2、受控读审计1/1：`server/.local-b1-where-used-v941-twelfth.log`，exit0、0skip。真实PostgreSQL16.15/Hibernate7.4.5、完整867迁移至当时V941；容器1CPU/768MiB，单JVM1GiB/2CPU；宿主并行任务存在，耗时不能冒充安静生产基线。

9例包含：XLSX/PDF真实worker1001产品全行与5证据节精确/不混加；只有独立WhereUsed权限；源取消/写失败后无发布；源完成后PDF格式期取消无发布；提交发生在worker snapshot与首条source SQL之间，旧任务1001、新任务1002；缺view或export不能受理；测试旧快照常规写仍SQLSTATE42501且值不变；同库逐21route/33个Native候选字段调用实源SQL，每字段恰好1查询。

八类实际report.export特殊源（账户期初、party流/明细、supplier statement、product cost、GLtrial、instant、shelf）各1001行跨3批，与原分页逐Map及尾余额等值。新增Native账户1001原事实/999唯一候选、空与重复count、字面%_正确，共Special9/9真实PG通过。机器回执 `.local-artifacts/b1-baseline/where-used-native-v941-verified-results.json` 保存精确testcase及XML哈希。

原15类62项文档轻量全绿/无POI WARN（v938-third）；RowBudget及后续共享writer/WhereUsed/Native54轻量断言在v940-seventh通过；精确数量UI5项通过。新预算重载/同步桥最终公共writer回归由根任务最后候选另录。PDF样本 `server/target-b1-document-validation/where-used-document.pdf` 13页/24,223B已全页渲染，人工检查首部/跨200批末行/历史节精确长数、中文/单位/身份/页码，无裁切重叠；正文201ID与加密有断言。这是测试样本，非发布制品。

## 原失败与复验

原日志保留：早期单号夹具用手工前缀触发永久注册，改用真实DocNumberService/ProductNoAllocator/MasterCodeService；旧快照写被永久只读guard拒绝，只有隔离测试那一笔旧快照使用原app.legacy_import=on的local事务，并反证没有泄漏；package/段/demand被deferred数量分割guard拒绝，按真实业务同一事务写完整分割。没有禁用trigger/constraint或放宽金额/数量/来源断言。

并行编译窗口的Audit构造器、Actual JsonSerializable、int/long、JUnit重载、审计读标记/旧class、PurchasePrint复合var错误分别留在第三～十一轮日志；不把未进入PG算作通过。V940表名错误由实源stock_documents/stock_document_items纠正；MVC初轮误用通用409/400已改取本仓原ErrorCode403/422。最终第十二相关12项全绿，原错误没有被清日志或放宽业务断言隐藏。

## 交付边界

本页是V941当时语义候选定向回执。最终为避让并行main新V936/V937，六个本轮迁移由根任务保原SQL字节顺延，使用新目标/独立库验证最终编号兼容；现有正式迁移不改字节、不repair。Root负责安全main差量整合、最终schema/源码匹配、合成浏览器最后组合源复核和交付清单。代码/测试/本地整合与提交、CI、制品、部署、真实业务使用验收分别记录；本页不替后者宣布通过。
