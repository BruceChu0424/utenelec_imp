# 本地整改实施记录

- 授权：读取并实施四包全部适用项，独立工作树；禁止合并 main、推送、公司库、部署、正式打包。
- 当前 main / 被审版：`fdeda88b3d73b24b8691ad132caa765196b19a3d`；主树未跟踪 `tmp/` 保留。
- 整合候选：`uimp/feedback-remediate-20261110`，`D:/Projects/uten_imp_worktrees/feedback-remediate-20261110`。
- A/B/C 独立分支及工作树：`uimp/feedback-remediate-{a,b,c}-20261110`；迁移预留 A=V1130、B=V1131、C=V1132，未需要则不新增。
- 原始证据：`D:/Projects/uten_imp_worktrees/feedback-audit-20261110/audit/`，本轮只读。
- 新原始证据：各整改工作树的 `evidence/`；工具、Maven 输出、TMP、PG、端口独立。
- 指纹：Git 源码按 Git blob 原始字节 SHA-256；下载、XLS/XLSX、截图、日志按实际文件字节。旧两个 .gitattributes 清单差异保留并单列，不修改旧证据配平。

## 实施中

| 包 | 范围 | 当前验证 |
|---|---|---|
| A | 旧齐套证据升级、编辑自身草稿、证明规模、投影变异 | 子工作树实现和独立 PostgreSQL 回归中 |
| B | 下单份额/拒绝与未知结果、权威退货订单来源、引入生命周期/精确文本 | 子工作树实现和真库回归中 |
| C | 七类物理工作簿守卫、五类旧持久化预览 | 已在新位置重跑旧攻击，候选和升级回归中 |
| D | 主档排序、完整结果资格、大范围真实选中、证据/WPF保全 | 产品修改已落地，Java/Flutter验证中 |

## D 当前方案

- 模具后台作业调用原有支持 sort/order 的服务重载；其他支持排序的五类已传参，余四类无排序服务合同。
- 主档逐批行没有输出资格，只有同身份、读修订和查询已有接受的完整结果才可打印/导出/批量。相同查询重读不拿逐批结果覆盖原完整结果，暂时读失败仍保留原完整结果。
- 打印输出把业务上下文围栏传至范围确认、预览、打印、内嵌下载；导出组件持续复查 enabled。
- 明确选中去掉50,000行数门槛，保留16MiB输出请求/估算内存预算。超过1024个UUID用单个类型化数组条件，保留权限/筛选交集、RR快照、稳定排序和缺失拒绝；不改导入或业务写入批次。
- Java首轮编译失败：ContactExportRequest仍引用被删除MAX_IDS，原日志 `logs/maven-initial.log` 保留；同类入口同步修复后进入第二轮。

最终验收必须在整合固定SHA后重新执行，以上实施中状态不代表完成。

## 2026-11-10 18:34 America/Denver 检查点

本候选 HEAD `3207f5f84`，不是最终冻结点。已本地整合：

- D：`1b37eb1b7`（31文件，含真实50,001选中/100k测试与WPF单位同查询失败保留），`78ba0a873`（20料原方法JDBC计数，10秒不变；格式化探针）。
- C：原`85418bf82`→本候选`fb3dcd75b`，原`9eccf1850`→`f777bf279`；文件物理守卫和server安全版本v2，签名保留公司名称合法冒号。
- A：原`81cc0eac0`→`e123513a5`；原`59364ea00`→`3207f5f84`，新增V1130/V1131，旧V1129及1130已提交字节不改。
- B：原`702d33de5`→`d43458e98`；原`a9047f52a`→`7a6b19dc4`，无迁移。

当前只有打印组件/主档测试的4处braces lint修正在跟踪未提交；`evidence/`仍未提交，里面private、编译/TMP/native/downloads均有忽略规则，不能宽泛强制add。

已跑的根证据（不能把重叠组相加）：

