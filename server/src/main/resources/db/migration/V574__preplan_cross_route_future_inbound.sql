-- V574 2026-09-13 跨路线在途调入（专属转拨 + 公共认领）与分析热路径索引
--
-- 背景与缺口（均为落库前逐行核实）：
--   1. 服务层已把「专属在途调入」的目标放开到采购/委外/自制三条路线，并让
--      转入动作沿用「来源路线」取号；但 V571 的 fn_guard_preplan_future_transfer
--      仍要求 target.confirmed_route = source_action.route，任何跨路线 INSERT
--      都会以 23514 被打回，功能在服务层通、在库里断。本迁移把这条等值约束
--      换成「目标路线白名单 + 目标行形态不变量」，仍是 fail-closed。
--   2. 「公共在途认领」此前只在服务层按目标路线过滤来源，自制目标查不到任何
--      来源、点了只会看到「当前没有可采用的公共在途」。服务层改为按来源路线
--      （BUY/SUBCONTRACT）取候选、认领动作沿用来源路线落库，守卫里
--      source_action.route <> claim_action.route 这条因此天然成立，无需放宽；
--      仓库口径 V569 已统一为同主仓（fn_warehouse_same_main），本迁移不再重复。
--   3. 两条跨分析热路径（让料软占用、入库唤醒候选）按 goods_id 扫全库物料行，
--      现有 idx_production_material_analysis_material_dimension 以 analysis_id
--      打头用不上；专属在途转拨表被 8 个采购/委外改单触发器按 external_item_id
--      逐行探测，却没有该列索引。本迁移补两条索引，为十年级数据量留出余地。
--
-- 不变量（放开后仍然成立，由本迁移或服务层锁死）：
--   · 来源只能是另一份计划已下单未实收的「外部份额」（route ∈ BUY/SUBCONTRACT
--     的 SUPPLY 动作），自制在制品、委外前置自制半成品永远不能当来源。
--   · 目标必须是同主仓、同货品/颜色/单位、仍在生效、且控制段不是 SHIP/REFERENCE
--     的活动需求行，路线必须已确认为 BUY/SUBCONTRACT/MAKE 之一。
--   · 单笔转入量不超过来源未实收容量（原有闸门）与目标毛需求（本迁移新增的
--     库侧宽松兜底）；精确的「目标待补量」上限由服务层按权威快照把关。
--   · 本迁移只替换函数体与新增索引，不新增表、不改表结构、不改历史行，
--     business_data_reset() 白名单与审计触发器覆盖均无需变动。

-- 1) 专属在途转拨：跨路线放开 + 目标行形态不变量
CREATE OR REPLACE FUNCTION fn_guard_preplan_future_transfer() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source preplan_supply_action_allocations%ROWTYPE; source_action preplan_supply_actions%ROWTYPE;
        target production_material_analysis_materials%ROWTYPE; source_material production_material_analysis_materials%ROWTYPE;
        cancelled NUMERIC; received NUMERIC; transfer preplan_future_supply_transfers%ROWTYPE;
