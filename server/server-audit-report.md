# Uten IMP Server 代码审计报告（重构前）

审计范围：`server/src/main/java` 全部 136 个文件 + `application*.yml` + `db/migration` 清单。
标注约定：【确定】= 有直接证据；【疑似】= 需人工/产品判断。行号基于当前 `feat/brand-theme-refresh` 工作区。

## 1. 包结构与命名问题

| # | 级别 | 问题 | 证据 |
|---|------|------|------|
| 1.1 | 【确定】 | camelCase 包名 `features.profileChange`，不符合 Java 全小写包名规范（建议 `profilechange`） | `features/profileChange/ProfileChangeService.java:1` |
| 1.2 | 【确定】 | `features.rbac` 混合三种职责：(a) 认证模型 `UserAccount`/`RefreshToken`/`PasswordHistory`（主要消费方是 `features.auth`）；(b) RBAC 模型 `Role`/`Permission`/各 join 实体；(c) 后台管理 API `UserController`+`UserService` | `rbac/RefreshToken.java`、`rbac/PasswordHistory.java` 仅被 `features/auth/*` 引用 |
| 1.3 | 【确定】 | `UserController` 类名与映射不符：类叫 User 但挂在 `/api/admin`，且承担角色/部门角色/权限覆盖管理 | `rbac/UserController.java:17-18` |
| 1.4 | 【疑似】 | `security.TxSessionVars` 实为「事务会话变量 + pgcrypto 加解密 + HMAC」，更接近 persistence/crypto 基础设施而非 security | `security/TxSessionVars.java:16-25` |
| 1.5 | 【疑似】 | `security.DataAccessPolicy` 是员工档案领域的数据可见性规则，领域知识在 org/employee，放在 security 包边界模糊 | `security/DataAccessPolicy.java:7-14` |
| 1.6 | 【疑似】 | `audit` 包只有写入侧（AuditService），`AuditLogRepository` 两个查询方法无人用——审计查询 API 未建 | `audit/AuditLogRepository.java:11,13` |
| 1.7 | 【确定】 | DTO 风格不统一：record（auth/rbac/profileChange/visitor 的 dto）vs Lombok class（`EmployeeDetail`、`EmployeeListItem`、`UserSummary`、`DepartmentDetail`、`DepartmentNode`） | 对比 `auth/dto/LoginRequest.java:5` 与 `org/employee/dto/EmployeeDetail.java:19` |
| 1.8 | 【确定】 | DTO 分组两种风格并存：`NestedDtos` 包装类（employee）vs `ProfileChangeDto`/`VisitorApplyDto`/`VisitorAuthDto`/`VisitorScanDto` 包装类 | `org/employee/dto/NestedDtos.java:10` |
| 1.9 | 【确定】 | `position` 包只有 Entity+Repository，无 Service/Controller——岗位无管理 API（仅靠种子），与 department 包结构不对称 | `org/position/` 仅 2 个文件 |

## 2. 死代码（逐项给证据）

**确定死代码（无任何引用，grep 全仓仅命中定义处）：**

