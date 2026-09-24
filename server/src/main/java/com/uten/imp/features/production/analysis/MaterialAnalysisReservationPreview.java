package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.common.inventory.MainWarehouseStockBudget;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.fulfillment.ContinuousSupplyBudget;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisService.*;

/** Projects confirmed-route reservations using the command's physical budget and exact source order. */
final class MaterialAnalysisReservationPreview {
    private final EntityManager em;
    private final ProductionExecutionReadinessService readiness;
    private final PreplanAnalysisPegPort sources;

    MaterialAnalysisReservationPreview(EntityManager em, ProductionExecutionReadinessService readiness,
            PreplanAnalysisPegPort sources) {
        this.em = em; this.readiness = readiness; this.sources = sources;
    }

    private record Need(UUID id, MaterialDimension dimension, List<MaterialRow> materials,
                        BigDecimal required, BigDecimal covered, BigDecimal future) {}
    private record Batch(List<Need> needs,List<UUID> materialIds,boolean continuous,boolean childMake,BigDecimal baseOutput) {}

    void project(UUID analysisId, UUID warehouse, List<IssuePreviewSeed> seeds,
            Map<UUID, SourceLine> sourceLines, List<BomNode> nodes, List<MaterialRow> materials,
            MaterialAnalysisIssuePreviewOverlay overlay) {
        Map<String,BomNode> byNode = new HashMap<>();
        nodes.forEach(node -> byNode.put(node.analysisItemId() + "|" + node.nodeKey(), node));
        Map<UUID,MaterialRow> byMaterial=new HashMap<>();materials.forEach(row->byMaterial.put(row.id(),row));
        Map<UUID,List<UUID>> matchingBySource=matchingMaterials(analysisId,seeds,false);
        Map<UUID,List<UUID>> matchingByParent=matchingMaterials(analysisId,seeds,true);
        List<Batch> batches=new ArrayList<>();
        int sequence = 0;
        for (IssuePreviewSeed seed : seeds) {
            sequence++;
            List<UUID> matching = seed.lineId()!=null?matchingBySource.getOrDefault(seed.lineId(),List.of())
                    :matchingByParent.getOrDefault(seed.newAnchorParentMaterialId(),List.of());
            List<MaterialRow> matched=matching.stream().map(byMaterial::get).filter(Objects::nonNull).toList();
            List<MaterialRow> direct = matched.stream().filter(row -> row.hardGate() && HARD_COMMITMENT_STAGES.contains(row.controlStage()))
                    .sorted(Comparator.comparing(MaterialRow::path).thenComparing(row -> row.id().toString())).toList();
            if (direct.isEmpty() && seed.growPlanId()==null) continue;
            SourceLine source = sourceLines.get(seed.lineId());
            BigDecimal rate = source == null ? BigDecimal.ONE : source.unitRate();
            BigDecimal baseOutput = seed.qty().multiply(rate);
            boolean continuous = true;
            List<Need> needs;
            UUID existingSegment = null;
            if (seed.growPlanId() != null) {
                List<Object[]> context = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT plan.status,item.qty,segment.id,segment.planned_qty,
                               segment.continuous_supply,fn_execution_route_allows_auto_promote(segment.id),
                               segment.auto_promote_when_ready,segment.product_unit_rate
                        FROM production_plans plan
                        JOIN production_plan_items item ON item.plan_id=plan.id AND NOT item.is_deleted
                        LEFT JOIN production_execution_segments segment ON segment.plan_id=plan.id AND NOT segment.is_deleted
                        WHERE plan.id=:plan
                        ORDER BY segment.segment_no,segment.id LIMIT 1
                        """).setParameter("plan",seed.growPlanId()));
                if (context.isEmpty()) throw conflict("追加计划来源已变化，请重新预览");
                Object[] row=context.getFirst();
                if (((Number)row[0]).intValue()==0) baseOutput=number(row[1]).add(seed.qty()).multiply(rate);
                else {
                    if (row[2]==null) throw conflict("已审核计划缺少执行段，请核对后重新预览");
                    if (!Boolean.TRUE.equals(row[5]) || !Boolean.TRUE.equals(row[6])) continue;
                    existingSegment=(UUID)row[2]; continuous=Boolean.TRUE.equals(row[4]);
                    baseOutput=number(row[3]).add(seed.qty()).multiply(number(row[7]));
                }
            }
            if (existingSegment == null) {
                if(direct.isEmpty())continue;
                Map<MaterialDimension,List<MaterialRow>> grouped = new LinkedHashMap<>();
                direct.forEach(row -> grouped.computeIfAbsent(row.dimension(), ignored -> new ArrayList<>()).add(row));
                needs=new ArrayList<>();
                for (var entry:grouped.entrySet()) {
                    BigDecimal required=BigDecimal.ZERO;
                    for (MaterialRow row:entry.getValue()) {
                        BomNode node=byNode.get(row.analysisItemId()+"|"+row.nodeKey());
                        if(node==null) throw conflict("下达预览缺少原始BOM路径，请重新分析");
                        required=required.add(node.requiredForSingleParentOutput(baseOutput));
                    }
                    UUID id=UUID.nameUUIDFromBytes(("ISSUE-PREVIEW:"+analysisId+":"+sequence+":"+entry.getKey()).getBytes(StandardCharsets.UTF_8));
                    List<MaterialRow> coveredPaths=matched.stream().filter(row->row.dimension().equals(entry.getKey()))
                            .sorted(Comparator.comparing(MaterialRow::path).thenComparing(MaterialRow::nodeKey)).toList();
                    needs.add(new Need(id,entry.getKey(),coveredPaths,required,BigDecimal.ZERO,BigDecimal.ZERO));
                }
            } else {
                needs=new ArrayList<>();
                for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT demand.id,demand.goods_id,demand.color_id,demand.unit_id,
                               fn_material_snapshot_required(demand.consumption_snapshot,segment.planned_qty+:added),
                               COALESCE((SELECT SUM(r.qty-r.released_qty) FROM stock_reservations r
                                   WHERE r.demand_id=demand.id AND NOT r.is_deleted),0),
                               COALESCE((SELECT SUM(p.allocated_qty-p.consumed_qty-p.released_qty)
                                   FROM production_material_supply_pegs p WHERE p.demand_id=demand.id AND p.status<>'REVERSED'),0)
                        FROM production_material_demands demand JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
                        WHERE segment.id=:segment AND NOT demand.is_deleted AND demand.material_increment_request_id IS NULL
                        ORDER BY demand.goods_id,demand.color_id NULLS FIRST,demand.id
                        """).setParameter("segment",existingSegment).setParameter("added",seed.qty()))) {
                    MaterialDimension dimension=new MaterialDimension((UUID)row[1],(UUID)row[2],(UUID)row[3]);
                    List<MaterialRow> paths=matched.stream().filter(material->material.dimension().equals(dimension))
                            .sorted(Comparator.comparing(MaterialRow::path).thenComparing(MaterialRow::nodeKey)).toList();
                    // A later master-BOM edit does not rewrite an existing task's frozen
                    // demand. It can still consume public stock without a current node peg.
                    needs.add(new Need((UUID)row[0],dimension,paths,number(row[4]),number(row[5]),number(row[6])));
                }
            }
            boolean childMake=source!=null ? "MAKE_COMPONENT".equals(source.sourceType())
                    : materials.stream().anyMatch(row->row.id().equals(seed.newAnchorParentMaterialId())&&"MAKE".equals(row.confirmedRoute()));
            batches.add(new Batch(needs,matching,continuous,childMake,baseOutput));
        }
        if(batches.isEmpty())return;
        // One physical-stock query for the entire command. Each virtual/existing demand keeps
        // its own original node mask; request order is applied only to in-memory budgets below.
        var allAvailability=readiness.previewBatchAvailability(warehouse,analysisId,batches.stream().flatMap(batch->batch.needs().stream()
                .map(need->new ProductionExecutionReadinessService.PreviewDemand(need.id(),need.dimension().goodsId(),need.dimension().colorId(),batch.materialIds()))).toList(),
                batches.stream().flatMap(batch->batch.materialIds().stream()).distinct().toList());
        Map<UUID,List<ProductionExecutionReadinessService.BatchAvailability>> allByDemand=new HashMap<>();
        allAvailability.forEach(row->allByDemand.computeIfAbsent(row.demandId(),ignored->new ArrayList<>()).add(row));
        for(Batch batch:batches) {
            List<Need> needs=batch.needs(); List<UUID> materialIds=batch.materialIds();
            // Growing a fixed/whole-package curve can require no new material. Its existing
            // formal coverage still belongs to the newly approved output quantity.
            if(batch.childMake())needs.forEach(need->overlay.updateFormalParentOutput(need.id(),batch.baseOutput()));
            Map<UUID,List<ProductionExecutionReadinessService.BatchAvailability>> byDemand=new HashMap<>();
            for(Need need:needs)byDemand.put(need.id(),adjust(need,materialIds,allByDemand.getOrDefault(need.id(),List.of()),overlay));
            // Modern analysis packages keep future responsibility in preplan actions. For
            // historical mixed packages, use the same actual receipt/peg selector as promotion.
            var receiptCandidates=readiness.previewGrowthReceipts(warehouse,needs.stream().filter(need->need.future().signum()>0)
                    .map(need->new ProductionExecutionReadinessService.PreviewReceiptDemand(need.id(),need.dimension().goodsId(),
                            need.dimension().colorId(),need.dimension().unitId(),need.required())).toList(),overlay.receipts(),overlay.publicReservations());
            Map<UUID,BigDecimal> increments=new LinkedHashMap<>();
            for(Need need:needs) {
                var leaves=byDemand.get(need.id());
                BigDecimal unprotected=leaves.stream().map(ProductionExecutionReadinessService.BatchAvailability::publicQty).reduce(BigDecimal.ZERO,BigDecimal::add);
                BigDecimal safety=leaves.stream().map(ProductionExecutionReadinessService.BatchAvailability::safetyQty).max(BigDecimal::compareTo).orElse(BigDecimal.ZERO);
                BigDecimal physical=MainWarehouseStockBudget.publicBudget(unprotected,safety).add(leaves.stream()
                        .map(ProductionExecutionReadinessService.BatchAvailability::qualifiedQty).reduce(BigDecimal.ZERO,BigDecimal::add));
                BigDecimal received=receiptCandidates.stream().filter(receipt->receipt.demandId().equals(need.id()))
                        .map(ProductionExecutionReadinessService.PreviewReceipt::qty).reduce(BigDecimal.ZERO,BigDecimal::add);
                BigDecimal take=ContinuousSupplyBudget.calculate(need.required(),need.covered(),need.future(),physical,
                        BigDecimal.ZERO,BigDecimal.ZERO,received,BigDecimal.ZERO,false).quantity();
                if(!batch.continuous() && take.compareTo(need.required().subtract(need.covered()).max(BigDecimal.ZERO))<0) {
                    increments.clear(); break;
                }
                if(take.signum()>0)increments.put(need.id(),take);
            }
            if(increments.isEmpty())continue;
            var selectedReceipts=readiness.previewGrowthReceipts(warehouse,needs.stream().filter(need->need.future().signum()>0&&increments.containsKey(need.id()))
                    .map(need->new ProductionExecutionReadinessService.PreviewReceiptDemand(need.id(),need.dimension().goodsId(),
                            need.dimension().colorId(),need.dimension().unitId(),increments.get(need.id()))).toList(),overlay.receipts(),overlay.publicReservations());
            Map<UUID,BigDecimal> generic=new LinkedHashMap<>(increments);
            for(var receipt:selectedReceipts) {
                Need need=needs.stream().filter(value->value.id().equals(receipt.demandId())).findFirst().orElseThrow();
                if(receipt.custodyReservationId()!=null)throw conflict("已有车间实物交接的任务不能按未开工计划追加");
                overlay.addReceipt(need.dimension(),receipt);
                generic.compute(receipt.demandId(),(id,qty)->qty.subtract(receipt.qty()));
            }
            // Exact received conversions happen before generic/preplan allocation in the real
            // command. Their actual leaves are debited before selecting the remaining sources.
            for(Need need:needs)byDemand.put(need.id(),adjust(need,materialIds,allByDemand.getOrDefault(need.id(),List.of()),overlay));
            var requests=needs.stream().filter(need->increments.containsKey(need.id())).map(need->new PreplanAnalysisPegPort.DemandSlice(
                    need.id(),need.dimension().goodsId(),need.dimension().colorId(),generic.get(need.id())))
                    .filter(request->request.requiredQty().signum()>0).toList();
            var prepared=needs.stream().filter(need->increments.containsKey(need.id())).flatMap(need->byDemand.get(need.id()).stream())
                    .anyMatch(leaf->leaf.ownedQty().signum()>0)
                    ?sources.previewAnalysisDemandTransfers(analysisId,warehouse,requests,materialIds,overlay.transfers(),overlay.publicReservations())
                    :List.<PreplanAnalysisPegPort.PreviewPlanTransfer>of();
            for(Need need:needs)if(increments.containsKey(need.id())) {
                var own=prepared.stream().filter(value->value.demandId().equals(need.id())).toList();
                var allocation=generic.get(need.id()).signum()>0?allocate(generic.get(need.id()),byDemand.get(need.id()),own):Map.<UUID,BigDecimal>of();
                own.forEach(value->overlay.addTransfer(need.dimension(),value));
                allocation.forEach((leaf,quantity)->overlay.addReservation(need.dimension(),leaf,quantity));
                for(MaterialRow material:need.materials()) overlay.addFormalCoverage(new FormalMaterialCoverage(need.id(),
                        material.analysisItemId(),material.nodeKey(),increments.get(need.id()),batch.childMake()?batch.baseOutput():null));
            }
        }
    }

    private Map<UUID,List<UUID>> matchingMaterials(UUID analysisId,List<IssuePreviewSeed> seeds,boolean parent) {
        var ids=seeds.stream().map(seed->parent?seed.newAnchorParentMaterialId():seed.lineId()).filter(Objects::nonNull).distinct().toList();
        if(ids.isEmpty())return Map.of();
        var query=em.createNativeQuery(!parent ? """
                SELECT source.id,material.id FROM production_material_analysis_items source
                LEFT JOIN production_material_analysis_materials parent ON parent.id=source.parent_analysis_material_id
                JOIN production_material_analysis_materials material ON material.analysis_id=source.analysis_id
                  AND material.analysis_item_id=COALESCE(parent.analysis_item_id,source.id)
                  AND ((parent.id IS NULL AND material.depth=1)
                    OR material.parent_node_key=parent.node_key
                    OR (parent.node_role='ROOT_SUPPLY' AND material.depth=1))
                  AND material.active AND fn_analysis_plan_material_matches(source.id,material.id)
                WHERE source.analysis_id=:analysis AND source.id IN (:sources) AND NOT source.is_deleted
                """ : """
                SELECT parent.id,material.id FROM production_material_analysis_materials material
                JOIN production_material_analysis_materials parent ON parent.id IN (:sources) AND parent.active
                  AND parent.analysis_id=material.analysis_id AND parent.analysis_item_id=material.analysis_item_id
                WHERE material.analysis_id=:analysis AND material.active
                  AND ((parent.node_role='ROOT_SUPPLY' AND material.depth=1 AND material.parent_node_key IS NULL)
                    OR (parent.node_role<>'ROOT_SUPPLY' AND material.parent_node_key=parent.node_key))
                """).setParameter("analysis",analysisId).setParameter("sources",ids);
        Map<UUID,List<UUID>> result=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(query))result.computeIfAbsent((UUID)row[0],ignored->new ArrayList<>()).add((UUID)row[1]);
        return result;
    }

    private static List<ProductionExecutionReadinessService.BatchAvailability> adjust(Need need,List<UUID> materialIds,
            List<ProductionExecutionReadinessService.BatchAvailability> available,MaterialAnalysisIssuePreviewOverlay overlay) {
        return available.stream().filter(row->row.demandId().equals(need.id())).map(row->{
            var key=new WarehouseMaterialDimension(row.warehouseId(),need.dimension());
            var previous=overlay.transfers().stream().filter(value->value.warehouseId().equals(row.warehouseId())
                    && need.dimension().equals(overlay.transferDimension(value.demandId()))
                    && (value.beneficiaryMaterialId()==null||materialIds.contains(value.beneficiaryMaterialId()))).toList();
            BigDecimal owned=row.ownedQty().subtract(previous.stream().map(PreplanAnalysisPegPort.PreviewPlanTransfer::qty)
                    .reduce(BigDecimal.ZERO,BigDecimal::add)).max(BigDecimal.ZERO);
            BigDecimal free=row.publicQty().add(row.qualifiedQty()).subtract(row.ownedQty())
                    .subtract(overlay.publicReservationChange(key)).add(owned).max(BigDecimal.ZERO);
            BigDecimal qualified=row.qualifiedQty().subtract(previous.stream().filter(PreplanAnalysisPegPort.PreviewPlanTransfer::qualified)
                    .map(PreplanAnalysisPegPort.PreviewPlanTransfer::qty).reduce(BigDecimal.ZERO,BigDecimal::add)).max(BigDecimal.ZERO).min(free);
            return new ProductionExecutionReadinessService.BatchAvailability(row.demandId(),row.warehouseId(),row.warehouseName(),
                    qualified,row.normalWarehouse()?free.subtract(qualified):BigDecimal.ZERO,row.safetyQty(),owned.signum()>0,
                    owned,row.normalWarehouse(),row.lineSide());
        }).sorted(Comparator.comparing(row->row.warehouseId().toString())).toList();
    }

    private static Map<UUID,BigDecimal> allocate(BigDecimal quantity,List<ProductionExecutionReadinessService.BatchAvailability> supply,
            List<PreplanAnalysisPegPort.PreviewPlanTransfer> prepared) {
        Map<UUID,BigDecimal> released=new LinkedHashMap<>();
        Map<UUID,ProductionMaterialAllocationFacade.OwnedSlice> owned=new LinkedHashMap<>();
        for(var source:prepared) {
            released.merge(source.warehouseId(),source.qty(),BigDecimal::add);
            if(source.explicitPreference())owned.merge(source.warehouseId(),new ProductionMaterialAllocationFacade.OwnedSlice(source.qty(),source.qualified()?source.qty():BigDecimal.ZERO),
                    (left,right)->new ProductionMaterialAllocationFacade.OwnedSlice(left.qty().add(right.qty()),left.qualifiedQty().add(right.qualifiedQty())));
        }
        List<UUID> normal=supply.stream().filter(ProductionExecutionReadinessService.BatchAvailability::normalWarehouse)
                .map(ProductionExecutionReadinessService.BatchAvailability::warehouseId).toList();
        Map<UUID,BigDecimal> physical=new LinkedHashMap<>();
        BigDecimal publicFree=BigDecimal.ZERO;
        for(var leaf:supply) {
            BigDecimal free=leaf.publicQty().add(leaf.qualifiedQty()).subtract(leaf.ownedQty()).add(released.getOrDefault(leaf.warehouseId(),BigDecimal.ZERO)).max(BigDecimal.ZERO);
            physical.put(leaf.warehouseId(),free);
            if(leaf.normalWarehouse())publicFree=publicFree.add(free.subtract(owned.getOrDefault(leaf.warehouseId(),new ProductionMaterialAllocationFacade.OwnedSlice(BigDecimal.ZERO,BigDecimal.ZERO)).qualifiedQty()).max(BigDecimal.ZERO));
        }
        BigDecimal[] budget={MainWarehouseStockBudget.publicBudget(publicFree,supply.stream().map(ProductionExecutionReadinessService.BatchAvailability::safetyQty).max(BigDecimal::compareTo).orElse(BigDecimal.ZERO))};
        BigDecimal[] pending={owned.entrySet().stream().filter(entry->normal.contains(entry.getKey())).map(entry->entry.getValue().qty().subtract(entry.getValue().qualifiedQty())).reduce(BigDecimal.ZERO,BigDecimal::add)};
        var allocation=ProductionMaterialAllocationFacade.allocateByQualifiedSourceOrder(quantity,normal,owned,(warehouse,limit,qualified,proof,isOwned)->{
            if(isOwned&&normal.contains(warehouse))pending[0]=pending[0].subtract(owned.get(warehouse).qty().subtract(owned.get(warehouse).qualifiedQty()));
            BigDecimal free=physical.getOrDefault(warehouse,BigDecimal.ZERO);
            BigDecimal take=ProductionMaterialAllocationFacade.allocationTake(limit,free,qualified,proof?BigDecimal.ZERO:budget[0].subtract(pending[0]).max(BigDecimal.ZERO));
            physical.put(warehouse,free.subtract(take));
            if(!proof)budget[0]=budget[0].subtract(take.subtract(qualified.min(free).min(take)));
            return take;
        });
        if(allocation.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(quantity)!=0)throw conflict("下达预览的实际来源库存不足，请刷新后重试");
        return allocation;
    }

    private static BigDecimal number(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
