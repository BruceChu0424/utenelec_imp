-- V645 ADR-104 追加自制并入未开工的生产计划
--
-- 背景：物料分析准备页追加自制(顶层产品行、自制子件锚点、要先自制目标件的委外锚点)时，
-- 每追加一次就新建一张生产计划。用户口径(2026-09-22)「自制的追加，生产车间没有去领料
-- 开工的前提下应该自动合并；如果已经开始执行了就创建新的单据」——与采购/委外的 V640
-- 「未订货的申请明细就地追加」同一条纪律。
--
-- 本迁移只新增四个判定函数 + 一条对账触发器，并锚点补丁三个身份守卫，只在「计划仍未
-- 开工」时放开**只增不减**的改量：计划明细 qty、计划关联行 submitted_qty / public_surplus_qty、
-- 以及作为供给来源被钉住的计划明细 qty。其余身份列与生命周期约束一个字节不动。
-- 执行段本身不改量：追加量在同一个 CONFIRMED 计划包里另起一段(与拆批同形态)，
-- 原执行段、冻结的物料需求、预留与备料单一字不动。
--
-- 「未开工」= 计划未删除/未取消/未中止/未结案、草稿或已审核、恰一条计划明细且完工/
-- 入库/封顶累计全 0、没有报工、没有拆批；已审核时必须有且只有一个 CONFIRMED 计划包，
-- 包里每一段仍是 WAITING/READY，每张备料单(DRAW)仍是未审核、未发料、未删除的草稿。
-- 与 ProductionPlanningPackageService.closeExecutionSegments / closeDraw 撤销计划包的判据同源。
--
-- 补丁方式沿用 V580/V588/V589/V640 纪律：取函数定义、行尾归一 LF、锚点不中宁可失败。

CREATE OR REPLACE FUNCTION fn_material_analysis_plan_growable(p_plan UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM production_plans plan
        WHERE plan.id = p_plan
          AND plan.material_analysis_id IS NOT NULL
          AND plan.material_analysis_item_id IS NOT NULL
          AND plan.is_deleted = FALSE
          AND COALESCE(plan.is_canceled, FALSE) = FALSE
          AND COALESCE(plan.is_stopped, FALSE) = FALSE
          AND COALESCE(plan.is_closed, FALSE) = FALSE
          AND plan.status IN (0, 1)
          AND (SELECT COUNT(*) FROM production_plan_items item
               WHERE item.plan_id = plan.id AND item.is_deleted = FALSE) = 1
          AND NOT EXISTS (
              SELECT 1 FROM production_plan_items item
              WHERE item.plan_id = plan.id
                AND item.is_deleted = FALSE
                AND (COALESCE(item.iqty, 0) <> 0
                     OR COALESCE(item.fqty, 0) <> 0
                     OR COALESCE(item.capped_qty, 0) <> 0))
          AND NOT EXISTS (
              SELECT 1
              FROM production_execution_segments segment
              WHERE segment.plan_id = plan.id
                AND segment.is_deleted = FALSE
                AND segment.status NOT IN ('WAITING', 'READY'))
          AND NOT EXISTS (
              SELECT 1
              FROM production_execution_segments segment
              JOIN production_execution_segment_splits split
                ON split.source_segment_id = segment.id
              WHERE segment.plan_id = plan.id)
          AND NOT EXISTS (
              SELECT 1
              FROM production_execution_segments segment
              JOIN production_daily_report_items report
                ON report.execution_segment_id = segment.id
              WHERE segment.plan_id = plan.id)
          AND NOT EXISTS (
              SELECT 1
              FROM production_planning_packages package
              JOIN production_planning_package_documents document
                ON document.package_id = package.id
               AND document.document_type = 'DRAW'
              JOIN stock_documents draw
                ON draw.id = document.document_id
              WHERE package.plan_id = plan.id
                AND package.is_deleted = FALSE
                AND (draw.is_deleted
                     OR draw.status <> 0
                     OR EXISTS (
                         SELECT 1 FROM stock_document_items item
                         WHERE item.doc_id = draw.id
                           AND COALESCE(item.issued_qty, 0) > 0)))
          AND (plan.status = 0
               OR (SELECT COUNT(*) FROM production_planning_packages package
                   WHERE package.plan_id = plan.id
                     AND package.is_deleted = FALSE
                     AND package.status = 'CONFIRMED'
                     AND package.execution_model_version = 1) = 1)
    )
$$;

COMMENT ON FUNCTION fn_material_analysis_plan_growable(UUID) IS
    'ADR-104：物料分析生成的生产计划是否仍未开工(草稿或已审核、恰一条明细且累计全 0、没有报工/拆批、每段仍 WAITING/READY、备料单仍是未审核未发料的草稿)，追加自制并入原计划的前提';

