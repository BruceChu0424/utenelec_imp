# 官网与 IMP 集成暂停交接

日期：2026-10-17（用户工作区时区 America/Denver）。用户要求“你先收尾 等以后再继续完成这个官网任务”。当前状态是**暂停，尚未全部完成**，不得把下列定向测试结果当成完整交付或生产验收。

## 保留位置与范围

- 工作树：`C:/Users/bruce/.codex/worktrees/website-imp-integration/uten_imp`。
- 分支：`uimp/website-imp-integration`；基准 HEAD：`7161a08ce`。
- 实现保留为工作树修改，暂停前没有暂存、提交、推送或合并；没有部署阿里云。不要清理或归档此工作树。
- 主工作区 `D:/Projects/uten_imp` 的并行修改保持原状，不要直接覆盖或整树回填。
- 原要求仍有效：完整公司及产品展示官网，支持联系销售，不含购物车、支付或线上下单；IMP 工作台管理官网内容；询盘真实持久化并交付销售；本地做好并测试，阿里云部署前再确认。
- 已使用 `frontend-design`，继续沿用现有品牌方向、Uten 组件与权限约束。

## 已实现及已经验证的边界

公开页面覆盖首页、目录、系列、产品详情、空间搭配、公司、制造质量、合作、资料、新闻及详情、岗位、案例、联系、隐私等。已有多语言、SSR 筛选分页、旧网址精确映射及产品来源校验。历史内容不能冒充已核验的型号参数或资质。

IMP 增加官网运营入口、连接状态与检查、超级管理员连接配置、短期授权进入 CMS；CMS 已有八类实体的持久草稿、固定版本预览、发布、版本恢复与审计。资料为受权限保护的私有 PDF 存储，公开下载重新检查发布与产品范围。

网站表单在同一事务保存询盘及待投递记录，ERP 主动拉取、幂等入库，提交后精确 ACK，销售收到真实通知和待办。已经完成一次实际浏览器提交与两个服务间真实 HTTP 验证：断开桥接时 PostgreSQL 保存 PENDING，恢复后销售 API 可读、通知生成、网站 ACK、重复数为 1。销售界面已实际显示“新的官网咨询”和工作台“官网询盘 1”。**尚未完成实际浏览器认领与保存跟进操作**。

完整本地回执（无密钥）在工作树根 `.local-artifacts/website-imp/end-to-end-evidence.json`：

- 网站来源：`cmvd48f9f0001dftd5dp5xblm`。
- ERP 询盘：`05a98a24-b7b0-470f-8fdb-f0f808b9868b`。
- 销售通知：`c4420906-f0bd-41a9-bac9-9839d090f53f`。
- 测试为本地合成项目和测试销售账号，不是线上客户询盘。

## 验证记录

以下路径除特别注明外，均相对工作树根目录。

| 验证 | 结果与限制 | 证据 |
|---|---|---|
| 网站最终测试全集 | 112 项：110 通过、0 失败、2 跳过 | `.local-artifacts/website-imp/final-validation/test-all.log` |
| 网站 TypeScript | exit 0 | `.local-artifacts/website-imp/final-validation/tsc.log`（成功时为空） |
| 网站 ESLint | exit 0，0 error，1 warning | `.local-artifacts/website-imp/final-validation/lint.log`；`postcss.config.mjs` 匿名默认导出警告尚未修 |
| CMS SQLite 与真实 PostgreSQL | 各 14/14 通过 | `.local-artifacts/website-imp/postgresql-tests/validation-summary.json` 与相关 JSON |
| 非空 SeriesMedia 的 SQLite → PostgreSQL 迁移 | 1/1 通过，24 模型计数/哈希回读，源库未变，重复迁移拒绝，临时测试库已删除 | `.local-artifacts/website-imp/postgresql-tests/series-media-*.json` |
| Flutter 定向测试与静态分析 | 67 项通过，定向 analyze 无问题 | 官网页面和工作台、询盘、徽标、路由相关测试；见实施记录测试入口 |
| Java 相关测试 | 101 项通过，含真实 PostgreSQL 并发与会话权限验证；不代表整仓全部回归 | `.local-artifacts/website-imp-integration/backend-verification.md` |
| 独立审查回归 | 发现的 6 项问题均修复，相关网站 15/15、最终 Java 合同 20/20 | `.local-artifacts/website-imp-integration/website-backend-review.md` |
| 公开页真实浏览器尺寸测量 | 15 页 × 375/768/1024/1440 共 60 次，无横向溢出或当时已加载图片损坏；不代替所有交互验收 | `.local-artifacts/website-imp/responsive-browser.jsonl` |
| 真实询盘跨服务联调 | 离线保存、销售读取及通知、ACK、去重均通过 | `.local-artifacts/website-imp/end-to-end-evidence.json` |

两项网站测试跳过原因：非空 SeriesMedia 的 PostgreSQL 用例需显式选择运行，该用例已独立通过；50 类旧站原始面包屑证据测试因当前工作树未包含完整 `.scrape/v2/output` 而跳过，**不能算通过**。主工作区的历史归档可供后续只读核对，不能拿其他工作区的测试结果替代本候选。

