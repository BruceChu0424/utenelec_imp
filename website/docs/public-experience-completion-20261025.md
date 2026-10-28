# 公开页面体验补全与共享入口核对

日期：2026-10-25；候选工作树 `website-completion/uten_imp`，基准 `f9192c79d`。本记录只说明本阶段公开界面的增量、调用清单和验收项目，完整网站及部署状态由主实施记录管理。阿里云尚未部署。

## 设计复核

继续使用已确认的建筑电气展厅方向：瓷白 `#FFFFFF`、产品浅灰 `#F3F5F4`、石墨文字 `#17292D`、次要文字 `#657377`、优腾青 `#0A707B`、边界灰 `#D7DFDF`。沿用本地系统字体，左对齐的型号与正文保持清晰层级，依靠产品和空间图片形成识别，不新增统计、资质、价格或商业承诺。

本阶段选择克制修整而不是另造页面模板：去掉没有步骤语义的菜单和搭配面板编号；产品在首页空间示意中保持静止；款式、场景与复位控制达到 44 px，页脚导航也统一至 44 px。展示选择的变化通过选中态和明确的深链接表达。

## 既有实现比较与唯一维护入口

| 能力及原入口 | 原有正确行为 | 发现的问题 | 处理及保留边界 |
|---|---|---|---|
| `LanguageSwitcher`，桌面页头和手机菜单共用 | 多语言、方向键、当前语言选中、点击外部关闭 | document 级 Escape 和手机对话框竞争，一次按键同时关闭两层；Tab 离开后语言菜单残留；切换语言丢弃锚点 | 继续仅维护一个语言组件；在组件内部消费 Escape、离开组件关闭、菜单项单一 Tab 入口，保留查询和锚点 |
| `MobileNav` 的对话框焦点管理 | 初始焦点、Tab 循环、Escape、关闭后恢复焦点、锁定背景滚动 | 焦点集合未排除负 tabIndex，不适配嵌套菜单的游标焦点 | 继续使用原焦点边界，排除负 tabIndex，尊重子控件消费过的键盘事件 |
| `publicProductView`，型号卡片/详情/搭配的共享展示边界 | 发布款式、图片路径过滤、合成款式属性隐藏、历史说明保留 | 存在实际款式时，产品级图库被丢弃 | 在该唯一入口合并并去重合规的产品级与款式级图片；不将图库照片推断为颜色、尺寸或技术参数 |
| `toStudioVariants` → 首页预览、完整试装 | 实际公开款式、落地插座排除、来源 ID、销售联系深链 | 仅产品主图产生的展示 fallback 没有可解析的持久 variant；首页进入完整试装又未带所选款式 | 仅实际持久 variant 进入试装选择；真实旧站合成 base 行仍保留。首页入口带当前实际 variant ID，产品详情的图片 fallback 仍可展示 |
| `getPublicResources` → 资料库及型号详情 | 只显示已公开资料、真实下载接口、语言/版本/市场元数据 | 型号详情漏掉系列级和通用资料；固定 100 条且无更多入口 | 旧函数全部迁移至唯一 `queryPublicResources`；SQL 计数和每页 24 条读取同一事务快照，不截断完整资料库 |
| `publicResourceWhere` → 资料查询及下载接口 | 文件、型号和系列的公开状态 | 需要在新增系列继承逻辑中继续保持一致 | 原权威规则保留，两侧继续共用。型号上下文必须自身公开，专属型号资料不会提升成系列或全局资料 |

## 完整调用清单与必要差异