| # | 位置 | 说明 |
|---|------|------|
| 2.1 | `features/auth/AuthService.java:353-358` | `private Set<String> permsOf(UUID)` 重载：私有方法，全仓无调用（只有 javadoc 自引用）；`permsOf(UserAccount)` 才是活路径 |
| 2.2 | `features/auth/AuthController.java:60-66` | `private String clientIp(...)`：无调用（login 直接用 `http.getRemoteAddr()`） |
| 2.3 | `audit/AuditService.java:81-83` | `currentUserIdOrSystem()`：全仓无调用 |
| 2.4 | `audit/AuditLogRepository.java:11,13` | `findByActorIdOrderByCreatedAtDesc` / `findByTargetTypeAndTargetIdOrderByCreatedAtDesc`：无调用（审计查询 API 未实现） |
| 2.5 | `common/web/PageResponse.java:20-27` | `static of(Page<T>)`：无调用，三处使用方都手写 `new PageResponse<>(items, page, size, ...)` |
| 2.6 | `security/DataAccessPolicy.java:26-28` | `isAdmin(Set<String>)`：无调用 |
| 2.7 | `common/web/ErrorCode.java:12,26-28` | `MUST_CHANGE_PASSWORD`、`QR_INVALID`、`QR_EXPIRED`、`QR_USED`：从未被 throw（QR 核验语义走了 `VisitorVerifyResponse.reason` 字符串，属重复建模） |
| 2.8 | `common/web/ApiException.java:26-30` | 三参构造器 `(code, message, fieldErrors)`：全仓无构造调用（fieldErrors 仅 GlobalExceptionHandler 从 validation 异常自行构造 ApiError） |
| 2.9 | `security/AuthUser.java:40-46` | 7 参构造器（不含 superAdmin）：无调用，`JwtAuthFilter:89` 用 8 参 |
| 2.10 | `features/profileChange/ProfileChangeRequest.java:97-100` | `isPending()`：无调用（各处仍用 `"pending".equals(...)`） |
| 2.11 | `features/auth/dto/LoginRequest.java:8` | `rememberDevice` 字段：后端从未读取（删除会改 API 契约，先确认前端） |
| 2.12 | `config/props/SecurityProperties.java:15` | `corsAllowedOrigins` 字段：`SecurityConfig.java:31` 用 `@Value` 直读，从未读该 props 字段 → 死属性 + 默认值两处不一致 |
| 2.13 | `UtenImpApplication.java:18` | `@EnableScheduling`：全仓无 `@Scheduled`（可先留，标注即可） |

**无人使用的 Repository 方法（仅声明，无调用点）：**

| # | 位置 |
|---|------|
| 2.14 | `org/department/DepartmentRepository.java:13` `findByCode` |
| 2.15 | `org/position/PositionRepository.java:10` `findByDepartmentIdOrderBySortOrderAsc`（整个 repo 仅 `findById` 被用） |
| 2.16 | `org/employee/EmployeeRepository.java:19,21,25` `findByDepartmentIdInAndDeletedFalse` / `findByDeletedFalse` / `countByDepartmentIdInAndDeletedFalse`（列表走 Specification，这些方法已被替代） |
| 2.17 | `org/employee/EmergencyContactRepository.java:12` `deleteByEmployeeId` |
| 2.18 | `rbac/UserRoleRepository.java:13` `findByIdUserId` |
| 2.19 | `rbac/UserPermissionOverrideRepository.java:12` `findByIdUserId` |
| 2.20 | `rbac/RolePermissionRepository.java:30` `deleteByIdRoleId` |
| 2.21 | `visitor/VisitorApplicationRepository.java:13` `findByQrToken`（verify 解码 token 后走 `findById`，不查 qr_token 列） |
| 2.22 | `visitor/VisitorRefreshTokenRepository.java:18` `countByVisitorAccountIdAndRevokedAtIsNull` |
| 2.23 | `visitor/VisitorAccountRepository.java:11` `existsByPhoneHash`（用的是 `findByPhoneHash`） |

**疑似死代码 / 未实现功能（需产品判断，勿直接删）：**

| # | 位置 | 说明 |
|---|------|------|
| 2.24 | `org/employee/EmployeeCredential.java` + `EmployeeCredentialRepository.java`；`EmployeeEducation.java` + `EmployeeEducationRepository.java` | 实体+仓库完整但**没有任何 Service/Controller 引用**（入职 DTO 也不含证书/学历）。表由 V03 迁移创建、且有 updated_at 触发器——属「建表未建功能」。删除映射不影响 DB，但需确认该功能是否排期中 |
| 2.25 | `visitor/sms/AliyunSmsGateway.java:21-26` | stub 实现：永远 `return false` + TODO。生产配 `provider=aliyun` 会让所有短信发送失败——要么实现要么在文档明示未就绪 |
| 2.26 | `visitor/VisitorSmsCode.java:34` `scene` 字段 | 全仓只写 `"login"`（`VisitorAuthService.java:46`），`SendCodeResponse.scene` 也只是回显——预留未用 |
| 2.27 | `rbac/RefreshToken.java:33-34` / `visitor/VisitorRefreshToken.java:33-34` `deviceInfo` | 只写不读（无接口返回设备列表） |

