# 持久化导入网页入口矩阵（prep，未执行文件操作）

基于 `31b25b93841d29b026ac02dce89eb3acb852c892`，产品 Java 沿 Root 47；最终未冻结。已完整对照 C `evidence/imports/REPORT.md`、`WEB-STEPS.md`、`evidence/c-final/REPORT.md` 和当前 Flutter/Controller/Service。C 的 PG/解析/146项测试不计本次真 Web。旧 WEB-STEPS 的版本2描述已过时，当前 `ImportColumnGuard.VERSION=3`；客户端不能自报版本。

**七类全部有真实网页写入口，凭证/余额与成本不是只读解析器。** 五类“持久旧预览版本门”是成本、科目、备注、辅助、会计（凭证/余额一类）；货品/BOM还会重读原 bytes，不能据“五类”漏掉它们。

## 普通身份和新基础前置

最终 [import-actors-final.json](import-actors-final.json) 不含密码，密码仅 Root private `syntheticAccountPassword`：

- masterImport：`USR-b-masterImport-f8b75d73` / `75ce9c4a-caea-42de-8ac5-a0dbb9fc6e9a`。仅 goods:view/import、goods:bom:create/delete、goods:cost:view/edit，以及 material_category:view、currency:view 两项真实页面读依赖；无 master 通配全权限、财务、审批或超管。
- financeImport：`USR-b-financeImport-f8b75d73` / `04bc1185-6427-4222-983a-9e46aa28815b`。仅 finance_report:view、finance:view:all、payment_style:edit、finance_post:execute。没有给它科目create、商品或资产写权限。
- 已只读核实可复用原普通财务 `USR-b-finance-ui-a635aa02` / `0b887a85-239a-4118-8d3f-246b166a7189` 的原6权限，**没有改其权限**；需要科目新增对应时用它，并与新 financeImport 分别提交/复核。
- 只新增独立 BOM 父件 `3de8a1b0-f09b-47df-bb50-f207fb00c859` / `BIMP-P-f8b75d73`，组件 `311b859f-9891-4efb-bd5b-edf8d56ed657` / `K01`，单位“个”。都归新 masterImport，**未建 BOM 行或成本单**，不影响原物料单。原合法 BOM 文件确实引用 K01、用量1.2345；否则原文件不能凭模拟适配器算真库合法。

`root-actors-run1` 1/1、compile0、未执行任何 import service。事务内逐项证明原 users/goods 不变、已由 Root 真 UI 保存的用途映射不变，11张 import/业务表计数不变。随后只对本次新 master 身份补齐 category/currency 两项只读依赖；原初始seed和补齐文件均保留，其他账号ACL摘要不变。不应重跑seed或再建K01。

## 七入口、最小权限与真实确认

