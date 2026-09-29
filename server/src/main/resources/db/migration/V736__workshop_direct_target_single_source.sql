-- V736 车间直送(「转下一道工序」)资格单一事实源与不可转原因码(ADR-127 第一步, 2026-09-27)。
--
-- 背景: 用户报「最下面那个 HV5ZJ012 明明有父层级、还在同一个车间，却转不了下一道工序」。
-- 实查: HV5ZJ012 在 2026-09-23 被改成委外件(委外前置自制)，做好后要先入仓、发外加工、
-- 回厂后上层工单再从仓库领料——拦住是对的，但界面只会说「(无同车间上层工单)」，是错的。
-- 同一条「能不能直送」的规则此前散在约 10 处(4 个库函数、3 个行触发器、3 个 Java 服务、
-- 3 处前端)，已经互相走样: 保存时只看父子关系不看接收方状态，审核时 7 种原因共用一句话，
-- fn_demand_direct_supply_eligible 另有一套更松的判定。
--
-- 本迁移把规则收成一处，其余全部变成它的包装或调用方:
--   1. fn_workshop_direct_relation_code(生产工单, 接收需求): 结构判定，返回 NULL=可直送，
--      否则按固定次序返回一个原因码 SOURCE_INVALID / TARGET_INVALID / SELF / GOODS_MISMATCH /
--      SUBCONTRACT_ROUTE / BUY_ROUTE / NO_PARENT_RELATION / DIFFERENT_WORKSHOP。
--      路线只在这里判，且只对与本工单挂钩的需求点名(fn_workshop_direct_linked_demands: 同一物料分析 /
--      子计划 / 在途挂钩)，不相干工单的委外/采购路线不会被说成转不了的原因;
--      父子关系证明(V615 原口径 + V715 共享批次口径)原样保留作内部证明。
--   2. fn_workshop_direct_relationship_allows = 原因码为空; fn_workshop_direct_responsibility_allows
--      = 原因码为空或只差车间(历史责任口径不变)。两者对全部调用方逐一等价(见 ADR-127 §2.1)。
--   3. fn_workshop_direct_targets(生产工单[, 接收需求[, 本次基本数量]]): 候选列表/单条校验共用的
--      表函数，逐条给出接收工单信息、还差多少、本来源最多可送、是否可送、原因码、原因大白话与排序。
--      列表只列结构上的上层；没有父子关系的不列，一条都不剩时由哨兵行说明真正的原因。
--   4. fn_assert_workshop_direct_target: 锁住接收方后读单条校验，不可送即抛
--      「无法转到下一道工序：<原因>」(23514, HINT=原因码, CONSTRAINT=workshop_direct_target_guard)。
--   5. 直送明细的守卫触发器改为调用它: 原 V612 接收状态块、V612 数量上限块、段车间相等、
--      V615 关系/数量守卫、V715 共享切片前的数量复核全部删除(规则只剩一份)。
--   6. fn_demand_direct_supply_eligible 改为「有同货品的在制工单与它存在真实直送关系」，
--      不再只看同车间有没有同货品工单(V605 的旧口径)。
--   7. (ADR-127 第二步) 一行报工可按工人的分配同时转给多个上层工单、其余送入仓库：每个接收工单
--      仍是一条独立的报工明细(一行一接收需求的守卫不变)，送入仓库的明细记下原因码
--      production_daily_report_items.output_route_reason(工人自选/能直送的都已分满/公共备货/
--      实际超产/或上面的某个不可转原因)，原因大白话仍只由 fn_workshop_direct_reason_text 给出。
--   8. (ADR-127 §8) 审核不再随接收工单数变慢：直送可用量/已覆盖量两个函数先按接收需求取出直送批、
--      再对出现的生产工单各判一次关系，两者写成 plpgsql(第 9 节)；审核路径上另五个 LANGUAGE sql 函数
--      (四个来源证明 + 线边仓料是否指名给需求)改为 plpgsql，查询文本从现有定义原样取出，
--      按数据库连接缓存执行计划(第 10 节)。结果与原定义逐条相同。
-- 不加表；只加上面第 7 点的一列(可空、存量行为空)，不改任何存量数据。

-- ============ 1. 生产侧是不是委外件(委外前置自制/委外备料/共享委外批次) ============
CREATE FUNCTION fn_workshop_direct_source_is_subcontract(p_producing UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM production_execution_segments producing
        JOIN production_plans plan ON plan.id = producing.plan_id
        JOIN production_material_analysis_items item
          ON item.id = plan.material_analysis_item_id
         AND item.analysis_id = plan.material_analysis_id
         AND NOT item.is_deleted
        WHERE producing.id = p_producing
          AND (item.source_type IN ('SUBCONTRACT_MAKE', 'SUBCONTRACT_PREPARATION')
               OR EXISTS (SELECT 1 FROM preplan_aggregate_batches batch
                          WHERE batch.anchor_analysis_item_id = item.id
                            AND batch.route = 'SUBCONTRACT')))
$$;
COMMENT ON FUNCTION fn_workshop_direct_source_is_subcontract(UUID) IS
    'V736 生产工单是否在做委外件(委外前置自制、委外备料或共享委外批次)：做好后必须先入仓再发外，不能车间内直送';

