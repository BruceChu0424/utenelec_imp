-- =====================================================================
-- V251：货品批量导入 + 一键撤回
-- =====================================================================
-- 背景：
--   货品资料此前无导入功能（全项目仅导出，无任何导入/上传解析）。新增「上传 .xlsx →
--   先检测后导入」两段式导入：缺分类/颜色/单位自动新建、编号重复拦死不覆盖、导入错了
--   按批次一键撤回。
--
-- 数据模型：
--   * goods_import_batches：每次导入一个批次（撤回入口按最近批次）。
--   * goods_import_creations：本批次新建的每一类实体（货品/分类/颜色/单位）。
--     撤回时按此表软删——只删本批次新建的，批次前已存在的分类/颜色不动（避免误删
--     把别的货品归类删飞）。
--
-- 权限：goods:import（独立权限点，跟随 goods:edit 回填授予；超管恒有）。
-- =====================================================================

-- ① 导入批次
CREATE TABLE IF NOT EXISTS goods_import_batches (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,                       -- 导入人（users.id；宽松不 FK，同其它审计列）
    filename    text,                        -- 原始文件名（仅展示/审计）
    row_count   integer NOT NULL DEFAULT 0,  -- 实际导入货品行数
    status      text NOT NULL DEFAULT 'IMPORTED'  -- IMPORTED / UNDONE
);

-- ② 本批次新建实体登记（撤回用）
CREATE TABLE IF NOT EXISTS goods_import_creations (
    batch_id     uuid NOT NULL REFERENCES goods_import_batches(id) ON DELETE CASCADE,
    entity_type  text NOT NULL,              -- GOODS / CATEGORY / COLOR / UNIT
    entity_id    uuid NOT NULL,
    PRIMARY KEY (batch_id, entity_type, entity_id)
);

COMMENT ON TABLE goods_import_batches IS '货品批量导入批次（V251；撤回入口按最近批次）';
COMMENT ON TABLE goods_import_creations IS '导入批次新建实体登记（V251；撤回时按此软删，只删本批新建）';

-- ③ 权限点 goods:import（module+category 与 goods:export 同归类，V228 范式）
INSERT INTO permissions (code, name, category, module, sort_order) VALUES
    ('goods:import', '导入货品', '货品资料', '基础资料', 22)
ON CONFLICT (code) DO NOTHING;

-- ④ 回填：导入跟随编辑（持有 goods:edit 的部门自动获得 goods:import）
INSERT INTO department_permissions (department_id, permission_id)
SELECT dp.department_id, p_import.id
FROM department_permissions dp
JOIN permissions p_edit   ON p_edit.id   = dp.permission_id
JOIN permissions p_import ON p_import.code = 'goods:import'
WHERE p_edit.code = 'goods:edit'
ON CONFLICT DO NOTHING;
