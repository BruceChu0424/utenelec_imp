# 对象级授权（按负责人隔离）—— 新窗口交接 Prompt

> 用途：把下面 `=== 复制开始 ===` 与 `=== 复制结束 ===` 之间的整段内容，粘到一个新的 Claude 窗口，它会自行读文档/代码、问业务决策、从采购模块开始实施。
>
> 背景：2026-08-07 权限/并发审计已确认 采购/委外/生产/库存 四模块缺对象级授权（详见同目录 `2026-08-07-权限安全与并发加固审计报告.md`）。本项为"范围 B"，需单独立项。

---

=== 复制开始 ===

你是 Uten IMP（制造业 ERP）的后端+前端工程师。工作目录 D:\Projects\uten_imp。后端 server/（Spring Boot + Postgres + Flyway），前端 lib/（Flutter + Riverpod + go_router）。

═══════════════════════════════════════════
【任务】给 采购 / 委外 / 生产 / 库存 4 个模块加「对象级授权（按负责人隔离）」，并新增「查看全部」权限点
═══════════════════════════════════════════

【背景：本次审计已确认的现状（你先自己复核，别盲信）】
- 销售（订单/报价/出货/退货/其它出货/报表）已有完整对象级隔离：server/.../features/sales/SalesDocumentAccessPolicy.java，被 7 个 Service 使用。这是金牌范式，照抄泛化。
- 基础资料（客户/货品）有 owner 可见性（OwnerVisibility）。
- 采购(purchase)/委外(subcontract)/生产(production)/库存(stock)：经核实**零对象级授权**，只有粗粒度 @PreAuthorize(:view/:edit)。→ 这 4 个就是本次目标。
- 复核命令：
  for m in sales purchase subcontract production stock warehouse finance; do echo "$m: $(grep -rlE 'AccessPolicy|OwnerVisibility|requireWritable|requireReadable' server/src/main/java/com/uten/imp/features/$m/ 2>/dev/null | wc -l) 个文件"; done

【设计目标（已与用户确认）】
普通用户只看自己"负责"的单据；持「模块:view:all」权限的人（主管/GM/超管）看全部；超管恒全量。不可达对象返 404（不泄露存在性）。老数据(owner 为空)按销售范式：可读不可写，或回填 owner。完全复用现成 OwnerVisibility，不要新造第二套机制。

═══════════════════════════════════════════
【动手前必须先读的文档】（按顺序）
═══════════════════════════════════════════
1. docs/99-项目治理/2026-08-07-权限安全与并发加固审计报告.md  ← 本次审计全貌（含精确结论）
2. docs/05-架构/全局机制.md §一(权限模型与路由守卫)、§6.5(对象级授权)、§6.6(嵌套资源授权)
3. docs/05-架构/安全策略.md §四(权限模型)、§4.8
4. docs/00-项目准则/10-安全准则.md（权限点与存储分级铁律）
5. docs/99-决策记录-ADR/ADR-011（权限模型：部门+个人覆盖，角色已下线）
6. docs/99-决策记录-ADR/ADR-017（模块化单体边界 —— 见下方"架构边界"坑）
7. docs/04-数据模型/实体字典.md + ER草图.md（找各表现有 owner/maker 列）
8. docs/数据迁移/54-部门默认权限矩阵.md（V212 默认权限，新权限点要同步）

═══════════════════════════════════════════
【动手前必须先读的代码（参考范式）】
═══════════════════════════════════════════
- server/src/main/java/com/uten/imp/features/sales/SalesDocumentAccessPolicy.java  ← 照这个泛化
- server/src/main/java/com/uten/imp/security/OwnerVisibility.java  ← scope 求值器（evaluate(scope, viewAllPerm)），复用它
- server/src/main/java/com/uten/imp/features/sales/order/SalesOrderService.java  ← 看 accessPolicy.requireReadable/requireWritable/readablePredicate/nativeReadScope/nativeReadScopeWithLegacySentinel/canRead/canWrite/ownerForNewDocument 怎么用在 list/detail/update/delete/new 上
- 4 个目标模块的 Service（每个都要改 list/detail/update/delete/approve/批量）：
  purchase/order/PurchaseOrderService、subcontract/order/SubcontractOrderService、production/plan/ProductionPlanService、stock/StockDocService（及其它采购/委外/生产单据 Service：request/receipt/return、application/inquiry 等）
- 它们的 @Entity（找有没有 maker_id/制单人 列可做 owner 来源；没有就加 owner_employee_id）