-- ============ 2. 结构原因码(唯一的「能不能直送」结构规则) ============
-- 2a. 与生产工单挂钩的同货品需求(结构挂钩只写这一份)。
-- 「挂钩」=接收需求与生产工单在同一条计划链上: 同一个物料分析，或都不走物料分析时有子计划链接 /
-- 在途挂钩(peg)。它只说明「可能是上层」，不等于父子关系成立；父子关系证明(V615/V715)都要求这几种
-- 关联之一，所以能直送的需求必然在这个范围里。两处共用、只在这里写一次:
--   1. 候选列表只在挂钩的需求里找上层，别的物料分析里同车间同货品的工单不再拉进来;
--   2. 委外件/按采购供应这两个路线原因只对挂钩的需求点名，没挂钩的一律是「不是由本工单供应」。
-- receiving_plan_canceled: 已取消的计划仍算挂钩(单条校验照常说原因)，候选列表不列。
-- 写成可内联的 SQL 表函数: 单条判定时外层按需求主键过滤，规划器直接按主键取那一条。
CREATE FUNCTION fn_workshop_direct_linked_demands(p_producing UUID)
RETURNS TABLE(demand_id UUID, receiving_plan_canceled BOOLEAN) LANGUAGE sql STABLE AS $$
    SELECT demand.id, plan.is_canceled
    FROM production_execution_segments producing
    JOIN production_plans source_plan ON source_plan.id = producing.plan_id
    JOIN production_material_demands demand
      ON demand.goods_id = producing.product_goods_id
     AND demand.color_id IS NOT DISTINCT FROM producing.product_color_id
     AND NOT demand.is_deleted
    JOIN production_execution_segments receiving
      ON receiving.id = demand.execution_segment_id AND NOT receiving.is_deleted AND receiving.id <> producing.id
    JOIN production_plans plan ON plan.id = receiving.plan_id AND NOT plan.is_deleted
    WHERE producing.id = p_producing AND NOT producing.is_deleted
      AND (plan.material_analysis_id = source_plan.material_analysis_id
           OR (source_plan.material_analysis_id IS NULL AND plan.material_analysis_id IS NULL
               AND (EXISTS (SELECT 1 FROM subplan_links link
                            WHERE link.plan_id = plan.id AND link.subplan_id = source_plan.id
                              AND NOT link.is_deleted)
                    OR EXISTS (SELECT 1 FROM production_material_supply_pegs peg
                               WHERE peg.demand_id IN (demand.id, demand.split_root_demand_id)
                                 AND peg.supply_type = 'PRODUCTION_PLAN_ITEM'
                                 AND peg.supply_item_id = producing.source_plan_item_id
                                 AND peg.status <> 'REVERSED' AND peg.allocated_qty > peg.released_qty))))
$$;
COMMENT ON FUNCTION fn_workshop_direct_linked_demands(UUID) IS
    'V736 与生产工单挂钩的同货品需求(同一物料分析 / 子计划链接 / 在途挂钩)：候选列表的范围，也是路线原因只对谁点名的依据；挂钩不等于父子关系成立';

-- 2b. 结构原因码。
CREATE FUNCTION fn_workshop_direct_relation_code(p_producing UUID, p_demand UUID)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_source RECORD;
    v_target RECORD;
    v_route TEXT;
BEGIN
    SELECT segment.id, segment.product_goods_id, segment.product_color_id, segment.workshop_department_id
    INTO v_source
    FROM production_execution_segments segment
    JOIN production_plans plan ON plan.id = segment.plan_id
    WHERE segment.id = p_producing AND NOT segment.is_deleted AND NOT plan.is_deleted;
    IF NOT FOUND THEN RETURN 'SOURCE_INVALID'; END IF;

    SELECT demand.goods_id, demand.color_id, demand.supply_route,
           receiving.id AS receiving_id, receiving.workshop_department_id
    INTO v_target
    FROM production_material_demands demand
    JOIN production_execution_segments receiving
      ON receiving.id = demand.execution_segment_id AND NOT receiving.is_deleted
    JOIN production_plans plan ON plan.id = receiving.plan_id AND NOT plan.is_deleted
    WHERE demand.id = p_demand AND NOT demand.is_deleted;
    IF NOT FOUND THEN RETURN 'TARGET_INVALID'; END IF;

    IF v_target.receiving_id = v_source.id THEN RETURN 'SELF'; END IF;
    IF v_source.product_goods_id IS DISTINCT FROM v_target.goods_id
       OR v_source.product_color_id IS DISTINCT FROM v_target.color_id THEN
        RETURN 'GOODS_MISMATCH';
    END IF;
    -- 路线只在这里判(原先散在 V605/V615/V715 三处的 supply_route='MAKE' 与 batch.route='MAKE')，
    -- 而且只对挂钩的需求点名：别的物料分析里同货品的委外/采购需求与本工单无关，拿它的路线当原因是错的。
    -- 这里点名路线还是 NO_PARENT_RELATION 都是「不可直送」，两个包装只认 NULL / DIFFERENT_WORKSHOP，结果不变。
    v_route := CASE
        WHEN v_target.supply_route = 'SUBCONTRACT' OR fn_workshop_direct_source_is_subcontract(p_producing)
            THEN 'SUBCONTRACT_ROUTE'
        WHEN v_target.supply_route IS DISTINCT FROM 'MAKE' THEN 'BUY_ROUTE'
    END;
    IF v_route IS NOT NULL THEN
        RETURN CASE WHEN EXISTS (SELECT 1 FROM fn_workshop_direct_linked_demands(p_producing) linked
                                 WHERE linked.demand_id = p_demand)
                    THEN v_route ELSE 'NO_PARENT_RELATION' END;
    END IF;
    -- 父子关系证明: V615 原口径(同分析父物料行 / 非分析计划的子计划与挂钩) 或 V715 共享批次份额。
    IF NOT (fn_workshop_direct_responsibility_allows_before_v715(p_producing, p_demand)
            OR EXISTS (SELECT 1 FROM fn_preplan_aggregate_direct_scopes(p_producing, p_demand))) THEN
        RETURN 'NO_PARENT_RELATION';
    END IF;
    -- 车间放最后: 历史责任口径(responsibility)只忽略这一条。
    IF v_source.workshop_department_id IS NULL
       OR v_source.workshop_department_id IS DISTINCT FROM v_target.workshop_department_id THEN
        RETURN 'DIFFERENT_WORKSHOP';
    END IF;
    RETURN NULL;
END $$;
COMMENT ON FUNCTION fn_workshop_direct_relation_code(UUID, UUID) IS
    'V736 车间直送结构判定唯一事实源：NULL=可直送；否则按次序返回 SOURCE_INVALID/TARGET_INVALID/SELF/GOODS_MISMATCH/'
    'SUBCONTRACT_ROUTE/BUY_ROUTE/NO_PARENT_RELATION/DIFFERENT_WORKSHOP 之一(不看接收状态与数量)；'
    '路线原因只对挂钩的需求(fn_workshop_direct_linked_demands)点名，没挂钩的是 NO_PARENT_RELATION';

