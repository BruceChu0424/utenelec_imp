-- =====================================================================
-- V233：对象级授权（按负责人 maker_id 隔离）— 采购/委外/生产/库存 + 查看全部权限点
-- =====================================================================
-- 背景：2026-08-07 权限审计「范围 B」NO-GO。销售已有完整 owner 隔离(V91
--   SalesDocumentAccessPolicy)；采购/委外/生产/库存此前只有粗粒度 :view/:edit，
--   任何持 :view 者可看全模块全部单据。本迁移补齐「查看全部」权限点 + 部门授权 +
--   数据范围委托 scope 放开 + maker_id 列表过滤索引。
--
-- 归属列 = maker_id（4 模块所有单据表已有，create 即填当前员工，无需加列/回填）。
--   老数据 maker_id 为 NULL → 公共可读、普通用户不可写（同销售范式）。
--   采购/委外「申请」是计划系统生成的只读需求单，不接入隔离（不在本迁移索引/授权范围）。
--
-- 业务决策（已确认）：严格按人隔离；普通员工只看自己制单的；持 *:view:all/超管看全部。
--   GM 得全部 4 个；财务得 purchase/subcontract/stock_doc；QA 得 purchase/subcontract。
--   production_plan/stock_doc 额外授予作业部门（车间/仓库须全见，否则断作业）。
--
-- 注：V228 module/category 两级分类是一次性 UPDATE，已应用；本迁移 INSERT 必须带 module 列，
--   否则新权限点落入「其他」兜底。授权页目录后端动态下发，前端零改。
-- =====================================================================

-- ---------------------------------------------------------------------
-- ① 4 个「查看全部」权限点（带 module/category，照 V227 ON CONFLICT DO UPDATE 幂等）
-- ---------------------------------------------------------------------
INSERT INTO permissions (code, name, module, category, sort_order) VALUES
    ('purchase:view:all',        '查看全部采购单据', '采购管理', '采购报表', 280),
    ('subcontract:view:all',     '查看全部委外单据', '委外管理', '委外报表', 280),
    ('production_plan:view:all', '查看全部生产单据', '生产管理', '生产计划', 280),
    ('stock_doc:view:all',       '查看全部仓库单据', '仓库管理', '仓库单据', 280)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order;

-- ---------------------------------------------------------------------
-- ② 部门默认授权（V212 已应用不可改；本迁移追加。ON CONFLICT DO NOTHING 幂等）
--   采购/委外：严格隔离 → 仅 GM/财务/QA（跨部门监管）。作业人员 own 自己的单。
--   生产计划：计划 maker=计划员但车间执行 → 作业部门须全见。
--   仓库单据：仓库须看全部流水（含生产自动生成）。
-- ---------------------------------------------------------------------

-- purchase:view:all → GM, DEPT_FIN, DEPT_QA
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d CROSS JOIN permissions p
WHERE p.code = 'purchase:view:all'
  AND d.code IN ('GM', 'DEPT_FIN', 'DEPT_QA')
  AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- subcontract:view:all → GM, DEPT_FIN, DEPT_QA
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d CROSS JOIN permissions p
WHERE p.code = 'subcontract:view:all'
  AND d.code IN ('GM', 'DEPT_FIN', 'DEPT_QA')
  AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- production_plan:view:all → GM, DEPT_PROD(车间继承), DEPT_ENG, SUB_PLAN(计划)
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d CROSS JOIN permissions p
WHERE p.code = 'production_plan:view:all'
  AND d.code IN ('GM', 'DEPT_PROD', 'DEPT_ENG', 'SUB_PLAN')
  AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- stock_doc:view:all → GM, DEPT_FIN, SUB_WH(仓库)
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d CROSS JOIN permissions p
WHERE p.code = 'stock_doc:view:all'
  AND d.code IN ('GM', 'DEPT_FIN', 'SUB_WH')
  AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- ③ user_data_scopes.scope CHECK 放开 4 个新模块（照 V91:22-24）
--   委托机制复用：管理员可授权「某用户看+改某归属人的本模块单据」(user_data_scopes
--   的 visibleOwners 同时影响 canRead 和 canWrite)。
-- ---------------------------------------------------------------------
ALTER TABLE user_data_scopes DROP CONSTRAINT IF EXISTS user_data_scopes_scope_check;
ALTER TABLE user_data_scopes ADD CONSTRAINT user_data_scopes_scope_check
    CHECK (scope IN ('goods', 'client', 'sales',
                     'purchase', 'subcontract', 'production_plan', 'stock_doc'));

-- ---------------------------------------------------------------------
-- ④ maker_id 部分索引（照 V91:17-20，加速 list 的 owner 过滤；仅隔离的单据表）
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_purchase_orders_maker   ON purchase_orders(maker_id)   WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_purchase_receipts_maker ON purchase_receipts(maker_id) WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_purchase_returns_maker  ON purchase_returns(maker_id)  WHERE maker_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_subcontract_orders_maker           ON subcontract_orders(maker_id)           WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_subcontract_inquiries_maker        ON subcontract_inquiries(maker_id)        WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_subcontract_material_issues_maker  ON subcontract_material_issues(maker_id)  WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_subcontract_material_returns_maker ON subcontract_material_returns(maker_id) WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_subcontract_receipts_maker         ON subcontract_receipts(maker_id)         WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_subcontract_returns_maker          ON subcontract_returns(maker_id)          WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_subcontract_wastes_maker           ON subcontract_wastes(maker_id)           WHERE maker_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_production_plans_maker        ON production_plans(maker_id)        WHERE maker_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_production_daily_reports_maker ON production_daily_reports(maker_id) WHERE maker_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_stock_documents_maker ON stock_documents(maker_id) WHERE maker_id IS NOT NULL;
