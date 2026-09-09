package com.uten.imp.features.production.analysis;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * Directed callback footprint, never a transitive closure of every matching SKU.
 * All queries are reads without FOR UPDATE. The coordinator locks their result;
 * the owning command then locks execution rows and verifies this read again.
 */
@Service
@RequiredArgsConstructor
@Transactional(propagation = Propagation.MANDATORY, readOnly = true)
public class ProductionMutationFootprintService implements ProductionMutationFootprintPort {
    private final EntityManager em;

    @Override
    public FulfillmentMutationLockPlan forStockDocuments(Collection<UUID> rawIds) {
        List<UUID> ids = ids(rawIds);
        var result = new Footprint();
        result.parts.add("stock-documents:" + ids);
        if (ids.isEmpty()) return result.build();
        var changed = new LinkedHashSet<WarehouseDimension>();
        var planItems = new LinkedHashSet<UUID>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT document.id,document.warehouse_id,document.to_warehouse_id,document.doc_type,
                       item.id,item.goods_id,item.color_id,item.upstream_item_id,
                       md5(to_jsonb(document)::text),md5(to_jsonb(item)::text)
                FROM stock_documents document LEFT JOIN stock_document_items item
                  ON item.doc_id=document.id AND item.is_deleted=FALSE
                WHERE document.id IN (:ids) AND document.is_deleted=FALSE
                ORDER BY document.id,item.id
                """).setParameter("ids", ids))) {
            result.row("document", row);
            UUID goods = (UUID) row[5], color = (UUID) row[6];
            result.inventory(goods, color);
            if ("FINISHED_IN".equals(row[3]) && goods != null && row[1] != null) {
                changed.add(new WarehouseDimension((UUID) row[1], goods, color));
            }
            if (row[7] != null) planItems.add((UUID) row[7]);
        }
        // Own production plan and original stock entitlement analyses may be
        // completed before this command reopens them. Do not scan old completed
        // analyses merely because they once used the same goods.
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT link.id,plan.id,plan.material_analysis_id,md5(to_jsonb(link)::text)
                FROM plan_draw_links link JOIN production_plans plan ON plan.id=link.plan_id
                WHERE link.draw_id IN (:ids) AND link.is_deleted=FALSE AND plan.is_deleted=FALSE
                ORDER BY link.id
                """).setParameter("ids", ids))) {
            result.row("document-plan", row); result.analysis((UUID) row[2]);
        }
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT reservation.id,reservation.owner_id,reservation.goods_id,reservation.color_id,
                       md5(to_jsonb(reservation)::text)
                FROM stock_reservations reservation
                WHERE reservation.source_doc_type='PRODUCTION_INBOUND' AND reservation.source_doc_id IN (:ids)
                  AND reservation.owner_type='PREPLAN_ANALYSIS' AND reservation.is_deleted=FALSE
                ORDER BY reservation.id
                """).setParameter("ids", ids))) {
            result.row("original-entitlement", row); result.analysis((UUID) row[1]);
            result.inventory((UUID) row[2], (UUID) row[3]);
        }
        // FG withdrawal returns registered cost shares to their actual input
        // nodes. Historical/manual inputs need not exist in the current BOM.
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT input.input_node_id,pool.goods_id,pool.color_id,
                       fn_warehouse_main_id(pool.warehouse_id),md5(to_jsonb(input)::text)
                FROM stock_document_items item
                JOIN stock_movements movement ON movement.source_doc_type='STOCK_DOC'
                  AND movement.source_doc_id=item.doc_id AND movement.source_item_id=item.id AND movement.direction=1
                JOIN stock_value_production_cost_outputs output ON output.movement_id=movement.id
                JOIN stock_value_production_cost_inputs input ON input.execution_segment_id=output.execution_segment_id
                JOIN stock_value_nodes node ON node.id=input.input_node_id
                JOIN stock_value_pools pool ON pool.id=node.pool_id
                WHERE item.doc_id IN (:ids) AND item.bill_type='FINISHED_IN'
                ORDER BY input.input_node_id
                """).setParameter("ids",ids))) {
            result.row("finished-cost-input",row);
            result.inventory((UUID)row[1],(UUID)row[2]);
            if(row[3]!=null)result.warehouses.add((UUID)row[3]);
        }
        if (!planItems.isEmpty()) {
            for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT item.id,item.plan_id,item.sales_order_item_id,sales_item.order_id,
                           link.id,linked_sale.order_id,md5(to_jsonb(item)::text),md5(to_jsonb(link)::text)
                    FROM production_plan_items item
                    LEFT JOIN sales_order_items sales_item ON sales_item.id=item.sales_order_item_id
                    LEFT JOIN plan_order_item_links link ON link.plan_item_id=item.id AND link.is_deleted=FALSE
                    LEFT JOIN sales_order_items linked_sale ON linked_sale.id=link.order_item_id
                    WHERE item.id IN (:ids) AND item.is_deleted=FALSE ORDER BY item.id,link.id
                    """).setParameter("ids", planItems))) {
                result.row("plan-sales", row); result.sales((UUID) row[3]); result.sales((UUID) row[5]);
            }
        }
        // Parent execution may become ready after receiving this component. Its
        // other demand dimensions belong in the same initial inventory lock set.
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH affected_segments AS (
                    SELECT DISTINCT demand.execution_segment_id
                    FROM stock_document_items item
                    JOIN production_material_supply_pegs peg ON peg.supply_type='PRODUCTION_PLAN_ITEM'
                      AND peg.supply_item_id=item.upstream_item_id AND peg.status<>'REVERSED'
                    JOIN production_material_demands demand ON demand.id=peg.demand_id AND demand.is_deleted=FALSE
                    WHERE item.doc_id IN (:ids) AND item.is_deleted=FALSE AND item.bill_type='FINISHED_IN'
                      AND demand.execution_segment_id IS NOT NULL
                )
                SELECT demand.id,demand.goods_id,demand.color_id,plan.material_analysis_id,
                       md5(to_jsonb(demand)::text)
                FROM affected_segments source JOIN production_material_demands demand
                  ON demand.execution_segment_id=source.execution_segment_id AND demand.is_deleted=FALSE
                  AND demand.status NOT IN ('RELEASED','REVERSED')
                JOIN production_plans plan ON plan.id=demand.plan_id AND plan.is_deleted=FALSE
                ORDER BY demand.id
                """).setParameter("ids", ids))) {
            result.row("parent-demand", row); result.inventory((UUID) row[1], (UUID) row[2]);
            result.analysis((UUID) row[3]);
        }
        addWakeupTargets(result, changed);
        expandAnalyses(result);
        return result.build();
    }

    @Override
    public FulfillmentMutationLockPlan forAnalyses(Collection<UUID> analysisIds) {
        var result = new Footprint(); ids(analysisIds).forEach(result::analysis);
        expandAnalyses(result); return result.build();
    }

    @Override
    public FulfillmentMutationLockPlan forSharedFutureClaim(UUID analysisId) {
        var result = new Footprint();
        result.analysis(analysisId);
        // A new claim will reference an existing request/application. Discover
        // that commercial source before entering inventory and analysis locks;
        // the post-insert refresh must never acquire an upstream lock late.
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT source.source_action_id,source.external_document_type,
                       source.external_document_id,source.claim_external_item_id,
                       source.available_to_claim_qty,source.expected_date
                FROM v_preplan_public_surplus_source_state source
                JOIN production_material_analyses analysis ON analysis.id=:analysisId
                  AND analysis.is_deleted=FALSE AND analysis.warehouse_id=source.warehouse_id
                WHERE source.source_analysis_id<>analysis.id
                  AND source.available_to_claim_qty>0 AND source.claim_external_item_id IS NOT NULL
                  AND source.external_document_type IN ('PURCHASE_REQUEST','SUBCONTRACT_APPLICATION')
                  AND EXISTS (
                    SELECT 1 FROM production_material_analysis_materials material
                    WHERE material.analysis_id=analysis.id AND material.active=TRUE
                      AND material.goods_id=source.goods_id
                      AND material.color_id IS NOT DISTINCT FROM source.color_id
                      AND material.unit_id=source.unit_id)
                ORDER BY source.source_action_id
                """).setParameter("analysisId", analysisId))) {
            result.row("shared-future-source", row);
            result.sources.add(new CommercialSource(
                    "PURCHASE_REQUEST".equals(row[1])
                            ? CommercialType.PURCHASE_REQUEST : CommercialType.SUBCONTRACT_APPLICATION,
                    (UUID) row[2]));
        }
        expandAnalyses(result);
        return result.build();
    }

    @Override
    public FulfillmentMutationLockPlan forPreview(
            Collection<UUID> salesItemIds, Collection<UUID> subcontractItemIds,
            Collection<WarehouseDimension> manualRoots, Collection<UUID> warehouseIds,
            Collection<UUID> existingAnalysisIds) {
        var result = new Footprint(); ids(existingAnalysisIds).forEach(result::analysis);
        var roots = new LinkedHashSet<UUID>();
        if (manualRoots != null) for (WarehouseDimension root : manualRoots) {
            result.inventory(root.goodsId(),root.colorId()); roots.add(root.goodsId());
            result.parts.add("preview-root:" + root);
        }
        List<UUID> sales = ids(salesItemIds), subcontract = ids(subcontractItemIds), warehouses = ids(warehouseIds);
        if (!sales.isEmpty()) for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id,item.order_id,item.goods_id,item.color_id,
                       md5(to_jsonb(item)::text),md5(to_jsonb(header)::text)
                FROM sales_order_items item JOIN sales_orders header ON header.id=item.order_id
                WHERE item.id IN (:ids) ORDER BY item.id
                """).setParameter("ids",sales))) {
            result.row("preview-sale",row); result.sales((UUID)row[1]);
            result.inventory((UUID)row[2],(UUID)row[3]); roots.add((UUID)row[2]);
        }
        if (!subcontract.isEmpty()) for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id,item.order_id,item.goods_id,item.color_id,source.id,application.application_id,
                       md5(to_jsonb(item)::text),md5(to_jsonb(source)::text)
                FROM subcontract_order_items item
                LEFT JOIN subcontract_order_item_sources source ON source.order_item_id=item.id
                LEFT JOIN subcontract_application_items application ON application.id=source.application_item_id
                WHERE item.id IN (:ids) ORDER BY item.id,source.id
                """).setParameter("ids",subcontract))) {
            result.row("preview-subcontract",row);
            result.sources.add(new CommercialSource(CommercialType.SUBCONTRACT_ORDER,(UUID)row[1]));
            if (row[5]!=null) result.sources.add(new CommercialSource(CommercialType.SUBCONTRACT_APPLICATION,(UUID)row[5]));
            result.inventory((UUID)row[2],(UUID)row[3]); roots.add((UUID)row[2]);
        }
        if (!warehouses.isEmpty()) for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,fn_warehouse_main_id(id),parent_id FROM warehouses WHERE id IN (:ids) ORDER BY id
                """).setParameter("ids",warehouses))) {
            result.row("preview-warehouse",row); if (row[1]!=null) result.warehouses.add((UUID)row[1]);
        }
        addCurrentBom(result,roots); expandAnalyses(result); return result.build();
    }

    @Override
    public FulfillmentMutationLockPlan forInventoryChange(
            Collection<WarehouseDimension> changedDimensions, Collection<UUID> exactAnalysisIds) {
        var result = new Footprint(); ids(exactAnalysisIds).forEach(result::analysis);
        List<WarehouseDimension> changed = changedDimensions == null ? List.of() : changedDimensions.stream()
                .filter(Objects::nonNull).filter(d -> d.goodsId()!=null && d.warehouseId()!=null).distinct().toList();
        changed.forEach(d -> result.inventory(d.goodsId(), d.colorId()));
        addWakeupTargets(result, changed); expandAnalyses(result); return result.build();
    }

    private void addWakeupTargets(Footprint result, Collection<WarehouseDimension> changed) {
        if (changed.isEmpty()) return;
        List<WarehouseDimension> dimensions = changed.stream().distinct()
                .sorted(Comparator.comparing(WarehouseDimension::toString)).toList();
        dimensions.forEach(d -> result.parts.add("changed-supply:" + d));
        // Before the first stock-in no ORIGIN/reservation exists yet. The
        // procurement footprint supplies its exact commercial analysis IDs;
        // the requested physical warehouse must already be locked as well.
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id,fn_warehouse_main_id(id) FROM warehouses WHERE id IN (:ids) ORDER BY id
                """).setParameter("ids", dimensions.stream().map(WarehouseDimension::warehouseId).distinct().toList()))) {
            result.row("changed-warehouse", row);
            if (row[1]!=null) result.warehouses.add((UUID)row[1]);
        }
        String warehouses = dimensions.stream().map(d -> d.warehouseId().toString()).collect(Collectors.joining(","));
        String goods = dimensions.stream().map(d -> d.goodsId().toString()).collect(Collectors.joining(","));
        String colors = dimensions.stream().map(d -> Objects.toString(d.colorId(), "")).collect(Collectors.joining(","));
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH dimensions AS (
                    SELECT * FROM unnest(CAST(string_to_array(:warehouses,',') AS uuid[]),
                        CAST(string_to_array(:goods,',') AS uuid[]),
                        CAST(string_to_array(:colors,',','') AS uuid[])) AS d(warehouse_id,goods_id,color_id)
                )
                SELECT analysis.id,analysis.warehouse_id
                FROM production_material_analyses analysis
                WHERE analysis.is_deleted=FALSE AND analysis.warehouse_id IS NOT NULL
                  AND (analysis.status IN ('ACTIVE','PARTIALLY_PLANNED') OR analysis.status='COMPLETED'
                    AND fn_material_analysis_fulfillment_status(analysis.id)<>'COMPLETED')
                  AND EXISTS(SELECT 1 FROM production_material_analysis_materials material
                    JOIN dimensions d ON d.goods_id=material.goods_id
                      AND d.color_id IS NOT DISTINCT FROM material.color_id
                    WHERE material.analysis_id=analysis.id AND material.active=TRUE
                      AND (fn_warehouse_same_main(d.warehouse_id,analysis.warehouse_id)
                        OR """ + MaterialAnalysisWakeupScopeSql.ownsQualifiedAt(
                            "analysis.id", "material.id", "d.warehouse_id", "d.goods_id", "d.color_id") + """
                        ))
                ORDER BY analysis.id
                """).setParameter("warehouses", warehouses).setParameter("goods", goods).setParameter("colors", colors))) {
            result.analysis((UUID) row[0]);
        }
    }

    private void expandAnalyses(Footprint result) {
        if (result.analyses.isEmpty()) return;
        Set<UUID> analyses = Set.copyOf(result.analyses);
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT source.id,item.order_id,md5(to_jsonb(item)::text),md5(to_jsonb(orders)::text)
                FROM production_material_analysis_items source JOIN subcontract_order_items item ON source.source_ref='SC-ORDER:'||item.id::text
                JOIN subcontract_orders orders ON orders.id=item.order_id
                WHERE source.analysis_id IN(:ids) AND source.source_type='SUBCONTRACT_PREPARATION' AND source.is_deleted=FALSE ORDER BY source.id
                """).setParameter("ids",analyses))){result.row("direct-subcontract-order",row);result.sources.add(new CommercialSource(CommercialType.SUBCONTRACT_ORDER,(UUID)row[1]));}
        // Cancelling or regenerating a supply action calls the owning request
        // lifecycle. Those commercial headers must precede I/A, even if the
        // current operation is initiated from the analysis page.
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT action.id,action.external_document_type,
                       COALESCE(request.id,application.id),md5(to_jsonb(action)::text)
                FROM preplan_supply_actions action
                LEFT JOIN purchase_requests request ON action.external_document_type='PURCHASE_REQUEST'
                  AND request.id=action.external_document_id
                LEFT JOIN subcontract_applications application ON action.external_document_type='SUBCONTRACT_APPLICATION'
                  AND application.id=action.external_document_id
                WHERE action.analysis_id IN (:ids)
                  AND action.external_document_type IN ('PURCHASE_REQUEST','SUBCONTRACT_APPLICATION')
                ORDER BY action.id
                """).setParameter("ids",analyses))) {
            result.row("analysis-external-source",row);
            if (row[2]!=null) result.sources.add(new CommercialSource(
                    "PURCHASE_REQUEST".equals(row[1]) ? CommercialType.PURCHASE_REQUEST : CommercialType.SUBCONTRACT_APPLICATION,
                    (UUID)row[2]));
        }
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT analysis.id,fn_warehouse_main_id(analysis.warehouse_id),md5(to_jsonb(analysis)::text),
                       item.id,sale.order_id,item.goods_id,item.color_id,md5(to_jsonb(item)::text)
                FROM production_material_analyses analysis
                LEFT JOIN production_material_analysis_items item ON item.analysis_id=analysis.id AND item.is_deleted=FALSE
                LEFT JOIN sales_order_items sale ON sale.id=item.sales_order_item_id AND item.source_type='SALES_ORDER_ITEM'
                WHERE analysis.id IN (:ids) AND analysis.is_deleted=FALSE ORDER BY analysis.id,item.id
                """).setParameter("ids", analyses))) {
            result.row("analysis", row); if (row[1]!=null) result.warehouses.add((UUID) row[1]);
            result.sales((UUID) row[4]); result.inventory((UUID) row[5], (UUID) row[6]);
        }
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT material.id,material.goods_id,material.color_id,md5(to_jsonb(material)::text)
                FROM production_material_analysis_materials material
                WHERE material.analysis_id IN (:ids) AND material.active=TRUE ORDER BY material.id
                """).setParameter("ids", analyses))) {
            result.row("material", row); result.inventory((UUID) row[1], (UUID) row[2]);
        }
        List<UUID> roots = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT DISTINCT item.goods_id FROM production_material_analysis_items item
                WHERE item.analysis_id IN (:ids) AND item.is_deleted=FALSE
                  AND item.source_type NOT IN ('MAKE_COMPONENT','SUBCONTRACT_MAKE')
                """, UUID.class).setParameter("ids",analyses),UUID.class);
        addCurrentBom(result,roots);
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT reservation.id,reservation.goods_id,reservation.color_id,md5(to_jsonb(reservation)::text),
                       fn_warehouse_main_id(reservation.warehouse_id)
                FROM stock_reservations reservation
                WHERE reservation.is_deleted=FALSE AND reservation.status=0
                  AND (reservation.owner_type='PREPLAN_ANALYSIS' AND reservation.owner_id IN (:ids)
                    OR EXISTS(SELECT 1 FROM v_preplan_stock_entitlement_beneficiary_balance entitlement
                       WHERE entitlement.stock_reservation_id=reservation.id
                         AND entitlement.beneficiary_analysis_id IN (:ids) AND entitlement.effective_qty>0)
                    OR reservation.owner_type='PRODUCTION_MATERIAL_DEMAND' AND reservation.qty>reservation.released_qty
                      AND EXISTS(SELECT 1 FROM preplan_stock_entitlement_events formalize
                        WHERE formalize.event_type='FORMALIZE' AND formalize.target_stock_reservation_id=reservation.id
                          AND formalize.beneficiary_analysis_id IN (:ids)
                          AND NOT EXISTS(SELECT 1 FROM preplan_stock_entitlement_events restored
                            WHERE restored.event_type='RESTORE' AND restored.counter_event_id=formalize.id)))
                ORDER BY reservation.id
                """).setParameter("ids", analyses))) {
            result.row("reservation", row); result.inventory((UUID) row[1], (UUID) row[2]);
            if (row[4]!=null) result.warehouses.add((UUID)row[4]);
        }
        // Intermediate SC assembly stays outside final-component entitlement.
        // Its original task and converted outbound reservations still require
        // their actual warehouses in the same directed mutation lock plan.
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT reservation.id,reservation.goods_id,reservation.color_id,
                       fn_warehouse_main_id(reservation.warehouse_id),md5(to_jsonb(reservation)::text)
                FROM stock_reservations reservation
                WHERE NOT reservation.is_deleted AND reservation.status=0 AND reservation.qty>reservation.released_qty
                  AND reservation.supply_type='PRODUCTION_FINISHED_IN'
                  AND (reservation.owner_type='SUBCONTRACT_PREPARE_TASK' AND EXISTS(
                        SELECT 1 FROM preplan_subcontract_make_tasks task
                        WHERE task.id=reservation.owner_id AND task.analysis_id IN (:ids))
                    OR reservation.owner_type='SUBCONTRACT_OUTBOUND' AND EXISTS(
                        SELECT 1 FROM subcontract_material_plan_items item
                        WHERE item.id=reservation.owner_id AND item.preparation_analysis_id IN (:ids))
                    OR reservation.owner_type='SUBCONTRACT_ORDER_PREPARATION' AND EXISTS(
                        SELECT 1 FROM stock_document_items item
                        JOIN production_plan_items production_item ON production_item.id=item.upstream_item_id
                        JOIN production_plans plan ON plan.id=production_item.plan_id
                        WHERE item.id=reservation.supply_id AND plan.material_analysis_id IN (:ids)))
                  AND fn_subcontract_preparation_reservation_has_qualified_origin(reservation.id)
                ORDER BY reservation.id
                """).setParameter("ids",analyses))) {
            result.row("subcontract-preparation-source",row);
            result.inventory((UUID)row[1],(UUID)row[2]);
            if(row[3]!=null)result.warehouses.add((UUID)row[3]);
        }
    }

    /**
     * Include the current BOM even when its root is BUY: this command may change
     * that route to MAKE. Lock reachability deduplicates each edge at each depth;
     * it does not enumerate every repeated BOM path. Business path validation
     * and exact quantities stay in MaterialAnalysisService.
     */
    private void addCurrentBom(Footprint result, Collection<UUID> roots) {
        if (roots.isEmpty()) return;
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                WITH RECURSIVE roots AS (
                    SELECT id AS goods_id FROM goods WHERE id IN (:rootIds)
                ), expansion AS (
                    SELECT bom.id,bom.component_goods_id,COALESCE(bom.color_id,goods.color_id) AS color_id,
                           1 AS depth,md5(to_jsonb(bom)::text) AS snapshot
                    FROM roots JOIN goods_bom_items bom ON bom.goods_id=roots.goods_id AND bom.is_deleted=FALSE
                    JOIN goods ON goods.id=bom.component_goods_id AND goods.is_deleted=FALSE
                    UNION
                    SELECT bom.id,bom.component_goods_id,COALESCE(bom.color_id,goods.color_id),
                           parent.depth+1,md5(to_jsonb(bom)::text)
                    FROM expansion parent JOIN goods_bom_items bom
                      ON bom.goods_id=parent.component_goods_id AND bom.is_deleted=FALSE
                    JOIN goods ON goods.id=bom.component_goods_id AND goods.is_deleted=FALSE
                    WHERE parent.depth<10
                )
                SELECT DISTINCT id,component_goods_id,color_id,snapshot FROM expansion ORDER BY id,component_goods_id,color_id
                """).setParameter("rootIds", roots))) {
            result.row("current-bom", row); result.inventory((UUID) row[1], (UUID) row[2]);
        }
    }

    private static List<UUID> ids(Collection<UUID> values) {
        return values == null ? List.of() : values.stream().filter(Objects::nonNull).distinct()
                .sorted(Comparator.comparing(UUID::toString)).toList();
    }

    private static final class Footprint {
        final Set<CommercialSource> sources = new LinkedHashSet<>();
        final Set<InventoryDimension> inventory = new LinkedHashSet<>();
        final Set<UUID> warehouses = new LinkedHashSet<>(), analyses = new LinkedHashSet<>();
        final List<String> parts = new ArrayList<>();
        void sales(UUID id) { if (id!=null) sources.add(new CommercialSource(CommercialType.SALES_ORDER,id)); }
        void analysis(UUID id) { if (id!=null) analyses.add(id); }
        void inventory(UUID goods, UUID color) { if (goods!=null) inventory.add(new InventoryDimension(goods,color)); }
        void row(String kind, Object[] row) { parts.add(kind + ":" + java.util.Arrays.toString(row)); }
        FulfillmentMutationLockPlan build() {
            return new FulfillmentMutationLockPlan(sources,inventory,warehouses,analyses,CanonicalFingerprint.sha256(parts));
        }
    }
}
