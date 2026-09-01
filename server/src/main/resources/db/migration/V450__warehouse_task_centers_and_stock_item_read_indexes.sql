-- V450: 仓库任务中心重组 + 库存详情页读路径索引。
--
-- 页面重组（前端 /warehouse/tasks/{outbound|inbound|draw} 与 /stock/item/:goodsId）
-- 不新增任何业务权限码，只把既有仓库/库存权限登记到 4 个新的页面权限面：
--   warehouse.outbound-tasks  出库任务中心（销售出库作业 + 委外出仓 + 其它/产成品出库单据）
--   warehouse.inbound-tasks   入库任务中心（预计到货/到货异常 + 采购/委外收货历史 + 产成品入库）
--   warehouse.draw-tasks      生产领料任务中心（履约待领 + 领料单 + 生产退料）
--   warehouse.stock-item      库存详情（即时库存双击进入：余额/流水/受控调整）
-- 本迁移不给任何部门/角色/个人授予权限；可见性仍由权限管理员显式授权决定。
--
-- 性能部分针对大数据量下的常驻读路径（角标轮询 + 库存详情按货品聚合）补覆盖/部分索引，
-- 不改写任何既有行、不改查询语义；老数据全部兼容（NULL/历史值不参与部分索引谓词）。

-- ---------------------------------------------------------------------------
-- 1) 页面权限面
-- ---------------------------------------------------------------------------

INSERT INTO permission_surfaces
    (id, surface_key, name, sort_order, enabled)
VALUES
    ('45000000-0000-4000-8000-000000000087',
     'warehouse.outbound-tasks', '出库任务中心', 87, TRUE),
    ('45000000-0000-4000-8000-000000000088',
     'warehouse.inbound-tasks', '入库任务中心', 88, TRUE),
    ('45000000-0000-4000-8000-000000000089',
     'warehouse.draw-tasks', '生产领料任务中心', 89, TRUE),
    ('45000000-0000-4000-8000-000000000090',
     'warehouse.stock-item', '库存详情', 90, TRUE)
ON CONFLICT (surface_key) DO NOTHING;

-- 面与权限的精确目录（exact_codes 精确匹配 + code_prefixes 前缀展开，V328 同构）。
CREATE TEMP TABLE v450_surface_permission_rules (
    surface_key VARCHAR(128) NOT NULL,
    exact_codes TEXT[] NOT NULL,
    code_prefixes TEXT[] NOT NULL,
    PRIMARY KEY (surface_key)
) ON COMMIT DROP;

INSERT INTO v450_surface_permission_rules VALUES
    ('warehouse.outbound-tasks',
     ARRAY[
         'sales_shipment:warehouse-work',
         'subcontract_outbound:view',
         'stock_doc:view'
     ],
     ARRAY['subcontract_outbound:', 'stock_doc:']),
    ('warehouse.inbound-tasks',
     ARRAY[
         'warehouse_inbound:view',
         'warehouse_inbound:stock_in',
         'warehouse_purchase_receipt_history:view',
         'warehouse_subcontract_receipt_history:view',
         'stock_doc:view'
     ],
     ARRAY['stock_doc:']),
    ('warehouse.draw-tasks',
     ARRAY['stock_doc:view'],
     ARRAY['stock_doc:']),
    ('warehouse.stock-item',
     ARRAY['stock:view', 'stock:balance:adjust'],
     ARRAY[]::TEXT[]);

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM v450_surface_permission_rules rule
JOIN permission_surfaces surface
  ON surface.surface_key = rule.surface_key
JOIN permissions permission
  ON permission.code = ANY (rule.exact_codes)
  OR EXISTS (
      SELECT 1
      FROM unnest(rule.code_prefixes) AS code_prefix(value)
      WHERE left(permission.code, length(code_prefix.value)) = code_prefix.value
  )
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- 目录完整性守卫：任一登记码缺失（被改名/下线）即中止，不允许半套权限面上线。
DO $$
DECLARE
    missing TEXT;
BEGIN
    SELECT string_agg(required.code, ', ' ORDER BY required.code)
    INTO missing
    FROM (VALUES
        ('sales_shipment:warehouse-work'),
        ('subcontract_outbound:view'),
        ('warehouse_inbound:view'),
        ('warehouse_inbound:stock_in'),
        ('warehouse_purchase_receipt_history:view'),
        ('warehouse_subcontract_receipt_history:view'),
        ('stock_doc:view'),
        ('stock:view'),
        ('stock:balance:adjust')
    ) AS required(code)
    LEFT JOIN permissions permission
      ON permission.code = required.code AND permission.active = TRUE
    WHERE permission.id IS NULL;

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'V450 missing active permissions: %', missing;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM permission_surfaces surface
        WHERE surface.surface_key IN (
            'warehouse.outbound-tasks', 'warehouse.inbound-tasks',
            'warehouse.draw-tasks', 'warehouse.stock-item')
          AND NOT EXISTS (
              SELECT 1
              FROM permission_surface_permissions link
              WHERE link.surface_id = surface.id
          )
    ) THEN
        RAISE EXCEPTION 'V450 surface registered without any permission link';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2) 读路径性能索引
-- ---------------------------------------------------------------------------

-- 出库任务中心/工作台角标 60s 轮询 countPendingWarehouseWork()：
-- 财务已放行且仓库作业未完结的放行单是小集合，部分索引使计数走 index-only scan。
-- （软删列是 SoftDeletableEntity 的 is_deleted，不是 JPA 字段名 deleted。）
CREATE INDEX idx_sales_shipments_warehouse_pending
    ON sales_shipments (warehouse_work_status)
    WHERE finance_audit = 1
      AND rejected = FALSE
      AND is_deleted = FALSE
      AND warehouse_work_status IN (
          'LEGACY_PENDING', 'PENDING_PICK', 'PICKING', 'PICKED', 'EXCEPTION');

-- 库存详情页按货品看流水（goods_id + 默认时间倒序），替代单列 goods_id 索引的排序开销。
CREATE INDEX idx_stock_movements_goods_date
    ON stock_movements (goods_id, transaction_date DESC);

-- 库存详情页按货品聚合余额：覆盖索引免回表。
CREATE INDEX idx_stock_balances_goods_cover
    ON stock_balances (goods_id)
    INCLUDE (warehouse_id, color_id, qty, weight, last_movement_date);

COMMENT ON INDEX idx_sales_shipments_warehouse_pending IS
    'Pending warehouse sales-outbound tasks (badge poll + outbound task center)';
COMMENT ON INDEX idx_stock_movements_goods_date IS
    'Stock item detail: movement history by goods, newest first';
COMMENT ON INDEX idx_stock_balances_goods_cover IS
    'Stock item detail: per-warehouse/color balance aggregation by goods';
