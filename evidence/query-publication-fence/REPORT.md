# 公共读取同事件轮查询漂移修复

产品提交 `b0fe9f7f6cc156db8a05d2b5fd07a642845bcac2`，基于 Root 当时实际 HEAD `4070cd831731c8246ecf76ba6ee64d8ca7c72733`，文件树 `6010d1834744ecf0845235ec04f2ba3bea523a8c`。独立工作树 `D:/Projects/uten_imp_worktrees/feedback-query-fence-20261111`，分支 `uimp/feedback-query-fence-20261111`。

这是 public `readScopedPage` 合同回归：调用query A读取后，同一事件轮内把必选 `currentQuery` 的结果改成B，不传可选 `isCurrent`，已缓存的true判断让旧A完成。独立审查原件在提交 `04faa8176f70a3f92c368ff6696ea5a5faa5a69e` 的 `evidence/independent-query-turn/`。本树再次真实执行原三例，得到2绿1红，见 `baseline-three`。Root4070和独立8c所用mixin均为Git blob `c95f7d66c4eb2eef01c7ca8b3d8ff37b5ed016ac`。这证明公共入口保障退化，不外推为已发生真实页面跨scope写入或资料泄漏。

## 唯一公共修复

只修改 `lib/shared/paging/scoped_paged_read_view_mixin.dart`，未改所有调用方以掩盖合同问题，也未修改表格/controller/响应式宿主、后端、数据库或运行中的Root backend。

- 行验证热循环继续每事件轮缓存深query/epoch核对，mounted/disposed/owner仍直接检查。
- fetchPage、fetchPageSized与fetchComplete的await结果先强制核对；返回/错误的finally使reader续接微任务不能借旧缓存判断。
- 每个实际prefix发布前强制核对；prefix消费回调结束后使缓存失效，覆盖回调同步改变查询。
- activity wrapper完成后、最终public Future返回前再次强制核对，覆盖已经接受完整结果的cache hit，防止调用方误授予输出资格。
- 错误/403处理前强制核对live归属；保持当前403的原回执和owner退休，旧query403不误退休当前view。
- 同一闭包最多保留一个expiry timer，新增发布栅栏不堆积多个同turn timer；销毁仍由原公共入口取消timer。没有删除memo或将深比较放回每行。

## 原反例、对照与验证

`test/shared/paging/scoped_query_publication_fence_test.dart` 保留原3例的合同与断言（同query合法、仅query切换应退休、显式invalidate应退休），不传可选isCurrent。另覆盖page/sized/complete/cache的旧结果不能授予CompleteOutputGuard、row-validation后prefix与无prefix最终屏障、prefix回调改query、同query两批prefix和accepted cache正例，以及旧query403/当前403两种owner回执。

| 轮次 | 结果 | 说明 |
|---|---|---|
| baseline-three | 2过1红 | 原反例，本树原生产blob；query-only返回旧结果 |
| candidate-three-budget | 5过 | 原3例+原预算2例 |
| all-boundaries / all-boundaries-two-batches | 各12过2 fixture红 | 新夹具误把只有一批的完整结果当成必有prefix，合法正例也无prefix；第二次脚本assert未落盘，故该次仍原夹具。两个原日志均保留，不冒充产品失败或删除断言。 |
| all-boundaries-corrected | 14过 | 改用真实两批输入，保原prefix正反业务断言 |
| public-regression | 385过 | 32个公共/页面文件 |
| analyze | 2条info | 缺if花括号、原probe多余dart:async import；原日志保留 |
| public-regression-final | **386过、0失败、0跳过** | 最终2文件源码，含新增无prefix最终guard负例 |
| analyze-final | **0 issue** | 最终产品+新增回归 |

最终32文件覆盖全部 `test/shared/paging/*test.dart`、ScopedPagedRead、完整读取/流与owner取消、退休翻译、403、CompleteOutputGuard、6扁平/4分类输出资格及写后退休、同query旧完整保留、真实shared pane打印导出、账户原串行异步批量和主档创建原回归。精确清单在 `test-list.json`。

**预算断言完全未改。** 原600行测试最终运行 `re-checks=3644 compares=8 loop checks=1212`；先前定向轮3641/7。差异来自原有真实slice让步次数，均保留原比较次数与检查次数的预算断言；额外深核对只随fetch/发布/返回栅栏发生，未恢复逐行深比较。没有增加时间门槛、最短等待或删除性能检查。386项是同一产品文件树的自动回归，不等同真实Web/Windows响应时间通过。

## 证据与复跑

所有日志及tool receipt原字节保留，原失败不覆盖。`source-proof.json`列出base/product/tree、两个变更文件blob与SHA-256，并证明 `master_data_table_view.dart` / `platform_table_controller.dart` 两个并行宿主blob完全不变。最终回归在提交前文件树执行，receipt如实记录当时HEAD4070和dirty状态；产品提交对应同一源码字节，不把之前7b检查改写成新SHA结果。Flutter采用本树私有工具快照，逐轮共享SDK hash核对均 `sdk_unchanged=true`。

复跑 `./evidence/query-publication-fence/rerun.ps1 -Tag 唯一新标签`。本分支不执行Maven/Flyway、没有接入统一Web库或测试crypto。Root会整合此小提交、A的共享宿主修复及其余已授权变更，再冻结最终SHA复验真实入口。main、原audit、其他工作树的未提交内容均未改；无推送、部署或正式打包。原真实响应式异常不由这些公共合同单测冒称闭环。