-- 计划明细的这次 UPDATE 是否就是并入追加：只增不减、封顶量不动、计划仍未开工。
CREATE OR REPLACE FUNCTION fn_is_material_analysis_plan_item_growth(
    p_item UUID, p_before NUMERIC, p_after NUMERIC, p_old_cap NUMERIC, p_new_cap NUMERIC)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT p_before IS NOT NULL
       AND p_after IS NOT NULL
       AND p_after > p_before
       AND COALESCE(p_old_cap, 0) = COALESCE(p_new_cap, 0)
       AND EXISTS (
           SELECT 1 FROM production_plan_items item
           WHERE item.id = p_item
             AND fn_material_analysis_plan_growable(item.plan_id))
$$;

COMMENT ON FUNCTION fn_is_material_analysis_plan_item_growth(UUID, NUMERIC, NUMERIC, NUMERIC, NUMERIC) IS
    'ADR-104：物料分析计划明细 qty 只增不减且计划仍未开工时，身份守卫放行这次改量';

-- 计划关联行的这次 UPDATE 是否就是并入追加：状态不变(SUBMITTED/APPROVED)、归需求量与公共
-- 备货量都只增不减且至少一个真的变大、计划仍未开工、计划明细已先改到「归需求 + 公共」之和。
CREATE OR REPLACE FUNCTION fn_is_material_analysis_plan_link_growth(
    p_plan UUID, p_old_status TEXT, p_new_status TEXT,
    p_old_submitted NUMERIC, p_new_submitted NUMERIC,
    p_old_surplus NUMERIC, p_new_surplus NUMERIC)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT p_old_status = p_new_status
       AND p_new_status IN ('SUBMITTED', 'APPROVED')
       AND COALESCE(p_new_submitted, 0) >= COALESCE(p_old_submitted, 0)
       AND COALESCE(p_new_surplus, 0) >= COALESCE(p_old_surplus, 0)
       AND (COALESCE(p_new_submitted, 0) > COALESCE(p_old_submitted, 0)
            OR COALESCE(p_new_surplus, 0) > COALESCE(p_old_surplus, 0))
       AND fn_material_analysis_plan_growable(p_plan)
       AND EXISTS (
           SELECT 1 FROM production_plan_items item
           WHERE item.plan_id = p_plan
             AND item.is_deleted = FALSE
             AND item.qty = COALESCE(p_new_submitted, 0) + COALESCE(p_new_surplus, 0))
$$;

COMMENT ON FUNCTION fn_is_material_analysis_plan_link_growth(UUID, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, NUMERIC) IS
    'ADR-104：计划关联行 submitted_qty / public_surplus_qty 只增不减、状态不变、计划未开工且明细已改到两者之和时，身份守卫放行这次改量';

-- 作为供给来源被钉住的计划明细(V162/V503 生产联动守卫)：只动 qty(与审计列)、只增不减、计划仍未开工。
CREATE OR REPLACE FUNCTION fn_is_material_analysis_plan_item_supply_growth(p_table TEXT, p_old JSONB, p_new JSONB)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT p_table = 'production_plan_items'
       AND (p_old - ARRAY['qty', 'updated_at', 'updated_by'])
           IS NOT DISTINCT FROM (p_new - ARRAY['qty', 'updated_at', 'updated_by'])
       AND (p_new->>'qty')::numeric > (p_old->>'qty')::numeric
       AND fn_material_analysis_plan_growable((p_old->>'plan_id')::uuid)
$$;

COMMENT ON FUNCTION fn_is_material_analysis_plan_item_supply_growth(TEXT, JSONB, JSONB) IS
    'ADR-104：被生产供给钉住的物料分析计划明细只增 qty 且计划未开工时，生产联动守卫放行这次改量';

-- ⓪ 计划明细身份守卫(V234 建、V614 版)：qty 改量除日报定稿封顶外，再放行「并入追加」。
DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    anchor TEXT := 'OR (OLD.qty IS DISTINCT FROM NEW.qty AND NOT fn_is_daily_report_plan_target_change(OLD.id,OLD.qty,NEW.qty,OLD.capped_qty,NEW.capped_qty))';
    replacement TEXT := 'OR (OLD.qty IS DISTINCT FROM NEW.qty AND NOT fn_is_daily_report_plan_target_change(OLD.id,OLD.qty,NEW.qty,OLD.capped_qty,NEW.capped_qty) AND NOT fn_is_material_analysis_plan_item_growth(OLD.id,OLD.qty,NEW.qty,OLD.capped_qty,NEW.capped_qty))';
