> 2026-10-26 最终本地组合候选编号说明（覆盖本文旧编号的当前状态，历史回执保原事实）：main 未提交 V936 explicit permissions 与 V937 verified employee identity aliases 保其原字节；B1 六份 SQL 仅在隔离整合候选中保原字节顺移为 V938 export jobs、V939 read scope/export stamp、V940 master read、V941 audit reader、V942 native、V943 purchase print。原实施树保旧编号供已冻结 classes 收件。最终组合使用新 target/私有 DB 验证，旧日志里的 V936～V941 不改写为新编号，也不自动视为最终组合证据。

# B1 原生单号候选完整分页

本页属于本轮本地 ERP B1。官网、B2～B5及全平台联合验收不在本轮交付范围；没有提交、发布或部署。

## 公共维护入口

- 服务端 `NativeFacetCandidates` 保存应用拥有的原始 SQL（IdentityHashMap，消费立即 remove，close 清空并恢复嵌套 scope）；`NativeFacets.query/rowsOf` 复用原17查询实现。不会从 Hibernate 已改成位置参数的 queryString 反推 SQL。
- `NativeFacetRoutes` 是21条精确路由/33个业务字段的白名单；前端路径由根任务生成至 `native_facet_routes.dart`，不手工维护两套路径列表。
- `NativeFacetCandidateInterceptor` 仅接原 handler 的 POST form 请求；全部过滤/关键词在 body，拒绝 URL query、错字段、重复保留参数、越界页码/size及过大请求。原 typed RequestParam、权限注解和 BusinessTaskRead 语义复用。所有当前33组合的原 facets handler 都没有 BusinessTaskRead；邻近 count handler 的注解不能挪用。
- `NativeFacetCandidateAdvice` 只包装成功响应；其后共享 `ReportReadScopeAdvice` 再读授权版本，撤权后返回 READ_SCOPE_CHANGED。捕获主体和 task/browse 身份分责；实际 scope 由本轮 V940 权威实现校验，不能拿 stock report 权限冒充 keeper ACL。
- 前端唯一 transport/UI适配是 `ApiClient.postForm`、`nativeFacetLoaders`、`nativeFacetSearchScope`，调用现有 MasterDataTableView 的 `facetPageLoaders`。保留 Uten 主题、输入保护、IME、防晚回执及候选菜单生命周期。

## 查询合同与差异

原 WHERE、生命周期、owner/keeper、关联来源、GROUP BY/count 口径保留，候选搜索只在原分组结果的业务单号值上做共享字面分词匹配；百分号、下划线及反斜杠不是 SQL 通配符。一次只执行选中字段的权威分组 SQL，其他同方法字段不取数；生产排程原完整 urgency/status 统计仅在兼容 GET 执行，候选 POST 不重复计算它。

每页最多100项，以 limit+1 得出 hasMore；不另跑总数。按映射后值稳定排序，NULL和空串沿旧 NativeFacets 约定映射为同一空值，并合并其原分组计数以避免两个同值候选跨页。空关键词下该桶排在第一页；非空关键词按原始业务值匹配，空值不匹配非空词。**空串仍沿原 UI 清除筛选合同，本轮没有新增“筛空”业务能力。** 原来 HAVING 排空的 IQC/FQC、物料分析、执行根、超产快照等入口继续排空。页内 count 是原事实的分组数量，不转换单位/币种。

旧 GET /facets 和 Repository 方法保留作为兼容接口（上限500），15个实际 UI 消费者全部改用独立远程候选，不再在每次业务列表/翻页后自动取旧500桶。生产排程继续用旧 GET 读取其完整独立状态统计，单号列仍走新 POST。账户流水此前缺少 UI 单号筛选，现接已存在的 billNo 服务端合同，滚动余额仍先对完整原事实计算。

候选版本是读取授权证明，不冒充业务内容版本；每页均重读当前原事实，不跨页复用分类内容，也不声称 HTTP 多页持有数据库长事务。输入、类别、原过滤、owner、server或授权 epoch 改变会退休旧菜单/晚回执。

## 完整调用清单

