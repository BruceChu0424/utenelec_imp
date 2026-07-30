-- =====================================================================
-- V85：货品归属授权（外贸系列按员工隔离可见）
-- =====================================================================
-- 背景：老库外贸货品按业务员建分类子树（成品→外贸系列(1胡钟炎)/外贸订单(2小苏/3刘炎勇)、
--   物料→外贸物料(胡钟炎/刘炎勇/小苏)），产品是专门给该员工的客户设计的，
--   其他业务员不应在筛选处看到。
-- 设计：
-- ① goods.owner_employee_id：归属业务员（NULL=公共货品，全员可见）。
--    老库子树→人 的映射由 migrate_goods_owner.sql 按分类闭包灌入（冪等 UPDATE）。
-- ② 新权限点 goods:view:all「查看全部归属货品（外贸）」：
--    默认规则 = 归属货品仅归属人本人可见；持此点者（销售管理/跟单支持等）可见全部。
--    超管恒有全部权限；默认不回填任何部门（最小授权，由权限管理页按需配置）。
-- 服务端强制（GoodsService.list/facets），前端零改动（行级过滤，筛选处自然只剩自己的）。
-- =====================================================================

ALTER TABLE goods
    ADD COLUMN IF NOT EXISTS owner_employee_id UUID REFERENCES employees(id);
CREATE INDEX IF NOT EXISTS idx_goods_owner ON goods(owner_employee_id) WHERE owner_employee_id IS NOT NULL;

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('goods:view:all', '查看全部归属货品（外贸）', '主数据', 22)
ON CONFLICT (code) DO NOTHING;
