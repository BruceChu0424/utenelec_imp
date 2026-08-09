# Uten Corporate Website

中山市优腾电器有限公司的多语言企业与产品展示站。项目定位是“产品目录 + 品牌内容 + 选型咨询”，不包含购物车、在线价格或支付。

## 当前能力

- Apple 产品发布页式首页：只突出后台标记的当前主推/最新产品，以大幅视觉与交替说明建立清晰节奏；响应式导航、克制动效与完整键盘焦点状态。
- 产品按“设计系列 → 功能产品 → 已确认 SKU / 颜色材质款式”组织；系列卡使用正式组合封面，缺封面时才以真实产品图生成临时组合封面。
- Space Studio：在客厅、矿物灰空间和胡桃木套房中拖动真实产品图，调整比例并连接到具体款式咨询。
- 中文、英文、西班牙语、法语、德语、葡萄牙语、阿拉伯语、俄语、日语、韩语 UI；裸域名按浏览器语言自动选择，手动切换后站内链接持续保留当前语言。
- 内容字段逐字段回退：当前语言 → 英文 → 中文，缺失翻译不会产生空白页面；阿拉伯语自动 RTL。
- 国际化业务内容：制造与质量、国际合作、专业资料和隐私说明；国际合作表单记录目标市场、客户类型、安装体系、产品范围、数量和时间计划。
- 专业资料中心内置 4 篇中英采购指南，正文、分类、发布状态和后续修改均进入 CMS 新闻/文章链路。
- `/admin` 内容后台：产品、款式、系列、场景、新闻、案例、招聘、留言和站点设置。
- SEO metadata、`sitemap.xml`、`robots.txt`，图片使用 Next.js + Sharp 优化。

## 技术栈

- Next.js 15 App Router、React 18、TypeScript
- Tailwind CSS + 项目设计 tokens
- next-intl
- Prisma 5 + SQLite
- Server Actions、JWT HttpOnly session、bcrypt

## 本地运行

前置：Node.js 20.19+ 或 22.13+（推荐当前 Node 22 LTS）。

```bash
cd website
npm install
copy .env.example .env
# 先编辑 .env：设置强随机 AUTH_SECRET，并填写符合下述策略的 ADMIN_PASSWORD
npm run db:push
# 仅对全新或可丢弃数据库：临时设置 ALLOW_DESTRUCTIVE_SEED=true
npm run db:seed
npm run dev
```

打开 `http://localhost:3000/zh`；后台为 `http://localhost:3000/admin`。

`db:seed` 会清理并重建内容，只能用于全新或可丢弃环境。它会在任何 `deleteMany` 之前同时要求 `ALLOW_DESTRUCTIVE_SEED=true` 和合格的 `ADMIN_PASSWORD`；任一缺失都会直接终止。密码缺失、为 `uten2024`、示例值或弱密码也会终止。密码至少 14 位，并包含大小写字母、数字、符号中的至少三类。seed 完成后应立即把开关恢复为 `false`。

已有数据库如果仍使用历史默认密码，后台会拒绝登录且只返回统一错误。先在 `.env` 中设置 `ADMIN_USERNAME` 与新的强 `ADMIN_PASSWORD`，再执行（命令不会打印密码，也不会创建不存在的账号；轮换成功后所有旧后台 JWT 会立即失效）：

```bash
npm run admin:reset-password
```

已有数据库升级必须先备份，然后执行：

```bash
npm run db:upgrade
```

它只同步新增结构，并为已有产品幂等补充默认款式和场景，不删除既有业务内容。

## 内容与旧站迁移

历史脚本只抓取了旧站的一小部分，不能把原先数据库的 65 个产品视为完整目录。2026-08-09 已通过 `.scrape/v2/` 重新执行中英文全量抓取、独立验证和受控导入：

- 中文 1121 个产品详情、英文 1036 个；共同 ID 1035、中文独有 86、英文独有 1。
- 2337 个来源素材 URL 全部获取成功，按内容哈希保留 2323 个本地媒体文件，失败 0。
- CMS 合并为 1122 个稳定产品主体；旧站原始 HTML 只进入不可发布审计记录。
- 当前公开 1121 个产品，聚合为 22 个设计系列和 52 个系列内功能集合；1122 个旧站基础款式均明确标记为合成占位，不冒充真实 SKU 或颜色。另有 1 条只有截断英文名、没有可核对中文名的旧记录保留在后台待审核，不对外发布；原先不完整的 65 个种子产品已取消发布。

完整迁移遵循：

1. 只抓取公司自有域名 `www.ch-uten.com`，保留源 URL、旧 ID、语言、分类与校验信息。
2. 分别遍历中文和英文产品列表的全部分页，再抓取每个详情页及其原始图片。
3. 先生成清单与缺失报告，确认数量后再导入；导入必须可重复执行并按旧 ID 更新。
4. 无法验证的颜色、规格、尺寸和翻译保持为空，不编造。
5. 上线前由产品负责人复核型号归类、图片授权、技术参数和已停产状态。

## 多语言策略