═══════════════════════════════════════════
【项目铁律（违反即返工）】
═══════════════════════════════════════════
1. 安全第一：前端 hide ≠ 安全，后端每个 list/detail/写/批量/导出端点都要独立校验对象级；SQL 全参数化。
2. 机制平台统一：复用 OwnerVisibility + 泛化一个 AccessPolicy，不要每个模块各写一套范围判定逻辑（避免"面粉加水"式重复）。
3. 迁移自包含：一个 Flyway 迁移里把"加列 + 回填 + 约束"一次做完；同步改 docs。最新迁移是 V231，你从 V232 开始。
4. 权限点契约三处同步：Flyway 权限目录(permissions 表 INSERT) + Flutter lib/shared/auth/permissions.dart 的 Perm 常量 + 部门默认矩阵(V212 风格的受控重置或 INSERT)。新权限码：purchase:view:all / subcontract:view:all / production_plan:view:all / stock_doc:view:all。
5. 架构边界(ADR-017，重点坑)：feature 之间不能随意 import。把泛化的 AccessPolicy 放在 security/ 或 common/(foundation，无边界限制)；若必须放 features/ 下并被多 feature 引用，要在 server/src/test/java/com/uten/imp/architecture/ArchitectureBoundaryTest.java 的 APPROVED_FEATURE_EDGES 登记 "X->Y" 边并更新 ADR-017，否则 mvn test 直接红。（上一次就是这里踩过）
6. 不可达返 404 不返 403（不泄露单据存在性）—— 仿 SalesDocumentAccessPolicy.requireReadable。
7. 即时失效：owner 写入/变更走 V135 auth_version/epoch（写 user_permission_overrides 会自动 revoke refresh + bump 版本，已有机制，别重造）。
8. 代理质量差：子代理(Explore 等)读的是摘录不是全文，常给错签名/列名。把它当"待证假设"，关键结论自己读真实代码 / 跑真实服务验证。
9. 并发会话共享本工作区：可能有人在别的窗口改代码。建议用 git worktree 隔离，或动手前 git status 确认干净；运行 jar 前确认=HEAD。

═══════════════════════════════════════════
【实施步骤（建议顺序）】
═══════════════════════════════════════════
0. 先 git：从最新 origin 拉一个新分支（如 feat/object-level-auth-by-owner），别在 main 上动。
1. 泛化策略：把 SalesDocumentAccessPolicy 抽成平台级（放 security/ 或 common/，避免边界问题），参数化 scope + viewAll 权限码。或每个模块各一个薄壳调它。
2. 逐模块（建议先做 采购 做通一个，验证范式，再复制到委外/生产/库存）：
   a. 定 owner 来源：优先复用现有 maker_id/制单人 列；没有则迁移加 owner_employee_id。
   b. 迁移：加列(若无) + 回填 owner(老数据按制单人回填，或置 null=公共可读+普通用户不可写，仿销售老数据) + 约束。
   c. 新建单据：owner = 当前登录员工（仿 ownerForNewDocument）。
   d. Service 改造：list 用 readablePredicate/nativeReadScope 过滤；detail/update/delete/approve/批量 先 requireReadable/requireWritable；导出同过滤。
   e. 权限点：注册 模块:view:all（Flyway + Perm + 默认矩阵授予 主管/GM；超管恒全量）。
   f. 前端：路由守卫/按钮按需；管理端授权页加"查看全部XX"权限项（V228 两级目录已就绪，挂到对应模块分类下）。
3. 负向越权测试：每模块写"user A 访问 user B 的单 → 404 / 列表不返回 B 的单"。

═══════════════════════════════════════════
【动手前必须先问用户的业务决策（别自己拍）】
═══════════════════════════════════════════
- 每个模块的 owner 具体是谁？建议默认 = 制单人(maker)，但要和用户确认采购单/委外单/生产计划/库存单据各自的"负责人"语义。
- 老数据 owner 回填策略：按制单人回填？还是置 null（公共可读、普通用户不可写）？
- 「查看全部」权限授予谁：部门主管？GM？超管恒有。哪些部门默认给？
（建议你给用户一个默认方案让他确认，而不是开放式提问。）

═══════════════════════════════════════════
【验证标准（不绿不算完成）】
═══════════════════════════════════════════
- mvn test：全量通过（当前基线 890 左右，0 失败），尤其 ArchitectureBoundaryTest 必须绿。
- UTEN_RUN_DB_TESTS=true mvn test -Dtest=FullChainEndToEndTest：全链路 29+ 绿（验证迁移应用 + 实体加载 + 各链路无回归）。
- 新增负向越权测试绿（A 访问 B 的单 → 404）。
- flutter analyze：0 issue（若改了前端）。
- 自己用真实数据/真实服务跑一遍越权场景，不要只靠单测 mock。

═══════════════════════════════════════════
【文档同步（完成后）】
═══════════════════════════════════════════
更新：安全策略 §四、全局机制 §6.5/§6.6、实体字典(各表加 owner_employee_id + 新权限码)、ADR-017(若有新边界)、对应模块页面文档。在 docs/99-项目治理/ 新增一份本次对象级授权实施报告（含越权矩阵证据）。

═══════════════════════════════════════════
【完成标准】
═══════════════════════════════════════════
4 个模块（采购/委外/生产/库存）list/detail/写/批量/导出全部对象级受控；新增 模块:view:all 权限并授予权威角色；老数据回填确定；负向越权测试 + 全链路 E2E + mvn 全量 + flutter analyze 全绿；文档同步；提交到 git（问用户是否 push）。先做通"采购"一个模块给用户验收，再铺其余三个。

=== 复制结束 ===