**被注释掉的代码块：未发现**（通读全部 136 文件，仅有正常 javadoc/行注释）。

## 3. 重复与可复用点

| # | 重复内容 | 位置 |
|---|---------|------|
| 3.1 | `sha256()` 复制 3 份 | `auth/RefreshTokenService.java:51`、`visitor/VisitorRefreshTokenService.java:56`、`visitor/VisitorSmsService.java:84` |
| 3.2 | 刷新令牌三件套近乎整体复制：实体字段、`issue/revoke/rawToken` 逻辑 | `rbac/RefreshToken(Repository)` vs `visitor/VisitorRefreshToken(Repository,Service)` 对照 `auth/RefreshTokenService.java:32-65` 与 `visitor/VisitorRefreshTokenService.java:28-69` |
| 3.3 | `hostInfo()` 逐字节相同；`toListItem` / `toListItemStaff` 相同 | `visitor/VisitorApplicationService.java:153-159,111-119` vs `visitor/VisitorApprovalService.java:268-274,258-266` |
| 3.4 | `maskPhone()` 两份 | `org/employee/EmployeeService.java:561-564` vs `visitor/VisitorAuthService.java:177-182` |
| 3.5 | `isBlank()` 三份 | `EmployeeService.java:577`、`VisitorApplicationService.java:161`、`ProfileChangeService`（经 `VisitorApplicationService.isBlank` 被 ApprovalService 跨类调用，耦合奇怪） |
| 3.6 | `last4()` 两份 | `common/util/IdCardUtil.java:46` vs `VisitorApplicationService.java:165-167` |
| 3.7 | 分页构造 `PageRequest.of(max(0,page-1), min(max(1,size),100))` 重复 4 处 | `EmployeeService.java:78`、`UserService.java:70`、`ProfileChangeService.java:137,200`；且 `ProfileChangeDto.Page` 与 `common.web.PageResponse` 是同一结构两套类 |
| 3.8 | 「仅 admin/superAdmin 可授 admin 角色」守卫复制 3 份 | `EmployeeService.java:312-317`、`UserService.java:128-133,173-178` |
| 3.9 | `cb.isFalse(root.get("deleted"))` + Specification 模板重复 5 处 | Employee/User/VisitorApproval/VisitorApplication/VisitorDirectory 各 Service |
| 3.10 | `requireStaff()` 重复 | `ProfileChangeService.java:323-327` vs `VisitorApprovalService.java:301-307` |
| 3.11 | `tx.bind()` 横切调用：17 处手写、位置不统一（多数在方法首行；`ProfileChangeService.submit` 在第 129 行循环之后；`review` 用 `bindActor`）。具备抽 AOP/拦截器统一的条件（仅报告现象） | 见 grep 结果 17 个调用点 |
| 3.12 | `requireDept/requireEmployee/require(UserAccount)` 等「findById+filter deleted+orElseThrow NOT_FOUND」模式重复 6+ 处 | DepartmentService:117、EmployeeService:535、UserService:253 等 |
| 3.13 | 员工姓名/部门名回填（findById→map getFullName）散落且 N+1：`ProfileChangeService.toBatchDetail` 每条记录最多 4 次 findById | `ProfileChangeService.java:469-507`、`UserService.java:77-85` |

可抽公共件建议：`HashUtil`(sha256)、`Strings`(isBlank/maskPhone/last4)、`Pageables`(分页构造)、`AdminGrantGuard`、`SoftDeleteSpecs`、`CurrentUserFacade`(requireStaff/requireHr)。

## 4. 过大文件拆分建议

### 4.1 `features/org/employee/EmployeeService.java`（590 行，15 个依赖）

职责清单：①列表 Specification 查询（L57-83）；②详情组装+按角色脱敏（L86-160, 497-527）；③入职 8 步原子建号（L163-325）；④HR 编辑+敏感/薪资重写（L328-403）；⑤生命周期 transfer/offboard/confirm/delete/history（L405-493）；⑥工具方法（L529-589）。

