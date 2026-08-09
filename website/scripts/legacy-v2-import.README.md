# 旧站目录 v2 安全导入

本导入器只处理 `website/.scrape/v2` 抓取器生成的 `uten-legacy-catalog/v2` 输出。它是企业产品展示站的目录迁移，不包含购物车、下单或价格生成。抓取结果中的价格必须始终为 `UNSET`；导入器不会把任何金额写入 CMS。

截至 2026-08-09，`.scrape/v2/output` 的全量抓取与 QA 已达到 `PASS`，可在导入器重新计算全部门禁且 `applyEligible=true` 后执行受控 apply。`PASS` 只表示输入完整性满足导入条件，**不等于生产发布批准**；正式库操作仍须经过负责人审批、维护窗口、schema 升级前备份、副本演练和导入后对账。

允许的验收与执行范围为：

- fixture 与 `.tmp/live-smoke` 的 dry-run；
- 临时/副本 SQLite 的事务、备份和媒体复制测试；
- `npm run test:legacy-import` 自动化测试。
- 对完整 `.scrape/v2/output` 保存 dry-run 计划，在副本库复核结果后，使用同一份未变更输入和计划执行经审批的 apply；禁止绕过 `qa-report`、`expectFull`、摘要或来源校验。

## 身份与发布边界

- 产品身份是 `ch-uten-v2:product:{oldSiteId}`，系列身份是 `ch-uten-v2:series:{sortId}`；名称从不参与去重。
- 同一个数字 `oldSiteId` 的中英文记录合并到同一 CMS 产品，两个语言的源 URL、哈希、抓取时间、raw 路径和完整原始 payload 分别保留在 `LegacySourceRecord`。
- 同名但不同 ID 始终是两个产品。与现有 CMS 同名也不会自动合并。
- 新导入的系列、产品和款式全部 `published=false`、`featured=false`、`sceneEnabled=false`，须经后台人工复核后再发布。
- 前台描述只使用清洗后的 `descriptionText`。`descriptionHtml` 仅可能存在于 `LegacySourceRecord.rawPayload`，并强制 `publishable=false`，禁止直接渲染。
- 当前抓取 schema 没有可靠颜色结构时，每个产品建立一个稳定的 `:{oldSiteId}:base` 款式，不虚构颜色、材质、SKU、尺寸或表面处理。
- 将来抓取器可在每个 locale 产品下输出 `variants[]`。每个款式必须有稳定 `sourceVariantId`，可带 `name`、`colorName`、`materialName`、`swatchHex`、`imageSha256`、`gallerySha256`、`finish` 与可空尺寸；仍不得按款式名称匹配。

## 1. 先升级副本数据库

Prisma 新增了导入运行、来源快照和哈希素材表。生产数据库升级属于独立发布动作，必须先备份并在副本验证。导入器的 apply 会在自身事务前再次自动备份，但它不会代替 schema 升级前的备份。

副本示例（不要把路径指向正式 `dev.db`）：

```powershell
$env:DATABASE_URL = 'file:D:/safe-copy/website-import-test.db'
npx.cmd prisma db push --skip-generate --accept-data-loss
```

这里的 `--accept-data-loss` **只允许用于已经备份的副本**：Prisma 会因给 `Product.sourceIdentity` 和 `ProductVariant.sourceIdentity` 新增唯一约束而发出通用警告。现有行在升级时该新列应全部为 `NULL`；必须核对 db-push 只列出这两项唯一约束警告，并复核升级前后产品/系列/款式数量一致。正式库仍需独立备份、维护窗口与人工批准，不能照抄副本命令直接执行。

## 2. Dry-run

Dry-run 不连接、不创建也不修改数据库。建议始终保存计划文件：

```powershell
npm.cmd run legacy:import:dry-run -- `
  --input .scrape/v2/.tmp/live-smoke `
  --report .scrape/v2/.tmp/live-smoke-import-plan.json
```

partial/fixture 的预期结果是 `status=pass`、`applyEligible=false`。这表示结构、来源和哈希可检查，不代表可以落库。

Dry-run 会独立验证：

- JSON/schema、`(locale, oldSiteId)` 与 `(locale, sortId)` 唯一性；
- `checkpoint.json` 版本、诊断/拒绝队列，以及所有顶层、嵌套和 checkpoint provenance 文件都位于输出目录内且 SHA-256 一致；
- 媒体字节数、SHA-256、来源 URL、图片魔数和尺寸；
- 所有产品价格仍为不可发布 `UNSET`；
- 产品到系列、媒体和款式的引用完整性；
- 1121/1036 数量、详情/列表页数量、中英文 ID 交差集、ID+SortPath 指纹和逐产品图片指纹；
- crawler 必需 QA checks、错误/冲突数组和 `expectFull`。

只有以下条件同时满足，计划才会 `applyEligible=true`：

1. `qa-report.json.status === "pass"`；
2. `qa-report.json.expectFull === true`；
3. `catalog.scope.fullRequested === true` 且已下载媒体；
4. 来源严格为 `http://www.ch-uten.com/`（loopback fixture 永不放行）；
5. 冻结全量基线、精确指纹、文件哈希和所有 importer 检查均通过。

## 3. Apply（仅未来全量 PASS 后）

Apply 必须同时提供刚生成的 dry-run 计划；`catalog.json`、`media.json`、`qa-report.json` 或 `checkpoint.json` 任一字节变化，digest 不一致就会拒绝。SQLite 路径显式传入，避免误用 `.env`：

```powershell
npm.cmd run legacy:import:apply -- `
  --input .scrape/v2/output `
  --plan .scrape/v2/output/import-plan.json `
  --database D:/safe-copy/website-import-test.db `
  --public-dir D:/Projects/uten_imp/website/public `
  --backup-dir D:/safe-copy/backups/legacy-v2
```

Apply 顺序固定为：

1. 重算 dry-run 与全量 QA 门禁；
2. 分别为数据库与解析后的 `public` 目录建立全局导入锁，避免不同数据库共享素材目录时互相回滚文件；
3. 通过 SQLite `VACUUM INTO` 创建一致性备份；
4. 只复制通过魔数验证的栅格图到 `public/uploads/legacy-v2/{hash-prefix}/{sha256}.{ext}`，复制后再次核对哈希再原子发布；已有路径必须内容相同，绝不覆盖；重复运行会核验并修复缺失的哈希素材；
5. 在一个 Prisma Serializable 事务内 upsert 哈希媒体、系列、产品、款式、图库关系和不可发布来源快照；
6. 事务失败时数据库自动回滚，并只清理由本次新复制的媒体；备份保留用于核查。

SVG、HTML 和非安全图片不会复制到 public；其他非公开素材仍可在 `LegacyMediaAsset` 中保留哈希与来源记录，`publicPath=null`。

## 验证

```powershell
npm.cmd run test:legacy-import
npx.cmd tsc --noEmit
```

测试覆盖：同名不同 ID、中英文同 ID 合并、partial apply 拒绝、现有同名 CMS 内容不被合并、SQLite 自动备份、哈希媒体路径、默认未发布、raw HTML 隔离、事务冲突回滚及新复制媒体清理。