| 公共入口 | 适用调用方 | 状态及差异 |
|---|---|---|
| `components/LanguageSwitcher.tsx` | `components/layout/SiteHeader.tsx`；`components/layout/MobileNav.tsx` | 两个调用方均复用同一实现；桌面点击外部与手机嵌套 Escape 的容器语义保留 |
| `components/layout/MobileNav.tsx` | `SiteHeader`，由 `app/[locale]/layout.tsx` 覆盖所有公开页面 | 统一手机及平板导航；菜单链接仍为实际页面导航，无购买流程 |
| `lib/public-product.ts: publicProductView` | `lib/catalog.ts: toCatalogProduct`、`toStudioVariants`；`app/[locale]/products/[code]/[slug]/page.tsx` | 卡片保持轻量主图投影；详情显示完整图库；搭配保持真实持久款式与场景启用限制 |
| `lib/catalog.ts: toStudioVariants` | 首页 `app/[locale]/page.tsx`；完整搭配 `app/[locale]/studio/page.tsx` | 全部调用方共享可选款式边界；详情仍可用无持久 variant 的产品图片作纯展示 |
| `components/home/StudioTeaser.tsx` | 首页 `app/[locale]/page.tsx` | 轻量预览和进入完整试装，不复制完整拖动/尺寸编辑器 |
| `components/studio/SceneStudio.tsx` | `app/[locale]/studio/page.tsx` | 原拖动、方向键、缩放、复位、款式和销售入口保留；不推断真实安装比例 |
| `lib/resources.ts: queryPublicResources` | `app/[locale]/resources/page.tsx`；产品详情 `app/[locale]/products/[code]/[slug]/page.tsx` | 资料库查询全部公开范围；产品详情仅查该型号、所属 COLLECTION/FAMILY 和无范围的通用资料 |
| `lib/resources.ts: publicResourceWhere` | 上述查询；`app/api/resources/[id]/download/route.ts` | 下载每次独立复核当前公开状态，列表页码或旧链接不授予下载权限 |
| `components/products/PublicResourceList.tsx`、`resourcePageHref` | 资料库和型号详情 | 两个列表和分页全部迁移；型号页分页保留选中 variant；翻页锚点为 `#documents` |
| `app/globals.css: .public-footer-grid a` | 所有公开页面的 `SiteFooter` | 仅公共页脚链接目标高度，不改 CMS 或 ERP 组件样式 |

旧 `getPublicResources` 已无有效代码调用，固定 100 条的旧实现已删除；未新建第二套资料可见规则。公共层保留原始内容、稳定 ID、实际语言和更新时间；没有写入产品参数、改价、改单位、改来源或改变发布事实。只读资料查询不产生业务重试或未知提交；客户询盘的持久提交合同未改。

## 自动验证范围

新增 `tests/public-resources.test.ts` 使用全新迁移 SQLite 库，包含：

- 型号专属、型号+系列、COLLECTION、FAMILY、全局资料的正确包含与隔离。
- 未公开/不存在的型号不能回退拿到通用资料，隐藏父级阻断公开查询和下载守卫。
- 112 条公开资料全部经有限分页取回，ID 不重复，超过旧 100 条上限仍可到达。
- 非法页码规整和产品款式查询参数保留。

`tests/public-catalog-pagination.test.ts` 新增：产品与款式图库完整保留、重复及远程路径排除；仅图片 fallback 不进入无法解析的 Studio 深链，真实旧站 base 款式仍可进入。

上述为本阶段增量测试范围，执行结果由本轮网站 quality gate 的当前日志给出，不使用上次暂停前通过记录代替本次证据。

## 实际浏览器验收清单

以下由主代理在本轮本地真实运行环境执行并保存结果；源码审查和自动测试不能替代。

1. 在 375 px 打开手机菜单，焦点先到关闭按钮；按 Tab/Shift+Tab 不进入背景页面。打开菜单内语言弹层，方向键/Home/End 能选择；第一次 Escape 仅关语言弹层并回到语言按钮，第二次才关手机菜单并回到打开菜单按钮。Tab 离开语言组件关闭弹层。
2. 桌面语言菜单复查同一键盘行为；在带筛选查询和锚点的网址切换语言，查询与锚点保留。阿拉伯语复查方向、菜单和焦点边界。
3. 首页空间预览切换场景和款式，选中态可识别；款式与场景触控目标至少 44 px。点击组件内进入完整试装后，地址带实际 variant，完整页面选中同一个款式，无 404。
4. 产品详情若含产品级多图和款式图，全部可切换；图库不拉伸、不重复，切换款式后咨询入口仍携带正确稳定 ID。未核验图片不能变成表面材料或参数声明。
5. 完整搭配用方向键、Shift+方向键、拖动、缩放及复位操作；产品详情与咨询链接对应当前选择，手机页面可滚动并触达全部操作。
6. CMS 真实发布系列级 PDF 后，专业资料页及该系列产品详情均能显示；型号专属 PDF 不出现在其他型号详情。下载实际非空 PDF 并核对元数据；下架后公开列表移除、原下载链接不可继续读取。
7. 资料超过 24 条时验证首尾翻页及稳定链接；型号页翻页保留 variant，返回上一页后无丢失或重复数据。空资料页仍提供真实索取资料的入口，不生成假下载按钮。
8. 375/768/1024/1440 px 复查手机菜单、详情图库、资料列表和搭配面板的溢出、焦点及图片加载；页脚导航可触达。

## 上传封套与私有资料就绪补验

