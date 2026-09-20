-- ============ 客户货款类型放开必填（2026-09-19 用户口径） ============
-- 用户口径：客户编辑表单除「基础」组（名称/状态）外全部选填——联系人、销售货款
-- 类型都不再必填；编号全自动（readOnly 不上送，服务端按分类前缀发号）。
--
-- 本迁移只动货款类型的库约束：V443 的
--   clients_online_sales_payment_type_required_chk
--     CHECK (legacy_id IS NOT NULL OR sales_payment_type IS NOT NULL) NOT VALID
-- 虽是 NOT VALID（存量不回扫），但对之后每一次 INSERT/UPDATE 都强制——新建客户
-- (legacy_id 为空)不带货款类型必被 23514 打回，DTO/@NotNull 与 create() 的显式
-- 抛错只是它的前端镜像。
--
-- 放开是安全的：分类诉求已在真正需要它的时点设闸——SalesShipmentService
-- 财务放行前 requireClassifiedSalesPaymentType()，未分类客户得到干净的 409
-- 「客户货款类型尚未分类，请先在客户资料选择月结、现金或定金」；列表/详情侧
-- null 本就显示「待人工分类」(client_node.dart salesPaymentTypeLabel)。
-- 顺带修掉一个潜伏雷：WebsiteInquiryClientAdapter.createFromInquiry() 建
-- 官网询盘客户时从不设置货款类型，此前 INSERT 必撞本约束。
--
-- 编辑语义保持「null=不动」：apply() 只在请求带非空值时覆盖，避免只提交部分
-- 字段的客户端把已分类客户抹回未分类。

ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS clients_online_sales_payment_type_required_chk;

COMMENT ON COLUMN clients.sales_payment_type IS
    '月结/现金/定金人工分类(V443)；V607 起创建可空(未分类)，财务放行前会被 '
    'requireClassifiedSalesPaymentType 拦截要求补选；不代表定金已到账';
