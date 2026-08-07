-- =====================================================================
-- V228：权限目录两级分类（module 一级 + category 二级）
-- =====================================================================
-- 背景：
--   权限管理页目录原本按 permissions.category 折叠成 ~30 个扁平分组，且历史种子把同一域
--   的权限拆散（库存=「库存」+「库存管理」；生产=「生产」+「生产管理」+「生产计划」+「生产报表」；
--   报销=「报销」+「员工报销」；退货质检/收货待检被塞进「库存管理」等），管理员"找权限找不到"。
--
-- 目标：重组为两级，与 App 7 大 Hub（销售/采购/委外/生产/钱流/仓库/基础资料）一致——
--   * module（一级，功能模块）：基础资料 / 销售管理 / 采购管理 / 委外管理 / 生产管理 /
--        仓库管理 / 财税管理 / 工程研发 / 人事行政 / 品质检测 / 系统管理
--   * category（二级，子类）：在 module 下进一步细分（货品资料 / 销售订货 / …）。
--   命名用功能模块名（不用部门名——权限按功能划分，一个部门常跨多模块）。
--
-- 实现：
--   * 新增 permissions.module 列承载一级；category 保留并规范化为二级子类名。
--   * 按「模块/子类」批量 UPDATE module + category，覆盖目录内全部权限点（含 V227 新增的
--     goods:discount:view——一并从「主数据」归入「基础资料·货品资料」）。
--   * 不动 sort_order：模块顺序由后端固定 MODULE_ORDER 决定，子类/权限顺序沿用既有
--     sort_order→code 稳定排序（历史 sort_order 碰撞由 code 兜底，无歧义）。
--   * 兜底：任何未被上面覆盖的权限（理论上应为 0；防并行/未来新增漂移）归入「其他」
--     模块，前端可见、便于发现后补归类，而非静默错放。
--
-- 单一事实来源：本迁移即 module 归类的权威表；后续新增权限点应在各自迁移里直接写
--   module + 规范 category，避免落入「其他」。同步文档：docs/数据迁移/55-权限模块分类.md。
-- =====================================================================

-- ① 新增一级模块列
ALTER TABLE permissions ADD COLUMN IF NOT EXISTS module VARCHAR(64);

-- ② 按模块/子类回填 module + 规范化 category
-- ── 1. 基础资料 ────────────────────────────────────────────────────────
UPDATE permissions SET module='基础资料', category='货品资料'
 WHERE code IN ('goods:view','goods:edit','goods:export','goods:view:all','goods:price:edit','goods:cost:view','goods:discount:view');
UPDATE permissions SET module='基础资料', category='物料分类'
 WHERE code IN ('material_category:view','material_category:edit');
UPDATE permissions SET module='基础资料', category='模具分类'
 WHERE code IN ('mould_category:view','mould_category:edit');
UPDATE permissions SET module='基础资料', category='模具'
 WHERE code IN ('mould:view','mould:edit');
UPDATE permissions SET module='基础资料', category='客户分类'
 WHERE code IN ('client_category:view','client_category:edit');
UPDATE permissions SET module='基础资料', category='客户资料'
 WHERE code IN ('client:view','client:edit','client:export','client:view:all');
UPDATE permissions SET module='基础资料', category='供应商分类'
 WHERE code IN ('supplier_category:view','supplier_category:edit');
UPDATE permissions SET module='基础资料', category='供应商资料'
 WHERE code IN ('supplier:view','supplier:edit','supplier:export');
UPDATE permissions SET module='基础资料', category='颜色'
 WHERE code IN ('color:view','color:edit');
UPDATE permissions SET module='基础资料', category='单位'
 WHERE code IN ('unit:view','unit:edit');
UPDATE permissions SET module='基础资料', category='币种'
 WHERE code IN ('currency:view','currency:edit','currency:export');
UPDATE permissions SET module='基础资料', category='仓库'
 WHERE code IN ('warehouse:view','warehouse:edit');
UPDATE permissions SET module='基础资料', category='账户资料'
 WHERE code IN ('account:view','account:edit','account:export');
UPDATE permissions SET module='基础资料', category='收付款类别'
 WHERE code IN ('payment_style:view','payment_style:edit');

-- ── 2. 销售管理 ────────────────────────────────────────────────────────
UPDATE permissions SET module='销售管理', category='销售报价'
 WHERE code IN ('sales_quote:view','sales_quote:edit');
