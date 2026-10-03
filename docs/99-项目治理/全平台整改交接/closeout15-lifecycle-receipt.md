# closeout15 lifecycle 第一验证小包回执

本回执只覆盖权限/审计/并发/设置/清理清册及清理竞态、盘点申请详情审计修复。R0.04源码清册已完成；R4.04正式原件保全仍进行中，已预留V773，不能据此宣告整个父项完成。

输入：Main `404614e6edf345c39f48fa16e03baa452bb30312` 加当时并行工作字节；隔离 `closeout15/lifecycle`。源代码、测试、资源独立冻结在 `.local-tmp/stage1-tree`（4407项）。未修改主目录、未部署、未写业务数据库，所有PG均为隔离测试库。

## 修复与覆盖

- 学习步骤以attempt+startedAt认领；旧成功/失败、未认领异常和旧证据记忆不覆盖新执行。claim与prepare-source之间已提交RUNNING的primary/additional原请求引用也保护来源，并限定来源提交人。过期剥离跳过RUNNING/锁行，每次1000，保留身份、步骤、次数和最小去重证据。
- AI排队超时从本次updated_at计算；结果只清终态、完成时间合法且不在未来的任务；结果和任务分别受学习引用/期限与模板候选自身期限保护。模板候选清理有界且避开正在处理的AI和学习。
- staging过期初次无对象仍排延迟复查，lookup失败重试不重复intent；internal迟到对象先观察并持久化exact version再删。物理删除完成/失败按attempt隔离，当前回执与附件/对账状态在短事务一起提交；失败不发布不完整成功证明。
- 盘点申请服务端detail没有等价查看审计，成功授权读取后补一次安全UUID/编号查看事件和中文动作/对象标签；无权/不存在不写成功查看，不放宽扫描器。
- 清册列出2928 Java/SQL输入、25设置、621写入口、权限/再认证检查、版本/租约/锁、显式审计/表登记、全部清理调度引用及8类策略。引用清单是源码事实，不冒充运行环境授权/安装验收。

## 真反例与验证

- 原8场景：8失败、0错误/跳过。临时队列正确并发3场景：3失败、0错误/跳过。初稿附件2未复现、1fixture错误单独留存，不计入真红。
- 初次5边界红中全局purge计数断言不足；已另用冻结baseline reader SQL和明确目标UUID复证5/5（primary/additional结果、primary/additional候选、future+used）。两个reader源SHA分别0b279343b2d0f9379236fd7d757faeee979f45b18a7a7f853e1172837d3747c8、d426239a6216149e22f000768d4ec3d45ca41e674cac17b8d099516c523caf00。私有故意红证明类已移出正常测试源码，保存在验证目录，正常CI/绿选择不含它。
- 首26类230项：3失败（详情审计缺口1、Receipt整批计数fixture2）、0错误、2Windows平台跳过，失败记录保留。更正后的目标UUID+合法过期对照、盘点审计和受影响审计10类77项：全部通过、0错误/跳过。
- 最终有效证据合并33类287项：285实际通过、0失败/错误、2Windows InternalStorage平台条件跳过；跳过的原生存储边界交叉引用Root本轮Linux14通过，不重复计数。33类冻结XML及汇总在 `.local-tmp/lifecycle-validation/stage1-reports` / `stage1-effective-verification.json`。
- 768MiB Maven、3GiB测试JVM、单fork，独立target。不是全仓套件/CI、服务器安装或业务验收证明。

## 未覆盖与保全默认

- 已确认AI原上传仅在ai_jobs.input_bytes，V742终态即清；markUsed没有原件保存，模板/学习证据是派生和最小事实，输入SHA不能恢复PDF/Excel/images。原件缺口由V773独立持久原件、append-only正式doc绑定、旧节点bytes前向保全、精准读权限和恢复引用子包继续实现。历史真正缺失不可伪造。
- 当前通知/会话没有自动年龄物理purge，显式通知移除仅本人状态；未办TODO/账号安全提醒及刷新复用/吊销/登录关联证据保留。07的180天/30天建议不是已经启用的销毁许可。
- 死亡不明且过期RUNNING学习保持原证据，不能按年龄猜成功；业务归档、Outbox瘦身、完整附件回收站与管理销毁入口属于其它明确步骤。
- 审计保全SQL/本次改动是候选源码事实，服务器实际模式需独立读/安装证明；本回执不声称已改变公司或本机运行库。

## 选定输出的精确SHA