| 家族 | 真页面、按钮与最小权限 | 检测→真正写入、预期边界 |
| --- | --- | --- |
| 货品 | `/basicinfo/goods` 顶栏/工具栏 **导入货品** → **选择导入方式**（新建货品/修改货品/混合导入）。入口需 goods:view + material_category:view，检测/提交需 goods:import。复制/替换BOM、查看原售价另按专门权限，不隐含授权。 | 选择文件→检测报告→**查看导入预览**→逐行核对/选择→**确认导入 N 条**。`POST /api/master/goods/import/detect` 原bytes；commit为 JSON file/base64 + 原planId/选择/相同mode，`POST .../commit`。原附加表应报准确位置、不能签可执行plan，goods/字典/批次不误写。合法文件新建“合成货品”，编号由服务端产生；核 goods、goods_import_batches 和原批次结果。 |
| BOM | `/basicinfo/goods/3de8a1b0-f09b-47df-bb50-f207fb00c859?tab=bom` → **导入组件**。直达详情需 goods:view，检测/合并/追加需 goods:bom:create，覆盖/需删除原行的变化另需 goods:bom:delete。 | 选文件→检测→合并核对/APPEND/REPLACE明确选择→**核对后提交/导入**。`POST /api/master/goods/{id}/bom/import/detect`，commit同路径`/commit`含原bytes+stateFingerprint+mode+替换选择。原第二表错误不能提交，三模式不误写。合法文件添加当前父件→K01、qty1.2345；核 goods_bom_items。状态指纹的`v1:`前缀不是列安全版本1，不要误改。 |
| 成本 | 同父件详情 `?tab=cost` → **更多操作** → **导入成本表**。goods:view、goods:cost:view/edit；成本页CurrencyRepository.dict另需 currency:view。历史/确认等业务资格仍由服务端返回。 | 上传→持久原预览→选产品区块→每一原行明确“对应物料价格/每产品费用/跳过此行”、价格单位、数量是否采用和**已核对**→**采用到本单**。`POST /api/master/goods/cost-sheets/import-preview?goodsId=...` multipart；`.../import-apply`含importId/blockKey/原成本input/所有mappings。攻击须拒绝第3行标题混明细，不能丢铜钉。合法两行铜柱1×2、铜钉1×4完整保留；可像C原对照逐行明确SKIP并填写理由，持久 goods_cost_import_mappings 一份完整两行回执，不能冒称已采用价格或保存成本单。需实际成本落库时继续 **保存草稿**，分别核成本单/计算事实。 |
| 科目目录 | `/finance/report/gl` → **科目代码对应** → **导入科目目录** → **选择科目目录文件**。finance_report:view + finance:view:all + payment_style:edit。 | `POST /api/finance/chart/import-preview` multipart，保原importId/owner/版本3/问题→**确认导入科目目录**，`POST .../import-apply`是持久命令（当前UI会发送完整原操作字段，不手工削成旧简化请求）。攻击小计D列问题不能apply；合法100199991目录1行有source_import_id、finance_chart_imports.applied_result，GL0增。导入目录≠新建/映射native科目；不要动七个已有用途。 |
| 辅助明细/目录 | `/finance/report/summary` 选 **应收账款明细表**（或应付），日期明确2026-09-01～09-30，**币别列头先选原表币别** → **导入原明细表**，填**来源账套**→**选择原明细文件**。同上三个权限。 | `POST /api/finance/auxiliary-imports/preview` multipart side/sourceSystem/currencyId/dateFrom/dateTo/file/(requestId)→原文/问题核对→**导入辅助目录草稿**，`POST .../directory-apply {importId}`。未知有值列拒绝apply；合法old-auxiliary为原客户00099、科目112201、期初/期末10，预期目录1项（可能已有同来源身份被复用），source_reviews保原件/版本3/回执，finance_auxiliary_items有原来源，**不自动改AR/AP/GL或匹配真实客户**。 |
| 经营备注 | `/finance/report/gl` 选 **公司经营损益表**，选择未锁的合成月份→**备注/差异原因**→**导入备注/差异原因**。同上三个权限。 | `POST /api/finance/expense-analysis/notes/import-preview` multipart period/file→检查原行列问题和预览→**应用预览**，`POST .../notes/import-apply {importId}`。重复/未知D列攻击拒绝，原业务值不变；合法备注“本地真实网页导入核验备注”1条、finance_expense_note_imports有原owner/原ID/applied_result。月份列和金额是只读，空白保留，不作批量改账。 |
| 会计凭证+余额 | `/finance/report/gl` → **原账套接续**。预览/提交/不同人审核最小 finance_report:view + finance:view:all + finance_post:execute；需要维护目录对应另需 payment_style:edit，新建native叶科目另需payment_style:create（原ordinaryFinance具备）。 | **导入原凭证83列**、**导入原科目余额11列**均调用 `POST /api/finance/accounting-imports/preview` multipart kind/sourceSystem/file，先存私有PREVIEW；不是GL通过。下节完整配对/对应/性质/辅助/期初/完整期间→**提交另一人复核** `POST /{id}/submit`→另一ordinary **复核通过并接续** `POST /{id}/approve`。攻击84列空缓存公式/83假签名必须定位且无GL/基线/POSTED，合法完整pair才可POSTED。 |

按钮文字以当前本地中文源码核对；报告动作可能进入 Uten 更多下拉。Root 用 CUA 真实文件选择/确认，同动作仅同最终运行版本的截图、真实HTTP path/status和SQL串链；本目录没有执行这些步骤。

## 精确原文件与合法对照

原 C 文件全部位于 **`D:/Projects/uten_imp_worktrees/feedback-remediate-20261110/evidence/imports/`**，不是26632用户/crypto。完整可复制绝对路径及SHA、物理XLSX单元格清单见 `root-readonly-1.json.files`，不要运行旧hardcoded脚本覆盖原日志：

| 家族 | 原攻击（相对上述绝对目录） | 原现成合法对照（同目录） |
| --- | --- | --- |
| goods | baseline/goods-extra-second-true.xlsx（另false原件也保留） | web-fixtures/goods-legal.xlsx |
| BOM | baseline/bom-extra-second-true.xlsx | web-fixtures/bom-legal.xlsx（K01/1.2345，本次已备新父件/组件） |
| cost | baseline/cost-title-true.xlsx（另false保留） | web-fixtures/cost-legal.xlsx |
| chart | baseline/chart-true.xlsx（另false保留） | web-fixtures/chart-legal.xlsx |
| note | baseline/note-duplicate.xlsx；baseline/note-unknown.xlsx | web-fixtures/note-legal.xlsx |
| aux | auxiliary-extra-current.xlsx；新版同反例另在 Root evidence/c-final/final-7b912287-files-auxiliary-extra-current.xlsx | old-auxiliary.xlsx |
| voucher/balance | baseline/voucher-empty-formula.xls；baseline/voucher-wrong-signature.xls；baseline/voucher-unknown-value.xls | baseline/voucher-style.xls（样式尾列合法，仅解析对照）；old-vouchers.xls + old-balances.xls（C原较复杂完整9月源，仍保留） |