BEGIN
    SELECT pg_get_functiondef('fn_guard_material_analysis_plan_item_identity()'::regprocedure)
    INTO definition;
    IF definition IS NULL THEN
        RAISE EXCEPTION 'V645 analysis plan item identity guard missing' USING ERRCODE = '23514';
    END IF;
    normalized := replace(definition, E'\r\n', E'\n');
    IF (length(normalized) - length(replace(normalized, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V645 analysis plan item identity guard shape changed' USING ERRCODE = '23514';
    END IF;
    patched := replace(normalized, anchor, replacement);
    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V645 cannot relax the analysis plan item identity guard safely' USING ERRCODE = '23514';
    END IF;
    EXECUTE patched;
END;
$patch$;

-- ① 计划关联行数量同步触发器(V490 建、V577 版)：submitted_qty / public_surplus_qty 在「并入追加」时放行；
--    UPDATE 分支原本就按 OLD/NEW 的差额回写分析行的 submitted_qty / approved_qty，这里只放开身份断言。
DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    anchor TEXT := E'        OR OLD.submitted_qty IS DISTINCT FROM NEW.submitted_qty\n        OR OLD.public_surplus_qty IS DISTINCT FROM NEW.public_surplus_qty\n';
    replacement TEXT := E'        OR ((OLD.submitted_qty IS DISTINCT FROM NEW.submitted_qty\n             OR OLD.public_surplus_qty IS DISTINCT FROM NEW.public_surplus_qty)\n            AND NOT fn_is_material_analysis_plan_link_growth(OLD.plan_id, OLD.allocation_status, NEW.allocation_status,\n                    OLD.submitted_qty, NEW.submitted_qty, OLD.public_surplus_qty, NEW.public_surplus_qty))\n';
BEGIN
    SELECT pg_get_functiondef('fn_sync_material_analysis_plan_link_qty()'::regprocedure)
    INTO definition;
    IF definition IS NULL THEN
        RAISE EXCEPTION 'V645 analysis plan link qty guard missing' USING ERRCODE = '23514';
    END IF;
    normalized := replace(definition, E'\r\n', E'\n');
    IF (length(normalized) - length(replace(normalized, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V645 analysis plan link qty guard shape changed' USING ERRCODE = '23514';
    END IF;
    patched := replace(normalized, anchor, replacement);
    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V645 cannot relax the analysis plan link qty guard safely' USING ERRCODE = '23514';
    END IF;
    EXECUTE patched;
END;
$patch$;

-- ② 生产联动的供给来源守卫(V503 版、V640 已补一处)：被钉住的计划明细在「并入追加」时放行 qty 只增。
DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    anchor TEXT := E'       OR fn_is_preplan_supply_line_growth(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW))) THEN RETURN NEW; END IF;';
    replacement TEXT := E'       OR fn_is_preplan_supply_line_growth(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW))\n       OR fn_is_material_analysis_plan_item_supply_growth(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW))) THEN RETURN NEW; END IF;';
BEGIN
    SELECT pg_get_functiondef('fn_guard_production_supply_source_item()'::regprocedure)
    INTO definition;
    IF definition IS NULL THEN
        RAISE EXCEPTION 'V645 production supply source item guard missing' USING ERRCODE = '23514';
    END IF;
    normalized := replace(definition, E'\r\n', E'\n');
    IF (length(normalized) - length(replace(normalized, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V645 production supply source item guard shape changed' USING ERRCODE = '23514';
    END IF;
    patched := replace(normalized, anchor, replacement);
    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V645 cannot relax the production supply source item guard safely' USING ERRCODE = '23514';
    END IF;
    EXECUTE patched;
END;
$patch$;

-- ③ 对账：放开改量之后，「计划明细 qty(+封顶量) = 关联行 归需求 + 公共备货」这条原本只在关联行
--    INSERT 时检查的守恒，改为在事务提交时对每一次 qty 改量都检查(日报定稿封顶 qty+capped 守恒，
--    并入追加两边同增，两条路都满足；其它改量早被 ⓪ 拒绝)。
CREATE OR REPLACE FUNCTION fn_check_material_analysis_plan_item_link_qty()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM production_plans plan
        WHERE plan.id = NEW.plan_id
          AND plan.material_analysis_id IS NOT NULL
    ) AND NOT EXISTS (
        SELECT 1
        FROM production_material_analysis_plan_links link
        WHERE link.plan_id = NEW.plan_id
          AND link.submitted_qty + COALESCE(link.public_surplus_qty, 0)
              = COALESCE(NEW.qty, 0) + COALESCE(NEW.capped_qty, 0)
    ) THEN
        RAISE EXCEPTION 'material-analysis plan item quantity must equal its plan link submitted + public surplus'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'material_analysis_plan_item_link_qty_guard';
    END IF;
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION fn_check_material_analysis_plan_item_link_qty() IS
    'ADR-104：物料分析计划明细 qty 改量后，提交时核对 qty + capped_qty = 关联行 submitted_qty + public_surplus_qty';

CREATE CONSTRAINT TRIGGER trg_check_material_analysis_plan_item_link_qty
    AFTER UPDATE OF qty ON production_plan_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.qty IS DISTINCT FROM NEW.qty)
    EXECUTE FUNCTION fn_check_material_analysis_plan_item_link_qty();

COMMENT ON FUNCTION fn_guard_material_analysis_plan_item_identity() IS
    '物料分析计划明细身份与数量不可变；V614 例外：日报定稿封顶(qty+capped_qty 守恒)；V645 例外：计划未开工时追加并入只增不减(ADR-104)';
COMMENT ON FUNCTION fn_sync_material_analysis_plan_link_qty() IS
    '物料分析计划关联行只追加不删、身份不可变并回写分析行 submitted/approved；V645 例外：计划未开工时 submitted_qty / public_surplus_qty 只增不减(ADR-104)';
