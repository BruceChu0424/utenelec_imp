# ADR-006 - 后端技术栈：Spring Boot + PostgreSQL

- **状态**：已接受
- **日期**：2026-07-22
- **影响**：整个后端、数据库、部署、前端网络层

## 上下文

Uten IMP 长期为纯前端 Mock 阶段（ADR-001..005 都聚焦前端）。Phase 2 起要"把人事从前端到后端、数据库、鉴权完整做完做全"，必须选定真实后端技术栈与数据库。这是 ADR-001（Flutter）与 ADR-002（Riverpod）之后的第三块地基决策。

候选后端：Spring Boot(Java) / NestJS(TypeScript) / Serverpod(Dart) / FastAPI(Python)。
候选数据库：PostgreSQL / MySQL / SQL Server / SQLite 嵌入。

## 决策

- **后端 = Spring Boot 3.x（Java 21）**：Spring Security 6 + Spring Data JPA + Hibernate + Flyway + jjwt + Argon2 + pgcrypto。
- **数据库 = PostgreSQL 16（公司本地服务器，中央库）**：pgcrypto 字段级加密、递归 CTE 查组织树、触发器审计。

## 理由

- **Spring Boot**：企业级标准、安全（Spring Security）/RBAC/审计极其成熟，中国企业 IT 团队维护与招人成本最低；机密数据场景案例多。
- **PostgreSQL**：原生 pgcrypto（身份证/手机/银行/薪资字段加密）、递归 CTE（组织树子树）、行级安全、pgaudit，正好满足"机密数据 + 安全审计"需求；社区与运维资源充足。
- **架构（客户端 → REST API → 中央库）**：200–1000 人共享公司数据，必须集中库；"本地"指公司内部服务器（非每端各存）。
- 前端仍为 Flutter，通过 Repository 接口访问后端（Mock/Dio 可切换），与 ADR-001/002 一致。

## 鉴权与安全（配套决策，见顶层计划 §四/§十三）

- 密码 Argon2id；默认密码=身份证后六位（仅内存派生，绝不落库/日志/返回）；首登强制改密；密码历史最近 5。
- 无状态 access JWT(15min) + 不透明轮换 refresh(7d，哈希入库，重用检测)。
- 登录防枚举（账号不存在与密码错同错误 + 时序抹平）+ 限流(5/min/IP) + 锁定(5次/15min)。
- DTO 按角色脱敏：身份证/银行仅 hr+admin、薪资 hr+finance+admin、manager/员工永不触碰。
- HTTPS 强制、CORS 严格、CSRF 关闭（JWT 走头）、令牌进 flutter_secure_storage（不入 shared_preferences）、备份加密。

## 后果

- **正面**：地基统一、安全审计可追溯、机密数据加密、前端方案不推翻。
- **负面**：新增 Java 后端代码量与运维；前端需引入 dio+secure_storage 网络层（已做）。
- **目录**：后端位于项目根 `server/`（与 `lib/` 平级，独立 Maven 工程），见 `01-规划/目录结构.md`。

## 相关

- [ADR-001 技术栈选型 Flutter](ADR-001-技术栈选型.md)
- [ADR-002 状态管理 Riverpod](ADR-002-状态管理选Riverpod.md)
- [05-架构/网络层与Mock.md](../05-架构/网络层与Mock.md)
- [05-架构/安全策略.md](../05-架构/安全策略.md)
- [06-老系统融合/00-融合总策略.md](../06-老系统融合/00-融合总策略.md)（后端启动后落地单向影子双写）

---

**最后更新**：2026-07-22