同阶段独立审查发现，原 Nginx 的 `/admin` 和 `/admin/` 限额为 10 MiB，会阻断应用允许的合法 20 MiB PDF。两处现在统一为 22 MiB，与 Next Server Actions 的 `22mb` 封套一致，保留公开表单的 256 KiB 限额、现有身份校验与 PDF 内容校验。现有部署合同与 Node 存储测试同时断言全部两个 admin 入口，避免只修一个入口。

`assertDocumentsDirectoryReady` 复用上传和下载的唯一 `documentDirectory` 权威，再检查目录读、写、遍历权限。`/api/health` 同时要求数据库、上传目录、私有资料目录和两张资料表可用；错误仍只返回 `503 {"status":"unavailable"}`，不返回文件路径、数据库信息或异常。生产路径规则未弱化，不自动创建缺失的正式挂载，不允许符号链接目录。Nginx 没有新增私有资料 alias。

本轮定向执行：

- `node --import tsx --test tests/health-readiness.test.ts tests/upload-storage.test.ts`：13 通过、0 失败、0 跳过。真实临时迁移库覆盖正常 readiness、目录被普通文件占用、符号链接目录、生产错误路径不自动创建、资料表缺失和不透明错误响应。日志：工作树根 `.local-artifacts/website-completion/public-readiness-tests.log`。
- `python -m unittest discover -s website/deploy/tests -p test_deployment_contract.py -v`：24 项，19 通过、0 失败、5 项因当前 Windows 缺少 POSIX bash/flock/ownership 场景而跳过；新增 Nginx/health 合同均通过。不能将跳过项记为 Linux 部署验收。
- 网站最终 lint、类型、全测试和生产构建由统一 quality gate 再覆盖本增量。

`deploy/website.env.example` 仅补充了现有固定 `DOCUMENTS_DIR` 路径和私有挂载说明。旧 installer/activation/paired-backup 链仍按原 SQLite 与 uploads 合同工作，**本轮未将其改成 PostgreSQL 加私有 documents 的正式部署恢复链**。云端供给、严格环境校验、完整备份恢复以及 PostgreSQL 发布合同须在用户另行确认部署前完成；缺失 documents 时 readiness 应正确失败，不允许绕过。该待办不影响本次独立本地联调，但禁止据此宣称模板可直接投产。

## 案例与历史活动详情补全

只读事实核对后，10 语言 `Cases.subtitle` 统一为“项目资料与公司历史记录”的对应表述；`About.teamTitle/teamBody` 改为产品技术沟通，不再将历史组织资料直接表述为当前已核验团队结构。关于页 SEO 与正文继续共用同一翻译 key。历史“指定产品”记录不代表供货、安装或交付，现有历史记录继续由 `isLegacyCompanyActivity` 标记。

原案例页仅有 `article` 卡片，项目正文被截成三行且没有实际详情入口；历史活动也没有独立详情。现已新增 `app/[locale]/cases/[slug]/page.tsx`，并给项目和活动的标题及“查看详情”添加真实链接。详情只使用已有 `CaseItem` 的标题、地点、完整正文、原有封面；没有新增客户、交付、产品参数或图片，没有将 `createdAt`/`updatedAt` 渲染为项目或活动日期。

| 既有实现/缺口 | 公共方案与完整调用方 | 清理及保留差异 |
|---|---|---|
| 新闻详情内嵌安全正文 renderer；案例需要同样的 CMS 纯文本、标题、列表语法 | 提取唯一 `components/content/ArticleContent.tsx`，继续使用原 `parseNewsContent` 有限语法解析；新闻详情、案例/活动详情全部接入 | 新闻页原内嵌渲染分支已删除；没有复制第二套 HTML 或正文清洗规则。新闻仍保留新闻日期/相关阅读，案例仅保留实际已有字段 |
| 案例列表内联 published 条件，新详情与 sitemap 需要同一公开边界 | `publicCaseWhere` 统一用于 `getCases`、`getCaseBySlug` 和 sitemap；Node proxy 的案例入口预检也复用 `getCaseBySlug` | 列表旧内联公开条件已迁移；草稿和未知记录返回 null，详情据此 `notFound()`，metadata 不暴露草稿标题 |
| 案例无 locale SEO 与可发现详情 | 复用 `buildPageMetadata`、`directContentLocales`、`pickLocale/tr`；完整直接内容才获得该语言索引与 hreflang；sitemap 加已公开且有完整直接内容的详情 | 跨语言 fallback 不假扮翻译，沿用 noindex/canonical 机制。旧 slug 不变，不需数据迁移 |