UPDATE permissions SET module='销售管理', category='销售订货'
 WHERE code IN ('sales_order:view','sales_order:edit','sales_order:price:view','sales_order:change_planned',
                'sales_order:priority','sales_order:reallocate','sales_order:confirm_partial_shipment');
UPDATE permissions SET module='销售管理', category='销售出货'
 WHERE code IN ('sales_shipment:view','sales_shipment:edit','sales_shipment:reject','sales_shipment:warehouse-work');
UPDATE permissions SET module='销售管理', category='其它出货'
 WHERE code IN ('sales_other_shipment:view','sales_other_shipment:edit');
UPDATE permissions SET module='销售管理', category='销售退货'
 WHERE code IN ('sales_return:view','sales_return:edit','sales_return:disposition');
UPDATE permissions SET module='销售管理', category='销售退货质检'
 WHERE code IN ('sales_return_quality:view','sales_return_quality:handle');
UPDATE permissions SET module='销售管理', category='销售报表'
 WHERE code IN ('sales_report:view','sales_report:export','sales:view:all');

-- ── 3. 采购管理 ────────────────────────────────────────────────────────
UPDATE permissions SET module='采购管理', category='采购申请'
 WHERE code IN ('purchase_request:view','purchase_request:edit');
UPDATE permissions SET module='采购管理', category='采购订货'
 WHERE code IN ('purchase_order:view','purchase_order:edit','purchase_order:submit_finance');
UPDATE permissions SET module='采购管理', category='采购收货'
 WHERE code IN ('purchase_receipt:view','purchase_receipt:edit');
UPDATE permissions SET module='采购管理', category='采购退货'
 WHERE code IN ('purchase_return:view','purchase_return:edit');
UPDATE permissions SET module='采购管理', category='采购报表'
 WHERE code IN ('purchase_report:view','purchase_report:export');
UPDATE permissions SET module='采购管理', category='到货异常'
 WHERE code IN ('supplier_return_task:handle');
UPDATE permissions SET module='采购管理', category='收货质检'
 WHERE code IN ('procurement_inspection:view','procurement_inspection:handle');

-- ── 4. 委外管理 ────────────────────────────────────────────────────────
UPDATE permissions SET module='委外管理', category='委外询价'
 WHERE code IN ('subcontract_inquiry:view','subcontract_inquiry:edit');
UPDATE permissions SET module='委外管理', category='委外申请'
 WHERE code IN ('subcontract_application:view','subcontract_application:edit');
UPDATE permissions SET module='委外管理', category='委外订货'
 WHERE code IN ('subcontract_order:view','subcontract_order:edit','subcontract_order:submit_finance');
UPDATE permissions SET module='委外管理', category='委外进仓'
 WHERE code IN ('subcontract_receipt:view','subcontract_receipt:edit');
UPDATE permissions SET module='委外管理', category='委外材料出仓'
 WHERE code IN ('subcontract_material_issue:view','subcontract_material_issue:edit');
UPDATE permissions SET module='委外管理', category='委外退货'
 WHERE code IN ('subcontract_return:view','subcontract_return:edit');
UPDATE permissions SET module='委外管理', category='委外材料退货'
 WHERE code IN ('subcontract_material_return:view','subcontract_material_return:edit');
UPDATE permissions SET module='委外管理', category='委外材料损耗'
 WHERE code IN ('subcontract_waste:view','subcontract_waste:edit');
UPDATE permissions SET module='委外管理', category='委外报表'
 WHERE code IN ('subcontract_report:view','subcontract_report:export');

-- ── 5. 生产管理 ────────────────────────────────────────────────────────
UPDATE permissions SET module='生产管理', category='生产计划'
 WHERE code IN ('production_plan:view','production_plan:edit','production_plan:forward_rd',
                'production_plan_cost:view','production:view','planning_supply_request:view');
UPDATE permissions SET module='生产管理', category='生产日报'
 WHERE code IN ('production_daily_report:view','production_daily_report:edit');
UPDATE permissions SET module='生产管理', category='生产报表'
 WHERE code IN ('production_report:view','production_report:export');
UPDATE permissions SET module='生产管理', category='物料反查'
 WHERE code IN ('production_where_used:view');

-- ── 6. 仓库管理 ────────────────────────────────────────────────────────
UPDATE permissions SET module='仓库管理', category='库存'
 WHERE code IN ('stock:view','stock:edit','stock:balance:adjust','inventory:view');
UPDATE permissions SET module='仓库管理', category='仓库单据'
 WHERE code IN ('stock_doc:view','stock_doc:edit');
UPDATE permissions SET module='仓库管理', category='仓库报表'
 WHERE code IN ('stock_report:view','stock_report:export');