| 路径 | 输入SHA256 | 输出SHA256 |
| --- | --- | --- |
| docs/99-项目治理/全平台整改交接/14-R0全平台现状复核.md | 54cf23938d6ea3f716156d1e8a9432c0a1c792d597b90c7ea391072097f3b5ef | 57682824d186a8dbe597236591cc32050936eda7288e8c91b0b19cf171acb2f5 |
| server/src/main/java/com/uten/imp/audit/AuditRetentionScheduler.java | 547bd39fbac4b0df5cc531f68e324c4e9302352790dbe1c4d9dd53ad647bab7c | cd603c811ab53de3a0dfd16ed426e0dfe214c2c07d97c1b20b93e20e32b056a2 |
| server/src/main/java/com/uten/imp/features/ai/job/AiJobRepository.java | 0b279343b2d0f9379236fd7d757faeee979f45b18a7a7f853e1172837d3747c8 | b77728d3f077e2ac38a5943f083acd1a15dd005d1465eb165f5ca306a2eac38c |
| server/src/main/java/com/uten/imp/features/attachment/AttachmentObjectOutboxProcessor.java | e9f06cede5cee492f7e3f39dae16d3e539866e171db858ba7e6893a1ca4796f7 | ac94576e22fada8f2bfbeb44670bae80fc3d835b8d2a76932d0f41ccf92849f3 |
| server/src/main/java/com/uten/imp/features/attachment/AttachmentObjectOutboxStore.java | 357681edd3197d6455580fd6bd7a8f922207ae5a1cb9eba599f21ca3cbb6e8a1 | 61b1ecafaa88116ce346ea53c01876f143dbf8e1d5e9bc935882af87a2c9f16c |
| server/src/main/java/com/uten/imp/features/attachment/AttachmentUploadExpiryScheduler.java | 5504baa2203296867f9fca4925c65debdf894467180cd5387d920012473fc117 | 5fd69da9ee6c68a243c9e18e72fa4108da120a9b043f98feebe7052c002cfe95 |
| server/src/main/java/com/uten/imp/features/attachment/AttachmentUploadSessionStore.java | ddbb6c4d6caa9ff9fb9c4235c2f1abc9592a5d74e3807c4039c7a04155fd2b4d | 8f5140a64b31fafebf374f0a569dd27444ebe89fb614c6f76014b75c2bc4504a |
| server/src/main/java/com/uten/imp/features/sales/learning/SalesLearningReceiptService.java | cba15b442a1716d19351a40e7886b7ceb77511f5cd256c47440eda39d54b4ff1 | b4c72e83b8a48501be442176a03db3164073661dcc0ba438f92a23a6dde4ae5f |
| server/src/main/java/com/uten/imp/features/sales/template/SalesQuoteTemplateStore.java | d426239a6216149e22f000768d4ec3d45ca41e674cac17b8d099516c523caf00 | f91da2b11a8df377795c103f428c12643c49496b2ff0fb0d12bf36fa27c2b789 |
| server/src/test/java/com/uten/imp/features/ai/job/AiJobQueuePostgresTest.java | b42a610f6cdaefd526979ed7a91e8ed43f20b95670940739fe060a44a69eb32f | 19deca58f83ec48496965e269ce2a2d20ddfb5c1b21e5793c642837ff3a5359d |
| server/src/test/java/com/uten/imp/features/ai/job/AiJobRetentionPostgresTest.java | e32f59c3993c41199e23ee1fb2d95083abd2577721367b3d082a6ff0d371e8eb | 4d737e745d4723ef7ea8aa3586d58f047beced0afca1c1680af8a0049010c43c |
| server/src/test/java/com/uten/imp/features/ai/job/SalesLearningReceiptPostgresTest.java | 0d1e868dd657e14bc4231ca30eba0cf98406655913a213cf9e618ef0169626fe | 1f6886c976698e34277e72267662a8d593a32f954456dde0031b0519de1b9d99 |
| server/src/test/java/com/uten/imp/features/attachment/AttachmentDeletionProviderScopeTest.java | 53aa1b58d18ce6c010f422c7aa69a89d816b7a3136114311b08cde0de8084755 | b0a2807a4bc601d262021ee48fe40f50c2824270efefb1930a137f9a108491e6 |
| server/src/test/java/com/uten/imp/features/sales/template/SalesQuoteTemplateStorePostgresTest.java | ad3d5e2abf044258cb155f085fbb25fac6fdb48539ad9bcdd06ea97455e4b540 | e8f6f5d28d02bd47fdec32e28c83879843bb3d0932f2c274d20f4494ecfd822d |
| server/src/test/java/com/uten/imp/features/attachment/AttachmentCleanupLeasePostgresTest.java | 新增 | 6b662d169176dde1dc68ca537296d84da8995d9bae7ac4674dd0db7ffb7e4d7c |
| scripts/governance/lifecycle_inventory.py | 新增 | d7411649659f0385c9e3259d48c56ac49bdb9084525dee2f29c5428ae3f600d0 |
| docs/99-项目治理/全平台整改交接/r0-permission-audit-lifecycle-inventory.json | 新增 | c95da5f4adb2111a7748871dbbd9ad841bb2182053cb947e77a2d17ed5e684a1 |
| server/src/main/java/com/uten/imp/features/stock/count/StockCountRequestController.java | 90c18ef44562f90cb71da4b8dfce644e56cfcd8821cea768da71941e83278049 | 414d76ed19765b4ce456fe49c080beeff722c8ce4d1d7ecb87f9446cc66e158b |
| server/src/main/java/com/uten/imp/audit/AuditEventInterpreter.java | 91a7f088996808380f812700721b8598584282eb7c4646ddfe667d318669ce3f | 66e86b82e659242fe93db0986dbef5a343a962d0f527e44554bd93de35b0ac1f |
| server/src/test/java/com/uten/imp/features/stock/count/StockCountRequestDetailAuditTest.java | 新增 | d39f29b1de47d7b45a3821c9e1ce6ac8b733f71f8be4ffa004a8912144d18c51 |
