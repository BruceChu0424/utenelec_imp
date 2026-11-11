# 并行 main 优化语义整合验收

产品合并提交：`c45c76c73bf1d4b8546ef67a4897b31bc0ec3da5`。双亲分别为整改候选 `4d45dc9b6c291e9d8e9121b48017b69030fd1f4c` 与当时实际 main `d5200b6bf68aae203542c3828ddc0d6498be2870`；文件树为 `6f99c47ffa3e42a7251138e0c0c1d902bea4ebfd`。main 引用仍为 d520，未修改 main、推送、部署或正式打包。

工作树 `D:/Projects/uten_imp_worktrees/feedback-integrate-main-20261110`，分支 `uimp/feedback-integrate-main-20261110`。这是独立候选的正常双亲 merge。Root 在4d45之后新增的其他整改/证据提交由 Root 后续正常合并保留；本提交没有整文件覆盖 Root 的最新工作树。主线14条新增提交及自动合并文件全部纳入，只有下列3个文件发生文本冲突。

## 三处公共入口

| 公共入口 | 主线能力保留 | 本轮整改能力保留及接缝处理 |
|---|---|---|
| `master_data_table_view.dart` | 每列扫描游标、2ms/256格扫描片及帧预算停车、行/集合/计划身份稳定、原地可变行刷新 | 真实schema/layout/权限变化才重做列布局；保留新的getter闭包及价格遮罩。新扩展列只退休受影响的量宽事实，保留业务列已测前缀；真正扩展值变化重扫对应扩展列；小量恢复扫描主动安排frame，避免等滚动才发布。原手动宽度、筛选、排序、滚动及草稿保留。 |
| `scoped_paged_read_view_mixin.dart` | owner每事件轮深检查缓存、匿名错误ref、退休翻译、timer销毁 | 同时保留 `CompleteOutputGuard` 的确认写入退休、冷读取不授予输出资格、同query已有完整结果被动重读失败的保留行为。没有使用普通readScopeRevision代替确认写入退休。 |
| `platform_table_controller.dart` | 记录membership增量、追加不重复读前缀、真正新实例/额外分组处理、structure/values revision细分 | 同owner串行队列+generation及时退休及跳过旧ticket；追加加入当前drain，强制不透明revision则全量重验。主档传原始source list区分稳定重建和新快照，sealed追加有proof时保持增量。`selected=[]` 仍访问服务器发现持久化cell，不因没有definitions跳过正确读取。 |

主线非冲突部分也保留：品牌按值发布/主题按target platform缓存、selection按frame缓存、完整流有界staging在同只读RR快照与读后栅栏校验后回放、统一错误帧，以及相应用例。NDJSON帧间空闲预算从普通45s独立为75s（服务端完整读取预算60s），只证明合法静默期不被提前误杀；这是传输正确性调整，不能作为性能达标证据。普通请求45s及物料20料10秒门槛均未改。

## 失败及修正

原始日志不覆写：

- `logs/private-flutter-first-both.log`：双边10文件首轮25过4红。强制revision错误复用追加尾部；扩展列落地使业务宽度调用1050变1078；同key新getter宽度停在87；新同ID持久化值未重验。四项均通过上表接缝处理修复，原断言保留，`both-glue-fixed` 29/29通过。
- `logs/private-flutter-width-probe*.log`：只在诊断轮使用assert内宽度探针，产品提交没有探针。
- `logs/private-flutter-full-both.log`：101文件自然结束899过、2既有跳过、29红；未取消此轮。
- `account-probe` 与 `account-probe-io`：同请求路径 GET auth/me、GET accounts/facets、POST accounts/summaries，在20个原fake帧后仍loading/0行，逐帧增加zero真实I/O事件后loading=false/3行。主线响应stream/codec需要真实事件轮，原28项页面驱动只有fake clock。沿用仓库已有 `pumpAndSettleWithIo`，不增加时间额度；Unit busy仍每场景60个原20ms采样帧，每帧只增加zero I/O turn。诊断夹具原文存 `account-workspace-io-probe.dart.txt`，不冒充验收测试。
- 第29项goods扩展列撤权测试把前序values响应扣住，再直接await串行队列后序reload，造成自锁。现在先启动后序撤权并断言旧响应不显示，释放前序gate后await两者，再执行重新授权/403；全部原业务断言保留。四个驱动文件单独46/46通过。
- `launcher-failure.txt`记录一个子进程启动错误：此机器stdin Python的sys.executable指向LibreOffice嵌入运行时，CreateProcess拒绝；未启动Flutter。后续用PowerShell splat同一JSON列表启动，未改测试或覆盖日志。

