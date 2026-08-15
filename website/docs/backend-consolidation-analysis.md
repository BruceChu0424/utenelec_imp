# 官网后台与 IMP 平台整合分析（2026-08-11）

<!-- WEBSITE-DEPLOYMENT-DEFERRED-20260812 -->
> **2026-08-12 实施状态**：官网延期到未来独立云服务器。因此本文的数据级整合建议也暂停；当前不配置
> token、不开放 ingest 网络路径、不在 ERP 主机安装官网。未来官网恢复时再重新做端到端评审与 UAT。

> 问题：官网的后端要不要不再单独维护，统一放进 IMP 平台？
> 即在 IMP 里找一处专门放"官网后台"：收客户留言、更新网站内容/图片/信息。

## 现状盘点

**官网（`website/`，Next.js 15 全栈）已经自带完整后台**，不是"没有后端"：

- `/admin` 受保护后台：产品、系列、场景、新闻、案例、招聘、**询盘留言（inquiries）**、站点设置、图片上传
- 技术栈：Next.js Route Handler + Prisma + SQLite，JWT 登录、限流、安全审计均已落地
- 内容与站点同库，保存即发布，配合 Next.js 图片优化与多语言（10 语言 i18n 字段）

**IMP（`server/` + `lib/`，Java Spring Boot + PostgreSQL + Flutter）**：

- 制造业一体化 ERP，含"综合营销"部门和客户主档（`features/master/client`）
- 当前生产状态仍为 **NO-GO**（见根 README 2026-08-09 清单），尚未达到上线条件

## 结论：不要重写，做"数据级整合"

**整体并入 IMP（重写 CMS）不建议**，原因：

1. **重复建设**：官网后台已覆盖留言收件、内容/图片/设置更新，重写为 Java + Flutter 管理端是数周级工作量，且 Flutter 表单体验很难超过现成的 Next.js 后台。
2. **风险耦合**：公开官网是 7×24 对外门面；IMP 尚未生产放行。把官网内容链绑到 IMP，等于让门面系统等内部系统成熟。
3. **架构错配**：CMS 贴近站点才有好体验——同库即时发布、图片优化、多语言 JSON 字段、SEO 预览，这些搬进 IMP 都会变差。

**值得统一的是"客户留言"这一条线**，建议分两步：

### 第一步（推荐，成本低）：询盘自动汇入 IMP

- 官网询盘落库后，由同步任务 / webhook 推送到 IMP 新增接口（如 `POST /api/website-inquiries`）
- IMP 侧落"官网询盘"列表（综合营销部门可见），可一键转客户主档 / 跟进任务
- 官网 `/admin/inquiries` 保留为只读副本与兜底收件箱
- 效果：销售只在 IMP 一个工作台处理所有客户留言，官网后台不用动

### 第二步（远期，等 IMP 生产 GO 后评估）：IMP 加"官网运营"模块

- 在 IMP 增加官网内容"审批/发布"视图，官网后台降级为执行端
- 仅当公司确实需要多人协作审批流时才值得做；当前单人/小团队维护官网，现有后台足够

## 一句话答复

后台不用重写。留言汇入 IMP 统一处理（值得做，第一步即可落地）；网站内容更新继续用官网自带后台（它就是为了这件事写的，且做得更好）。

---

## 落地记录（2026-08-11，已实现）

第一步"询盘汇入 IMP"已按本文档落地：

- **服务端**（`features/webinquiry/` + V253 迁移）：`website_inquiries` 表（source_id 幂等、状态机 new→following→converted/closed、审计触发器）；
  `POST /api/website-inquiries/ingest` 共享密钥接收（`uten.website.inquiry-ingest-token`，fail closed）；
  列表 / 详情 / 跟进 / 关闭 / **一键转客户**（创建最小客户主档并关联）接口，权限点 `webinquiry:view` / `webinquiry:manage`（最小授权，权限管理页授综合营销部）。
- **Flutter**：工作台 → 综合营销部 →「官网询盘」，列表按状态筛选、详情页一键跟进/转客户/关闭。
- **官网**：`submitInquiry` 落库后 fire-and-forget 推送（`IMP_INGEST_URL` / `IMP_INGEST_TOKEN`），推送失败不影响客户提交。
- **部署注意**：本地部署（site=local）下 LocalNetworkGuardFilter 覆盖全部路径，官网服务器须在 `UTEN_LOCAL_ALLOWED_CIDRS` 内网段中；云端部署需另评估该守卫对 ingest 的影响。
