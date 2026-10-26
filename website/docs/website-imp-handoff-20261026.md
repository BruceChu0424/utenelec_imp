# 官网与 IMP：2026-10-26 暂停交接

用户要求：“你差不多可以收尾了，剩下的内容下次再进行”。当前状态为**暂停，整站任务尚未全部完成**。不自动继续功能、启动测试或部署，等待用户下次继续。

## 保存位置

- 工作树：`C:/Users/bruce/.codex/worktrees/website-completion/uten_imp`。
- 分支：`uimp/website-completion`；本轮基准：`f9192c79d`。
- 本轮源码仍为未暂存、未提交的工作树修改，未推送、未合并。不要清理或归档该工作树。
- 旧实现后来以 `fcb05b4d2` 等提交进入 main；2026-10-17 的旧工作目录与本地库已被清理，本轮重新从当前源码建立了独立环境。主目录 `D:/Projects/uten_imp` 的其他 ERP 修改未回填或覆盖。
- 额外恢复备份：`D:/Projects/uten_imp/.local-artifacts/website-completion-pause-20261026`。其中包含**本地测试私密配置**，不能公开、上传官网或提交 Git。
- 技术与操作手册：[阿里云官网与公司本地 ERP 联动](aliyun-local-erp-integration.md)、[桥接协议](../../server/docs/website-management-bridge.md)、[公开体验记录](public-experience-completion-20261025.md)、[质量检查阶段](quality-acceptance-20261026.md)、[旧站内容覆盖](legacy-content-coverage-20261026.md)。

原范围仍有效：专业公司与产品展示官网，所有页面和详情页完整、美观；可以联系销售，**不提供订货、购物车、支付或金钱交易**。官网放阿里云，公司 ERP 在本地。先完成本地验收，正式部署前仍须用户确认。前端继续使用已读的 `frontend-design`，保留来源、权限和已有业务事实。

## 本轮已实际跑通

### 销售链路

真实浏览器从 GK11 产品详情进入联系销售，在桥接停用时提交合成项目 `官网联动验收20261026`：

1. 官网 PostgreSQL 保存正文及 PENDING 投递；此时 ERP 尚未收到。
2. 通过 IMP 超级管理员真实连接配置 UI、统一再次认证后启用连接。
3. ERP 出站 worker 唯一入库、生成销售通知，网站 ACK 指向同一 ERP ID。
4. 实际销售账号登录工作台 → 官网询盘 → 打开记录 → “开始跟进(记为我的)” → 保存跟进备注。
5. 重新登录后从“跟进中”打开，负责人、备注和历史仍在；独立只读检查实际销售 GET 200 可见，原来源、通知、ACK 一致。

稳定回执：网站 `cmvov10kb0002xtoe82ar914q`；投递 `cmvov10kb0003xtoe3hs4k6vt`；ERP `2cb10932-dd59-4351-85eb-242115f3670f`。ERP 重复数 1，`RECEIVED / CLAIMED / FOLLOW_UP` 各 1，负责人和事件操作者均为合成销售员工。不是线上客户记录，没有发送外部消息。

证据：工作树根 `.local-artifacts/website-completion/live-flow-evidence.json`、`offline-receipt-evidence.json`、`browser-interactions.json`、`screenshots/sales-followup-persisted.png`。早期过期/被新登录替代的 API token 401 诊断保留；最后 `followed-up` 阶段已通过，不能用旧 401 报告覆盖最终结果。

### CMS 修改、发布与恢复

通过 ERP 实际服务签发的 PKCE 单次授权进入官网后台，使用真实表单：

- 保存首页草稿后前台仍为旧标题；固定版本预览有真实内容与字段差异。
- 发布后刷新前台采用新内容。
- 恢复前的确认框可取消；取消后前台不变。明确确认后恢复到发布前内容，产生新的版本记录。
- 再次通过草稿及发布保留最终首页文案、矿物灰场景和正式 Z9 家族；最终首页版本为 `cmvpa8uwy01zf1mmiijux4wd8`。
- 真实维护并分别发布 4 个 Z9 产品的主推排序和场景展示，保留原始产品、款式、来源及未核验参数状态：`cmslmtmvt03i61102m7q62q6a`、`cmslmtmvv03i81102yetnnqjx`、`cmslmtmw603ii1102o88c2lyb`、`cmslmtmvx03ia1102z4gky16e`，排序 0–3。

