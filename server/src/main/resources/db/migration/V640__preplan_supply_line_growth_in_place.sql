-- V640 ADR-099 数量单一入口：未订货的申请明细就地追加
--
-- 背景：物料分析准备页改为「计划量驱动子层」后，顶层追加下达会让下层物料的
-- 「还需安排」变大。用户口径：只要采购/委外那边还没有下单(明细未订货、采购或
-- 委外部门还没动过它)，追加的量直接改到之前那张申请明细上；已经订货的才另立
-- 新申请。供给行动(preplan_supply_actions)与它的分摊行是这张申请明细的计划侧
-- 镜像，V250/V460 把外部化之后的 requested_qty / allocated_qty、V472 把公共量
-- 钉成不可变，本迁移只对「明细仍未订货」的供给行动放开**只增不减**的改量，
-- 其余身份列与生命周期约束一个字节不动。
--
-- 补丁方式沿用 V580/V588/V589 纪律：取函数定义、行尾归一 LF、锚点不中宁可失败。

-- 申请明细是否仍未被采购/委外部门动过：申请仍开着(草稿或已下达、未结案/未中止/
-- 未删除)、明细未删除、已订量为 0，且没有任何订货单来源引用它(含待财务审核的
-- 草稿订货单——那已经是「在采购」)。
CREATE OR REPLACE FUNCTION fn_preplan_external_item_unordered(p_route TEXT, p_item UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT CASE p_route
        WHEN 'BUY' THEN EXISTS (
            SELECT 1
            FROM purchase_request_items item
            JOIN purchase_requests request ON request.id = item.request_id
            WHERE item.id = p_item
              AND item.is_deleted = FALSE
              AND request.is_deleted = FALSE
              AND request.status IN (0, 1)
              AND request.is_closed = FALSE
              AND COALESCE(request.is_stopped, FALSE) = FALSE
              AND COALESCE(item.ordered_qty, 0) = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM purchase_order_item_sources source
                  JOIN purchase_order_items order_item
                    ON order_item.id = source.order_item_id
                   AND order_item.is_deleted = FALSE
                  JOIN purchase_orders header
                    ON header.id = order_item.order_id
                   AND header.is_deleted = FALSE
                  WHERE source.request_item_id = item.id))
        WHEN 'SUBCONTRACT' THEN EXISTS (
            SELECT 1
            FROM subcontract_application_items item
            JOIN subcontract_applications application ON application.id = item.application_id
            WHERE item.id = p_item
              AND item.is_deleted = FALSE
              AND application.is_deleted = FALSE
              AND application.status IN (0, 1)
              AND application.is_closed = FALSE
              AND COALESCE(item.ordered_qty, 0) = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM subcontract_order_item_sources source
                  JOIN subcontract_order_items order_item
                    ON order_item.id = source.order_item_id
                   AND order_item.is_deleted = FALSE
                  JOIN subcontract_orders header
                    ON header.id = order_item.order_id
                   AND header.is_deleted = FALSE
                  WHERE source.application_item_id = item.id))
        ELSE FALSE
    END
$$;

COMMENT ON FUNCTION fn_preplan_external_item_unordered(TEXT, UUID) IS
    'ADR-099：采购申请明细/委外申请明细是否仍未订货(申请开着、已订量 0、无订货单来源引用)，就地追加数量的前提';

-- 供给行动是否允许就地追加：外部化到采购申请/委外申请、状态仍是 CREATED、没有
-- 被别的计划转走或认领过份额，且它锚定的每一条需求明细(与公共明细)都仍未订货。
CREATE OR REPLACE FUNCTION fn_preplan_supply_action_growable(p_action UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM preplan_supply_actions action
        WHERE action.id = p_action
          AND action.operation_type = 'SUPPLY'
          AND action.status = 'CREATED'
          AND action.route IN ('BUY', 'SUBCONTRACT')
          AND action.external_document_type IN ('PURCHASE_REQUEST', 'SUBCONTRACT_APPLICATION')
          AND NOT fn_preplan_action_has_future_transfer(action.id)
          AND NOT fn_preplan_action_has_shared_claims(action.id)
          AND EXISTS (
              SELECT 1 FROM preplan_supply_action_allocations allocation
              WHERE allocation.action_id = action.id
                AND allocation.external_item_id IS NOT NULL)
          AND NOT EXISTS (
              SELECT 1 FROM preplan_supply_action_allocations allocation
              WHERE allocation.action_id = action.id
                AND allocation.external_item_id IS NOT NULL
                AND NOT fn_preplan_external_item_unordered(action.route, allocation.external_item_id))
          AND (action.public_surplus_external_item_id IS NULL
               OR fn_preplan_external_item_unordered(action.route, action.public_surplus_external_item_id))
    )
