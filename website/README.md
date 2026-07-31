# 优腾电器官网 · Uten Website

> 中山市优腾电器有限公司官网（前台展示 + 多语言 CMS 后台）
> Next.js 14 全栈 · 中英双语（结构支持任意语言扩展）· SQLite（可平滑迁移 PostgreSQL）

---

## ✨ 功能

**前台（中英双语）**
- 首页（**苹果风 / Cinema Dark**）：全屏 Hero（环境光斑 + 银白渐变巨字 + IP 形象发光徽章）→ 数据滚动计数 → **4 款精选产品大卡（少量克制，非密集罗列）** → 核心工艺 → 关于 → 样板工程 → 新闻 → 合作 CTA
- 走进优腾、产品中心（系列 + 详情）、新闻资讯（列表 + 详情）、样板工程、招商加盟（留资表单）、人才招聘、联系我们（留言表单）
- 响应式（手机 / 平板 / 桌面）、**默认深色**（可切浅色）、语言切换、滚动浮现动效、SEO 元数据

**后台 CMS（`/admin`）**
- 仪表盘（数据概览 + 新留言提醒）
- 产品管理（增删改 + **图片上传** + 中英文 + 首页推荐）
- 产品系列、新闻资讯、样板工程、人才招聘（均中英双语 CRUD）
- 客户留言（来自联系/招商表单，标记已处理）
- 站点设置（首页标语、联系方式，中英文）

---

## 🛠 技术栈

| 层 | 选型 |
|---|---|
| 框架 | Next.js 14 (App Router, RSC, Server Actions) |
| 样式 | Tailwind CSS + 设计系统 CSS 变量（**Cinema Dark 深色电影感**：深空 `#06080C` + 品牌青绿 `#009A8E` + 玻璃态 + 环境光斑） |
| 字体 | Lexend + Source Sans 3（运行时 `<link>` 加载，**不用 next/font/google** 避免国内构建下载失败；中文系统字体兜底） |
| 动效 | 自研 `Reveal`（滚动浮现）+ `CountUp`（数字计数）+ 光斑漂移；统一 Expo 缓动，尊重 `prefers-reduced-motion` |
| 数据库 | Prisma + SQLite（本地零配置；服务器可换 PostgreSQL） |
| 多语言 | next-intl（UI 文案）+ i18n JSON 字段（内容，加语言不改表结构） |
| 认证 | jose (JWT) + bcryptjs，Cookie session |
| 图标 | lucide-react |

---

## 🚀 快速开始

**前置**：Node.js ≥ 18

```bash
cd website
npm install            # 安装依赖
npm run db:push        # 创建 SQLite 数据库 + 表
npm run db:seed        # 填充真实数据（产品/新闻/系列等，来自旧站素材）
npm run dev            # 开发模式  http://localhost:3000
```

生产构建：

```bash
npm run build          # prisma generate + next build
npm run start          # 生产模式
```

---

## 🔐 后台管理

- 地址：`/admin`（如 `http://localhost:3000/admin`）
- 初始账号：**admin** / **uten2024**（来自 `.env`，仅首次 seed 生效）
- **首次登录后请立即在数据库修改密码**（见下方安全说明）

后台所有内容编辑都分「中文 / English」两组，填一组即可上线，另一组留空会自动回退到中文。

---

## 🌍 多语言扩展（外贸）

默认 `zh` / `en`。**新增任意语言只需 2 步**（无需改数据库表结构）：

1. `i18n/routing.ts` 的 `locales` 数组加入新语言，如 `'es'`
2. 复制 `messages/en.json` → `messages/es.json` 并翻译

之后后台每条内容的 i18n 字段即可填入 `es` 版本（可直接编辑数据库，或后续在后台表单增加语言输入）。前台 `/es/...` 自动可用。

---

## 📁 目录结构