公开页面的另一次定向验证（150 个 SSR 页面、搜索、分页、图片和 sitemap 等）见 `D:/Projects/uten_imp/.local-artifacts/website-redesign-20261017/formal-public-verification.md`。该文件是本候选的测试报告，运行站点是端口 3008；不要把早期端口 4310 的静态原型当成正式结果。

## 暂停时服务与数据

本次临时服务已经停止，已复查 3008、3009、8189、55439 没有监听。其他项目服务未停止。

- 官网原入口：`http://127.0.0.1:3008/zh`，Next.js 开发服务。
- IMP Web 原入口：`http://127.0.0.1:3009`。
- ERP API 原入口：`http://127.0.0.1:8189/api`。
- 独立 PostgreSQL 容器：`uten-website-imp-local-pg`，标签 `uten.task=website-imp-integration`，已正常停止；`AutoRemove=false`，数据卷保留，**未删除容器或卷**。
- PostgreSQL 主机绑定：`127.0.0.1:55439`，两个本地库 `uten_erp_local`、`uten_website_local`。
- 私密测试配置 `.local-artifacts/website-imp/local-config.json` 和会话 `.local-artifacts/website-imp/e2e-sessions.json` 均已确认被 Git 忽略。保留在本机，不可提交、复制进报告或打印其中密码及令牌。恢复时重新登录，不复用过期会话。
- 数据与上传文件已保留。不要删除 `.local-artifacts`、`.local-state`、网站上传目录或 Docker 卷。

## 恢复工作顺序

1. 先读取本记录与 `website/docs/website-imp-implementation.md`，检查当前分支和并行变更，继续使用该独立工作树。
2. 启动自有容器 `docker start uten-website-imp-local-pg`，不得操作其他 PostgreSQL 容器。
3. 使用 Node 24.19.0 启动保留的 `.local-artifacts/website-imp/run-website.mjs` 与 `run-erp.mjs`。这两个脚本自行读取本地私密配置。Node 路径为 `C:/Users/bruce/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe`。API 必须使用最新 `.local-artifacts/website-imp-integration/backend-build/classes` 作为 classpath 首项；暂停前运行实例尚未统一重启到最后一次 token 边界修正，不要沿用旧进程或旧 `server/target/classes`。
4. 从工作树根启动 Flutter：`D:/Software/Flutter/flutter/bin/flutter.bat run -d web-server --web-hostname 127.0.0.1 --web-port 3009 --dart-define=API_BASE_URL=http://127.0.0.1:8189/api`。**API_BASE_URL 的 `/api` 不能遗漏**。Flutter Web 如只有 Canvas，需启用 accessibility 后再操作表单。
5. 补完销售 UI：从官网询盘待办打开真实记录，认领、追加跟进并刷新确认，验证通知和权限状态；已有通知与 API 回执不能替代该操作。
6. 补完超级管理员 UI：IMP 官网运营连接检查、配置与进入 CMS，确认单次授权身份，完整走一遍首页内容保存草稿、公开页保持旧内容、预览、发布、公开页变化、恢复与回读。再验证产品管理和真实 PDF 上传、发布、下载、下架；自动化已经覆盖八类 CMS 实体，但这一整段跨应用浏览器验收尚未完成。
7. 继续细化首页最终文案、图片及部分旧 CMS 栏目文案；通过 CMS 发布并留证据，不要直接改数据库冒充管理流程已验收。公共页面移动菜单、键盘导航、图库和搭配交互仍需补验。
8. 完成最终生产构建与质量门禁。尚未完成 `next build` 和完整 quality gate。检查 `website/scripts/quality-gate.mjs` 在干净 `.next` 时的类型生成顺序：Next 16 的 `next-env.d.ts` 引用生成类型，可能需要先 `next typegen` 再 `tsc`，这是待验证事项。涉及 npm ci/generate/build 时先停开发服务，避免 Windows 文件锁。使用支持的 Node 版本及实际 npm CLI，不能用系统旧 Node 22.12。
9. 更新 README 等技术文档的实际 Next 16/React 19 与双 Prisma 数据库说明，补齐冻结候选的最终验证与 Git 差异检查，再评估是否提交/合并。当前测试不是整仓完整发布门禁。
10. 本地验收完成后向用户展示真实页面和管理结果。阿里云的正式域名、HTTPS、密钥、耐久存储、备份恢复、网络与部署仍需独立准备和用户确认，当前没有上线结果或云端验收结论。

## 继续时避免重复踩坑

- Java → Next 本地桥接必须保持 HTTP/1.1；默认 h2c 升级已在真实联调中失败，并有回归覆盖。
- 桥接 token 合同为 `[A-Za-z0-9+/=_-]{43,512}`；不要退回只检查 32 字符。
- 不要重新复制主工作区的账号、询盘或其他业务数据。现有本地来源迁移只复制公开内容，非空图库另外用独立 fixture 验证。
- 迁移脚本只接受明确离线 SQLite 备份和空 PostgreSQL 目标；当前本地目标已有数据，不能再次执行合并式迁移。
- 资料上传、发布、租约及撤权均有提交时权限检查；不要为了本地演示弱化生产路径、HTTPS 或会话约束。
- 浏览器自动化重新接手时先恢复 CUA 文档；测试密码、bridge secret、ERP token 不进入工具输出、网址查询参数、报告或 Git。

恢复前不再自动推进功能、测试或部署；等待用户后续继续指令。
