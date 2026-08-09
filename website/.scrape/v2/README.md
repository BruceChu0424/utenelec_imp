# UTEN 旧站完整迁移抓取器 v2

这是一个独立、只读、可恢复的迁移工具。它不会修改 Prisma、数据库、seed 或网站前台，也不会提交旧站表单。

默认抓取范围锁定为：

- 中文产品总列表 94 页、1121 个产品；
- 英文产品总列表 87 页、1036 个产品；
- `(locale, oldSiteId)` 是产品唯一身份，不按名称去重；
- 中文/英文详情、分类树、新闻及明确列出的静态页面；
- 页面所引用的产品图、正文图和可下载文档；
- 中文产品素材 URL 基线为 2137，英文为 2025。

基线冻结于 2026-08-09。全量结果偏离基线时，`qa-report.json` 会给出 delta 并判定失败，不会静默放宽。

## 安全边界

- 网络层只实现 `GET`，任何其他方法在发送前即被拒绝。
- 生产抓取只允许 `http://www.ch-uten.com/` 同源请求。
- `Save.asp`、`MessageSave.asp` 被显式拒绝；不遍历或提交 form action。
- 页面请求和媒体请求分别使用正向允许列表；验证码/任意 ASP action 即使出现在 `<img>` 中也不会下载。
- 外域、`javascript:`、`mailto:`、`tel:`、带用户名密码的 URL 均不进入请求队列。
- 并发强制限制为 2–4，默认 3；所有线程共用全局节流。
- 每次 GET 默认最多 4 次尝试，带指数退避；429/5xx/超时可恢复重试。
- 原始 HTML 和素材都按内容 SHA-256 保存，不使用旧站文件名作为身份。
- 价格固定输出为 `UNSET`、无金额、未批准发布；抓取器不会生成价格。

## 环境

依赖见 `requirements.txt`，需要 Python 3.11+。

当前 Windows 工作机 PATH 中的 `python.exe` 是不可执行的 WindowsApps 占位程序；已验证可用解释器为：

```powershell
$py = 'C:\Users\bruce\AppData\Local\Python\bin\python.exe'
& $py --version
& $py -m pip install -r website\.scrape\v2\requirements.txt
```

建议在仓库根目录执行以下命令。若使用正常配置的 Python，可将 `& $py` 替换为 `python`。

## 先跑离线 smoke

```powershell
$py = 'C:\Users\bruce\AppData\Local\Python\bin\python.exe'
& $py website\.scrape\v2\crawler.py smoke
```

该 smoke 启动一个本地 HTTP fixture，完整执行：列表 → 同名不同 ID 详情 → 中英文 → 新闻 → 静态页 → 图片下载 → SHA-256 去重 → checkpoint 续跑 → 输出验证。它还断言：

- 两个中文产品都叫 `GK11` 但旧 ID 不同，必须保留两条；
- 第二次运行完全复用 checkpoint，不产生新的 HTTP 请求；
- 所有请求均为 GET，保存端点从未触碰；
- 多个 URL 内容相同的图片按 SHA-256 合并，但保留全部来源 URL/引用关系。

保留 smoke 产物用于查看：

```powershell
& $py website\.scrape\v2\crawler.py smoke `
  --output website\.scrape\v2\.tmp\fixture-smoke `
  --keep-output
```

运行单元测试：

```powershell
Push-Location website\.scrape\v2
& $py -m unittest discover -s tests -v
Pop-Location
```

## 小范围真实烟测

下面只读取中英文各 1 个总列表页、每种语言 2 个详情、1 个新闻列表页、1 个静态页，并下载这些页面引用的素材；它不是全量抓取：

```powershell
& $py website\.scrape\v2\crawler.py crawl `
  --output website\.scrape\v2\.tmp\live-smoke `
  --max-product-list-pages 1 `
  --max-details-per-locale 2 `
  --max-news-list-pages 1 `
  --max-static-pages-per-locale 1 `
  --concurrency 2 `
  --attempts 2 `
  --timeout-seconds 12 `
  --throttle-ms 500

& $py website\.scrape\v2\crawler.py validate `
  --output website\.scrape\v2\.tmp\live-smoke `
  --expect-partial
```

如果当前 shell 无法访问旧站，但浏览器可以访问，应以离线 smoke/单元测试验证工具，并换到能通过 HTTP 访问 `www.ch-uten.com` 的运行环境执行全量；不要改为 HTTPS，旧站 HTTPS 会关闭连接。

## 全量抓取与恢复

以下命令会执行完整抓取。首次运行前应预留磁盘空间并确认旧站仍可访问：

```powershell
& $py website\.scrape\v2\crawler.py crawl `
  --output website\.scrape\v2\output `
  --concurrency 3 `
  --attempts 4 `
  --timeout-seconds 20 `
  --throttle-ms 350
```

命令中断后，使用完全相同的 `--output` 再执行即可。默认 `resume=true`：