CMS 预览版本 `cmvp8sgii011m1mmic1u7253t` 和 `cmvpa0s7e01vr1mmi3854iwkl` 均实际做过恢复。不要再直接恢复这些旧版本覆盖当前内容；旧版本的“已有后续修改”阻断是正确保护。

截图：`screenshots/home-current-20261026.png`、`home-current-full-20261026.png`、`home-restored.png`、`imp-website-connected.png`。`browser-interactions.json` 明确记录草稿、发布、恢复、取消确认和销售回读检查。

## 本轮源码修正与验证边界

| 内容 | 本轮结果与限制 |
|---|---|
| 网站核心门禁阶段 | 133/133，0 skip；lint 0 warning、tsc、正式迁移、双 audit 0 漏洞、空库 Next 16 Webpack build 通过。该阶段早于后续 UI 收尾，不能代替最终源码构建 |
| 当前 Java 相关验证 | 108 项通过；空库 861 个迁移到 V935。官网迁移现为 V879，不能沿用旧记录的 V873 |
| 公开站点只读覆盖 | 9737 请求：4599 页面/旧 ASP、3004 真实链接、2134 图片字节解码；sitemap 2234 URL 全覆盖。正常根语言协商和 Next 流式 meta 跳转已复核，无其他异常。不是浏览器逐项交互或生产性能 SLO |
| 旧站资料 | 2157 产品 HTML、2323 素材哈希保留；1122 独立旧产品 ID 有来源，实际公开产品 1121。当前旧站有界 8 页均 200，未扫猜 ID |
| 产品图库、手机菜单 | 真实图库切换通过；375px 两层 Escape 行为、关闭后焦点恢复通过；全站最终尺寸/视觉矩阵尚未补齐 |
| 案例详情与错误边界 | 已补真实详情、共享安全正文与发布守卫、metadata/sitemap。25 项定向测试；20 项 HTTP，包括十语言品牌真 404、RTL、noindex、Host/伪造头边界通过。尚缺最后浏览器 404 视觉与真实下架回执 |
| 表单初始化保护 | 发现仅 client onSubmit 的表单在 hydration 前按 GET 提交。唯一 `ClientForm` 实现 POST + SSR inert，接入全部 7 处：询盘、CMS 草稿、产品、系列、资料、场景、独立登录。原生 Server Action 和目录 GET 筛选保留。SSR 2 项及增量 56 项、lint/tsc 通过 |
| 恢复/删除确认 | 统一 `ConfirmationDialog`；恢复触发为 type=button，只有显式确认才 requestSubmit，避免初始化前直接提交。恢复取消与确认已通过实际 UI；删除草稿的实际 UI 尚未补验 |
| 非 release 本机入口 | Flutter 唯一 URI 验证允许显式编译开关下的三个 exact loopback HTTP；默认关闭，Release 始终拒绝 HTTP。43 项测试、analyze 通过 |
| Flutter 构建 | 最新 profile 和 release 均已编译通过，摘要在 `flutter-final-build-evidence.json`。profile 为本地验收，release 同源 `/api` 且未启用本机例外；不能把 profile 当生产包 |
| 最后发布状态控件 | Case/News/Job 新共享 `PublicationField`，始终提交现有 parser 兼容的 on/false；新建默认不公开、既有保留状态，完善 label 关联。定向 lint/tsc、SQLite+SSR 17/17 通过；未做此最后增量的 PG 回归和实际浏览器上下架 |

生产 Next build 尚未在**最后全部源码**上重跑；本轮没有全仓发布门禁、Linux 正式产物、阿里云部署或生产 UAT 结论。

## 暂停前环境和备份

全部自有服务已停止，已复查 3008、3009、8189、55439 没有监听。其他项目服务未停止。

- PostgreSQL 容器 `uten-website-completion-local-pg`，标签 `uten.task=website-completion-20261025`，`AutoRemove=false`，容器与卷保留。
- 卷：`85e686914f9d73a8767bb93f3e9218c04dfc63dce564bba9adbee5a40d14690e`。本地库：`uten_website_local`、`uten_erp_local`。
- 配置：工作树根 `.local-artifacts/website-completion/local-config.json`，已经确认被 Git 忽略。含本地测试密码与解密所需键，不能打印或提交。API 会话和单次入口文件也被忽略，恢复时重新登录。
- 网站图片保留在 `website/public/uploads`，私有资料目录在 `website/.local-state/documents`；暂停时尚无实际上传/公开 PDF。
- 应用停止后导出两库 custom-format dump；`backup-manifest.json` 有大小/摘要，`pg_restore --list` 已通过。备份目录另存 `local-config.private.json`，不包含旧访问令牌。**尚未进行新库恢复演练**，不能将可读清单当演练通过。
- 同目录收尾保存源码差异、当前改动文件、公开素材、证据与启动辅助脚本；保留原卷，不要因为有 dump 就删除原卷或覆盖现有数据库。