拆分方案：
- `EmployeeQueryService` ← ①②（list/detail/history + fillSensitive/decryptMasked/maskPhone/probationEnd）
- `EmployeeOnboardingService` ← ③（validation、身份证派生、建号 8 步）
- `EmployeeCommandService` ← ④⑤（update/transfer/offboard/confirm/delete）
- `EmployeeSensitiveWriter` ← updateSensitive/updateCompensation（加密写入收敛一处）
- `EmployeeMapper` ← toList/toHistory/detail 装配
- `nn/isBlank` 进公共 `Strings`

### 4.2 `features/profileChange/ProfileChangeService.java`（507 行）

职责清单：①提交 submit（直改+建批次，L59-131）；②员工侧查询/撤销（L134-190）；③HR 队列/详情/审批（L197-303）；④计数器（L306-317）；⑤字段读取/应用三个大 switch（readCurrentValue L344-375 / applyDirectEdit L378-410 / applyReviewedChange L413-441，三者映射表高度重叠）；⑥批次折叠+DTO 组装（aggregateStatus L457、toBatchDetail L469-507）。

拆分方案：
- `ProfileChangeSubmitService` ← ①（含幂等、24h 防重）
- `ProfileChangeQueryService` ← ②③的列表/详情（myList 与 hrList 的批次折叠逻辑几乎相同，合并）
- `ProfileChangeReviewService` ← review + 计数器
- `ProfileFieldApplier` ← ⑤三个 switch 收敛为一张「fieldCode → reader/writer」映射表（消除重复且防漏字段）
- `ProfileChangeMapper` ← toBatchDetail + 姓名批量回填（修 N+1）
- `requireStaff/requireHr` 下沉公共

### 4.3 `features/auth/AuthService.java`（365 行，16 个依赖，构造器 90 行）

职责清单：①login+锁定计数+防枚举（L92-150）；②refresh/logout 轮换（L152-194）；③changePassword（L200-241）；④me/verifyPassword（L243-270）；⑤令牌签发与 profile 组装（L274-309）；⑥权限合成 rolesOf/permsOf（L311-358）。

拆分方案：
- `LoginService` ← ①（rate limiter、dummy hash、锁定）
- `PasswordService` ← ③④的 verifyPassword（+ PasswordHistory 写入）
- `TokenIssuer` ← ②⑤（配合 RefreshTokenService）
- `PermissionResolver` ← ⑥（permsOf/rolesOf；顺带删 2.1 的死重载）
- AuthService 退化为薄 facade 或直接由 Controller 分别注入

### 4.4 `features/visitor/VisitorApprovalService.java`（310 行）

职责清单：①HR 审批 list/detail/action（L52-108）；②被访人确认（L112-156）；③保安核验 verify/checkIn+QR 签发（L160-239, 309）；④拉黑（L291-299）；⑤green/red/hostInfo/load 等装配（L241-307）。

拆分方案：
- `VisitorHrApprovalService` ← ①
- `VisitorHostConfirmService` ← ②
- `VisitorGateService` ← ③④（verify/checkIn/blacklist + genQr/genPasscode/QrPayload）
- `VisitorApplicationMapper` ← hostInfo/toListItem（与 VisitorApplicationService 共用，消除 3.3）

### 4.5 `features/rbac/UserService.java`（257 行）

职责清单：①账号列表/摘要（L57-85）；②账号状态/解锁/重置密码（L87-120）；③角色分配+角色列表（L122-151）；④部门默认角色（L153-185）；⑤个人权限覆盖（L187-244）。

拆分方案：
- `UserAccountAdminService` ← ①②
- `RoleAdminService` ← ③④
- `PermissionOverrideAdminService` ← ⑤
- 公共 `AdminGrantGuard`（3.8）

## 5. 不一致与坏味道

**【确定】行为级问题（建议优先看）：**