- 已成功页面从 `raw/html/**` 按 checkpoint 校验 SHA-256 后读取；
- 已成功素材从 `media/**` 校验 SHA-256 后复用；
- 失败项不会被标记为成功，下次运行会重试；
- checkpoint 会分批原子落盘，Ctrl+C 时不会删除已有成果。

不要对已有输出使用 `--no-resume`；该选项遇到 checkpoint 会直接拒绝，避免覆盖。

完成后执行全量硬校验：

```powershell
& $py website\.scrape\v2\crawler.py validate `
  --output website\.scrape\v2\output `
  --expect-full
```

只有 `status=pass` 才应进入后续 CMS 导入。抓取器本身不修改数据库。

进程退出码：`0=pass`、`2=warn`、`1=fail`。因此旧站网络不可达、部分资源失败等情况不会在脚本流水线中被误当作成功。

## 输出

输出目录默认被本目录 `.gitignore` 忽略：

```text
output/
├─ checkpoint.json
├─ catalog.json
├─ media.json
├─ qa-report.json
├─ raw/html/{locale}/{kind}/{sourceHash}.html
└─ media/{sha256-prefix}/{sha256}.{ext}
```

### `catalog.json`

包含：

- `products`：`identityKey`、`locale`、`oldSiteId`、名称/列表标签、SortID/SortPath/Sequence、详情正文 HTML/文本、包装提示、多型号提示、缩略图/详情图来源和媒体哈希、价格 `UNSET`；
- `categories`：`(locale, sortId)` 身份、父节点、SortPath、名称、是否由产品路径推断；详情页存在完整 breadcrumb 时，以其对齐 SortPath 后的名称为权威值，同时保留 `listingName`、`detailBreadcrumbName` 和 `detailBreadcrumbSource` 供审计；
- `news`：旧 ID、分类、标题、日期原文、正文 HTML/文本、素材；
- `pages`：关于、荣誉、工程案例、招商、招聘、联系等静态页面；
- 每条记录都保留 `sourceUrl`、`finalUrl`、`scrapedAt`、`sourceHash`、`rawHtmlPath`。

隐藏的出口产品叶子 SortID `63/64/65/69` 会依据详情 SortPath 补入分类树，不会因侧栏未展示而丢失。

`descriptionHtml` 和新闻 `bodyHtml` 是为审计保留的旧站原文，字段旁固定带有 `UNTRUSTED_LEGACY_HTML_DO_NOT_RENDER` 标记。它们未经发布级消毒，禁止直接传入 `dangerouslySetInnerHTML` 或 CMS 富文本渲染；前台应使用纯文本，或在导入审核阶段按允许标签重新消毒。

### `media.json`

以内容哈希聚合素材，记录：

- `sha256`、MIME、字节数、扩展名；
- 图片宽高；
- 本地相对路径；
- 全部 `sourceUrls` 和页面/产品 `sourceRefs`；
- 下载或内容校验失败项。

HTML 冒充图片、损坏图片、未知内容不会写成成功素材。图片尺寸由 Pillow 解码验证，不能仅相信文件扩展名或响应头。

### `qa-report.json`

始终输出机器可读检查结果和相对冻结基线的 delta。全量硬门槛包括：

| 指标 | 中文 | 英文 |
|---|---:|---:|
| 产品总列表页 | 94 | 87 |
| 产品 | 1121 | 1036 |
| 详情 | 1121 | 1036 |
| 实际有产品的叶子 SortID | 60 | 58 |
| 非空详情 | 814 | 801 |
| 空详情 | 307 | 235 |
| 新闻 | 19 | 3 |
| 配置内静态页（含 `tian.asp`） | 17 | 7 |
| 新闻正文素材唯一 URL | 118 | 1 |
| 产品素材唯一 URL | 2137 | 2025 |

此外还检查：

- `(locale, oldSiteId)`、`(locale, sortId)` 唯一；
- 精确 `oldSiteId + SortID + SortPath` 集合 SHA-256 签名，不能用错误 ID 抵消漏失 ID；
- 中英文 ID 交集 1035、仅中文 86、仅英文 1；
- 每个 ID 对应的缩略图/详情主图 URL 签名，以及逐产品下载哈希和图片尺寸；
- 原始 HTML/媒体文件存在且 SHA-256 一致；
- 独立 `validate` 遍历 checkpoint 中所有列表页、详情页、新闻页、静态页和媒体，而非只检查最终 catalog 引用；
- 抓取阶段的 parse errors/conflicts 持久化在 checkpoint，后续独立验证不会把原失败“洗绿”；
- 来源字段齐全；
- 0 个耗尽重试的页面/素材；
- 0 个 U+FFFD 解码替换字符；
- 0 个保存端点/外域 URL；
- 价格仍为不可发布的 `UNSET`。

旧站数据变化时，报告会保留 actual、expected、delta，必须人工确认后才能更新冻结基线。