CREATE OR REPLACE FUNCTION fn_workshop_direct_relationship_allows(p_producing UUID, p_demand UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT fn_workshop_direct_relation_code(p_producing, p_demand) IS NULL
$$;
COMMENT ON FUNCTION fn_workshop_direct_relationship_allows(UUID, UUID) IS
    'V736 起为 fn_workshop_direct_relation_code 的包装：原因码为空=当前可建立车间直送关系';

CREATE OR REPLACE FUNCTION fn_workshop_direct_responsibility_allows(p_producing UUID, p_demand UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE(fn_workshop_direct_relation_code(p_producing, p_demand), 'DIFFERENT_WORKSHOP')
           = 'DIFFERENT_WORKSHOP'
$$;
COMMENT ON FUNCTION fn_workshop_direct_responsibility_allows(UUID, UUID) IS
    'V736 起为 fn_workshop_direct_relation_code 的包装：原因码为空或只差车间=历史直送责任仍成立(历史认领口径)';

-- ============ 3. 原因的大白话与接近程度(唯一一份文案) ============
CREATE FUNCTION fn_workshop_direct_reason_rank(p_code TEXT)
RETURNS INTEGER LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_code
        WHEN 'QTY_EXCEEDS_REMAINING' THEN 10
        WHEN 'SOURCE_SHARE_USED_UP' THEN 20
        WHEN 'DEMAND_ALREADY_COVERED' THEN 21
        WHEN 'RECEIVER_STATUS' THEN 30
        WHEN 'PLAN_NOT_ACTIVE' THEN 31
        WHEN 'PACKAGE_NOT_CONFIRMED' THEN 32
        WHEN 'DEMAND_CLOSED' THEN 33
        WHEN 'DIFFERENT_WORKSHOP' THEN 40
        WHEN 'SUBCONTRACT_ROUTE' THEN 50
        WHEN 'BUY_ROUTE' THEN 51
        WHEN 'NO_PARENT_RELATION' THEN 60
        WHEN 'SELF' THEN 61
        WHEN 'GOODS_MISMATCH' THEN 62
        WHEN 'SOURCE_INVALID' THEN 63
        WHEN 'TARGET_INVALID' THEN 64
        WHEN 'NO_RECEIVER_ISSUED_YET' THEN 70
        WHEN 'NOT_A_COMPONENT' THEN 71
        ELSE 0
    END
$$;
COMMENT ON FUNCTION fn_workshop_direct_reason_rank(TEXT) IS
    'V736 不可直送原因的接近程度：数字越小越接近可送；没有可送工单时界面显示最小的那条原因';

-- 上下文(接收工单、货品、车间、状态)缺省时给中性说法：报工详情按已存的原因码回看送仓原因时
-- 不再有当时的接收工单与车间，文案仍然只有这一份。
CREATE FUNCTION fn_workshop_direct_reason_text(
    p_code TEXT, p_receiver TEXT, p_goods TEXT, p_workshop TEXT, p_state TEXT,
    p_qty NUMERIC, p_remaining NUMERIC)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT CASE p_code
        WHEN 'QTY_EXCEEDS_REMAINING' THEN format('%s本次基本数量 %s 超过最多可送 %s，超出部分请送入仓库或分给其它上层工单',
            CASE WHEN p_receiver IS NULL THEN '' ELSE '转给' || p_receiver || ' 的' END,
            trim_scale(p_qty), trim_scale(GREATEST(COALESCE(p_remaining, 0), 0)))
        WHEN 'SOURCE_SHARE_USED_UP' THEN '本工单承担的份额已全部交接 (同计划行拆出的工单共用额度)'
        WHEN 'DEMAND_ALREADY_COVERED' THEN format('%s的 %s 已经备齐 (仓库备料或其它直送)', receiver, goods)
        WHEN 'RECEIVER_STATUS' THEN format('%s%s，不再接收直送', receiver, COALESCE(p_state, '已开工或已结束'))
        WHEN 'PLAN_NOT_ACTIVE' THEN format('%s的生产计划%s', receiver, COALESCE(p_state, '已停用'))
        WHEN 'PACKAGE_NOT_CONFIRMED' THEN format('%s的计划包已取消，不再接收直送', receiver)
        WHEN 'DEMAND_CLOSED' THEN format('%s已不再需要 %s', receiver, goods)
        WHEN 'DIFFERENT_WORKSHOP' THEN format('%s在%s，跨车间必须送入仓库', receiver, COALESCE(p_workshop, '其它车间'))
        WHEN 'SUBCONTRACT_ROUTE' THEN format('%s 是委外件：做好后先送入仓库，发外加工回来后，上层工单再从仓库领料', goods)
        WHEN 'BUY_ROUTE' THEN format('%s的 %s 按采购供应，只能从仓库领料', receiver, goods)
        WHEN 'NO_PARENT_RELATION' THEN format('%s的 %s 不是由本工单供应 (属于别的物料分析或已由其它来源承担)', receiver, goods)
        WHEN 'SELF' THEN '不能转给本工单自己'
        WHEN 'GOODS_MISMATCH' THEN '所选上层工单需要的不是这个货品'
        WHEN 'SOURCE_INVALID' THEN '报工来源工单已失效，请刷新后重试'
        WHEN 'TARGET_INVALID' THEN '所选上层工单已失效，请刷新后重新选择'
        WHEN 'NO_RECEIVER_ISSUED_YET' THEN '上层工单还没下达到车间，暂时没有可接收的工单'
        WHEN 'NOT_A_COMPONENT' THEN '本工单做的是顶层产品，没有下一道工序，请送入仓库'
        -- 以下只用于报工送入仓库的那部分(output_route_reason)，不是「不可转」原因。
        WHEN 'USER_CHOSEN' THEN '报工时选择送入仓库'
        WHEN 'RECEIVERS_FULL' THEN '能直送的上层工单都已分满，其余送入仓库'
        WHEN 'PUBLIC_SHARE' THEN '计划内的公共备货部分，统一送入仓库'
        WHEN 'ACTUAL_SURPLUS' THEN '超出计划的实际产量，统一送入仓库'
    END
    -- 有接收工单称呼时带一个空格接后文(「上层工单 ZX… 在二车间」)，没有时直接接(「上层工单在其它车间」)。
    FROM (SELECT CASE WHEN p_receiver IS NULL THEN '上层工单' ELSE p_receiver || ' ' END AS receiver,
                 COALESCE(NULLIF(p_goods, ''), '这个货品') AS goods) context
$$;
COMMENT ON FUNCTION fn_workshop_direct_reason_text(TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC) IS
    'V736 不可直送原因与报工送仓原因的大白话(唯一一份文案，界面、报工详情与数据库报错共用；不含代号)';

-- ============ 4. 候选列表/单条校验共用的表函数 ============
-- 列表模式(p_demand 为空): 只在与本工单挂钩的同货品需求里找(fn_workshop_direct_linked_demands，任意车间，
-- 计划已取消的不列)，列出结构上的上层并逐条给出原因；没有父子关系(或本身无效)的不列，也不拿来当原因。
-- 一条都不剩时返回一条哨兵行(demand_id 为空)说明真正的原因: 顶层产品 / 上层还没下达 / 委外件 / 来源失效。
-- 别的物料分析里同车间同货品的工单不再拉进来，所以它们既不会挡住哨兵，也不会以委外/采购的名义冒充上层。
-- 校验模式(p_demand 有值): 恰好一行；给了 p_base_qty 时再判「本次数量超过最多可送」。
-- receiver_open: 结构与接收状态都允许(只可能差数量)——保存报工时据此区分「不能送」(当场报原因)
-- 与「这次送不下」(按原口径拆成送入仓库的部分)；eligible 另外要求还差数量且本来源还有份额。
-- sort_order 为「先急后缓」: 接收计划所属分析行的优先级、交期(分析行交期/需求日期/计划交期)、
-- 计划单号、工单号、需求 id——与 AggregateQuantityAllocator.ORDER 的优先级/日期/来源 id 同一次序。
-- receiver_label: 原因文案里称呼接收方的那几个字(「上层工单 ZX…」)，保存报工核数量时复用同一称呼。
CREATE FUNCTION fn_workshop_direct_targets(
    p_producing UUID, p_demand UUID DEFAULT NULL, p_base_qty NUMERIC DEFAULT NULL)
RETURNS TABLE(
    demand_id UUID, receiving_segment_id UUID, receiving_segment_code TEXT, receiving_status TEXT,
    receiving_continuous BOOLEAN, receiving_plan_id UUID, receiving_plan_no TEXT,
    receiving_product_goods_id UUID, receiving_workshop_id UUID,
    demand_warehouse_id UUID, package_warehouse_id UUID,
    required_qty NUMERIC, covered_qty NUMERIC, receiver_shortfall_qty NUMERIC, remaining_qty NUMERIC,
    receiver_open BOOLEAN, eligible BOOLEAN, reason_code TEXT, reason_text TEXT, reason_rank INTEGER,
    sort_order INTEGER, receiver_label TEXT)
LANGUAGE sql STABLE AS $$
WITH producing AS MATERIALIZED (
    -- 与 fn_workshop_direct_relation_code 的 SOURCE_INVALID 同一口径(工单或其计划已删即失效)。
    SELECT segment.id, segment.product_goods_id, segment.plan_id, segment.source_plan_item_id
    FROM production_execution_segments segment
    JOIN production_plans plan ON plan.id = segment.plan_id
    WHERE segment.id = p_producing AND NOT segment.is_deleted AND NOT plan.is_deleted
), scope AS MATERIALIZED (
    SELECT p_demand AS demand_id WHERE p_demand IS NOT NULL
    UNION
    SELECT linked.demand_id
    FROM fn_workshop_direct_linked_demands(p_producing) linked
    WHERE p_demand IS NULL AND NOT linked.receiving_plan_canceled
), structured AS MATERIALIZED (
    SELECT scope.demand_id,
           demand.status AS demand_status, demand.required_qty AS demand_required,
           demand.warehouse_id AS demand_warehouse, demand.need_date, demand.goods_id AS demand_goods,
           receiving.id AS receiving_id, receiving.segment_code, receiving.status AS segment_status,
           COALESCE(receiving.continuous_supply, FALSE) AS continuous,
           receiving.workshop_department_id AS receiving_workshop, receiving.product_goods_id AS receiving_product,
           plan.id AS plan_id, plan.bill_no, plan.status AS plan_status, plan.is_deleted AS plan_deleted,
           plan.is_stopped, plan.is_closed, plan.is_canceled, plan.delivery_date AS plan_delivery,
           package.id AS package_id, package.status AS package_status, package.is_deleted AS package_deleted,
           package.warehouse_id AS package_warehouse,
           item.line_priority, item.delivery_date AS item_delivery,
           fn_workshop_direct_relation_code(p_producing, scope.demand_id) AS structure_code
    FROM scope
    LEFT JOIN production_material_demands demand ON demand.id = scope.demand_id
    LEFT JOIN production_execution_segments receiving ON receiving.id = demand.execution_segment_id
    LEFT JOIN production_plans plan ON plan.id = receiving.plan_id
    LEFT JOIN production_planning_packages package
      ON package.id = receiving.package_id AND package.plan_id = plan.id
    LEFT JOIN production_material_analysis_items item ON item.id = plan.material_analysis_item_id
), stated AS MATERIALIZED (
    SELECT structured.*,
           COALESCE(structure_code, CASE
               WHEN plan_deleted OR is_canceled OR is_closed OR is_stopped
                    OR plan_status IS DISTINCT FROM 1 THEN 'PLAN_NOT_ACTIVE'
               WHEN package_id IS NULL OR package_deleted
                    OR package_status IS DISTINCT FROM 'CONFIRMED' THEN 'PACKAGE_NOT_CONFIRMED'
               WHEN NOT COALESCE(segment_status IN ('WAITING', 'READY', 'DISPATCHED')
                                 OR (segment_status = 'IN_PROGRESS' AND continuous), FALSE) THEN 'RECEIVER_STATUS'
               WHEN demand_status IN ('RELEASED', 'REVERSED') THEN 'DEMAND_CLOSED'
           END) AS state_code
    FROM structured
), measured AS MATERIALIZED (
    SELECT stated.*,
           CASE WHEN state_code IS NULL THEN fn_workshop_direct_covered_base_qty(stated.demand_id) END AS covered,
           CASE WHEN state_code IS NULL THEN fn_workshop_direct_remaining_for_source(p_producing, stated.demand_id) END AS remaining
    FROM stated
), coded AS (
    SELECT measured.*,
           '上层工单' || COALESCE(' ' || measured.segment_code, '') AS receiver_label,
           COALESCE(state_code, CASE
               WHEN demand_status = 'FULFILLED' OR demand_required - covered <= 0 THEN 'DEMAND_ALREADY_COVERED'
               WHEN remaining <= 0 THEN 'SOURCE_SHARE_USED_UP'
               WHEN p_base_qty IS NOT NULL AND p_base_qty > remaining THEN 'QTY_EXCEEDS_REMAINING'
           END) AS code
    FROM measured
), described AS (
    SELECT coded.*,
           row_number() OVER (ORDER BY coded.line_priority NULLS LAST,
                                       COALESCE(coded.item_delivery, coded.need_date, coded.plan_delivery) NULLS LAST,
                                       coded.bill_no NULLS LAST, coded.segment_code NULLS LAST,
                                       coded.demand_id::text)::INTEGER AS ordinal,
           fn_workshop_direct_reason_text(coded.code, coded.receiver_label,
               COALESCE(NULLIF(goods.code, ''), NULLIF(goods.name, ''), '这个货品'),
               COALESCE(workshop.name, '其它车间'),
               CASE coded.code
                   WHEN 'PLAN_NOT_ACTIVE' THEN CASE
                       WHEN coded.plan_deleted OR coded.is_canceled THEN '已取消'
                       WHEN coded.is_closed THEN '已结案'
                       WHEN coded.is_stopped THEN '已暂停'
                       ELSE '未审核' END
                   WHEN 'RECEIVER_STATUS' THEN CASE coded.segment_status
                       WHEN 'IN_PROGRESS' THEN '已按齐套开工'
                       WHEN 'COMPLETED' THEN '已完工'
                       ELSE '已取消' END
               END,
               p_base_qty, coded.remaining) AS text
    FROM coded
    LEFT JOIN goods ON goods.id = COALESCE(coded.demand_goods,
        (SELECT product_goods_id FROM production_execution_segments WHERE id = p_producing))
    LEFT JOIN departments workshop ON workshop.id = coded.receiving_workshop
), listed AS (
    SELECT described.demand_id, described.receiving_id, described.segment_code, described.segment_status,
           described.continuous, described.plan_id, described.bill_no, described.receiving_product,
           described.receiving_workshop, described.demand_warehouse, described.package_warehouse,
           described.demand_required, described.covered,
           CASE WHEN described.covered IS NULL THEN NULL
                ELSE GREATEST(described.demand_required - described.covered, 0) END AS shortfall,
           GREATEST(COALESCE(described.remaining, 0), 0) AS source_remaining,
           described.state_code IS NULL AS open, described.code IS NULL AS allowed, described.code, described.text,
           fn_workshop_direct_reason_rank(described.code) AS code_rank, described.ordinal,
           described.receiver_label
    FROM described
    -- 列表只列结构上的上层(可送，或说得出它现在为什么不能收)。不是上层的行(没有父子关系、本身无效)
    -- 不列，也就不会挡住哨兵、不会被当成不可转原因；单条校验照常返回那一行与它的原因。
    WHERE p_demand IS NOT NULL
       OR described.code IS NULL
       OR described.code NOT IN ('NO_PARENT_RELATION', 'SELF', 'GOODS_MISMATCH', 'SOURCE_INVALID', 'TARGET_INVALID')
)
SELECT * FROM listed
UNION ALL
SELECT NULL::UUID, NULL::UUID, NULL::TEXT, NULL::TEXT, FALSE, NULL::UUID, NULL::TEXT, NULL::UUID, NULL::UUID,
       NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, 0::NUMERIC,
       FALSE, FALSE, sentinel.code,
       fn_workshop_direct_reason_text(sentinel.code, NULL, sentinel.goods_label, NULL, NULL, NULL, NULL),
       fn_workshop_direct_reason_rank(sentinel.code), 1, NULL::TEXT
FROM (
    SELECT CASE
               WHEN NOT EXISTS (SELECT 1 FROM producing) THEN 'SOURCE_INVALID'
               WHEN fn_workshop_direct_source_is_subcontract(p_producing) THEN 'SUBCONTRACT_ROUTE'
               WHEN EXISTS (
                       SELECT 1 FROM producing
                       JOIN production_plans plan ON plan.id = producing.plan_id
                       JOIN production_material_analysis_items item
                         ON item.id = plan.material_analysis_item_id
                        AND item.analysis_id = plan.material_analysis_id AND NOT item.is_deleted
                       WHERE item.source_type IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE', 'AGGREGATE_MAKE'))
                    OR EXISTS (
                       SELECT 1 FROM producing JOIN subplan_links link
                         ON link.subplan_id = producing.plan_id AND NOT link.is_deleted)
                    OR EXISTS (
                       SELECT 1 FROM producing JOIN production_material_supply_pegs peg
                         ON peg.supply_type = 'PRODUCTION_PLAN_ITEM'
                        AND peg.supply_item_id = producing.source_plan_item_id
                        AND peg.status <> 'REVERSED') THEN 'NO_RECEIVER_ISSUED_YET'
               ELSE 'NOT_A_COMPONENT'
           END AS code,
           (SELECT COALESCE(NULLIF(goods.code, ''), NULLIF(goods.name, ''), '这个货品')
            FROM producing JOIN goods ON goods.id = producing.product_goods_id) AS goods_label
) sentinel
-- 没有一条结构上的上层时才出哨兵(上面已把不是上层的行剔除)。生产侧是委外件时挂钩的行都是委外原因，
-- 一条都没有也由哨兵点名「委外件」。
WHERE p_demand IS NULL AND NOT EXISTS (SELECT 1 FROM listed)
ORDER BY 21
$$;
COMMENT ON FUNCTION fn_workshop_direct_targets(UUID, UUID, NUMERIC) IS
    'V736 车间直送候选与单条校验唯一入口：逐条返回接收工单、还差多少、本来源最多可送、是否可送、原因码与大白话、先急后缓次序';

-- ============ 5. 断言: 数据库守卫与应用层共用 ============
CREATE FUNCTION fn_assert_workshop_direct_target(p_producing UUID, p_demand UUID, p_base_qty NUMERIC)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_verdict RECORD;
BEGIN
    -- 锁住接收计划/计划包/工单，防止判定后停产、关闭或取消的状态穿透(原 V612 口径)；
    -- 再锁需求本身，同一需求的并发直送串行累计(原 V612 数量块口径)。
    PERFORM 1
    FROM production_material_demands demand
    JOIN production_execution_segments receiving ON receiving.id = demand.execution_segment_id
    JOIN production_plans plan ON plan.id = receiving.plan_id
    JOIN production_planning_packages package ON package.id = receiving.package_id AND package.plan_id = plan.id
    WHERE demand.id = p_demand
    FOR SHARE OF plan, package, receiving;
    PERFORM 1 FROM production_material_demands WHERE id = p_demand FOR UPDATE;
    SELECT target.eligible, target.reason_code, target.reason_text
    INTO v_verdict
    FROM fn_workshop_direct_targets(p_producing, p_demand, p_base_qty) target;
    IF v_verdict.eligible IS NOT TRUE THEN
        RAISE EXCEPTION USING
            MESSAGE = '无法转到下一道工序：'
                || COALESCE(v_verdict.reason_text, '所选上层工单已失效，请刷新后重新选择'),
            ERRCODE = '23514',
            HINT = COALESCE(v_verdict.reason_code, 'TARGET_INVALID'),
            CONSTRAINT = 'workshop_direct_target_guard';
    END IF;
END $$;
COMMENT ON FUNCTION fn_assert_workshop_direct_target(UUID, UUID, NUMERIC) IS
    'V736 车间直送断言：锁接收方后按 fn_workshop_direct_targets 单条校验，不可送即抛「无法转到下一道工序：<原因>」(23514)';

-- ============ 6. 守卫触发器改为调用断言，删掉重复的内联规则 ============
CREATE FUNCTION fn_guard_workshop_direct_target()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_source_segment UUID;
    v_base_qty NUMERIC;
BEGIN
    SELECT item.execution_segment_id, round(NEW.qty * COALESCE(item.unit_rate, 1), 4)
    INTO v_source_segment, v_base_qty
    FROM production_daily_report_items item
    WHERE item.id = NEW.source_report_item_id;
    PERFORM fn_assert_workshop_direct_target(v_source_segment, NEW.to_demand_id, v_base_qty);
    RETURN NEW;
END $$;
COMMENT ON FUNCTION fn_guard_workshop_direct_target() IS
    'V736 直送明细写入前的唯一资格守卫(结构/接收状态/数量)，名字排在共享切片触发器之前先执行';

-- 行级 BEFORE 触发器按名字字母序执行: trg_a_... 排在 trg_aggregate_direct_slices 之前，
-- 共享切片只在资格断言通过之后才记录。
DROP TRIGGER trg_workshop_direct_relationship ON production_workshop_direct_transfer_items;
DROP FUNCTION fn_guard_workshop_direct_relationship();
CREATE TRIGGER trg_a_workshop_direct_target_guard
    BEFORE INSERT ON production_workshop_direct_transfer_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_direct_target();

-- V584/V612 守卫只保留与资格无关的部分: 追加式不可改删、整行镜像、需求与接收工单身份、
-- 线边仓属于本车间且与收料需求同主仓。接收状态、数量上限、两段同车间已由上面的断言负责。
CREATE OR REPLACE FUNCTION fn_guard_workshop_direct_transfer_item()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'workshop direct transfer items cannot be deleted'
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.reversal_id IS NOT NULL
           OR NEW.reversal_id IS NULL
           OR (to_jsonb(NEW) - 'reversal_id')
              IS DISTINCT FROM (to_jsonb(OLD) - 'reversal_id') THEN
            RAISE EXCEPTION 'a workshop direct transfer item is immutable apart from one reversal stamp'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    -- 去向必须真的是「转送车间」，数量必须等于该报工行的申报量(一行报工对一条接收需求)。
    IF NOT EXISTS (
            SELECT 1 FROM production_daily_report_items item
            WHERE item.id = NEW.source_report_item_id
              AND item.destination = 'WORKSHOP'
              AND item.is_deleted = FALSE
              AND item.qty = NEW.qty) THEN
        RAISE EXCEPTION 'a workshop direct transfer must mirror one whole WORKSHOP-destined report line'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'workshop_direct_transfer_item_source_guard';
    END IF;

    -- 收料需求必须属于收料工单，且货品/颜色与这条报工行一致。
    IF NOT EXISTS (
            SELECT 1
            FROM production_material_demands demand
            JOIN production_daily_report_items item
              ON item.id = NEW.source_report_item_id
            WHERE demand.id = NEW.to_demand_id
              AND demand.execution_segment_id = NEW.to_execution_segment_id
              AND demand.is_deleted = FALSE
              AND demand.goods_id = item.goods_id
              AND demand.color_id IS NOT DISTINCT FROM item.color_id) THEN
        RAISE EXCEPTION 'a workshop direct transfer must point at one live demand of the same goods'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'workshop_direct_transfer_item_demand_guard';
    END IF;

    -- 直送单头的车间就是出料工单的车间；线边仓必须是这个车间自己的，
    -- 且与收料需求同主仓(fn_warehouse_same_main 是同主仓分仓领料的硬前提，V489)。
    IF NOT EXISTS (
            SELECT 1
            FROM production_workshop_direct_transfers transfer
            JOIN warehouses line_side
              ON line_side.id = transfer.line_side_warehouse_id
            JOIN production_material_demands demand ON demand.id = NEW.to_demand_id
            JOIN production_daily_report_items item
              ON item.id = NEW.source_report_item_id
            JOIN production_execution_segments producing
              ON producing.id = item.execution_segment_id
            WHERE transfer.id = NEW.transfer_id
              AND line_side.is_line_side
              AND line_side.is_deleted = FALSE
              AND line_side.workshop_department_id = transfer.workshop_department_id
              AND producing.workshop_department_id = transfer.workshop_department_id
              AND fn_warehouse_same_main(line_side.id, demand.warehouse_id)) THEN
        RAISE EXCEPTION 'workshop direct transfer requires its own workshop line-side warehouse under the demand main warehouse'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'workshop_direct_transfer_item_workshop_guard';
    END IF;
    RETURN NEW;
END;
$$;

-- 共享切片: 数量复核已由断言在同一语句更早执行；锁住来源物料后逐份切，份额被并发交接
-- 抢先用完时给出同一套大白话。
CREATE OR REPLACE FUNCTION fn_record_aggregate_direct_slices()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE producing UUID; remaining NUMERIC; scope RECORD; take NUMERIC; ordinal INTEGER:=0; actor UUID;
BEGIN
 SELECT source.execution_segment_id,round(NEW.qty*COALESCE(source.unit_rate,1),4),header.created_by
 INTO producing,remaining,actor FROM production_daily_report_items source
 JOIN production_workshop_direct_transfers header ON header.id=NEW.transfer_id WHERE source.id=NEW.source_report_item_id;
 IF NOT EXISTS(SELECT 1 FROM fn_preplan_aggregate_direct_scopes(producing,NEW.to_demand_id)) THEN RETURN NEW; END IF;
 -- Source-material locks serialize warehouse attribution and alias/member
 -- handovers in the same ownership scope, not across unrelated workshops.
 PERFORM 1 FROM production_material_analysis_materials material WHERE material.id IN(
   SELECT source_material_id FROM fn_preplan_aggregate_direct_scopes(producing,NEW.to_demand_id)) ORDER BY material.id FOR UPDATE;
 FOR scope IN SELECT * FROM fn_preplan_aggregate_direct_scopes(producing,NEW.to_demand_id) ORDER BY allocation_id NULLS FIRST,alias_id NULLS FIRST LOOP
   take:=LEAST(remaining,fn_preplan_aggregate_direct_scope_remaining(scope.source_material_id,scope.target_material_id,scope.alias_id,scope.allocation_id));
   IF take<=0 THEN CONTINUE; END IF;
   ordinal:=ordinal+1;
   INSERT INTO preplan_aggregate_direct_transfer_slices(transfer_item_id,slice_no,source_material_id,target_material_id,aggregate_alias_id,supply_action_allocation_id,qty_base,created_by)
   VALUES(NEW.id,ordinal,scope.source_material_id,scope.target_material_id,scope.alias_id,scope.allocation_id,take,actor);
   remaining:=remaining-take;
   EXIT WHEN remaining=0;
 END LOOP;
 IF remaining<>0 THEN
   RAISE EXCEPTION USING
     MESSAGE='无法转到下一道工序：'||fn_workshop_direct_reason_text('SOURCE_SHARE_USED_UP',NULL,NULL,NULL,NULL,NULL,NULL),
     ERRCODE='23514', HINT='SOURCE_SHARE_USED_UP', CONSTRAINT='workshop_direct_target_guard';
 END IF;
 RETURN NEW;
END $$;

-- ============ 7. 持续生产识别复用同一条关系(取代 V605 的同车间同货品旧口径) ============
CREATE OR REPLACE FUNCTION fn_demand_direct_supply_eligible(p_demand UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM production_material_demands demand
        JOIN production_execution_segments receiving
          ON receiving.id = demand.execution_segment_id
        WHERE demand.id = p_demand
          AND demand.is_deleted = FALSE
          AND receiving.workshop_department_id IS NOT NULL
          AND (EXISTS (
                   SELECT 1 FROM production_execution_segments producing
                   WHERE producing.product_goods_id = demand.goods_id
                     AND producing.product_color_id IS NOT DISTINCT FROM demand.color_id
                     AND producing.is_deleted = FALSE
                     AND producing.status IN ('WAITING', 'READY', 'DISPATCHED', 'IN_PROGRESS')
                     AND fn_workshop_direct_relationship_allows(producing.id, demand.id))
               OR EXISTS (
                   SELECT 1 FROM production_workshop_direct_transfer_items transfer_item
                   JOIN production_daily_report_items source_item
                     ON source_item.id = transfer_item.source_report_item_id
                    AND source_item.goods_id = demand.goods_id
                    AND source_item.color_id IS NOT DISTINCT FROM demand.color_id
                   WHERE transfer_item.reversal_id IS NULL
                     AND (transfer_item.to_demand_id = demand.id
                          OR transfer_item.to_demand_id = demand.split_root_demand_id
                          OR transfer_item.to_execution_segment_id = receiving.id))));
$$;
COMMENT ON FUNCTION fn_demand_direct_supply_eligible(UUID) IS
    'V736 需求可否由直送供给：有同货品的在制工单与它存在真实直送关系(fn_workshop_direct_relationship_allows)，'
    '或已有货品比对过的直送行指向它；路线、车间与父子关系只在 fn_workshop_direct_relation_code 判定';

-- ============ 8. 报工送入仓库部分的原因码(ADR-127 第二步：一行报工分给多个上层工单) ============
-- 工人在报工页把一行产量逐个分给上层工单(先急后缓)，剩下的送入仓库。服务端每个接收工单写一条
-- 独立的转送明细(一行一接收需求，既有守卫全部照旧)，送入仓库的明细记下为什么没转：
--   USER_CHOSEN      还能直送，工人选择送入仓库；
--   RECEIVERS_FULL   能直送的上层工单都已分满；
--   PUBLIC_SHARE     计划内的公共备货部分(ADR-118，一律入库)；
--   ACTUAL_SURPLUS   超出计划的实际产量(ADR-118，一律入库)；
--   其余             一个可送的上层工单都没有时，最接近可送的那条不可转原因(与报工页红字同一个)。
-- 只写不改：审核不重新分流(ADR-118 §3 不静默改去向)，学习口径(V711)也不读这一列。
ALTER TABLE production_daily_report_items
    ADD COLUMN output_route_reason TEXT,
    ADD CONSTRAINT production_daily_report_items_output_route_reason_chk CHECK (
        output_route_reason IS NULL OR (destination = 'WAREHOUSE' AND output_route_reason IN (
            'USER_CHOSEN', 'RECEIVERS_FULL', 'PUBLIC_SHARE', 'ACTUAL_SURPLUS',
            'SOURCE_SHARE_USED_UP', 'DEMAND_ALREADY_COVERED', 'RECEIVER_STATUS', 'PLAN_NOT_ACTIVE',
            'PACKAGE_NOT_CONFIRMED', 'DEMAND_CLOSED', 'DIFFERENT_WORKSHOP', 'SUBCONTRACT_ROUTE',
            'BUY_ROUTE', 'NO_PARENT_RELATION', 'SELF', 'GOODS_MISMATCH', 'SOURCE_INVALID',
            'TARGET_INVALID', 'NO_RECEIVER_ISSUED_YET', 'NOT_A_COMPONENT')));
COMMENT ON COLUMN production_daily_report_items.output_route_reason IS
    'V736 送入仓库的报工明细为什么没转下一道工序(原因码；大白话由 fn_workshop_direct_reason_text 给出)；转送明细与存量行为空';

-- ============ 9. 直送料可用量先按接收需求收窄、再判关系(ADR-127 第三步：审核不随接收工单数平方变慢) ============
-- 原写法(V615)把关系判定 fn_workshop_direct_relationship_allows(单次要走一遍父子关系证明)与
-- 「这批料是投给哪条需求的」并列写在同一层条件里：规划器把判定下推到「同货品的全部报工明细」上
-- 逐条先算，再按接收需求过滤。一张报工分给 N 个上层工单后同货品明细就有 N 条，审核里每查一次
-- 可用量都把 N 条的关系全判一遍，整次审核随 N 平方增长(实测 11 个接收工单时一次审核 1661 次关系判定)。
-- 改为先按接收需求(+线边仓、货品)取出直送批，物化后再对出现的每个生产工单只判一次关系。
-- 同一视图、同一判定、同一求和，结果与原定义完全相同；只改求值次序。两个函数写成 plpgsql 并固定通用计划，
-- 执行计划按数据库连接缓存(原 LANGUAGE sql 每条外层语句都要重新规划一遍，见第 10 节)。
CREATE OR REPLACE FUNCTION fn_workshop_direct_source_available(p_warehouse UUID, p_demand UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE
SET plan_cache_mode = force_generic_plan AS $$
BEGIN
    RETURN (
    WITH lots AS MATERIALIZED (
        SELECT lot.producing_segment_id, lot.available_qty
        FROM production_material_demands demand
        JOIN v_workshop_direct_supply_lots lot
          ON lot.to_demand_id IN (demand.id, demand.split_root_demand_id)
         AND lot.line_side_warehouse_id = p_warehouse
         AND lot.goods_id = demand.goods_id
         AND lot.color_id IS NOT DISTINCT FROM demand.color_id
        WHERE demand.id = p_demand
    ), related AS MATERIALIZED (
        SELECT producing.producing_segment_id
        FROM (SELECT DISTINCT producing_segment_id FROM lots) producing
        WHERE fn_workshop_direct_relationship_allows(producing.producing_segment_id, p_demand)
    )
    SELECT COALESCE(SUM(lots.available_qty), 0)
    FROM lots JOIN related ON related.producing_segment_id = lots.producing_segment_id
    );
END
$$;

CREATE OR REPLACE FUNCTION fn_workshop_direct_covered_base_qty(p_demand UUID)
RETURNS NUMERIC LANGUAGE plpgsql STABLE
SET plan_cache_mode = force_generic_plan AS $$
BEGIN
    RETURN (
    WITH lots AS MATERIALIZED (
        SELECT lot.producing_segment_id, lot.available_qty
        FROM production_material_demands demand
        JOIN v_workshop_direct_supply_lots lot
          ON lot.to_demand_id IN (demand.id, demand.split_root_demand_id)
        WHERE demand.id = p_demand
    ), related AS MATERIALIZED (
        SELECT producing.producing_segment_id
        FROM (SELECT DISTINCT producing_segment_id FROM lots) producing
        WHERE fn_workshop_direct_relationship_allows(producing.producing_segment_id, p_demand)
    )
    SELECT COALESCE((SELECT SUM(qty - released_qty) FROM stock_reservations
                     WHERE demand_id = p_demand AND NOT is_deleted), 0)
         + COALESCE((SELECT SUM(lots.available_qty)
                     FROM lots JOIN related ON related.producing_segment_id = lots.producing_segment_id), 0)
    );
END
$$;

-- ============ 10. 审核路径上的几个来源证明函数改为按会话缓存执行计划(ADR-127 第三步，语义逐字不变) ============
-- 这五个函数原是 LANGUAGE sql 的单条查询(四个来源证明 + 线边仓料是否指名给这条需求)。PostgreSQL 16 对这种函数不缓存执行计划：外层每条语句
-- (以及每次从别的函数里调用)都要把函数体重新规划一遍。「合格来源证明」一次规划实测 60-130ms，
-- 执行不到 1ms；一张报工分给 11 个上层工单时审核里要调它几百次，时间几乎全花在反复规划上。
-- 改为 plpgsql 的 RETURN (原查询)：查询文本从现有定义原样取出，不手抄、不改条件；plpgsql 在同一个
-- 数据库连接里只规划一次并复用。名称、参数名、返回值、STABLE/STRICT 全部保持。函数上固定
-- plan_cache_mode = force_generic_plan：与原 SQL 函数一样按「参数未知」规划(计划形状不变)，只是不再每次重做；
-- 不固定的话 plpgsql 会因「带参数值的计划估价更低」而一直按调用重新规划，等于没改。
-- 合格来源证明另加三处「先按主键取驱动行」的 OFFSET 0 围栏(条件本来就要求这些主键相等)：
-- 执行时先按预留取它自己的权益事件、按事件指向的入库行取那一行，再去比对其余条件，
-- 不再先扫同一车间段的全部入库行、逐行判断是否公共产出。
DO $plan_cached_proofs$
DECLARE
    target RECORD;
    body TEXT;
    needle TEXT;
    replacement TEXT;
BEGIN
    FOR target IN
        SELECT proc.oid, proc.proname, proc.prosrc, proc.proisstrict, proc.provolatile,
               proc.prorettype, language.lanname
        FROM pg_proc proc
        JOIN pg_language language ON language.oid = proc.prolang
        WHERE proc.oid IN (
            'fn_preplan_reservation_has_qualified_origin(uuid)'::regprocedure,
            'fn_workshop_direct_responsibility_allows_before_v715(uuid,uuid)'::regprocedure,
            'fn_finished_in_is_public_output(uuid)'::regprocedure,
            'fn_daily_report_is_public_output(uuid)'::regprocedure,
            'fn_line_side_stock_targets_demand(uuid,uuid)'::regprocedure)
        ORDER BY proc.proname
    LOOP
        IF target.lanname <> 'sql' OR target.provolatile <> 's' OR target.prorettype <> 'boolean'::regtype THEN
            RAISE EXCEPTION 'V736 % is no longer a STABLE boolean SQL function', target.proname;
        END IF;
        body := regexp_replace(replace(target.prosrc, chr(13), ''), '[[:space:];]+$', '');
        body := regexp_replace(body, '^[[:space:]]+', '');
        IF body !~* '^SELECT[[:space:]]' THEN
            RAISE EXCEPTION 'V736 % body is not a single SELECT', target.proname;
        END IF;
        IF target.proname = 'fn_preplan_reservation_has_qualified_origin' THEN
            FOR needle, replacement IN VALUES
                ('JOIN preplan_stock_entitlement_events origin_event',
                 'JOIN (SELECT * FROM preplan_stock_entitlement_events own_event'
                     || ' WHERE own_event.stock_reservation_id=p_reservation OFFSET 0) origin_event'),
                ('SELECT 1 FROM procurement_iqc_stock_in_batch_items stock_item',
                 'SELECT 1 FROM (SELECT * FROM procurement_iqc_stock_in_batch_items driving'
                     || ' WHERE driving.id=origin_event.event_group_id OFFSET 0) stock_item'),
                ('SELECT 1 FROM stock_document_items stock_item',
                 'SELECT 1 FROM (SELECT * FROM stock_document_items driving'
                     || ' WHERE driving.id=exact.source_stock_document_item_id OFFSET 0) stock_item')
            LOOP
                IF (length(body) - length(replace(body, needle, ''))) / length(needle) <> 1 THEN
                    RAISE EXCEPTION 'V736 qualified origin anchor changed: %', needle;
                END IF;
                body := replace(body, needle, replacement);
            END LOOP;
        END IF;
        EXECUTE format(
            'CREATE OR REPLACE FUNCTION public.%I(%s) RETURNS boolean LANGUAGE plpgsql STABLE%s'
                || ' SET plan_cache_mode = force_generic_plan AS %L',
            target.proname,
            pg_get_function_arguments(target.oid),
            CASE WHEN target.proisstrict THEN ' STRICT' ELSE '' END,
            E'BEGIN\n    RETURN (\n' || body || E'\n    );\nEND');
    END LOOP;
END
$plan_cached_proofs$;
