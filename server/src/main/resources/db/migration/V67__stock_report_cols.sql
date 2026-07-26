-- =====================================================================
-- V67：仓库报表所需字段补列（仓库管理 / 仓库报表）
-- =====================================================================
-- 背景：V48 建表时人员字段只留了 *_id(UUID) 且迁移留空，无 *_legacy_id 兜底，
--   导致仓库单据历史人名无法恢复（与采购 V65 / 销售 V66 不一致）。本批补回：
-- ① stock_documents 人员 *_legacy_id（worker/maker/approver）：保留老库 B_Worker.ID，
--   **等员工档案（employees）录入 legacy_id 后自动对齐**（报表 LEFT JOIN employees
--     ON e.legacy_id = o.*_legacy_id OR e.id = o.*_id）。历史单据人名暂时空显示。
--   · worker_legacy_id 在不同 doc_type 语义不同：TRANSFER/OTHER_IN=经办人、
--     DRAW=领料人(源 GetID)、WDRAW=退料人(源 ReturnID)、FINISHED_IN/OUT/CHECK=跟单员。
-- ② ass_team：老库 O_PDraw.AssTeam 装配班组（文本，非人员 FK）。
-- ③ employees.legacy_category：老库 B_Worker 子类（报表人名后显示「（子类）」标记）。
--
-- 详见 docs/数据迁移/17-仓库管理-新库与迁移.md 与计划 clever-snacking-kettle.md。
-- =====================================================================

-- ---------------- stock_documents：人员 *_legacy_id + 装配班组 ----------------
ALTER TABLE stock_documents
    ADD COLUMN IF NOT EXISTS worker_legacy_id   INT,
    ADD COLUMN IF NOT EXISTS maker_legacy_id    INT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id INT,
    ADD COLUMN IF NOT EXISTS ass_team           TEXT;

-- ---------------- employees：老库子类标记（legacy_id 由 V65 已加，此处不重复） ----------------
ALTER TABLE employees ADD COLUMN IF NOT EXISTS legacy_category TEXT;

-- ---------------- 权限点（仿 V44 purchase_report:view） ----------------
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('stock_report:view', '查看仓库报表', '库存管理', 212)
ON CONFLICT (code) DO NOTHING;

-- view 给所有部门（仓库报表内部可见，与 stock_doc:view 一致）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE p.code = 'stock_report:view' AND d.is_deleted = false
ON CONFLICT DO NOTHING;

-- ---------------- 报表过滤辅助索引（人员 legacy_id facet 筛选） ----------------
CREATE INDEX IF NOT EXISTS idx_sd_worker_lid ON stock_documents(worker_legacy_id);
CREATE INDEX IF NOT EXISTS idx_sd_maker_lid  ON stock_documents(maker_legacy_id);
CREATE INDEX IF NOT EXISTS idx_sd_approver_lid ON stock_documents(approver_legacy_id);

-- ---------------- 列注释 ----------------
COMMENT ON COLUMN stock_documents.worker_legacy_id   IS '经办/领料/退料/跟单 人→B_Worker.ID（待 employees.legacy_id 对齐回填 worker_id）';
COMMENT ON COLUMN stock_documents.maker_legacy_id    IS '制单→B_Worker.ID（待回填 maker_id）';
COMMENT ON COLUMN stock_documents.approver_legacy_id IS '审核→B_Worker.ID（待回填 approver_id）';
COMMENT ON COLUMN stock_documents.ass_team           IS '装配班组 O_PDraw.AssTeam（文本，仅 DRAW 领料用）';
COMMENT ON COLUMN employees.legacy_category          IS '老库 B_Worker 子类；报表人名后显示「（子类）」标记，HR 录入可清空';
