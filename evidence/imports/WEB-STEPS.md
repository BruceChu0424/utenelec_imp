# C 包真实网页验收夹具

所有文件都是合成数据。旧审查目录未改写；本目录 baseline 是独立复制件，本轮基线探针只读旧 build 的 classpath，输出重定向到新目录。

## 普通岗位

由统一验收夹具创建可登录的普通财务账号，`is_super_admin=false`，按需执行 `prepare-web.sql` 给该账号授权；不要给账号超管标志。最小科目/备注链需 `finance_report:view`、`finance:view:all`、`payment_style:edit`。会计接续还需 `finance_post:execute`。本包没有修改统一验收库，原 ID/文件/谱系跨版本实验另在本包专用 PostgreSQL 26632。

## 最小两条真实页面链

1. 进入 `/finance/report/gl`，打开“科目代码对应”，点击“导入科目目录”→“选择科目目录文件”，选 `web-fixtures/chart-legal.xlsx`（科目 `100199991 / 合成导入现金核查`）。预览没有问题、服务端版本为 2，点击“确认导入科目目录”。公开上传接口是 `POST /api/finance/chart/import-preview`，multipart `file`；确认接口为 `POST /api/finance/chart/import-apply`，正文只有 `{ "importId": "服务器返回的 UUID" }`。数据库核对 `finance_chart_codes` 的该编码、原 `source_import_id` 和 `finance_chart_imports.applied_result`；不会生成 GL 分录。
2. 进入公司经营损益报表，选择一个未锁定的合成月份，打开“备注/差异原因”→“导入备注/差异原因”，选 `web-fixtures/note-legal.xlsx`，点击“应用预览”。公开上传接口 `POST /api/finance/expense-analysis/notes/import-preview`，multipart `period`、`file`；确认接口 `POST /api/finance/expense-analysis/notes/import-apply`，正文 `{ "importId": "服务器 UUID" }`。数据库按月份/预览 `lineKey` 核对 `finance_operating_report_notes` 的“本地真实网页导入核验备注”和 `finance_expense_note_imports.applied_result`。

应分别再上传 `baseline/chart-true.xlsx`（小计行 D 有值）、`baseline/note-duplicate.xlsx`、`baseline/note-unknown.xlsx`。科目应显示带 D 列标签和原行号的问题，禁止应用；备注应明确拒绝第 4 列被替换。查业务表数量及值未变。不能将“预览有问题”算成业务成功应用。

## 其他原件

`web-fixtures/cost-legal.xlsx` 保留两条材料“铜柱/1/2、铜钉/1/4”；`baseline/cost-title-true.xlsx` 必须明确拒绝第 3 行混合产品标题和明细，不能只显示一条材料。

货品/BOM 的 `web-fixtures/{goods,bom}-legal.xlsx` 是原审查工作簿删除附加表的对照；对应 `baseline/{goods,bom}-extra-second-true.xlsx` 必须拒绝第二表具体位置，不能签发可执行计划，也不能进入 APPEND、REPLACE 或 merged 写入适配器。BOM 合法提交仍需按当前库中的真实父件、组件编号重新准备，不把仓库夹具中的模拟适配器当作真库写入。

BIFF8 原件 `baseline/voucher-empty-formula.xls`、`voucher-wrong-signature.xls` 分别必须报第 84 列公式问题、输出签名错误；`voucher-style.xls` 纯样式空尾列仍合法。会计接续的余额、科目映射和不同岗位审核沿原合同，不把解析通过记作总账已入账。

## 回执与退休

页面取消选择和退出再打开不能改写已冻结批次。未知提交只核对原 `importId` / 原命令回执。经营备注已经应用后由另一有权岗位锁定期间，原 owner 原 ID 重试必须返回原 JSON 且只写一次；另一 owner 不能取得原私有回执。跨版本实测脚本 `run-upgrade.ps1 seed` / `verify` 会另外核对五种持久化来源的 v1 拒绝、原 JSON 与父子谱系不变。