1. **管理员「锁定」不生效**：`UserService.setStatus(id,"locked")`（L88-93）只写 status 不写 lockedUntil；而 `AuthService.login:122-128` 只检查 `"disabled"` 和 `lockedUntil` 时间戳，从不检查 `"locked"` 状态 → lock 接口形同虚设。
2. **乐观锁基线失效**：`Employee.version` 注释承诺「每次写都 +1」（`Employee.java:88-93`），但 `EmployeeService.update/transfer/onboard` 全部不写 version（仅 `ProfileChangeService.java:126,282` 递增）→ HR 直改档案后，`ProfileChangeService.review:273` 的版本校验照样通过，防合并竞态失效。
3. **车牌明文/密文双列读错列**：V14 起只写 `plate_no_enc`（`VisitorApplicationService.java:57`），但列表与核验响应读的是遗留明文列 `getPlateNo()`（`VisitorApprovalService.java:245,255,265`、`VisitorApplicationService.java:118`）→ 新数据列表/扫码页车牌恒为 null，详情页却有值。
4. **`tx.bind()` 调用时机**：`ProfileChangeService.submit` 在 L129 才 bind，而循环内 `countRecentActiveByField` 查询会触发 JPA auto-flush，先 flush 的 INSERT 触发 `fn_audit` 时 `app.actor_id` 尚未设置 → 部分审计行 actor 为 NULL（V18 触发器 + V05 `fn_audit` 读 `current_setting('app.actor_id')`，已核实）。
5. **AuthService 全程无 tx.bind()**：`changePassword`（L200-241）在已认证上下文写 `users` 表（V05 已挂审计触发器），触发器行 actor 恒为 NULL；虽有 `logExplicit` 事件行，但 before/after 行丢 actor。同理 `VisitorAuthService.login` 写 `visitor_accounts`（V12 触发器）未 bind。
6. **Controller 绕过 Service**：`UserController.java:23,77-81` 直接注入 `PermissionRepository` 做查询。
7. **`VisitorDirectoryService.listDepartments:35` 用 `findAll()` 不过滤软删**，与 `DepartmentService.tree:28`（`findByDeletedFalseOrderById`）不一致 → 已删部门泄露给访客。

**【确定】一致性坏味道：**

8. `EmployeeController.update:53` 缺 `@Valid`（其余写接口都有）。
9. `ProfileFieldPolicy.java:97` `HR_ONLY.contains(fieldCode) || isHrOnly(fieldCode)` 恒等冗余；`REQUIRES_REVIEW`（L72-79）里 `emergencyContact.name/phone/relationship` 三个条目永远不会匹配真实 fieldCode（真实码是 `emergencyContact.0.name`，由 `isEmergencyContactSubfield` 兜底）——死条目误导读者。
10. 全限定名当 import 用：`VisitorApplicationService.java:33`（EmployeeRepository）、`VisitorAuthService.java:39`（LoginRateLimiter）。
11. QR 语义双轨：`ErrorCode.QR_*`（死，见 2.7）vs `VisitorVerifyResponse.reason` 字符串 `"invalid"/"expired"/"used"`。
12. `AuthService.me(...)` 把 `currentUser::requireId` 当 `Supplier` 参数传入（L244），Service 本该自取——参数化无收益。
13. `VisitorRefreshTokenService.revokeAllByVisitor:47-54` 全表 `findAll()` 内存过滤（自带 TODO），对照员工侧 `revokeAllByUserId` 是批量 UPDATE。
14. `EmployeeSensitive.java:6-10`、`EmployeeCompensation.java:6-10` 未使用 import（FetchType/JoinColumn/MapsId/OneToOne）。
15. record/class DTO 混用（见 1.7）；`DepartmentSaveRequest` 等可变 class 承载请求体，而同类请求（`SetRolesRequest`）是 record。

**【疑似】需人工判断：**

16. `AuthService.login:133` 登录成功 `setStatus("active")` 会把管理员手动的 `locked` 一并冲掉（与问题 1 联动）。
17. `AuditService.log(...)` 仅 logout 一处使用，其余全走 `logExplicit`——两个方法可考虑合并。
18. `audit` 触发器未覆盖 `emergency_contacts`（员工可直改）与 `department_roles`/`user_permission_overrides`（V05/V12/V18 清单已核实）——是否有意为之需确认。