$$;

COMMENT ON FUNCTION fn_preplan_supply_action_growable(UUID) IS
    'ADR-099：供给行动锚定的申请明细仍未订货时，允许 requested_qty / public_surplus_qty / allocated_qty 只增不减地就地追加';

-- 申请明细的这次 UPDATE 是否就是就地追加：只动 qty(与审计列)、只增不减，且这条明细被某个
-- 仍可就地追加的供给行动锚定(需求明细或公共明细)。V162/V503 的生产联动守卫据此放行。
CREATE OR REPLACE FUNCTION fn_is_preplan_supply_line_growth(p_table TEXT, p_old JSONB, p_new JSONB)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT p_table IN ('purchase_request_items', 'subcontract_application_items')
       AND (p_old - ARRAY['qty', 'updated_at', 'updated_by'])
           IS NOT DISTINCT FROM (p_new - ARRAY['qty', 'updated_at', 'updated_by'])
       AND (p_new->>'qty')::numeric > (p_old->>'qty')::numeric
       AND EXISTS (
           SELECT 1
           FROM preplan_supply_actions action
           LEFT JOIN preplan_supply_action_allocations allocation
             ON allocation.action_id = action.id
           WHERE action.route = CASE p_table WHEN 'purchase_request_items' THEN 'BUY' ELSE 'SUBCONTRACT' END
             AND (allocation.external_item_id = (p_old->>'id')::uuid
                  OR action.public_surplus_external_item_id = (p_old->>'id')::uuid)
             AND fn_preplan_supply_action_growable(action.id))
$$;

COMMENT ON FUNCTION fn_is_preplan_supply_line_growth(TEXT, JSONB, JSONB) IS
    'ADR-099：申请明细只增 qty 且被仍可就地追加的供给行动锚定时，生产联动守卫放行这次改量';

-- ⓪ 申请明细的生产联动守卫(V503 版 fn_guard_production_supply_source_item)：就地追加放行。
DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    anchor TEXT := E'       OR fn_is_proven_procurement_qty_revision(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW))) THEN RETURN NEW; END IF;';
    replacement TEXT := E'       OR fn_is_proven_procurement_qty_revision(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW))\n       OR fn_is_preplan_supply_line_growth(TG_TABLE_NAME,to_jsonb(OLD),to_jsonb(NEW))) THEN RETURN NEW; END IF;';