```
website/
├── app/
│   ├── [locale]/            # 前台（中英双语路由前缀）
│   │   ├── page.tsx         # 首页
│   │   ├── products/        # 产品中心（列表/系列/详情）
│   │   ├── news/            # 新闻
│   │   ├── about|cases|join|careers|contact/
│   │   └── layout.tsx       # 前台根布局（Header/Footer/字体）
│   └── admin/               # 后台（不在 locale 下，中文界面）
│       ├── login/           # 登录
│       ├── (protected)/     # 鉴权后的各管理页
│       └── actions.ts       # 全部 Server Actions (CRUD/上传/认证)
├── components/
│   ├── motion/              # Reveal(滚动浮现) / CountUp(数字计数)
│   ├── home/Hero.tsx        # 全屏电影 Hero
│   └── layout|admin|...     # 页头/页脚/后台/UI
├── lib/                     # db(prisma) / auth / content(i18n解析) / queries(含 getLatestProducts)
├── i18n/                    # routing / navigation(createNavigation) / request
├── messages/                # zh.json / en.json (UI 文案)
├── prisma/                  # schema.prisma + seed.ts + dev.db
├── public/
│   ├── images/logo/         # 品牌 logo（logo_name 字标 + logo_ip IP 吉祥物）
│   ├── images/raw/          # 旧站抓取的素材图片（初始内容）
│   └── uploads/             # 后台上传的图片（运行时生成）
└── design-system/MASTER.md  # 设计系统（Cinema Dark 视觉宪法）
```

---

## 📦 部署到服务器

网站最终要放在服务器上。推荐两种方式：

### 方式 A：Node + PM2（推荐，最简单）

```bash
# 服务器上（需 Node 18+）
git clone <repo> && cd website
npm install --omit=dev
npm run build
# 编辑 .env：改 AUTH_SECRET、ADMIN_PASSWORD、SITE_URL、DATABASE_URL
npm install -g pm2
pm2 start "npx next start -p 3000" --name uten-website
pm2 save && pm2 startup      # 开机自启
```

用 Nginx 反代 3000 端口到 80/443（加 HTTPS）。

### 方式 B：Docker

```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY . .
RUN npx prisma generate && npm run build
EXPOSE 3000
CMD ["npx", "next", "start", "-p", "3000"]
```

> **数据持久化**：SQLite 文件 `prisma/dev.db` 和 `public/uploads/` 必须挂载为卷，否则容器重建丢数据。

### 切换到 PostgreSQL（数据量大时）

1. 服务器装 PostgreSQL，建库
2. 改 `.env`：`DATABASE_URL="postgresql://user:pass@host:5432/uten"`
3. `schema.prisma` 的 `provider` 改 `postgresql`（并可将 `String` JSON 字段改回 `Json` 类型）
4. `npx prisma db push && npm run db:seed`

---

## 🔒 安全注意事项（上线前必读）

1. **改 AUTH_SECRET**：`.env` 的 `AUTH_SECRET` 改成长随机串（`openssl rand -base64 32`）
2. **改管理员密码**：登录后台后，或直接在数据库更新 `User.password`（bcrypt hash）
3. **HTTPS**：生产必须走 HTTPS（Nginx + Let's Encrypt），登录 cookie 才安全
4. **数据库备份**：定期备份 `prisma/dev.db`（或 PostgreSQL）
5. `.env` 已在 `.gitignore`，**勿提交真实密钥**

---

## 🖼 图片与素材

- **品牌 logo**: `public/images/logo/`（`logo_name.png` 字标 + `logo_ip.png` IP 吉祥物，来自 `assets/images/`）
- 旧站素材（产品图、新闻图、内页图）已抓取在 `public/images/raw/`（约 1000 张，35MB），作为初始内容
- 后台上传的图片存到 `public/uploads/`（本地磁盘）
- 迁移素材脚本在 `.scrape/`（爬虫 `scrape.py` + 解析器 `parse.py`，可重跑）

---

## 🎨 设计系统

完整设计规范见 [`design-system/MASTER.md`](design-system/MASTER.md)（色彩 / 字体 / 间距 / 动效 / 组件 / 反模式）。改版前先读。

---

## 📞 默认联系信息（示例）

来自旧站，请在后台「站点设置」修改为真实信息：
- 电话：0760-22125999 / 221256
- 备案：粤ICP备2024341039号

© 中山市优腾电器有限公司
