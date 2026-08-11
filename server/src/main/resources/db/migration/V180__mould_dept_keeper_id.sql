-- =====================================================================
-- V180：模具主档加 department_id / keeper_id（对齐生产计划单）
-- =====================================================================
-- 目的：模具的「车间」(place)、「保管人」(keeper) 原为纯文本列（源老库 B_Mould.Place /
--   summary 的人名/车间名）。现加 id 关联列，对齐生产计划单（V55 department_id+workshop_name
--   并存、V82 纯 ALTER ADD UUID）的「id + 文本名双列」模式：
--   * 新数据：前端 picker 落 department_id / keeper_id，后端按 id 解析名回写 place/keeper 文本列。
--   * 老数据：按 name 回填 id（部门命中率高——注塑车间等是 V07 种子部门；员工命中率中低），
--     未命中留 NULL，靠 place/keeper 文本兜底显示。
--   * 跨模块不建 FK（契约§一：各模块 DDL 互不 FK，跨模块联动在 Service 层）。
--   * 现有 facets/筛选按 place 文本聚合（MouldService.FACET_COLUMNS），保留文本列 → 零改造。
--
-- 幂等：回填带 `xx_id IS NULL` 守卫，重跑不覆盖；ALTER 在已存在列上会由 Flyway 失败提示（不应用两次）。
-- 事务性 DDL，失败整笔回滚。详见 docs/数据迁移/05-模具资料-新库与迁移.md。
-- =====================================================================

ALTER TABLE moulds ADD COLUMN department_id UUID;
ALTER TABLE moulds ADD COLUMN keeper_id     UUID;

CREATE INDEX idx_moulds_department ON moulds(department_id);
CREATE INDEX idx_moulds_keeper     ON moulds(keeper_id);

COMMENT ON COLUMN moulds.department_id IS '车间部门 id（departments.id，对齐生产计划单；place 文本作 fallback 显示，跨模块不建 FK）';
COMMENT ON COLUMN moulds.keeper_id     IS '保管人员工 id（employees.id，对齐生产计划单；keeper 文本作 fallback 显示，跨模块不建 FK）';

-- ====================== 老数据回填：place（车间名）→ departments.name ======================
-- 注塑车间/五金铜柱/机械加工/装配/ESD电子智造/电力轨道 6 个车间均为 V07 种子部门（parent=DEPT_PROD），
-- moulds.place 文本可与 departments.name 精确匹配，命中率高。DISTINCT ON 防重名取确定一行。
UPDATE moulds m SET department_id = x.id
FROM (
    SELECT DISTINCT ON (name) id, name
    FROM departments WHERE is_deleted = false
    ORDER BY name, id
) x
WHERE m.department_id IS NULL
  AND m.is_deleted = false
  AND m.place IS NOT NULL
  AND x.name = m.place;

-- ====================== 老数据回填：keeper（保管人名）→ employees.full_name ======================
-- moulds.keeper 是 B_Mould.summary 的人名自由文本，与 employees 无 legacy_id 对齐通路，仅按 full_name
-- 匹配；重名/空白/异写命中不上 → 留 NULL（靠 keeper 文本兜底）。DISTINCT ON 防重名取确定一行。
UPDATE moulds m SET keeper_id = x.id
FROM (
    SELECT DISTINCT ON (full_name) id, full_name
    FROM employees WHERE is_deleted = false
    ORDER BY full_name, id
) x
WHERE m.keeper_id IS NULL
  AND m.is_deleted = false
  AND m.keeper IS NOT NULL
  AND x.full_name = m.keeper;