UPDATE permissions SET module='仓库管理', category='预计到货'
 WHERE code IN ('warehouse_inbound:view');

-- ── 7. 财税管理 ────────────────────────────────────────────────────────
UPDATE permissions SET module='财税管理', category='销售收款'
 WHERE code IN ('finance_receipt:view','finance_receipt:edit');
UPDATE permissions SET module='财税管理', category='采购付款'
 WHERE code IN ('finance_payment:view','finance_payment:edit');
UPDATE permissions SET module='财税管理', category='一般费用'
 WHERE code IN ('finance_expense:view','finance_expense:edit');
UPDATE permissions SET module='财税管理', category='其它收入'
 WHERE code IN ('finance_other_income:view','finance_other_income:edit');
UPDATE permissions SET module='财税管理', category='银行存取'
 WHERE code IN ('finance_bank_transfer:view','finance_bank_transfer:edit');
UPDATE permissions SET module='财税管理', category='应收应付与账户流水'
 WHERE code IN ('ar_ap_ledger:view','finance_reconciliation:view');
UPDATE permissions SET module='财税管理', category='资产与待摊'
 WHERE code IN ('finance_asset:view','finance_asset:edit','finance_asset:approve','finance_asset:post',
                'finance_asset:dispose','finance_asset:export','finance_asset_period:manage');
UPDATE permissions SET module='财税管理', category='总账过账'
 WHERE code IN ('finance_post:execute');
UPDATE permissions SET module='财税管理', category='发运审核'
 WHERE code IN ('finance_shipment_audit');
UPDATE permissions SET module='财税管理', category='订货审批'
 WHERE code IN ('finance_order_approval:view','finance_order_approval:review');
UPDATE permissions SET module='财税管理', category='钱流报表'
 WHERE code IN ('finance_report:view','finance_report:export');
UPDATE permissions SET module='财税管理', category='审批负责人'
 WHERE code IN ('workflow_assignment:manage');
UPDATE permissions SET module='财税管理', category='敏感驾驶舱'
 WHERE code IN ('dashboard:finance-sensitive:view');

-- ── 8. 工程研发 ────────────────────────────────────────────────────────
UPDATE permissions SET module='工程研发', category='研发任务'
 WHERE code IN ('rd_task:view','rd_task:edit','rd_task:resolve');

-- ── 9. 人事行政 ────────────────────────────────────────────────────────
UPDATE permissions SET module='人事行政', category='员工档案'
 WHERE code IN ('employee:view','employee:create','employee:edit','employee:delete',
                'employee:pii:view','employee:pii:edit','employee:compensation:view','employee:compensation:edit',
                'employee:export');
UPDATE permissions SET module='人事行政', category='部门'
 WHERE code IN ('department:view','department:edit');
UPDATE permissions SET module='人事行政', category='工资条'
 WHERE code IN ('payroll:view:self','payroll:view:all','payroll:generate','payroll:review','payroll:publish','payroll:export');
UPDATE permissions SET module='人事行政', category='报销'
 WHERE code IN ('expense:apply','expense:approve','expense:pay');
UPDATE permissions SET module='人事行政', category='访客'
 WHERE code IN ('visitor:apply','visitor:view','visitor:approve','visitor:check-in','visitor:blacklist','visitor:host-confirm');
UPDATE permissions SET module='人事行政', category='个人信息'
 WHERE code IN ('profile:edit:self','profile:review');
UPDATE permissions SET module='人事行政', category='通知'
 WHERE code IN ('notice:read','notice:publish');
UPDATE permissions SET module='人事行政', category='意见箱'
 WHERE code IN ('suggestion:submit','suggestion:reply');

-- ── 10. 品质检测 ───────────────────────────────────────────────────────
UPDATE permissions SET module='品质检测', category='检测记录'
 WHERE code IN ('lab:test:view','lab:test:upload');

-- ── 11. 系统管理 ───────────────────────────────────────────────────────
UPDATE permissions SET module='系统管理', category='审计中心'
 WHERE code IN ('audit_log:view','audit_log:export');
UPDATE permissions SET module='系统管理', category='授权管理'
 WHERE code IN ('authorization:manage');
UPDATE permissions SET module='系统管理', category='账号管理'
 WHERE code IN ('account:support','user:manage','viewcontext:scoped');

-- ③ 兜底：未被覆盖的权限（应仅可能是并行/未来新增且未写 module 者）归入「其他」，便于发现后补归类。
UPDATE permissions SET module='其他' WHERE module IS NULL;
