package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 委外领料对物料分析的覆盖投影(ADR-143 §4.5)。
 *
 * <p>委外件 P 与车间产品同构：委外订货明细领走的每一种直属物料，按「草稿 + 已发净量
 * − f_i(合格入库回厂量)」逐种计为 P 下面那个物料节点的已覆盖量，不同物料从不相加。
 * 订货明细合并了多张申请时，先整条扣掉已做成 P 入库的料，剩下的料中带专属交接的量归交接时
 * 记下的父节点，其余(公共库存领出)按各来源申请还缺的料分给各 P 节点；超出申请的超额与
 * 手工明细不归任何分析。这里只读事实，不授予任何可复用库存。</p>
 */
final class SubcontractComponentCustodyProjection {
    private SubcontractComponentCustodyProjection() {}

    /** Correlated to the original exact reservation, including already issued custody. */
    static final String TRANSFERRED_EVIDENCE = """
            EXISTS (
                SELECT 1 FROM subcontract_component_stock_handoffs custody
                JOIN stock_reservations outbound ON outbound.id=custody.target_reservation_id
                  AND NOT outbound.is_deleted AND outbound.qty>outbound.released_qty
                WHERE custody.source_reservation_id=reservation.id)
            """;

    /**
     * 订货明细 {@code item} 已合格入库的委外件基本量(回厂未经质检的整单入库计实收量，
     * 质检中的按仓库已确认入库量)，扣除已退回委外商的量。分析侧唯一口径：
     * 申请 DONE 判定、P 的计划产出与本投影的物料消耗都用它。
     */
    static final String ORDER_ITEM_STOCKED_BASE_SQL = """
            GREATEST(COALESCE((
                SELECT SUM(CASE WHEN inspection.id IS NULL
                                THEN receipt_item.qty*COALESCE(receipt_item.unit_rate,1)
                            WHEN inspection.status IN ('PARTIAL','RESOLVED')
                                THEN COALESCE(inspection.warehouse_stocked_base_qty,0)
                            ELSE 0 END)
                FROM (SELECT * FROM subcontract_receipt_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_receipt_items',archive_origin.id)) receipt_item
                JOIN (SELECT * FROM subcontract_receipts archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_receipts',archive_origin.id)) receipt ON receipt.id=receipt_item.receipt_id
                  AND receipt.status=1 AND NOT receipt.is_deleted
                LEFT JOIN procurement_inspection_items inspection ON inspection.receipt_type='SUBCONTRACT'
                  AND inspection.receipt_item_id=receipt_item.id
                WHERE receipt_item.order_item_id=item.id AND NOT receipt_item.is_deleted),0)
              -COALESCE(item.returned_qty,0)*COALESCE(item.unit_rate,1),0)
            """;

    /**
     * 委外供给行动 {@code action}(preplan_supply_actions 别名)的已合格入库回厂量 R_a(P 基本量)：
     * 该行动全部申请明细(含公共超量明细)所在订货明细的合格入库量，按来源 FIFO 分摊到这些申请明细后求和。
     */
    static final String ACTION_STOCKED_BASE_SQL = """
            COALESCE((
                SELECT SUM(fn_subcontract_order_source_share(item.id,source.application_item_id,
                    %s))
                FROM subcontract_order_item_sources source
                JOIN (SELECT * FROM subcontract_order_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_order_items',archive_origin.id)) item ON item.id=source.order_item_id AND NOT item.is_deleted
                JOIN (SELECT * FROM subcontract_orders archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_orders',archive_origin.id)) document ON document.id=item.order_id
                  AND document.status=1 AND NOT document.is_deleted
                WHERE source.alloc_qty>0 AND source.application_item_id IN (
                    SELECT allocation.external_item_id FROM preplan_supply_action_allocations allocation
                    WHERE allocation.action_id=action.id AND allocation.external_item_id IS NOT NULL
                    UNION
                    SELECT action.public_surplus_external_item_id
                    WHERE action.public_surplus_external_item_id IS NOT NULL)
            ),0)
            """.formatted(ORDER_ITEM_STOCKED_BASE_SQL);