BEGIN
    SELECT pg_get_functiondef('fn_guard_production_supply_source_item()'::regprocedure)
    INTO definition;
    IF definition IS NULL THEN
        RAISE EXCEPTION 'V640 production supply source item guard missing' USING ERRCODE = '23514';
    END IF;
    normalized := replace(definition, E'\r\n', E'\n');
    IF (length(normalized) - length(replace(normalized, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V640 production supply source item guard shape changed' USING ERRCODE = '23514';
    END IF;
    patched := replace(normalized, anchor, replacement);
    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V640 cannot relax the production supply source item guard safely' USING ERRCODE = '23514';
    END IF;
    EXECUTE patched;
END;
$patch$;

-- ① 供给行动身份守卫(V460 版)：外部化之后 requested_qty 可在「明细未订货」时只增不减。
DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    anchor TEXT := E'       OR OLD.requested_qty IS DISTINCT FROM NEW.requested_qty\n       OR OLD.external_document_type';
    replacement TEXT := E'       OR (OLD.requested_qty IS DISTINCT FROM NEW.requested_qty\n           AND NOT (NEW.requested_qty > OLD.requested_qty\n                    AND fn_preplan_supply_action_growable(OLD.id)))\n       OR OLD.external_document_type';
BEGIN
    SELECT pg_get_functiondef('fn_guard_preplan_supply_action_history()'::regprocedure)
    INTO definition;
    IF definition IS NULL THEN
        RAISE EXCEPTION 'V640 supply action history guard missing' USING ERRCODE = '23514';
    END IF;
    normalized := replace(definition, E'\r\n', E'\n');
    IF (length(normalized) - length(replace(normalized, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V640 supply action history guard shape changed' USING ERRCODE = '23514';
    END IF;
    patched := replace(normalized, anchor, replacement);
    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V640 cannot relax the supply action history guard safely' USING ERRCODE = '23514';
    END IF;
    EXECUTE patched;
END;
$patch$;

-- ② 分摊行身份守卫(V460 版)：外部化之后 allocated_qty 可在「明细未订货」时只增不减。
DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    anchor TEXT := E'       OR OLD.allocated_qty IS DISTINCT FROM NEW.allocated_qty\n       OR OLD.external_item_id IS DISTINCT FROM NEW.external_item_id';
    replacement TEXT := E'       OR (OLD.allocated_qty IS DISTINCT FROM NEW.allocated_qty\n           AND NOT (NEW.allocated_qty > OLD.allocated_qty\n                    AND fn_preplan_supply_action_growable(OLD.action_id)))\n       OR OLD.external_item_id IS DISTINCT FROM NEW.external_item_id';
BEGIN
    SELECT pg_get_functiondef('fn_guard_preplan_supply_allocation_history()'::regprocedure)
    INTO definition;
    IF definition IS NULL THEN
        RAISE EXCEPTION 'V640 supply allocation history guard missing' USING ERRCODE = '23514';
    END IF;
    normalized := replace(definition, E'\r\n', E'\n');
    IF (length(normalized) - length(replace(normalized, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V640 supply allocation history guard shape changed' USING ERRCODE = '23514';
    END IF;
    patched := replace(normalized, anchor, replacement);
    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V640 cannot relax the supply allocation history guard safely' USING ERRCODE = '23514';
    END IF;
    EXECUTE patched;
END;
$patch$;

-- ③ 公共量身份守卫(V472 版)：外部化之后 public_surplus_qty 可在「明细未订货」时只增不减；
--    原本没有公共份的行动追加公共份时，公共明细锚只能指向它自己的需求明细(合并明细形态)。
DO $patch$
DECLARE
    definition TEXT;
    normalized TEXT;
    patched TEXT;
    anchor TEXT := E'    IF OLD.external_document_id IS NOT NULL\n       AND (NEW.public_surplus_qty IS DISTINCT FROM OLD.public_surplus_qty\n            OR NEW.public_surplus_external_item_id\n                 IS DISTINCT FROM OLD.public_surplus_external_item_id\n            OR NEW.operation_type IS DISTINCT FROM OLD.operation_type';
    replacement TEXT := E'    IF OLD.external_document_id IS NOT NULL\n       AND ((NEW.public_surplus_qty IS DISTINCT FROM OLD.public_surplus_qty\n             AND NOT (NEW.public_surplus_qty > OLD.public_surplus_qty\n                      AND fn_preplan_supply_action_growable(OLD.id)))\n            OR (NEW.public_surplus_external_item_id\n                 IS DISTINCT FROM OLD.public_surplus_external_item_id\n                AND NOT (OLD.public_surplus_external_item_id IS NULL\n                         AND fn_preplan_supply_action_growable(OLD.id)\n                         AND EXISTS (\n                             SELECT 1 FROM preplan_supply_action_allocations allocation\n                             WHERE allocation.action_id = OLD.id\n                               AND allocation.external_item_id = NEW.public_surplus_external_item_id)))\n            OR NEW.operation_type IS DISTINCT FROM OLD.operation_type';
BEGIN
    SELECT pg_get_functiondef('fn_guard_preplan_public_surplus_history()'::regprocedure)
    INTO definition;
    IF definition IS NULL THEN
        RAISE EXCEPTION 'V640 public surplus history guard missing' USING ERRCODE = '23514';
    END IF;
    normalized := replace(definition, E'\r\n', E'\n');
    IF (length(normalized) - length(replace(normalized, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V640 public surplus history guard shape changed' USING ERRCODE = '23514';
    END IF;
    patched := replace(normalized, anchor, replacement);
    IF patched IS NOT DISTINCT FROM normalized THEN
        RAISE EXCEPTION 'V640 cannot relax the public surplus history guard safely' USING ERRCODE = '23514';
    END IF;
    EXECUTE patched;
END;
$patch$;

COMMENT ON FUNCTION fn_guard_preplan_supply_action_history() IS
    '外部化供给行动身份不可变；V640 例外：明细仍未订货时 requested_qty 允许只增不减的就地追加(ADR-099)';
COMMENT ON FUNCTION fn_guard_preplan_supply_allocation_history() IS
    '外部化分摊行身份不可变；V640 例外：明细仍未订货时 allocated_qty 允许只增不减的就地追加(ADR-099)';
COMMENT ON FUNCTION fn_guard_preplan_public_surplus_history() IS
    '公共超量与认领身份不可变；V640 例外：明细仍未订货时公共量允许只增不减、公共明细锚允许从空指向自己的需求明细(ADR-099)';
