# 官网与 IMP 正式实施记录

2026-10-17：用户确认完整实施，并追加网站仅作公司/产品展示、联系销售，不包含购物车、购物、付款或下单。先在隔离本地环境完成并测试，阿里云部署前另行确认。

## 范围与设计

沿用本轮 frontend-design 的瓷白/石墨/优腾青品牌方向，进一步精简模板化大卡片和装饰元素。完整公开页面覆盖首页、目录、系列、型号详情、空间搭配、公司、制造质量、项目、新闻/文章、资料、合作、联系、招聘和隐私。所有主操作使用浏览或联系销售，删除清单式购物暗示。真实型号、资料、媒体、审核状态、来源和多语言必须保留。

IMP 工作台提供真实站点概要、连接体检、受授权网页编辑入口、内容/产品/媒体/发布栏目、询盘办理和超级管理员连接设置；网站保留独立内容与公开运行能力。

## 源码入口

| 能力 | 入口 |
|---|---|
| 官网公开页面与目录 | `app/[locale]/`、`components/products/`、`lib/catalog-query.ts` |
| IMP 官网工作台与会话绑定 | 项目根 `lib/features/website_management/` |
| IMP 询盘来源、时间线与跟进 | 项目根 `lib/features/webinquiry/` |
| ERP 站点配置、授权桥接与入库 | 项目根 `server/src/main/java/com/uten/imp/features/webinquiry/management/` |
| 网站单次授权和持久投递 | `lib/imp-portal.ts`、`lib/inquiry-delivery.ts`、`app/api/imp/` |
| CMS 草稿、发布、恢复 | `lib/cms-inputs.ts`、`lib/cms-apply.ts`、`lib/cms-revisions.ts`、`app/admin/(protected)/releases/` |
| 文件和资料管理 | `app/admin/resource-actions.ts`、`components/admin/ResourceForm.tsx` |

## 桥接契约 v1

服务端固定站点origin，Authorization Bearer令牌只在环境/后端，不回传前端；部署默认禁用，配置与密钥分离。所有接口禁止重定向到其他域，不记录个人信息和令牌。

- GET `/api/imp/bridge/status`：siteId、ready、publishedRevision、pendingInquiries、oldestPendingAt、lastDeliveryAt。
- GET `/api/imp/bridge/inquiries?limit=20`：只读返回未确认任务，items包含deliveryId、sourceId及现有询盘字段、服务端核验的sourceContext。
- POST `/api/imp/bridge/inquiries/ack`：`{items:[{deliveryId,sourceId,erpInquiryId}]}`；只有ERP提交成功后发送；重复读和确认必须幂等。
- POST `/api/imp/bridge/authorizations`：requestId、actorId、employeeId、displayName、permissions、section、expiresAt、codeChallenge。服务器生成60秒单次opaque code，只存hash；授权最长5分钟。
- IMP `/api/website-management`；`/config` PUT expectedVersion；`/check` POST；`/open` POST section/codeChallenge。open返回entryUrl/code/expiresAt，固定入口为 `/admin/imp-entry`。Flutter将code和随机verifier放URL fragment，网站经同源POST验证PKCE并在身份确认后消费，创建HttpOnly短时会话。长token不进入URL。

询盘先在网站同事务保存正文与投递记录；IMP主动出站拉取，可兼容内网部署。ERP持久导入/幂等去重后确认；销售待办和通知来自已提交事实。网络错误、重复投递、进程重启、领取并发、越权和撤权需要回归。

## CMS 编辑、审核与版本恢复

首页和站点栏目、产品、系列、场景、新闻、工程案例、岗位、资料均按同一流程运行：编辑表单 → 持久草稿 → 指定版本预览 → 有权人员发布。`app/admin/actions.ts` 不再直接修改这些公开内容表；图片文件上传仍属于独立的受权限保护的媒体存储流程。

`stageCmsRevision` 接收明确的实体类型、稳定 ID、UPSERT/DELETE 和纯字符串表单 payload。重复的款式、规格和列表字段使用字符串数组保留 `getAll` 语义。服务端重新核验编辑权限，并读取当前实体及受影响子行；prepare 只生成冻结快照，不临时写公开表。新内容及新款式/系列媒体在保存草稿时分配稳定 ID。

编辑页通过 `getCmsEditState` 在同一读事务取得内容与 `baseHash`，避免旧内容配上新基准。产品、系列、资料保留 `rowVersion`，其他实体使用快照摘要。错误响应保留表单输入；保存成功进入该草稿的固定版本网址。

发布只接受 revision ID，不能由客户端提交“发布后内容”。显式 Serializable 事务中核验发布权限和有效短期授权、比较当前快照、认领 DRAFT、重新校验父级公开状态与资料范围、应用冻结内容、记录发布快照与审计；实体写入再按行版本、更新时间或原设置值进行 CAS。重复或并发发布同一 revision 只允许一次生效，失败保持原公开内容及 DRAFT 状态，不自动重放失败写操作。

恢复使用独立 `website:rollback` 权限，只能撤回当前仍与目标发布快照一致的版本。它恢复该版本发布前的内容，并创建新的发布记录；稳定产品/款式/素材 UUID、旧站来源标识、原始来源正文、来源图库关系均保留。行版本继续递增，不倒拨。场景或其它关联发生后续修改时拒绝覆盖；父级已下架、资料仍关联等条件继续生效。

预览由冻结快照生成标题、正文、图片、款式和逐字段差异，不执行旧站 HTML，也不以重新查询的当前内容冒充旧版本。发布记录保留清晰的状态、创建时间、版本 ID 和审计信息。已有缺少 `baseHash` 或完整快照的历史记录不能直接发布或恢复。

## 本地验证入口

- Flutter：`flutter test --no-pub test/features/website_management/website_management_test.dart test/features/webinquiry/website_inquiry_lifecycle_test.dart test/shared/badges/badge_registry_contract_test.dart test/features/dashboard/workbench_layout_provider_test.dart test/router_access_policy_test.dart`。
- CMS：`node --import tsx --test tests/cms-revisions.test.ts tests/admin-guardrails.test.ts tests/publication-guards.test.ts`。测试创建新的临时 SQLite 迁移库，不使用开发库或生产数据。
- 发布前仍须完成当前候选构建、实际浏览器及连接环境的验收；上面的本地通过结论不代替正式部署和岗位 UAT。

## 当前状态

2026-10-26 按用户要求再次暂停，尚未标记整站完成。本轮已实际验证销售收件、认领、保存跟进及重新登录回读，以及官网首页草稿、发布、取消恢复、确认恢复与前台回读。当前代码、数据库、截图和源码备份的位置、准确验证边界、未完成事项及恢复步骤见 [最新暂停交接记录](website-imp-handoff-20261026.md)。

阿里云官网与公司本地 ERP 的具体配置及操作见 [联动操作手册](aliyun-local-erp-integration.md)。新工作保留在独立 `uimp/website-completion` 工作树，未提交、推送、合并或部署。旧 [2026-10-17 记录](website-imp-handoff-20261017.md) 是历史状态，其原工作目录和服务配置已不再适用于本轮；不得按旧路径恢复。
