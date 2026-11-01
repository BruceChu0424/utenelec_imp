# Flutter 销售审核组合 CI 根因与公共入口

本项独立分支 `uimp/release2539-flutter-manager-ci-fix`，基于主链 `65063dd8a`，用于本轮发布的已证实 CI 阻断。下一版客户端发布工作台继续隔离于自己的分支，不随本项合入，不修改版本号、服务端或 SQL。

## 实际 CI 证据

`9477b9c7a` 的 Flutter/Web job `124746337934` 与旧 `2fd786740` 的 job `124745468494` 均完整结束：14291 通过、7 失败、69 跳过，失败集合相同。未取消旧检查。主工作区 `output/release-2539-resume/ci-final-readonly/flutter-final/` 保留两份完整日志及 `failures.json`。

- `9477-flutter-web.log` SHA-256：`3b2f5b14015fc457efeaae3dc3c9ea597a2e991f57a1738cec14459f0698153d`。
- `2fd-flutter-web.log` SHA-256：`77e6f8d131820e84566647250eaab529844f60dac854a03d6bf3a3348d1daeb7`。

七项对应六个文件：审核责任来源测试仍要求旧直写文案；native scope 两例仍查找“提交财务核价”；路由总数实际 247、登记仍为 244；架构新增 `sales->finance` 私有依赖；两审核页权限精确来源登记未随阶段同步；报价源码契约只读财务 record，没有识别负责人实际投影。

## 根因修复与保留差异

- `sales_manager_review_page` 直接使用财务私有仓库构成真实依赖问题。既有订单审核 DTO 与仓库整体升至 `lib/shared/sales_review/`，类型名称、财务/负责人阶段参数、端点、请求体、解析、修订号及未知提交证明均保留；移除旧实现，全部生产调用方与测试同步导入公共入口，没有加架构例外。去除 import 与位置说明后的 DTO/仓库实现与原件逐字一致。
- 公共仓库的 facet 解析依赖同时沿唯一实现升至已有 `shared/models/master_facet_bucket.dart`；旧 `master_facet.dart` 通过已有 export 继续兼容其他调用方，不复制解析器，不把 feature 私有依赖藏入 shared。架构回归将三个公共审核文件与 facet owner 纳入无反向 feature 依赖检查。
- 两审核页复用 `SalesReviewPermissions` 身份枚举，明确报价/订货 × 财务/负责人四种配置；仅替换重复的权限码选取。服务端动作集合、native actor、代办只读、超管既有分支、业务状态、撤权、同一认领租约与未知提交保护均留在原处。经理驳回/撤销继续独立于批准；订货财审仍保留既有确认权限兼管驳回的合同。
- 权限全局 cap 仍为 677。两页迁出重复身份表后删除其旧精确登记，登记增量校验和从 296 收紧为实际 290；296 是校验和，不能当成第二个额度。没有自动生成宽松 baseline、泛化例外或删除保护断言。
- 三条负责人路由分别登记精确 any 权限：队列允许报价/订货查看任一；报价与订货详情分别只接受本类查看码。原逐条全路由、豁免、页面范围核对继续执行。
- 审核责任断言同时锁定经理与财审的当前条件表达式；native scope 两个弹窗从真实本地化上下文取当前“提交负责人审核”文案，旧确认回调在权限刷新或 ABA 后仍必须零写入。不是补认领或放开 actor 门槛。
- `SalesManagerReviewProjection.quote` 确实把行字段 `financePriceByName/At` 更名为 `reviewPriceByName/At`，也更名表头。生产 parser 原本已支持 neutral 优先与财务回兼，因此不删除 fallback、不改服务端字段。源码契约精确读取并锁定两组实际 rename，核对 DTO 与投影的全部读取键；新增真实形状用例核对阶段、作者、时间、认领类型、权限动作、金额原始文本及单位分组，混合旧字段不能覆盖当前负责人。

## 入口与验证范围

Web 与现有 Flutter 桌面使用同一公共实现。生产迁移覆盖负责人队列、订单审核详情、财审列表/计数、修订表格，以及平台表格注册与显示事实；对应审计中心、合计栏、报价来源条、历史、仓库方法与源码合同测试一并迁移。旧私有模型/仓库在 `lib` 和 `test` 中零引用。Win7 WPF 完整 ERP 与负责人审核仍为候选未迁移，本项没有开放 WPF 写入口；最终组合的源摘要由发布主任务统一 canonical 同步，不覆盖并行台账。

本工作树采用现有锁和缓存，`PUB_HOSTED_URL=https://pub.dev`、`--no-pub`，未修改依赖。18 个定向测试文件覆盖 191 项：六个原失败文件、负责人审核与未知提交、订单仓库、审批协议、公共身份映射、财审列表/详情/审计中心、合计/报价来源/历史及公共 facet 传输。首轮公共身份配置触发 `use_enums` 提示后改为枚举，最终按同一范围复核；各次原始日志均保留。

最终结果与日志摘要见本工作树 `build-flutter-manager-ci-focused.log`、`build-flutter-manager-ci-analyze.log`。静态检查使用 `--fatal-infos` 覆盖公共入口、所有变更生产调用方及关键契约测试。该本地证据不代替最终审核提交完整 CI 全绿，也不代表正式构建、上传或生产验收。

最终复核 **191 通过，失败/错误/跳过均为 0**；14 项静态分析目标 **No issues found**，无警告或 info。测试日志 SHA-256 `4ca3ea2801837ea679dcba9b9e51a695a5789f216640b869abbee95b9a1d3ca5`；静态日志 SHA-256 `261ff59cf3a517a9d26c1007be8ed3b9abd07185d88c1bd93d0beb10f008f97b`。现有 Flutter 镜像来源提示保留，不作为业务警告隐去。