- `logs/dart-d-round2.log`：共享Flutter主档VM 25/25；含冷读失败禁止输出、同查询完整结果重读失败保留。
- `logs/baseline-d2-counterexample.log`：另建`D:/Projects/uten_imp_worktrees/feedback-baseline-replay-20261110`从fdeda检出，只复制新测试；原实现`Expected false / Actual true`，exit1。该工作树保留。
- `logs/maven-d-round3.log`及`round3-surefire-reports/`、`round3-compiled/`：35项34通过1夹具排序失败，0异常。50,002真实模具造数687222ms，实际选择已缩到原范围，但夹具误用不支持的code DESC，故读首行为升序。当前夹具改为真实支持的tqty DESC且造数即含精确套数；没有放松顺序断言。仍须在最终候选真正跑通。
- `logs/integrated-unit-1.log` / `integrated-unit-1-reports/`：整合源码清编译，96项95通过、1私有Excel条件跳过、0失败/错，19类选择。编译输出`build-integrated-1`独立。
- WPF x86/x64原`--table-output-contracts`均过。新增`--complete-read-output-qualification`在原C#实现失败于同查询重读丢完整结果；`wpf-qualification-baseline.log`保留。修后两架构均6断言通过，原输出/搜索IME/身份退休也通过（`logs/wpf-candidate-*`）。WPF仍非Win7真机，不提升373项DoD。
- `baseline-provenance.json`：原audit raw文件SHA清单（旧目录只读）、373项受保护字段相同、history524完整，两个.gitattributes原blob/raw差异分别记录。后续运行`provenance.py final`比较原件未变，不能覆盖baseline。
- `logs/integrated-dart-analyze.log`首轮73问题，其中新B四探针dynamic静态错误已交B强类型修，A两info交A，根4处braces已改。不能宣称analyze绿。
- `logs/wpf-progress-check.log`因源码inventory合法漂移失败；最后统一business_inventory --write + progress_tracker sync/check，保证status/owner/DoD/dependencies/nativeTargets及原notes/evidence/history保全，不跳过检查。

正在运行：根`budget-cold-1.log`，对当前已编译整合代码只跑原`AggregateMaterialOrderEndToEndTest#twentyMaterialLinesCompleteWithinDeadlineBudget`，用JDBC计数/耗时而非猜测优化。exec session 66753。B先前冷单独JVM15941ms红项、完整原组热4500ms绿项分开保留；根独占AggregateMaterialOrderWriteService/PreviewService性能修复，B继续采样/类型修复。

根尚未开始最终真实Web/UI。统一新PG容器`uten-feedback-final-20261110`，127.0.0.1:26630/feedback（空库）；backend28630、proxy28631。`private/runtime.json`持久化合成DB/账号密码以及jwtSecret/hmacKey/pgpMasterKey，不能打印或入git。`start_server.ps1`已改为持久化键；A/B外部seed必须用同一键，否则PII加密与runtime不一致。A/B正修动态属性优先级。C专用旧库26632使用原自己的测试密钥，不能混入统一Web库。

根现成脚本：`private_flutter.py`调用仓库私有Flutter工具不改SDK；`PhysicalXlsxScale.java`+`run_physical_scale.ps1`生成/逐行SAX重读1,048,600真实行/2sheet并取消清理，须最终SHA执行；`proxy.mjs`真实API反代，可在private/fault.json主动丢第一真实NDJSON frame后的连接，仅作明确标记的传输故障注入；不替换业务API/provider。

下一步必须持续：收A三材料6000旧草稿/seed密钥/lint增量、B强类型探针/seed密钥增量、C当前源码历史夹具定向复跑与报告；修/解释20料冷/热/代表负载原10秒红项；同步WPF台账元数据和新增证据但不改受保护状态；固定一份最终候选SHA后清编译并逐项重跑A/B/C/D原反例与合法对照，包括D真实50,001/十万真库/百万XLSX；启动该SHA统一Web后台、用普通岗位走真实下单/报工/退货审批与库存财务/两模具下载/持久化导入，做共享Flutter桌面真实交互。分清服务PG、VM、合成Chrome、真Web→PG、本机原生与目标设备。最后独立复核、八项判定报告/矩阵/命令/准确分组计数和原证据路径。不合main、不推送、不部署、不正式打包。