Root 最终操作应优先用下节新构造的简单**完整10月pair**，不要把纯样式尾列合法文件或旧v1预览当成直接可POSTED的业务批次。

## 合法会计接续：10月完整源 → 11月原生业务

**顺序是业务边界，不靠换日期绕守卫。** 当前只读 Root gl_entries、finance_gl_opening_baselines、finance_accounting_period_coverage均0（`root-import-baseline-with-opening.json`）。首次接续必须在任何GL已生成之前，原有业务单不删不改。

源码依据：`FinanceAccountingImportService.prepare` 的 `effectiveFrom` 为源月份1日，approve写期初基准/完整月coverage；approve拒绝已有任何GL/有效基准的第二次首次接续。`GlPostingService.generatePeriod:94` 调 `NativeFinancialPostingAccountService.requireNoImportedPeriod:408`，后者按**POSTED未冲销、ORIGINAL_BALANCE_AND_COMPLETE_JOURNALS、精确period相同**拒绝原生生成/重复立往来。不是静默过滤，也不只比较某个cutover末日。故11月源若POSTED，会挡11月原生GL；改用完整10月真实合成源，coverage=2026-10，基准effective_from=2026-10-01，10/31期末保留，11/11业务不命中此月份门。其他配置/来源/业务守卫仍必须实际通过。

三份文件绝对路径：

- `D:/Projects/uten_imp_worktrees/feedback-b-import-ui-prep-20261111/evidence/b-import-ui-prep/accounting-pair-202610/legal-vouchers-202610.xls`
- `D:/Projects/uten_imp_worktrees/feedback-b-import-ui-prep-20261111/evidence/b-import-ui-prep/accounting-pair-202610/legal-balances-202610.xls`
- `D:/Projects/uten_imp_worktrees/feedback-b-import-ui-prep-20261111/evidence/b-import-ui-prep/accounting-pair-202610/legal-chart-202610.xlsx`

它们按原正常83/11/3列模板构造，内容真为10月：凭证F1=2026-10-01、F52=10，余额标签2026.10-2026.10；目录工作表名含2026-10。不是只改名。完整 SHA 在 `accounting-pair-file-hashes.json`；原11月三文件/首轮本地格式报告未覆盖，保留作为不适宜同月原生生成的对照。`local-format-check.json` 仅本地纯parser/reconcile校验（版本3、0问题），没有Root服务预览、上传、submit或approve。

1. CUA以原ordinaryFinance登录 `/finance/report/gl`。在 **科目代码对应→导入科目目录** 真正上传/确认10月目录。原代码19019991=`B网页接续合成资产`、39019991=`B网页接续合成权益`；与原C合法100199991目录无关，只选这两行。
2. 在对应/新增界面为19019991新建**独立普通ACCOUNT资产叶科目**，为39019991新建**独立普通EQUITY权益叶科目**，保留服务实际生成的UUID/code；确认二者的本位币属性为当前真实人民币UUID，不按名称猜配。不要复用库存/应付/其他七个用途科目，也不移动/替换原用途。维护用 `FinanceChartService.createTargetCommand` (`POST /api/finance/chart/{code}/create-target`) / 原map命令，UI取原行版本。
3. **原账套接续**填写同一新来源账套 `BUI-WEB-202610`，分别上传10月凭证/余额。文件内ledger=`BUI01`、company=`B网页合成验收`、year=2026、month=10。正常服务新签版本3，保留两个新importId，不使用C原专库UUID/旧预览。
4. **原文预览**：完整10月只有一张凭证 `BUI01|2026|10|记|BUI0001`，两分录资产借100/权益贷100；两科目期初借贷均0，本期资产借100/权益贷100，10/31期末同额。逐科目核对无差额，保原83列/11列，不省略其他有值字段。
5. **科目对应**仅两原代码对应步骤2真实UUID及同一本位币。**凭证性质**选 `OPERATING`（普通业务），不是PNL_CLOSE/期初/结转。没有客户、供应商、员工、部门、项目辅助字段；这两个普通非往来科目没有required辅助规则，**辅助复核不绑定其他AR/AP目录或原件**。期初均明确0，无人工期初分配、无零余额损益省略例外，首次接续 `appendPeriod=false`。
6. 在**核对与提交**确认本合成账套该月完整、原余额及辅助依据完整、逐张性质已核对，并如实填写“完整10月仅此一笔合成权益投入、两科目期初0、无辅助分录；原始文件及逐科目发生额已核对”。这是生成器定义的完整合成事实，不代表公司原账套。点 **提交另一人复核**，原body保两个importId/version、两账户选择/币别、完整期间true、OPERATING、原requestId。
7. 切换新 financeImport 普通账号，在原账套接续待复核读取原提交批次，核原文件、两UUID、期初/性质/完整性，填写真实复核说明→**复核通过并接续**。必须另一用户，保真实approve请求/原回执；submit者不能自己批准。若状态/映射/原件已变则按正常退回复核，不UPDATE旧JSON/版本。
8. SQL必须看到成对批次POSTED、同一result和互相paired、submitted_by/approved_by不同，基准effective_from=2026-10-01，coverage=2026-10；空期初不生成期初分录，预期**1个 FINANCIAL_SOURCE 凭证、2条100分录、净额0**。重复原复核请求返回原回执不增写。任何只有PREVIEW/解析0问题的结果都不能记POSTED。
9. 再执行11月真实退货分岗审批与普通HTTP `GL generate?period=2026-11`，最后CUA实际GL报表读取及来源分栏对照。11月native生成不覆盖/删除10月FINANCIAL_SOURCE；仍需满足原账配置/身份/库存成本/期间等守卫，不提前宣称通过。

