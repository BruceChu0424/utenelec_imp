-- V423：下线货品「生产 BOM 策略」与计划级 BOM 例外放行。
--
-- 背景：系统不再以主档策略强制维护 BOM。无 BOM 货品进入物料分析后按「直接自制」
-- 投产：有 BOM → 展开子层级物料并做齐套检查；无 BOM → 无物料需求，可直接生成
-- 计划与 ZERO_MATERIAL 执行分段（原因 DIRECT_MAKE，证据 = 物料分析事实）。
-- 历史证据列 zero_material_exception_reason / zero_material_authorized_by 与
-- production_execution_segments 的 CHECK 约束保留不动，存量 PLAN_BOM_OVERRIDE
-- 执行段继续可读可审计；新段不再产生该原因。

-- 1) 先重写执行段证据触发器：剥离对 goods.production_bom_policy 与
--    production_plans.bom_override_* 的引用（列删除后旧函数会在运行期崩溃）。
--    DIRECT_MAKE 只要求计划挂有与段一致的物料分析事实；
--    PLAN_BOM_OVERRIDE 不再允许新建（历史行不受 INSERT 守卫影响）。
CREATE OR REPLACE FUNCTION fn_guard_execution_segment_requirement_shape()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.material_requirement_mode = 'ZERO_MATERIAL'
       AND NEW.status = 'WAITING' THEN
        RAISE EXCEPTION 'zero-material execution segment must start READY'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_zero_ready_guard';
    END IF;
    IF TG_OP = 'INSERT'
       AND NEW.material_requirement_mode = 'ZERO_MATERIAL'
       AND NOT (
           (
               NEW.zero_material_reason = 'DIRECT_MAKE'
               AND EXISTS (
                   SELECT 1
                   FROM production_plans plan
                   WHERE plan.id = NEW.plan_id
                     AND plan.is_deleted = FALSE
                     AND plan.material_analysis_id =
                         NEW.zero_material_analysis_id
               )
           )
           OR
           (
               NEW.zero_material_reason = 'NO_PRODUCTION_HARD_GATE'
               AND EXISTS (
                   SELECT 1
                   FROM goods_bom_items bom
                   WHERE bom.goods_id = NEW.product_goods_id
                     AND bom.is_deleted = FALSE
               )
               AND NOT EXISTS (
                   SELECT 1
                   FROM goods_bom_items bom
                   WHERE bom.goods_id = NEW.product_goods_id
                     AND bom.is_deleted = FALSE
                     AND bom.hard_gate = TRUE
                     AND bom.control_stage IN (
                         'START', 'ASSEMBLY', 'FINISH')
               )
           )
       ) THEN
        RAISE EXCEPTION 'zero-material evidence does not match the plan/BOM facts'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_zero_evidence_guard';
    END IF;
    IF TG_OP = 'UPDATE'
       AND (
           OLD.material_requirement_mode
               IS DISTINCT FROM NEW.material_requirement_mode
           OR OLD.zero_material_reason
               IS DISTINCT FROM NEW.zero_material_reason
           OR OLD.zero_material_analysis_id
               IS DISTINCT FROM NEW.zero_material_analysis_id
           OR OLD.zero_material_exception_reason
               IS DISTINCT FROM NEW.zero_material_exception_reason
           OR OLD.zero_material_authorized_by
               IS DISTINCT FROM NEW.zero_material_authorized_by
       ) THEN
        RAISE EXCEPTION 'execution segment material requirement shape is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT =
                      'production_execution_segment_requirement_immutable_guard';
    END IF;
    RETURN NEW;
END;
$$;

-- 2) 生产计划：删除计划级 BOM 例外放行列（机制整体下线）。
ALTER TABLE production_plans
    DROP CONSTRAINT IF EXISTS production_plan_bom_override_shape_chk,
    DROP COLUMN IF EXISTS bom_override_reason,
    DROP COLUMN IF EXISTS bom_override_by;

-- 3) 货品主档：删除生产 BOM 策略列（含 V234 回填与 CHECK 约束）。
ALTER TABLE goods
    DROP CONSTRAINT IF EXISTS goods_production_bom_policy_chk,
    DROP COLUMN IF EXISTS production_bom_policy;

-- 4) 权限清理：无 BOM 生产例外放行、待排产 BOM 缺失转发研发，随机制一并下线。
DELETE FROM permission_surface_permissions
WHERE permission_id IN (
    SELECT id FROM permissions
    WHERE code IN (
        'production_material_analysis:bom_override',
        'production_plan:forward_rd'));

DELETE FROM user_permission_overrides
WHERE permission_id IN (
    SELECT id FROM permissions
    WHERE code IN (
        'production_material_analysis:bom_override',
        'production_plan:forward_rd'));

DELETE FROM manager_permission_delegations
WHERE permission_id IN (
    SELECT id FROM permissions
    WHERE code IN (
        'production_material_analysis:bom_override',
        'production_plan:forward_rd'));

DELETE FROM role_permissions
WHERE permission_id IN (
    SELECT id FROM permissions
    WHERE code IN (
        'production_material_analysis:bom_override',
        'production_plan:forward_rd'));

DELETE FROM department_permissions
WHERE permission_id IN (
    SELECT id FROM permissions
    WHERE code IN (
        'production_material_analysis:bom_override',
        'production_plan:forward_rd'));

DELETE FROM permissions
WHERE code IN (
    'production_material_analysis:bom_override',
    'production_plan:forward_rd');