详情使用与新闻一致的阅读宽度和正文样式，提供返回列表及真实联系页面；历史活动显示公司历史档案说明，不暗示现行项目交付或认证。

本轮定向 `public-cases.test.ts`、`news-content.test.ts` 与 `catalog-public-contract.test.ts` 共 **25 通过、0 失败、0 跳过**，覆盖完整长文保留、HTML 字符串转义、列表/详情/metadata/sitemap 的发布一致性、下架后的移除、直接 locale 与 fallback 的索引边界、入口上下文防伪及全局 404 路由合同。日志：工作树根 `.local-artifacts/website-completion/public-cases-tests.log`。实际 HTTP 和浏览器验收范围分别记录，不由单测冒充。

首页精选无需硬编码型号：`getLatestProducts` 使用 CMS 的 `featured DESC → sortOrder ASC → createdAt DESC → id DESC`，首页取前四个型号；系列候选优先 `hero.zh.heroSeriesId`，然后这些型号的实际家族，再按已公开家族补齐。正式 Z9 是已公开 FAMILY `cmslmtkjr01um1102cwcyujpj`，不是未公开旧占位 `cms88ksu00001bwl66spkp33s`。主代理通过实际 CMS 设置主推与排序并发布，保存草稿不改变官网；如希望四个现代系列同时突出，应在相应家族各选真实主推型号，不在源码写死系列。

### 案例 HTTP 状态与流式边界

仅在案例 page 或 generateMetadata 调用 `notFound()`，会受现有祖先 `loading.tsx` 影响而返回 200+noindex；直接从 locale root layout 抛出则失去品牌错误壳。最终方案限定在案例入口：Node `proxy` 用相同 `getCaseBySlug/publicCaseWhere` 进行一次有界公开读取，未知或草稿在流式渲染前同源内部 rewrite 到没有实际 `app/page` 的根路径 `/`，交由真正 unmatched 的 `global-not-found.tsx` 返回完整 404 文档。地址栏保持原网址，正常案例仍走原 next-intl，详情 page 和 metadata 继续独立复核。失败的 root-layout throw 预检和局部 provider wrapper 均已撤回；其它页面 loading、布局和发布算法未改。

全局文档按 Next 16 本地文档启用 `experimental.globalNotFound`，提供完整 `html/body`、既有公共 CSS 和 Intl provider，只渲染唯一的 `PublicNotFound` 展示组件；原有局部 not-found 入口也继续复用该组件。`proxy` 清除来路自带的私有 case/locale header，只按实际 URL 的受支持 locale 重建请求上下文；全局入口再次校验 locale 白名单，不缓存跨请求语言。客户端仅获得错误页必需的三组公开翻译。

必要的 `skipProxyUrlNormalize: true` 保留 `Request.url` 的实际 origin，避免 Next 把 loopback `127.0.0.1` 改成 `localhost` 后将同源 rewrite 当成外部自代理并 307 到首页。路径判断仍使用 `nextUrl.pathname`，没有信任来路 Host 拼装重写地址、没有自 HTTP 回抓、没有手写内部 rewrite header 或第二套 HTML 模板。`/` 无直接或 route-group 根页面、global-not-found 开关、原点保留配置和 locale matcher 对应关系均有合同回归；日后增加根页面须同时调整该错误入口，不能静默把失效案例导向首页。

已实际 HTTP 验证十种 locale 的未知案例：全部真 404、完整正确语言的品牌 heading、阿拉伯语 RTL、三个正确语言返回链接、noindex、原 URL 不变且无 Location；故意伪造 case 与 locale header 也不改变结果、不返回该私有 header。六个正常公开页面（含案例详情）仍 200，站点根入口依旧按 locale 跳转；另外模拟正式域名 Host 与 HTTPS 反向代理头，根入口和管理员登录仍为正确相对跳转，未知案例仍为品牌 404，没有 loopback 地址泄露或自代理。20 项回执见 `.local-artifacts/website-completion/public-cases-http.json`。真实迁移数据库测试覆盖草稿和发布后下架；通过实际 CMS 下架的 HTTP 回执及浏览器可见展示，由主代理补验。

已有未知新闻和产品详情仍为 Next 的 200+noindex 行为；本增量未擅自扩大入口数据库读取到其它路径。全局 404 仍须被最终生产构建及质量门禁覆盖，`globalNotFound` 当前属于该 Next 版本明确标记的实验选项。最终运行源码冻结后，不在主代理实际 CMS 草稿/发布过程中修改配置或触发开发服务重启。