UI 文案位于 `messages/*.json`。数据库内容保存在每条记录的 `i18n` JSON 字符串中，例如：

```json
{
  "zh": { "name": "一位开关" },
  "en": { "name": "1-gang switch" },
  "es": { "name": "Interruptor de 1 elemento" }
}
```

后台当前优先提供中文和英文编辑字段，其余语言可继续扩展为同一内容编辑工作流。保存中文/英文时会合并现有 JSON，未编辑的西班牙语、法语等语言不会被覆盖；后台英文输入框只读取真实 `en` 内容，空英文保持缺失，不会把中文回写成伪翻译。UI 已完整本地化不代表旧站产品正文已有高质量的十语言翻译；前台缺失内容仍会按展示回退规则显示。当前 sitemap 与索引默认只发布已审校的中英文；其他语言页面可访问但 `noindex`，完成市场审校后再进入索引。

## 图片与场景

- `.scrape/v2/output/`：被 Git 忽略的完整抓取、来源 HTML、QA 与导入清单。
- `public/uploads/legacy-v2/`：已导入的哈希媒体；旧站清晰度差异较大。
- `public/images/scenes/`：Space Studio 的原创空间背景。
- `public/uploads/`：后台上传文件。服务端会完整解码、限制 4000 万像素、拒绝动画，自动旋转、缩放并重编码为去元数据 WebP；输入上限 8 MB。CMS 只接受 `/uploads/` 与 `/images/` 站内路径。
- 场景试装当前采用快速的 2.5D 合成。后续获得准确 GLB 模型后，可增加 `<model-viewer>` 或 React Three Fiber，不需要改产品/CMS数据结构。

## 常用命令

```bash
npm run dev          # 开发服务器
npm run build        # Prisma Client + 正式构建
npm run start        # 启动正式构建
npm run lint         # ESLint
npm run db:push      # 同步数据库结构
npm run db:backfill  # 幂等补充 v2 内容
npm run db:upgrade   # db:push + db:backfill
npm run db:studio    # Prisma Studio
npm run admin:reset-password # 从环境变量安全轮换既有管理员密码
npm run catalog:normalize     # 只读预演目录规范化
npm run content:guides        # 只读预演 4 篇国际采购指南；apply 需显式确认参数
npm run content:international-settings # 只读预演国际页面 CMS 初始内容；apply 需显式确认参数
npm run content:public-claims # 只读检查旧新闻/示例岗位/材料文案；apply 需 PUBLIC_CLAIMS_V1 确认
npm run test:catalog-public   # 系列、路由、款式与组合封面合同测试
npm run test:news-content     # 采购指南分类与安全正文结构测试
npm run test:seo-localization # 已审校语言索引与 hreflang 边界测试
```

## 部署边界

- 设置至少 43 字符的密码学随机 `AUTH_SECRET`（例如 `openssl rand -base64 32`）和唯一管理员密码；不要提交 `.env`。缺失、短、低熵或复制示例的 `AUTH_SECRET` 会在服务启动时安全终止，登录与 JWT 验签也会拒绝继续。seed 与密码轮换命令都会拒绝缺失、默认或弱密码；seed 还必须单独设置 `ALLOW_DESTRUCTIVE_SEED=true`。
- 后台登录在服务端统一校验未知/已知账号，并按账号、客户端和全局维度限速；错误文案不暴露账号是否存在。当前限速状态保存在单个 Node 进程内，多实例部署必须改用 Redis/数据库等共享存储。默认不信任任何客户端 IP 请求头；只有可信反向代理会覆盖该头、且应用源站不可直连时，才可将 `ADMIN_TRUSTED_CLIENT_IP_HEADER` 设置为白名单中的代理头（如 `cf-connecting-ip` 或 `x-forwarded-for`）。
- SQLite 文件与 `public/uploads/` 必须放在持久卷并定期备份。多实例或无状态平台应先迁移到托管数据库和对象存储。
- 上线边缘必须把全部 HTTP 请求 301/308 到 HTTPS，并确认生产响应包含 HSTS；通过反向代理限制后台登录尝试并记录管理操作。
- `prisma db push` 适合当前早期站点，但正式长期维护应建立受控迁移文件和恢复演练。
- 正式发布前仍需完成：产品颜色/材质/尺寸的人工结构化、新闻日期与公司事实审核、专业翻译、目标服务器构建、真机 UAT、SEO 重定向表、备份恢复演练和性能监控。

国际内容取舍、文章路线、事实分级与上线资料清单见 [`docs/international-content-strategy.md`](docs/international-content-strategy.md)。采购指南受控写入说明见 [`docs/international-guides-seed.md`](docs/international-guides-seed.md)。

设计规范见 [`design-system/MASTER.md`](design-system/MASTER.md)。
单台云服务器的上线步骤与回滚门禁见 [`docs/cloud-server-deployment.md`](docs/cloud-server-deployment.md)。
产品目录语义与前后台共同规则见 [`docs/product-catalog-architecture.md`](docs/product-catalog-architecture.md)，受控迁移步骤见 [`docs/product-catalog-migration.md`](docs/product-catalog-migration.md)。