## 6. 配置与资源

**application.yml / dev / prod：**

1. 【确定】CORS 默认值三处不一：`application.yml:43`（`localhost:53764,localhost:8080`）vs `SecurityConfig.java:31` @Value 默认（`localhost:53764`）vs `SecurityProperties.java:15` 死字段（`localhost:53764`）。
2. 【疑似】swagger/springdoc 无 prod 关闭配置，且 `SecurityConfig.java:47-49` 对 swagger-ui 与 v3/api-docs `permitAll`——生产暴露 API 文档需确认。
3. 【确定】`application-dev.yml:8` `com.uten.imp: DEBUG` 与 base `application.yml:76` 重复。
4. 【疑似】`application-prod.yml:8` `show-sql: false` 为无效重申（base 未开）；`application.yml:19` `time_zone: UTC` + `jackson.time-zone: UTC` 是有意统一，保留。
5. 【确定】敏感项 fail-fast 设计良好（jwt/pgp/hmac/bootstrap 均无弱默认），无硬编码密钥。

**db/migration 清单（21 个，历史不可改，仅列名）：**
V01 enable_pgcrypto / V02 departments_positions / V03 employees / V04 auth_rbac / V05 audit / V06 seed_rbac / V07 seed_org / V08 seed_admin / V09 audit_redact_password / V10 id_card_hash / V11 roles_permissions_audit / V12 visitor / V13 visitor_perm_split / V14 visitor_plate_enc / V15 visitor_passcode / V16 super_admin / V17 doc_seed_admin / V18 profile_change_requests / V19 profile_change_perms / V20 profile_change_requests_audit_columns / V21 admin_perm_assignment

## 7. 风险分级处理建议

**A 级（安全机械操作，可直接做）：**
- 删 2.1-2.10、2.13-2.23 全部死代码（私有方法、死 Repository 方法、死构造器/枚举值/字段；2.11 `rememberDevice` 先问前端）
- `profileChange` → `profilechange` 包改名（IDE 重构，import 全量联动）
- 抽 `HashUtil/Strings/Pageables`（3.1、3.4-3.7）并替换调用点
- 清理未使用 import（5.14）；FQN 改 import（5.10）
- yml 去重（6.1 统一到 SecurityProperties、6.3、6.4）
- 合并 `ProfileChangeDto.Page` → `PageResponse`（注意字段名 total/totalElements 差异，前端联动）

**B 级（需小心的移动/拆分）：**
- rbac 包三分：`features/auth/model`（UserAccount/RefreshToken/PasswordHistory）、`features/rbac`（纯角色权限模型）、`features/admin`（UserController/UserService→按 4.5 拆分）
- 五大 Service 按第 4 节方案拆分（先拆 EmployeeService 与 ProfileChangeService，收益最大）
- `ProfileFieldApplier` 映射表化（4.2，消除三个 switch 的漏字段风险）
- 员工/访客刷新令牌合并为泛型化单套（3.2，表不动只并 Java 侧）
- `TxSessionVars` 移至 `common/crypto` 一类的基础包（1.4）

**C 级（有行为风险，先确认再动）：**
- 修「lock 不生效」（5.1）：改 login 检查 status 或 lock 写 lockedUntil——影响现有账号状态语义
- 修 version 递增（5.2）：EmployeeService 各写路径补 `version+1`——会使在途 pending 申请 409（这正是设计意图，但需知会 HR 流程）
- 车牌读列统一改 `plateNoEnc` 解密（5.3）：行为变化（列表开始显示车牌），明文列待 V14 注释所说「后续清理」
- `tx.bind()` 前置到方法首行 / AuthService 补 bindActor（5.4、5.5）：审计数据变化
- 删 EmployeeCredential/EmployeeEducation 实体映射（2.24）：需产品确认证书/学历功能不上线
- 生产关闭 swagger permitAll（6.2）
- 紧急联系人等表补审计触发器（5.18）：新迁移，影响 DB