BEGIN
    IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Future supply transfer history is append-only' USING ERRCODE='55000'; END IF;
    IF TG_TABLE_NAME='preplan_future_supply_transfer_cancellations' THEN
        -- NULL/NULL is reserved for rows already present when V571 added the
        -- columns. Never invent a split or accept this legacy shape on INSERT.
        IF NEW.restore_to_source_qty IS NULL OR NEW.public_release_qty IS NULL THEN
            RAISE EXCEPTION 'New future cancellation requires an explicit restoration/public split' USING ERRCODE='23514';
        END IF;
        SELECT * INTO transfer FROM preplan_future_supply_transfers WHERE id=NEW.transfer_id FOR UPDATE;
        PERFORM id FROM preplan_supply_action_allocations WHERE id IN(transfer.source_allocation_id,transfer.target_allocation_id) ORDER BY id FOR UPDATE;
        cancelled:=fn_preplan_future_transfer_cancelled_qty(transfer.id);received:=fn_preplan_future_transfer_received_qty(transfer.id);
        IF transfer.id IS NULL OR NEW.qty>transfer.qty-cancelled-received THEN
            RAISE EXCEPTION 'Only the unreceived future transfer remainder may be cancelled' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    SELECT * INTO source FROM preplan_supply_action_allocations WHERE id=NEW.source_allocation_id FOR UPDATE;
    SELECT * INTO source_action FROM preplan_supply_actions WHERE id=source.action_id FOR UPDATE;
    SELECT * INTO source_material FROM production_material_analysis_materials WHERE id=source.analysis_material_id;
    -- 目标行同样取行锁：跨路线放开后，两个会话可以从不同来源同时转入
    -- 同一个目标行，各自都不超过服务层算出的待补量、合计却会超额。锁住
    -- 目标行让这类并发串行化，与来源侧的 FOR UPDATE 对称。
    SELECT * INTO target FROM production_material_analysis_materials WHERE id=NEW.target_material_id FOR UPDATE;
    IF source.id IS NULL OR source.analysis_id<>NEW.source_analysis_id OR source.analysis_material_id<>NEW.source_material_id
      OR source.external_item_id IS DISTINCT FROM NEW.external_item_id OR source_action.operation_type<>'SUPPLY'
      OR source_action.status='CANCELLED' OR source_action.route NOT IN('BUY','SUBCONTRACT')
      OR target.id IS NULL OR target.analysis_id<>NEW.target_analysis_id OR NOT target.active OR NOT source_material.active
      OR (target.goods_id,target.color_id,target.unit_id) IS DISTINCT FROM (source_material.goods_id,source_material.color_id,source_material.unit_id)
      -- 2026-09-13：目标不再要求与来源同路线——外部在途是「最终件」，谁缺谁用。
      -- 取而代之的是目标行形态不变量：路线已确认为三条主路线之一，且不是
      -- 只作参考/发货段的行（这两段不产生需要外部供给的净需求）。
      OR target.confirmed_route IS NULL OR target.confirmed_route NOT IN('BUY','SUBCONTRACT','MAKE')
      OR target.control_stage IN('SHIP','REFERENCE')
      -- 库侧宽松兜底：任何单笔转入都不可能超过目标行的毛需求。精确的
      -- 「扣除现货与既有在途后的待补量」由服务层按权威快照把关。
      OR NEW.qty>GREATEST(target.required_qty,0)
      OR NOT EXISTS(SELECT 1 FROM production_material_analyses a JOIN production_material_analyses b ON b.id=NEW.target_analysis_id
          WHERE a.id=NEW.source_analysis_id AND NOT a.is_deleted AND NOT b.is_deleted
            AND a.status IN('ACTIVE','PARTIALLY_PLANNED','COMPLETED') AND b.status IN('ACTIVE','PARTIALLY_PLANNED','COMPLETED')
            AND fn_warehouse_same_main(a.warehouse_id,b.warehouse_id))
      OR NEW.qty>fn_preplan_future_source_available_qty(source.id)
      OR (NEW.target_need_date IS NOT NULL AND (NEW.expected_date IS NULL OR NEW.expected_date>NEW.target_need_date) AND NOT NEW.allow_late_supply) THEN
        RAISE EXCEPTION 'Future transfer source, scope, timing or unreceived capacity is invalid' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;

-- 2) 现货让料的库侧端点守卫补层级：让料放开到第 1 层及以下之后，第 0 层
--    根供给行仍然不参与（它走自己的根产出交付通道）。服务层已按此判定，
--    这里把同一条规则补进库侧守卫，让两端都 fail-closed。
DO $reallocation_endpoint_depth$
DECLARE definition TEXT; patched TEXT;
BEGIN
    SELECT pg_get_functiondef('fn_validate_preplan_material_reallocation_endpoints()'::regprocedure)
      INTO definition;
    patched := replace(definition,
        'OR source_material.control_stage IN (''SHIP'', ''REFERENCE'')',
        'OR source_material.depth < 1 OR target_material.depth < 1
          OR source_material.control_stage IN (''SHIP'', ''REFERENCE'')');
    IF patched = definition THEN
        RAISE EXCEPTION 'V574 reallocation endpoint stage guard anchor missing';
    END IF;
    EXECUTE patched;
END;
$reallocation_endpoint_depth$;

-- 3) 跨分析热路径索引
--    a. 让料软占用与入库唤醒候选都按 goods/color/unit 跨全库找活动物料行；
--       既有维度索引以 analysis_id 打头，这两条路径用不上。
CREATE INDEX IF NOT EXISTS idx_production_material_analysis_material_goods_lookup
    ON production_material_analysis_materials(goods_id, color_id, unit_id, analysis_id)
    WHERE active = TRUE;

--    b. 采购/委外改单、关闭、请购中止的 8 个守卫按 external_item_id 反查转拨。
CREATE INDEX IF NOT EXISTS idx_future_transfer_external_item
    ON preplan_future_supply_transfers(external_item_id, created_at, id);

COMMENT ON INDEX idx_production_material_analysis_material_goods_lookup IS
    '跨分析按货品维度定位活动物料行：让料软占用与入库唤醒候选的主索引';
COMMENT ON INDEX idx_future_transfer_external_item IS
    '按外部明细反查专属在途转拨：采购/委外改单与关闭守卫的主索引';

-- 4) 权限目录文案跟着能力走：跨路线放开后，「采用公共在途」不再要求同路线。
--    只改目录里的说明文字与「跨计划让料」的能力描述，
--    不新增权限码、不改任何授权关系。
UPDATE permissions
SET name = '物料分析采用公共在途',
    description = '允许在同主仓、同货品颜色单位且按期的范围内，显式采用其它分析已批准的公共在途；'
        || '目标可以是采购、委外或自制（车间）物料，我方供料 BOM 的委外件除外'
WHERE code = 'production_material_analysis:claim_shared_future';

UPDATE permissions
SET name = '跨物料分析让料与在途调入'
WHERE code = 'production_material_analysis:cross_reallocate';