## 另有持久“原表采集/比对”入口，不能混称七类业务Apply

全调用方复核还看到共享 `FinanceTemplateSourceUpload`：`POST /api/finance/template-imports/costs/preview` 保存不可变 `finance_template_sources`（成本/铜柱/塑料/领料/其他应收等原表），`.../assets/preview` 为资产折旧/摊销原表。入口包括 `/finance/report/cost` 的相应原表输入对话框、往来对账详情 **原表导入比对**、其他应收物料原表、资产详情/原账接续组 **导入财务原表**。随后是各自模板input/statement comparison或资产接续命令，**保存原件不等于改AP/GL或已接续资产**。成本类原件采集需report:view + finance:view:all + payment_style:edit；资产原件需finance_asset:view/edit，当前两个新角色刻意未授资产写权限，不用大包权限兜底。

这些是另外的财务模板/原件合同，不可把本轮七类文件改名上传后宣称合法对照。公司私有Excel/对应资产或对账原单未提供时，保来源/身份/期初/精度/审核合同，单列原件与岗位现场验证；原C唯一私有Excel skip仍未验。原始模板可从对应正常导出/下载获取，按实际模板和来源事实准备后才做相应原表采集。Win7 WPF未迁移导入继续未迁移，不因同HTTP已有而算真机支持。

该共享服务当前白名单也已逐项清点：成本/物料原件 `copperFee/copperDetail/plasticUsage/plasticIssue/plasticReturn/plasticFinished/salesCostSummary/otherReceivableStatement`，往来原件 `subcontractStatement/supplierStatement/clientStatement`，资产原件 `depreciation/amortization/depreciationCompleted`。`/finance/report/cost` 的真实行（须有对应clientId/periodLineId/sourceLineId/requisitionId）→**维护原表资料/维护原表订单号**→**导入原表**，采集后另走 `/api/finance/cost-template-inputs`；对账详情→**原表导入比对**，另走 `/api/finance/statement-documents/comparisons/preview` 与提交比对；资产详情/组接续的原件采集另走 `/api/finance/asset-template-inputs`。缺少这些实际行/对应原件的分支不能拿空模板或本轮七类文件代替成功，原件保存、比对/模板输入保存和会计/库存事实分别核验。当前只为七类原反例及其合法对照补前置，未擅自再造采购/生产/资产业务行或授资产大包权限。

## 原始证据和只读核查

`capture_imports.py --config ROOT_PRIVATE/runtime.json --out NEW.json` 为同一read-only RR完整快照：七张业务表内容指纹、各持久导入批次ID/owner/kind/status/版本/问题数/原回执、GL期初/月份coverage。攻击应业务指纹逐项不变；预览可依法新增不可执行原件记录，不能误要求“所有表0新增”。合法Apply按各表独立核对完整原件和结果，不以页面进程存活代替。

本次未实际上传任何文件，也没改变任何旧预览或七个用途。Root26630身份/必要新master前置之外只读；旧审计audit、C原文件/失败均未覆盖。源码/输入/运行日志与哈希最终manifest绑定。无main合并、push、部署、正式包。