    /**
     * 一个物料节点的委外领料覆盖。
     *
     * @param netQty 归属本节点的「草稿 + 已发净量 − f_i(合格入库回厂量)」(物料基本单位，不小于 0，未封顶)
     * @param remainingParentOutputQty 父节点 P 的剩余计划产出 U(P 基本量)：各未结委外供给行动
     *        按分摊比例的 (申请量 + 公共超量 − R_a)；调用方用它把覆盖封顶到 U 对应的物料需求
     */
    record ChildCoverage(UUID analysisItemId, String childNodeKey, UUID childMaterialId,
                         UUID goodsId, UUID colorId, BigDecimal netQty,
                         BigDecimal remainingParentOutputQty) {
    }

    /**
     * A draft still owns physical stock at its actual warehouse, exclusively for this child UUID.
     * The analysis filter runs first (MATERIALIZED): the per-row origin proof is expensive and
     * must only see this analysis' own open custody rows, never the company-wide handoff table.
     */
    static List<Object[]> held(EntityManager em, UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH scoped AS MATERIALIZED (
                    SELECT custody.id AS custody_id,custody.created_at,custody.source_reservation_id,
                           child.id AS child_id,child.analysis_item_id,child.node_key,
                           outbound.goods_id,outbound.color_id,child.unit_id,outbound.warehouse_id,
                           GREATEST(outbound.qty-outbound.consumed_qty-outbound.released_qty,0) AS qty
                    FROM production_material_analysis_materials child
                    JOIN subcontract_component_stock_handoffs custody ON custody.child_material_id=child.id
                    JOIN stock_reservations outbound ON outbound.id=custody.target_reservation_id
                      AND outbound.status=0 AND NOT outbound.is_deleted
                      AND outbound.qty>outbound.consumed_qty+outbound.released_qty
                    WHERE child.analysis_id=:analysisId AND child.active
                )
                SELECT custody_id,child_id,analysis_item_id,node_key,
                       goods_id,color_id,unit_id,warehouse_id,qty
                FROM scoped
                WHERE fn_preplan_reservation_has_qualified_origin(source_reservation_id)
                ORDER BY created_at,custody_id
                """).setParameter("analysisId", analysisId));
    }

    /**
     * 本分析每个委外 P 节点下各直属物料节点的领料覆盖(ADR-143 §4.5)。
     *
     * <p>口径(全部按物料逐种、物料基本单位计；订货单位 × 冻结单耗 b_i 换算)：
     * <ul>
     *   <li>剩余料 = 计划行已发净量(issued_qty) + 未发草稿量 − f_i(这条订货明细全部合格入库回厂量，
     *       含手工与超额部分)——已做成 P 并入库的料先整条扣掉，不再覆盖任何人的需求；</li>
     *   <li>各归属方还缺的料 = 归属订货量 × b_i − f_i(本方按来源先后分到的合格入库回厂量)，
     *       与 P 的剩余计划产出 U 用同一套来源先后分摊；</li>
     *   <li>专属交接量(交接记录 qty − 已释放)先归交接时的父节点，不超过该方还缺的料；
     *       合计超过剩余料时等比缩到剩余料；</li>
     *   <li>其余剩余料只分给扣掉专属量后仍有空额的归属方，按空额权重累计取整；
     *       超出全部空额的部分不归任何分析；</li>
     *   <li>归属订货量 = 来源申请明细的 alloc_qty × 该申请明细在各分析分摊行中的占比
     *       (只认委外 SUPPLY 行动，不含共享在途认领)。</li>
     * </ul>
     * 两张分析合并成一条订货明细、回厂按来源先后记到前一张时，领出的料也随之算作做进了前一张的 P：
     * 后一张仍按自己还缺的料显示缺口，不会把前一张已用掉的料当成自己的覆盖。
     * 顶层委外件(ROOT_SUPPLY)的直属物料是同一来源行的第 1 层节点。同一 P 下若有两个同物料同颜色的
     * 直属节点，覆盖全部记到路径最靠前的那个。</p>
     */
    static List<ChildCoverage> coverageForAnalysis(EntityManager em, UUID analysisId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery(("""
                WITH RECURSIVE live_actions AS MATERIALIZED (
                    SELECT action.id,action.requested_qty,action.public_surplus_qty,
                           action.public_surplus_external_item_id
                    FROM preplan_supply_actions action
                    WHERE action.analysis_id=:analysisId AND action.route='SUBCONTRACT'
                      AND action.operation_type='SUPPLY' AND action.status IN ('OPEN','CREATED','IN_PROGRESS')
                      AND action.external_document_type='SUBCONTRACT_APPLICATION'
                      AND (action.requested_qty>0 OR action.public_surplus_qty>0)
                ), live_items AS MATERIALIZED (
                    SELECT allocation.action_id,allocation.external_item_id AS application_item_id
                    FROM live_actions action
                    JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
                    WHERE allocation.external_item_id IS NOT NULL
                    UNION
                    SELECT action.id,action.public_surplus_external_item_id
                    FROM live_actions action WHERE action.public_surplus_external_item_id IS NOT NULL
                ), sources AS MATERIALIZED (
                    SELECT source.order_item_id,source.application_item_id,source.alloc_qty
                    FROM subcontract_order_item_sources source
                    JOIN (SELECT * FROM subcontract_order_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_order_items',archive_origin.id)) item ON item.id=source.order_item_id AND NOT item.is_deleted
                    JOIN (SELECT * FROM subcontract_orders archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_orders',archive_origin.id)) document ON document.id=item.order_id
                      AND document.status=1 AND NOT document.is_deleted
                    WHERE source.alloc_qty>0 AND source.order_item_id IN (
                        SELECT relevant.order_item_id FROM subcontract_order_item_sources relevant
                        WHERE relevant.application_item_id IN (SELECT application_item_id FROM live_items))
                ), stocked AS MATERIALIZED (
                    SELECT item.id AS order_item_id,COALESCE(item.unit_rate,1) AS order_unit_rate,
                           %s AS stocked_base
                    FROM (SELECT * FROM subcontract_order_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_order_items',archive_origin.id)) item
                    WHERE item.id IN (SELECT order_item_id FROM sources)
                ), received AS (
                    SELECT live.action_id,SUM(fn_subcontract_order_source_share(
                               source.order_item_id,source.application_item_id,stocked.stocked_base)) AS qty
                    FROM live_items live
                    JOIN sources source ON source.application_item_id=live.application_item_id
                    JOIN stocked ON stocked.order_item_id=source.order_item_id
                    GROUP BY live.action_id
                ), public_owners AS MATERIALIZED (
                    SELECT responsibility.*
                    FROM preplan_supply_actions action
                    CROSS JOIN LATERAL (
                """ + SubcontractPublicResponsibilityProjection.OWNERS_FOR_ACTION_SQL + """
                    ) responsibility
                    WHERE action.route='SUBCONTRACT' AND action.operation_type='SUPPLY'
                      AND action.status<>'CANCELLED' AND action.requested_qty=0 AND action.public_surplus_qty>0
                      AND action.public_surplus_external_item_id IN (SELECT application_item_id FROM sources)
                ), private_budget_allocations AS MATERIALIZED (
                """ + MaterialAnalysisService.allocationBudgetRowsSql(
                        "source.analysis_id=:analysisId AND source.action_id IN (SELECT id FROM live_actions)") + """
                ), parent_output_parts AS (
                    SELECT allocation.analysis_material_id AS parent_material_id,
                           SUM(
                """ + MaterialAnalysisService.allocationBudgetShareSql(
                        "action.requested_qty+action.public_surplus_qty-COALESCE(received.qty,0)") + """
                           ) AS remaining_qty
                    FROM live_actions action
                    JOIN private_budget_allocations allocation ON allocation.action_id=action.id
                      AND allocation.analysis_id=:analysisId AND allocation.allocated_qty>0
                    LEFT JOIN received ON received.action_id=action.id
                    WHERE action.requested_qty>0
                    GROUP BY allocation.analysis_material_id
                    UNION ALL
                    SELECT responsibility.analysis_material_id,
                """ + SubcontractPublicResponsibilityProjection.remainingShareSql(
                        "action.public_surplus_qty-COALESCE(received.qty,0)") + """
                    FROM public_owners responsibility
                    JOIN live_actions action ON action.id=responsibility.action_id
                    LEFT JOIN received ON received.action_id=action.id
                ), parent_output AS (
                    SELECT parent_material_id,SUM(remaining_qty) AS remaining_qty
                    FROM parent_output_parts GROUP BY parent_material_id
                ), owner_allocations AS (
                    SELECT source.order_item_id,source.application_item_id,source.alloc_qty,
                           allocation.id AS allocation_id,allocation.analysis_id,
                           allocation.analysis_material_id,allocation.allocated_qty
                    FROM sources source
                    JOIN preplan_supply_action_allocations allocation
                      ON allocation.external_item_id=source.application_item_id AND allocation.allocated_qty>0
                    JOIN preplan_supply_actions action ON action.id=allocation.action_id
                      AND action.analysis_id=allocation.analysis_id
                      AND action.route='SUBCONTRACT' AND action.operation_type='SUPPLY'
                      AND action.status<>'CANCELLED' AND action.external_document_type='SUBCONTRACT_APPLICATION'
                    UNION
                    SELECT source.order_item_id,source.application_item_id,source.alloc_qty,
                           allocation.id,allocation.analysis_id,
                           allocation.analysis_material_id,allocation.allocated_qty
                    FROM sources source
                    JOIN preplan_supply_actions action
                      ON action.public_surplus_external_item_id=source.application_item_id
                      AND action.route='SUBCONTRACT' AND action.operation_type='SUPPLY'
                      AND action.status<>'CANCELLED' AND action.external_document_type='SUBCONTRACT_APPLICATION'
                    JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
                      AND allocation.analysis_id=action.analysis_id AND allocation.allocated_qty>0
                    UNION ALL
                    -- No private allocation is manufactured: this public-only physical
                    -- source has company-material responsibility from its frozen intent.
                    SELECT source.order_item_id,source.application_item_id,source.alloc_qty,
                           responsibility.analysis_material_id,responsibility.analysis_id,
                           responsibility.analysis_material_id,responsibility.qty
                    FROM sources source
                    JOIN public_owners responsibility ON responsibility.external_item_id=source.application_item_id
                ), owner_shares AS MATERIALIZED (
                    SELECT owner.order_item_id,owner.analysis_id,owner.analysis_material_id AS parent_material_id,
                           owner.allocated_qty,SUM(owner.allocated_qty) OVER(
                               PARTITION BY owner.order_item_id,owner.application_item_id) AS owner_total,
                           owner.alloc_qty,stocked.order_unit_rate,
                           fn_subcontract_order_source_share(owner.order_item_id,owner.application_item_id,
                               stocked.stocked_base) AS source_stocked_base
                    FROM owner_allocations owner
                    JOIN stocked ON stocked.order_item_id=owner.order_item_id
                ), plan_lines AS MATERIALIZED (
                    SELECT line.*,
                           GREATEST(line.gross_qty-(
                """ + ceilMaterialFractionSql("stocked.stocked_base*line.bom_unit_qty", "stocked.order_unit_rate") + """
                           ),0) AS pool_qty
                    FROM (
                        SELECT plan_item.id AS plan_item_id,plan_item.order_item_id,
                               plan_item.goods_id,plan_item.color_id,plan_item.bom_unit_qty,
                               plan_item.issued_qty+COALESCE((
                                   SELECT SUM(issue_item.qty)
                                   FROM (SELECT * FROM subcontract_material_issue_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_material_issue_items',archive_origin.id)) issue_item
                                   JOIN (SELECT * FROM subcontract_material_issues archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('subcontract_material_issues',archive_origin.id)) issue ON issue.id=issue_item.issue_id
                                     AND issue.status=0 AND NOT issue.is_deleted
                                   WHERE issue_item.plan_item_id=plan_item.id AND NOT issue_item.is_deleted),0) AS gross_qty
                        FROM subcontract_material_plan_items plan_item
                        JOIN subcontract_material_plans plan ON plan.id=plan_item.plan_id
                          AND NOT plan.is_deleted AND plan.status<>'CANCELED'
                        WHERE plan_item.order_item_id IN (SELECT order_item_id FROM stocked)
                          AND NOT plan_item.is_deleted AND plan_item.bom_unit_qty>0
                    ) line
                    JOIN stocked ON stocked.order_item_id=line.order_item_id
                ), owner_material_raw AS (
                    -- Material factors stay in numerators until the final ceiling.
                    SELECT line.plan_item_id,owner.analysis_id,owner.parent_material_id,
                           owner.alloc_qty*owner.allocated_qty*line.bom_unit_qty*owner.order_unit_rate AS owned_numerator,
                           owner.source_stocked_base*owner.allocated_qty*line.bom_unit_qty AS stocked_numerator,
                           owner.owner_total*owner.order_unit_rate AS denominator
                    FROM owner_shares owner
                    JOIN plan_lines line ON line.order_item_id=owner.order_item_id
                ), owner_material_integers AS (
                    SELECT raw.plan_item_id,raw.analysis_id,raw.parent_material_id,
                           raw.owned_numerator*factor.value AS owned_numerator,
                           raw.stocked_numerator*factor.value AS stocked_numerator,
                           raw.denominator*factor.value AS denominator
                    FROM owner_material_raw raw
                    CROSS JOIN LATERAL (
                        SELECT POWER(10::numeric,GREATEST(SCALE(raw.owned_numerator),
                            SCALE(raw.stocked_numerator),SCALE(raw.denominator))) AS value
                    ) factor
                ), owner_material_parts AS (
                    -- Merge equal denominators before the recursive fold, not raw allocation rows.
                    SELECT part.plan_item_id,part.analysis_id,part.parent_material_id,
                           SUM(div(part.owned_numerator,reduced.factor)) AS owned_numerator,
                           SUM(div(part.stocked_numerator,reduced.factor)) AS stocked_numerator,
                           div(part.denominator,reduced.factor) AS denominator
                    FROM owner_material_integers part
                    CROSS JOIN LATERAL (
                        SELECT gcd(gcd(part.owned_numerator,part.stocked_numerator),part.denominator) AS factor
                    ) reduced
                    GROUP BY part.plan_item_id,part.analysis_id,part.parent_material_id,
                             div(part.denominator,reduced.factor)
                ), owner_material_terms AS (
                    SELECT part.plan_item_id,part.analysis_id,part.parent_material_id,
                           div(part.owned_numerator,reduced.factor) AS owned_numerator,
                           div(part.stocked_numerator,reduced.factor) AS stocked_numerator,
                           div(part.denominator,reduced.factor) AS denominator,
                           ROW_NUMBER() OVER w AS part_number,
                           COUNT(*) OVER(PARTITION BY part.plan_item_id,part.analysis_id,part.parent_material_id) AS part_count
                    FROM owner_material_parts part
                    CROSS JOIN LATERAL (
                        SELECT gcd(gcd(part.owned_numerator,part.stocked_numerator),part.denominator) AS factor
                    ) reduced
                    WINDOW w AS (PARTITION BY part.plan_item_id,part.analysis_id,part.parent_material_id
                                 ORDER BY part.denominator)
                ), owner_material_sums AS (
                    -- Exact GCD/LCM addition preserves 1/6 + 1/13 + 10/39 = 1/2.
                    SELECT plan_item_id,analysis_id,parent_material_id,owned_numerator,stocked_numerator,
                           denominator,part_number,part_count
                    FROM owner_material_terms WHERE part_number=1
                    UNION ALL
                    SELECT part.plan_item_id,part.analysis_id,part.parent_material_id,
                           div(combined.owned_numerator,reduced.factor),
                           div(combined.stocked_numerator,reduced.factor),
                           div(combined.denominator,reduced.factor),part.part_number,part.part_count
                    FROM owner_material_sums running
                    JOIN owner_material_terms part ON part.plan_item_id=running.plan_item_id
                      AND part.analysis_id=running.analysis_id AND part.parent_material_id=running.parent_material_id
                      AND part.part_number=running.part_number+1
                    CROSS JOIN LATERAL (SELECT gcd(running.denominator,part.denominator) AS value) common
                    CROSS JOIN LATERAL (
                        SELECT div(part.denominator,common.value) AS running_factor,
                               div(running.denominator,common.value) AS part_factor
                    ) factors
                    CROSS JOIN LATERAL (
                        SELECT running.owned_numerator*factors.running_factor
                                   +part.owned_numerator*factors.part_factor AS owned_numerator,
                               running.stocked_numerator*factors.running_factor
                                   +part.stocked_numerator*factors.part_factor AS stocked_numerator,
                               running.denominator*factors.running_factor AS denominator
                    ) combined
                    CROSS JOIN LATERAL (
                        -- Evaluate this large GCD once instead of inlining it into each output.
                        SELECT gcd(gcd(combined.owned_numerator,combined.stocked_numerator),combined.denominator) AS factor
                        OFFSET 0
                    ) reduced
                ), owner_materials AS MATERIALIZED (
                    SELECT plan_item_id,analysis_id,parent_material_id,owned_numerator,stocked_numerator,denominator
                    FROM owner_material_sums WHERE part_number=part_count
                ), material_denominator_terms AS (
                    SELECT plan_item_id,denominator,
                           ROW_NUMBER() OVER(PARTITION BY plan_item_id ORDER BY denominator) AS part_number,
                           COUNT(*) OVER(PARTITION BY plan_item_id) AS part_count
                    FROM (SELECT DISTINCT plan_item_id,denominator FROM owner_materials) denominators
                ), material_denominator_sums AS (
                    SELECT plan_item_id,denominator,part_number,part_count
                    FROM material_denominator_terms WHERE part_number=1
                    UNION ALL
                    SELECT part.plan_item_id,
                           running.denominator*div(part.denominator,gcd(running.denominator,part.denominator)),
                           part.part_number,part.part_count
                    FROM material_denominator_sums running
                    JOIN material_denominator_terms part ON part.plan_item_id=running.plan_item_id
                      AND part.part_number=running.part_number+1
                ), material_units AS (
                    -- Every owner shares an integer scale; one four-decimal tick is base_denominator units.
                    SELECT plan_item_id,denominator AS base_denominator,denominator*10000 AS material_denominator
                    FROM material_denominator_sums WHERE part_number=part_count
                ), exact AS (
                    SELECT handoff.plan_item_id,handoff.parent_material_id,
                           SUM(GREATEST(LEAST(handoff.qty,target.qty)-target.released_qty,0)) AS qty
                    FROM plan_lines line
                    JOIN subcontract_component_stock_handoffs handoff ON handoff.plan_item_id=line.plan_item_id
                    JOIN stock_reservations target ON target.id=handoff.target_reservation_id
                      AND NOT target.is_deleted
                    GROUP BY handoff.plan_item_id,handoff.parent_material_id
                ), needs AS (
                    SELECT line.plan_item_id,line.goods_id,line.color_id,units.base_denominator,
                           line.pool_qty*units.material_denominator AS pool_units,
                           owner.analysis_id,owner.parent_material_id,owner_need.qty AS need_units,
                           LEAST(COALESCE(exact.qty,0)*units.material_denominator,owner_need.qty) AS exact_take_units
                    FROM plan_lines line
                    JOIN owner_materials owner ON owner.plan_item_id=line.plan_item_id
                    JOIN material_units units ON units.plan_item_id=line.plan_item_id
                    CROSS JOIN LATERAL (
                        SELECT GREATEST(owner.owned_numerator*10000-(
                """ + ceilMaterialFractionSql("owner.stocked_numerator", "owner.denominator") + """
                            )*10000*owner.denominator,0)*div(units.base_denominator,owner.denominator) AS qty
                    ) owner_need
                    LEFT JOIN exact ON exact.plan_item_id=line.plan_item_id
                      AND exact.parent_material_id=owner.parent_material_id
                ), exact_ranked AS (
                    SELECT needs.*,
                           SUM(exact_take_units) OVER(PARTITION BY plan_item_id) AS exact_total_units,
                           SUM(exact_take_units) OVER(PARTITION BY plan_item_id ORDER BY analysis_id,parent_material_id
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS exact_running_units
                    FROM needs
                ), balances AS (
                    -- Quantize the exact budget first; public stock may only use its remainder.
                    SELECT exact_ranked.*,
                """ + halfUpIntegerFractionSql(
                        "LEAST(pool_units,exact_total_units)*exact_running_units", "exact_total_units*base_denominator") + """
                           -(
                """ + halfUpIntegerFractionSql(
                        "LEAST(pool_units,exact_total_units)*(exact_running_units-exact_take_units)", "exact_total_units*base_denominator") + """
                           ) AS exact_ticks
                    FROM exact_ranked
                ), opens AS (
                    SELECT balances.*,GREATEST(need_units-exact_ticks*base_denominator,0) AS open_units,
                           GREATEST(pool_units-SUM(exact_ticks*base_denominator) OVER(PARTITION BY plan_item_id),0) AS public_left_units
                    FROM balances
                ), ranked AS (
                    SELECT opens.*,
                           LEAST(public_left_units,SUM(open_units) OVER(PARTITION BY plan_item_id)) AS public_pool_units,
                           SUM(open_units) OVER(PARTITION BY plan_item_id) AS open_total_units,
                           SUM(open_units) OVER(PARTITION BY plan_item_id ORDER BY analysis_id,parent_material_id
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS open_running_units
                    FROM opens
                ), nets AS (
                    SELECT parent_material_id,goods_id,color_id,
                           GREATEST((exact_ticks+(
                """ + halfUpIntegerFractionSql(
                        "public_pool_units*open_running_units", "open_total_units*base_denominator") + """
                           )-(
                """ + halfUpIntegerFractionSql(
                        "public_pool_units*(open_running_units-open_units)", "open_total_units*base_denominator") + """
                           ))/10000,0) AS net_qty
                    FROM ranked WHERE analysis_id=:analysisId
                )
                SELECT parent.analysis_item_id,child.node_key,child.id,nets.goods_id,nets.color_id,
                       SUM(nets.net_qty)::numeric,MAX(parent_output.remaining_qty)::numeric
                FROM nets
                JOIN parent_output ON parent_output.parent_material_id=nets.parent_material_id
                JOIN production_material_analysis_materials parent ON parent.id=nets.parent_material_id
                  AND parent.analysis_id=:analysisId AND parent.active
                JOIN LATERAL (
                    SELECT candidate.id,candidate.node_key
                    FROM production_material_analysis_materials candidate
                    WHERE candidate.analysis_id=parent.analysis_id
                      AND candidate.analysis_item_id=parent.analysis_item_id AND candidate.active
                      AND candidate.goods_id=nets.goods_id
                      AND candidate.color_id IS NOT DISTINCT FROM nets.color_id
                      AND ((parent.node_role='ROOT_SUPPLY' AND candidate.depth=1)
                           OR (parent.node_role<>'ROOT_SUPPLY' AND candidate.parent_node_key=parent.node_key))
                    ORDER BY candidate.path,candidate.node_key
                    LIMIT 1
                ) child ON TRUE
                GROUP BY parent.analysis_item_id,child.node_key,child.id,nets.goods_id,nets.color_id
                HAVING SUM(nets.net_qty)>0
                ORDER BY parent.analysis_item_id,child.node_key
                """).formatted(ORDER_ITEM_STOCKED_BASE_SQL)).setParameter("analysisId", analysisId))
                .stream()
                .map(row -> new ChildCoverage((UUID) row[0], (String) row[1], (UUID) row[2],
                        (UUID) row[3], (UUID) row[4], decimal(row[5]), decimal(row[6])))
                .toList();
    }

    /** Never approximate a ratio before a ceiling can promote its rounding tail by one material tick. */
    private static String ceilMaterialFractionSql(String numerator, String denominator) {
        return """
                fn_subcontract_draw_f((div((%s)*10000,(%s))
                    +CASE WHEN mod((%s)*10000,(%s))>0 THEN 1 ELSE 0 END)/10000,1)
                """.formatted(numerator,denominator,numerator,denominator);
    }

    /** Integer division keeps a repeating ratio from moving an exact half-tick boundary. */
    private static String halfUpIntegerFractionSql(String numerator, String denominator) {
        return """
                COALESCE(div((%s),NULLIF((%s),0))
                    +CASE WHEN 2*mod((%s),NULLIF((%s),0))>=(%s) THEN 1 ELSE 0 END,0)
                """.formatted(numerator,denominator,numerator,denominator,denominator);
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }
}