见同目录 `11-B1-Native候选调用清单.csv`，共21条路由/33字段，含六种仓库历史的 billNo+sourceDocNo、产成品 taskNo+planNo、IQC二字段/FQC三字段及车间两字段，未把普通公司级库存报表强套 keeper 范围。

## 定向证据

- 前端公共候选+实际 IQC/FQC/SalesProgress/LossClaim：4套18项通过，`native-facet-caller-first.log`。公共候选+MasterDataTable远程搜索/翻页/IME/晚响应/错误重试最终2套14项通过，`native-facet-helper-final.log`。初轮新fixture未隔离默认网络探测Timer的3个失败保留，修为假server/permissions后原断言复验通过。
- 仓库历史scope/type/late read、财务审批/应付、委外短交、产成品入库、执行根、超产、物料分析、排程、车间实际调用方：10套147项通过，`native-facet-callers-second.log`。20项最终定向analyze无问题，`native-facet-ui-analyze-final.log`；harness全局快捷键最后窄改另analyze通过，`native-harness-analyze-final.log`。
- 真实 PostgreSQL 16.15 / Hibernate 7.4.5：V941当时语义候选完整867迁移通过，`WhereUsedExportWorkerPostgresTest.everyNativeCandidateRouteUsesItsRealBusinessSqlExactlyOnceOnTheMigratedSchema` 逐21route/33字段调用真实服务，使用原FROM/WHERE/GROUP BY及绑定，不是复制简化SQL；每选中字段只执行1条分组SQL，其他字段/排程urgency不执行。此项证明SQL/绑定/当前schema，权限矩阵另由共享authority/HTTP关卡证明，不把mock policy的SQL测试当权限验收。
- 实际FinanceReportService账户1,001原始事实：NULL和空串合成一个旧空值、两个重复值合并原count，共999唯一候选，10页完整等值；空桶第一页、总原事实计数1,001，字面%_与反斜杠正确。该例与八实际report.export源合计Special9/9通过。
- 真实typed Controller MVC保原GET结构、POST body过滤参数、同scope版本发布、权限晚撤返回原403 READ_SCOPE_CHANGED、URL筛选拒绝原422、advice不递归/ThreadLocal清理：2/2通过；公共Plan/21路线33字段/嵌套/边界7项另通过。测试最初误用通用409/400的期望已按仓库原ErrorCode403/422修正，原日志保留，未改业务错误码。
- 新POST曾会被审计当语义写操作的缺口已由公共 `AuditRequestContext.markControlledRead` 接受服务器内部不可伪造标记修复；标记保留到审计afterCompletion，不依赖已关闭ThreadLocal。成功读不产生伪业务写记录，403/422失败仍原审计，实际1/1通过。
- 机器回执：`.local-artifacts/b1-baseline/where-used-native-v941-verified-results.json`；最后相关12项(WhereUsed9/MVC2/审计1) exit0、0skip，日志 `server/.local-b1-where-used-v941-twelfth.log`；Special9来源为此前同源PG回执。

合成浏览器入口 `tool/b1_native_facet_harness.dart` 拒绝全部业务wire，1201候选/页100、迟到2.5s、全局Alt+A/B/R、独立输入与collector。根任务原实现源GUI v4已真实搜索1201并选中(count7)、滚动第2页、验证A→B→A与scope变化关闭旧popup/清旧选择且独立输入保留；保存13条trace及截图 `native-1201-selected-v4.png` / `native-aba-scope-retired-v4.png`。这是合成真实UI操作；最终组合源短复核由根任务另录，不冒充真实业务库/员工UAT或全平台联合验收。

## 原失败与后续边界

V940最初自然业务名误写为不存在表名的迁移失败已修为实源stock_documents/stock_document_items；第七原PG日志保留。WhereUsed测试夹具的单号、永久历史guard、执行段原子分割约束失败及无关并行编译窗口均详见WhereUsed专项；没有禁用约束/触发器、导入共享数据或降低业务断言。

这些回执对应当时V941语义候选。最终为避让并行main迁移而顺延后的新schema、源码整合、公共预算后续兼容与发布检查，须使用根任务最后的新目标/私有库回执，不能以这里旧编号替代。本轮只收本地ERP B1，完成后停止；不进入B2～B5，不发布，不声称联合验收已通过。