## 同一文件树验证

所有生产/测试修改完成后才执行最终组合；运行期间没有再改这些文件。原工具receipt如实保留当时HEAD=4d45及dirty状态，而不是补写为之后的提交号。运行中的文件树checkpoint与提交后的48个变更文件SHA-256/Git blob完全一致，最终index tree也与产品提交tree一致；见 `candidate-source-start.json`（其capturedAt是运行中checkpoint，不是进程启动时）与 `candidate-source-end.json`。

| 验证 | 结果 | 原始证据 |
|---|---|---|
| 双边10个关键文件 | 29过 | `private-flutter-both-glue-fixed.json` / 同名log |
| 四个页面驱动回归 | 46过 | `private-flutter-drivers-fixed.json` / 同名log |
| 公共表格、分页、权限、输出资格、页面全组合101文件 | 928过、0失败、2既有capture开关跳过 | `private-flutter-full-both-drivers-fixed.json` / 同名log（3:34自然结束） |
| 三个产品及四个驱动文件分析 | 0 issue | `private-flutter-analyze-glue-fixed.json` / 同名log |
| fresh Maven编译3277生产/2757测试源码，完整流4类 | 21过、0跳过、BUILD SUCCESS | `server/maven.log`、`server/exit.txt`、`server/surefire/`原8文件 |

关键计数：3000记录唯一请求3000、peakInFlight=1、scopeReads=1、recordIdCalls=3000；稳定父重建/新leading group维持正确membership读取。主档progressive续量 `widthCells=1576 expected=1576 indexBuilds=0`。所有原断言和红日志均保留。完整组合包含fresh同key getter、持久化cell/definition更新、可变row、冷失败、确认写后重读失败、同query旧完整保留、权限退休、未保存输入/未知提交与旧导出任务恢复。

Flutter使用工作树私有工具快照，每轮记录共享SDK相关文件前后hash，`sdk_unchanged=true`。Maven输出与TMP独立，不碰正在运行的backend target。未使用Root统一Web数据库、未做并发Flyway。

## 边界与后续

上述是该merge文件树的自动回归与后端流协议验证，不等于真实Web/Windows性能或全链验收。Root已经保留的“真实模具页面宽→窄、Tooltip/GlobalKey重挂引起RenderLayoutBuilder mutation”尚由A的Split/Adaptive独立分支修复，本分支没有Portal猜测修补，也不把裸表格或本轮单测绿色写成真实异常已关闭。Root合并本提交及其他已授权整改后，仍须冻结新候选，在同一源码版本重编Web/Windows并重跑真实入口和性能（首50/完整分开、原1秒与10秒门槛不变）。C包7b的真实文件/PG/v1/v2证据是独立已完成记录，不能替代新最终SHA验证。私有公司模板/原单/目标Win7设备缺失仍须现场验收。

复跑用 `./evidence/main-integration/rerun.ps1 -Tag 唯一新标签`；后端加 `-Server`。脚本拒绝覆盖原结果；禁止clean共享运行产物。原构建、私有工具与TMP保留本机但不入git；本目录公开raw日志/XML/JSON以binary属性保留字节，manifest列出sha256。凭据扫描44个归档前文件，Bearer/JWT/credential assignment匹配均0；规则结果见 `credential-scan.json`。