## 下次从这里继续

1. 读取本文件、检查当前 worktree/branch 及并行变更。不要重置主目录或按旧 2026-10-17 路径操作。
2. 启动原自有容器，保留原配置和数据身份，不重新生成密钥/seed/重复合并迁移：`docker start uten-website-completion-local-pg`。
3. 用 Node 24 启动 `.local-artifacts/website-completion/run-erp.mjs` 和 `run-website.mjs`。API 为 8189 `/api`、官网为 3008。Java 21；classpath 必须用该任务 `backend/build/classes` 与 `backend/runtime-classpath.txt`。工作树丢失时需按保存源码重新构建，不拿其他任务 classes 运行。
4. 本地 IMP 使用已编译 profile 目录，通过同源 `/api` 代理运行：进程环境 `UTEN_LOCAL_WEB_ROOT=.local-artifacts/website-completion/imp-profile`，运行 `serve-imp-local.mjs`，监听 127.0.0.1:3009。此 profile 显式启用 `UTEN_WEBSITE_ALLOW_LOOPBACK_HTTP=true`，仅非 release 生效。正式 release 不接受本机 HTTP 官网，正式部署应使用 HTTPS。
5. **优先补工作台跳转闭环**：最后 URI 修复后 profile 已编译且代理已切换，但尚未刷新 profile、重新登录并实际从 IMP 点“进入编辑器”跑完整跳转。此前旧 release 正确拒绝 HTTP；后台 PKCE 页面与编辑动作已通过服务签发入口实测，不要把两者混为同一条已通过链路。
6. 不要在 UI 验收期间再运行 `bootstrap-actors.mjs` 或并行 API 登录同一员工；新登录会结束旧会话，旧原始 sid 的 portal 租约撤销是正常保护。需要独立销售 GET 时协调有效会话，避免用已过期 token 的 401 否定已完成业务。
7. 修复后入口会立即移除 fragment，保持路由 history.state。授权 60 秒单次有效，cookie/租约仍有时间边界；过期或开发重启后回 IMP 重开，不复制私密网址或放宽校验。
8. 补资料真实 UI：现有 `.local-artifacts/website-completion/fixtures/website-acceptance.pdf` 和 PNG 是**明确合成验收文件**。尚未通过界面上传、发布、下载、下架或清理；不能伪称已有产品规格书。下次验收后应撤下测试资源，实际资料需公司核验。
9. 用最后新增展示状态控件实际测试 Case/News/Job 草稿→下架发布→404/隐藏→恢复/重新公开，保留稳定 ID/来源/语言与原文。当前 3 条案例仍公开，未改内容、未下架。融侨锦城只证明旧站“指定产品”的历史记载，不能改写为已供货、已安装、已交付；可补有来源的历史说明或待核验下架。该选择尚未执行。
10. 继续完善资料页旧文案、案例/历史正文和全站视觉；最后统一检查每一类页面及详情、手机/平板/桌面、键盘、搭配、图片、错误/空状态。不要发布虚构岗位、参数、认证、交期或客户案例填空。
11. 旧站 `contact.zh.phone2/address` 和 `contact.en.phone2` 与当前后台不同，具体对照仅在忽略的 `legacy-live/comparison.json`。本轮保留后台现值，没有盲目用旧站覆盖；正式内容验收时由公司核对。
12. 冻结最新源码后运行最终网站全测试/PG 增量、lint/tsc、生产 build，补 Flutter 当前候选必要回归及源差异核对；已有 checkpoint 不代替这一步。不要在活动 Next/Prisma 进程中重跑 npm ci/generate 导致 Windows 锁或打断表单。
13. 通过后打开真实官网和 [联动操作手册](aliyun-local-erp-integration.md) 给用户看。当前手册约定云端官网与本地 ERP 主动 HTTPS 拉取/ACK、权限和短授权；正式 PG 发布门禁及 PG+图片+私有 PDF 配套备份恢复仍待云部署阶段补齐。旧 SQLite 签名发布脚本不能直接换 URL 当 PG 发布工具。

恢复或发布不能覆盖他人的新修改，不能把持久受理/送达当销售已读，更不能把本地测试当已部署阿里云。