## 19:20 后续接续状态

- HEAD `681b588b5`（之后未提交还有base投影实验）。已追加A `3f5c1a93`→`22bcb7089`（三料6000 create/edit/旧稿approve完整真PG均过、secret绑定、lint）；B `034f1bd41`→`f1bb6e904`（真实source adapter priceText、强类型探针、精确HTTP422、seed共享key），`9c8538f96`→`681b588b5`（真source sheet交互及ABA、seed显式opt-in）；C `43116cb7`→`56c664902`（V1127真实历史造数→升级）、`f44da0b13`→`03c24dc09`（C完整evidence/imports已入Git）。`022788ec7`为根braces lint清理。
- C全部收口：七类当前真PG攻击无业务表误写，合法科目/备注/辅助实际写入和成本合法SKIP映射；五类真正旧v1＋科目父/子、旧已应用备注锁期重放/另一owner拒绝全部过；文件59=58通过1私有跳过，成本7/7，Goods历史31/31；原红日志不改。raw PG dump仍C原树本地12.8MB，root evidence/imports/REPORT.md含SHA。
- A26项函数/四路旧库升级及三料6000三路和DIRECT_LOT均过；源已稳定。A现承担**新的Windows真HTTP验收测试**，从root22bcb建`uimp/feedback-desktop-20261110`独立树。仅测试/helper/极小Debug+LocalTest日志路径门控；现有Roaming/Local Uten/UTEN Local Test存在，不能碰其prefs/凭据/草稿/原生日志。A发现PathProvider override不足以隔离shared_preferences_windows自己的实例，正在给真实插件绑定私有路径，4个已锁定平台测试依赖只改为直接dev声明不换版本/hash。未运行app/未登录，待root28630与账号就绪。
- C现承担**D2新补口**：从022788建`uimp/feedback-output-writes-20261110`。原真实“状态PATCH成功1次→同查询续批失败→旧结果仍enabled”红例已保留，主干修后纯刷新保留与写后退休2/2已过；迁移所有自定义写后reload。又发现6扁平主档color/unit/currency/account/settlement/warehouse根本未接资格，不走4类MasterEntityPane，正在补实测并统一公共完整资格入口；包括旧任务恢复耦合。root不可自行改这些Dart共享文件，等其提交审查。
- B产品/原例：55退货VM、45专属页VM，最新12类型化反例、真实source adapter2/2及其旧lib失败2/2均完；113 PG长轮112通过1测试预期400而接口正确422，已单方法1/1收口准确422＋零业务写。B现继续核查非aggregate `_notifyRoute/issueWorkshopPlans` 的未知结果冻结/票据：不能只改aggregate截图入口，先看ApiClient已有机制不造第二队列，尚未闭环。Java性能核心仍root独占。
- 根冷20料：`budget-cold-1.log` 10546ms红；1139 SQL、7743ms JDBC、commit695ms、405 material摘要读计3029ms。派生`budget-cold-1-derived.json`。`budget-trace-1/`真实安全SQL fingerprint＋源码调用位置1.5MB，无值/SQL正文。B原冷15941与热4500仍单列。
- 根已提交 `4c5c5d80c`：公共refreshWithAnchorGrowthState返回最终view；有配额变化完整刷新重读，无变化可下一阶段一次消费；保留旧outcome/int调用，最终receipt后仍重读。不跨事务缓存/不减锁校验。`run_budget_overlay.ps1` task-owned增量编译＋原10秒方法的`budget-perf-view-cold-1`冷调用5215ms过，但SQL仍1139，**不能把下降归功该条件复用**。最终仍须清编译最终SHA再安静/代表并行测。
- 当前**未提交实验**：MaterialAnalysisService.baseIssuePreviewView=全新overlay一次project(true)+detail；AggregatePreview.preview与Write预锁/回退3无增量调用迁移，所有加seed/claim/reservation的两阶段保留。新增完整JSON对照`AggregateMaterialOrderEndToEndTest#freshBaseProjectionMatchesTheOriginalSecondPassForNestedAnchorsAndRealStock`，对新嵌套、已有MAKE锚点/别名、真入库后原快照过时三状态比较原第二次投影。`budget-base-parity-1`正在跑（exec session60660），若不等必须调查/撤该实验，不能放松断言。
- 根已准备`seed_mould.sql/ps1`：统一DB在B seed后复制maker的**同合成密码hash**建两个非超管、模具域仅mould:view/export账号：feedback-mould-qa（Web）、feedback-mould-win-qa（Windows，避免登录互踢）。插1626 AU-00001..01626，tqty反序首1.125；字段与原old真Web fixture相同，不关触发器。脚本尚未执行，B seed输出路径作为必填输入。Root runtime.json已经有持久化3key，统一DB仍空未启动server/seed。
- proxy新增仅测试故障loseCommittedReplyPaths：真服务器完整2xx响应后丢传输，不伪造业务值；用于真实Web未知提交→原票据重试→查库仅一笔。NDJSON首帧后断流保留。
- 根 .gitattributes明确原始log/XML/JSON/二进制不换行转换，源码Git blob LF；旧两属性文件不改。Root evidence脚本/日志多数仍未入Git；别强制add private/build/native/downloads目录。

## 21:55 后续整合与真实界面预验（不是最终SHA验收）

当前已收V1130/1131历史证明、B全部下单入口未知原意图冻结、十类主档完整资格及写后退休、PlatformTable串行读取与布局追加增量、WPF大选择原票据；各自提交及evidence/imports、output-writes、table-layout保留源头与证据。main仍fdeda88b3d73b24b8691ad132caa765196b19a3d，未合并/推送/部署/正式打包。

根885e4b51f性能改动的真实三态完整JSON对照通过。20料原10秒方法首冷10546ms失败保留，后冷9168ms过不能覆盖旧红或代表并行通过。1139→1105 SQL、405→376 material摘要读是实测减少，不将全部墙钟变化归因该优化。最终同SHA仍须清编译安静/代表并行分别跑。

准备Web是42b7源Debug全应用，28631真反代28630/26630 PG。private-flutter-web-prepare-1.json的command_prefix因原list alias被追加参数，旧receipt原样保留，shared SDK哈希确认未变；脚本已用list(prefix)修正，最终另跑新tag。Web mould账号feedback-mould-qa与Windows feedback-mould-win-qa均非超管；1626真模具按套数升序首AU-01626/1.125。真实网页已显示逐批追加、排序并同步生成普通下载，实际文件复制到忽略downloads/preparation。后台导出原私有目录未建致fallback，补建本地目录后真实GET capabilities/recent，但“正在恢复导出任务”未收尾，无POST；原截图mould-job-restore-stall.jpg/代理元数据保留，不算后台作业通过。最终新build须重跑处理。

A/B公开业务造数均在合成库。B首次seed错误引导ADMIN唯一员工冲突，业务数量0原日志保留；改为runtime同bootstrap后b-run2真1/1过，A a-run1真1/1过。私有持久化三密钥同runtime，无触发器关闭。Denver 11-10时Asia/Shanghai业务日期为11-11，夹具记录时区，不改业务时钟。

独立审查新增成本真文件反例：v2把mixed-header-tail材料行丢掉，把“小计数器件”按子串小计丢掉，正确断言2pass/2fail原件保留。fafaaa665→本候选bddc425c7修结构物理证据与精确标签，server安全版本3；旧v2 pending也重检，C用真实v2编译程序在专用26632签发，不伪造版本。五类v1/v2升级与最终候选仍待收口。

规模增强实际暴露50001真选中ArrayContains渲染uuid[] @> array[id]，COUNT15秒/首读22秒，真实XLSX超原事务时限，旧失败保留。规模代理独占公共谓词真实EXPLAIN与修复，最终冻结等其小生产补丁，不加timeout。预验与最终验收分别列。
