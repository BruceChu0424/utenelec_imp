package com.uten.imp.features.production.mrp;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.common.inventory.MainWarehouseStockBudget;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequestService;
import com.uten.imp.features.production.execution.ProductionExecutionBatch;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService;
import com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

import static com.uten.imp.features.production.execution.ProductionExecutionBatch.*;

/** Explicit complete-kit sub-batches of an unused analysis-backed execution segment. */
@Service
@RequiredArgsConstructor
public class ProductionExecutionBatchService {
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionWorkshopMembership membership;
    private final ProductionExecutionPlanningService planning;
    private final ProductionExecutionReadinessService readiness;
    private final ProductionDrawRequestService drawRequests;
    private final ProductionPlanMutationFootprintService mutationFootprint;
    private final PreplanAnalysisPegPort preplanPeg;
    private final MasterCodeService codes;
    private final ChainNoticeService notices;
    private final ObjectMapper json;

    @Transactional(readOnly = true)
    public Preview preview(PreviewRequest request) {
        if (request == null || request.segmentId() == null) throw invalid("请选择需要分批领料的车间任务");
        Context context = context(request.segmentId(), request.expectedVersion(), false);
        return buildPreview(context, request.quantity());
    }

    @Transactional
    public Result submit(SubmitRequest request) {
        if (request == null || request.segmentId() == null || request.expectedVersion() == null
                || request.idempotencyKey() == null || !request.idempotencyKey().matches("[A-Za-z0-9._:-]{8,128}")
                || request.previewFingerprint() == null || !request.previewFingerprint().matches("[0-9a-f]{64}"))
            throw invalid("分批领料缺少任务、版本或幂等键，请重新核对汇总");
        BigDecimal quantity = positive(request.quantity());
        tx.bind();
        UUID actor = currentUser.requireId();
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,561))")
                .setParameter("key", actor + ":SPLIT:" + request.idempotencyKey()).getSingleResult();
        String hash = fingerprint(List.of(request.segmentId().toString(),request.expectedVersion().toString(),
                quantity.toPlainString(),request.previewFingerprint()));
        Source initial = source(request.segmentId());
        requireAccess(initial);
        List<Object[]> prior = rows("""
                SELECT source_segment_id,batch_segment_id,remaining_segment_id,request_hash
                FROM production_execution_segment_splits WHERE created_by=:actor AND idempotency_key=:key
                """, Map.of("actor",actor,"key",request.idempotencyKey()));
        if (!prior.isEmpty()) {
            Object[] replay=prior.getFirst();
            if (!request.segmentId().equals(replay[0]) || !hash.equals(replay[3])) throw conflict("相同幂等键对应不同分批领料请求");
            return new Result(uuid(replay[1]),uuid(replay[2]),documents(uuid(replay[1])),true);
        }
        var guard=mutationFootprint.beginPlan(initial.planId(),List.of());
        preplanPeg.lockPlanningPackageInventoryDimensions(initial.planId());
        lock("production_plans",initial.planId());
        lock("production_planning_packages",initial.packageId());
        lock("production_execution_segments",initial.id());
        Context context=context(initial.id(),request.expectedVersion(),true);
        Preview preview=buildPreview(context,quantity);
        if (!preview.fingerprint().equals(request.previewFingerprint())) throw conflict("物料库存、任务或BOM已变化，请重新核对分批领料汇总");
        if (quantity.compareTo(preview.maxReadyQty())>0) throw conflict("本次数量超过当前可齐套生产量");
        guard.verifyUnchanged();
        UUID batch=UUID.randomUUID();
        UUID remaining=preview.remainingQty().signum()>0?UUID.randomUUID():null;
        Source source=context.source();
        em.createNativeQuery("""
                INSERT INTO production_execution_segment_splits(source_segment_id,batch_segment_id,remaining_segment_id,
                    source_qty,batch_qty,remaining_qty,expected_version,request_hash,idempotency_key,created_by)
                VALUES(:source,:batch,:remaining,:total,:quantity,:residual,:version,:hash,:key,:actor)
                """).setParameter("source",source.id()).setParameter("batch",batch).setParameter("remaining",remaining)
                .setParameter("total",source.qty()).setParameter("quantity",quantity).setParameter("residual",preview.remainingQty())
                .setParameter("version",source.version()).setParameter("hash",hash).setParameter("key",request.idempotencyKey())
                .setParameter("actor",actor).executeUpdate();
        em.createNativeQuery("UPDATE production_execution_segments SET status='CANCELLED',lock_version=lock_version+1,updated_at=now(),updated_by=:actor WHERE id=:id")
                .setParameter("actor",actor).setParameter("id",source.id()).executeUpdate();
        em.createNativeQuery("""
                UPDATE production_material_demands SET released_qty=required_qty,status='RELEASED',lock_version=lock_version+1,updated_at=now(),updated_by=:actor
                WHERE execution_segment_id=:id AND NOT is_deleted
                """).setParameter("actor",actor).setParameter("id",source.id()).executeUpdate();
        List<MaterialSlice> batchMaterials=slices(context,source.offset(),quantity);
        createChild(context,batch,quantity,source.offset(),batchMaterials,actor);
        if (remaining!=null) createChild(context,remaining,preview.remainingQty(),source.offset().add(quantity),
                slices(context,source.offset().add(quantity),preview.remainingQty()),actor);
        splitSalesAllocations(source.id(),batch,remaining,quantity,actor);
        if (batchMaterials.stream().allMatch(material->material.requiredQty().signum()==0)) {
            em.createNativeQuery("UPDATE production_execution_segments SET status='READY',updated_by=:actor WHERE id=:id")
                    .setParameter("actor",actor).setParameter("id",batch).executeUpdate();
        } else {
            readiness.promoteAfterMaterialRecheck(batch,source.warehouseId());
            long version=((Number)em.createNativeQuery("SELECT lock_version FROM production_execution_segments WHERE id=:id")
                    .setParameter("id",batch).getSingleResult()).longValue();
            var drawPreview=drawRequests.preview(new ProductionDrawRequest.PreviewRequest(
                    List.of(new ProductionDrawRequest.Item(batch,version))));
            if (!distribution(preview.summaries()).equals(distribution(drawPreview.summaries())))
                throw conflict("实际领料分仓或数量与刚才核对的汇总不同，本次未提交；请刷新后重新确认");
            drawRequests.submit(new ProductionDrawRequest.SubmitRequest(
                    List.of(new ProductionDrawRequest.Item(batch,version)),
                    "batch-draw-"+batch,drawPreview.fingerprint()));
        }
        notices.resolveProductionWorkshopTasks(List.of(source.id()),"SPLIT");
        if (remaining!=null) notices.notifyExecutionSegmentWorkshopAssigned(remaining);
        return new Result(batch,remaining,documents(batch),false);
    }

    private Context context(UUID id,Long expectedVersion,boolean locked) {
        Source source=source(id); requireAccess(source);
        if (expectedVersion!=null && expectedVersion!=source.version()) throw conflict("车间任务已变化，请刷新后重新选择");
        if(!source.autoPromote())throw conflict("该任务已人工暂缓，请先解除暂缓后再分批领料");
        if (!"WAITING".equals(source.status()) || source.analysisId()==null || source.closed()
                || source.workshopId()==null || !source.active()) throw conflict("仅有效物料分析来源的等待物料任务可以分批领料");
        Number activity=(Number)em.createNativeQuery("""
                SELECT (SELECT count(*) FROM production_planning_package_documents WHERE execution_segment_id=:id)
                    +(SELECT count(*) FROM production_daily_report_items WHERE execution_segment_id=:id)
                    +(SELECT count(*) FROM production_material_demands demand
                       JOIN production_material_supply_pegs peg ON peg.demand_id=demand.id WHERE demand.execution_segment_id=:id)
                    +(SELECT count(*) FROM production_material_demands demand
                       JOIN stock_reservations reservation ON reservation.demand_id=demand.id WHERE demand.execution_segment_id=:id)
                """).setParameter("id",id).getSingleResult();
        if (activity.longValue()!=0) throw conflict("该任务已有正式采购或委外供给绑定、物料预留或领用记录，须先核对来源，不能直接拆批");
        var snapshot=locked?planning.lockedSnapshot(source.planId(),source.warehouseId(),Map.of()):planning.preview(source.planId(),source.warehouseId());
        var product=snapshot.productLines().stream().filter(line->line.sourcePlanItemId().equals(source.planItemId()))
                .findFirst().orElseThrow(()->conflict("原计划行BOM快照不可用"));
        if (!source.bomFingerprint().equalsIgnoreCase(product.bomFingerprint())) throw conflict("BOM已变化，不能按当前规则改算原冻结任务，请先处理原计划");
        List<Material> materials=rows("""
                SELECT root.id,root.goods_id,goods.code,goods.name,root.color_id,color.name,root.unit_id,unit.name,
                    root.required_qty,root.per_product_qty,root.supply_route,current_demand.id,current_demand.required_qty,
                    COALESCE((SELECT sum(prior_demand.required_qty) FROM production_material_demands prior_demand
                        JOIN production_execution_segments prior ON prior.id=prior_demand.execution_segment_id
                        WHERE prior_demand.split_root_demand_id=root.id AND prior.split_root_segment_id=:root
                          AND prior.split_start_qty+prior.planned_qty<=:offset AND prior.status NOT IN ('CANCELLED','REVERSED')
                          AND prior_demand.status='FULFILLED' AND NOT prior.is_deleted AND NOT prior_demand.is_deleted
                          AND NOT EXISTS(SELECT 1 FROM production_material_stock_postings issue WHERE issue.demand_id=prior_demand.id
                            AND issue.posting_type='ISSUE' AND fn_material_issue_pending_return(issue.id,NULL)>0)),0)
                FROM production_material_demands root JOIN goods ON goods.id=root.goods_id
                LEFT JOIN colors color ON color.id=root.color_id LEFT JOIN units unit ON unit.id=root.unit_id
                LEFT JOIN production_material_demands current_demand ON current_demand.execution_segment_id=:id
                    AND NOT current_demand.is_deleted AND (current_demand.id=root.id OR current_demand.split_root_demand_id=root.id)
                WHERE root.execution_segment_id=:root AND NOT root.is_deleted ORDER BY root.id
                """,Map.of("root",source.rootId(),"offset",source.offset(),"id",id)).stream().map(row->{
            var usage=product.materials().stream().filter(value->value.goodsId().equals(row[1])&&Objects.equals(value.colorId(),row[4]))
                    .findFirst().orElseThrow(()->conflict("原冻结物料在BOM中已不存在"));
            if (usage.required(source.rootQty(),product.productUnitRate()).compareTo(decimal(row[8]))!=0)
                throw conflict("原冻结需求与BOM精确计量规则不一致，不能直接拆批");
            BigDecimal current=usage.required(source.offset().add(source.qty()),product.productUnitRate())
                    .subtract(usage.required(source.offset(),product.productUnitRate()));
            if (current.compareTo(decimal(row[12]))!=0) throw conflict("剩余批次需求与原批累计计量不一致");
            return new Material(uuid(row[0]),uuid(row[11]),uuid(row[1]),str(row[2]),str(row[3]),uuid(row[4]),str(row[5]),
                    uuid(row[6]),str(row[7]),decimal(row[8]),decimal(row[9]),str(row[10]),decimal(row[13]),usage);
        }).toList();
        if (materials.isEmpty()) throw conflict("原任务没有可核对的冻结物料需求");
        var availability=readiness.batchAvailability(source.warehouseId(),materials.stream().map(Material::currentDemandId)
                .filter(Objects::nonNull).toList(),source.analysisId(),source.analysisItemId());
        return new Context(source,product,materials,availability);
    }

    private Preview buildPreview(Context context,BigDecimal requested) {
        Source source=context.source();
        for (Material material:context.materials()) {
            BigDecimal prior=material.usage().required(source.offset(),context.product().productUnitRate());
            if (source.offset().signum()>0 && material.usage().requiresExactSnapshot() && material.priorIssued().compareTo(prior)<0)
                throw conflict("前批固定或整包物料尚未实际领齐，请先完成前批领料后继续分批");
        }
        Map<UUID,BigDecimal> available=new LinkedHashMap<>();
        for (Material material:context.materials()) {
            var supply=context.availability().stream().filter(value->Objects.equals(value.demandId(),material.currentDemandId())).toList();
            BigDecimal publicQty=supply.stream().map(ProductionExecutionReadinessService.BatchAvailability::publicQty).reduce(BigDecimal.ZERO,BigDecimal::add);
            BigDecimal safety=supply.stream().map(ProductionExecutionReadinessService.BatchAvailability::safetyQty).max(BigDecimal::compareTo).orElse(BigDecimal.ZERO);
            available.put(material.rootDemandId(),MainWarehouseStockBudget.publicBudget(publicQty,safety).add(supply.stream()
                    .map(ProductionExecutionReadinessService.BatchAvailability::qualifiedQty).reduce(BigDecimal.ZERO,BigDecimal::add)));
        }
        BigInteger low=BigInteger.ZERO,high=source.qty().movePointRight(4).toBigIntegerExact();
        while(low.compareTo(high)<0) {
            BigInteger mid=low.add(high).add(BigInteger.ONE).shiftRight(1);
            boolean fits=slices(context,source.offset(),new BigDecimal(mid,4)).stream()
                    .allMatch(slice->slice.requiredQty().compareTo(available.getOrDefault(slice.rootDemandId(),BigDecimal.ZERO))<=0);
            if(fits)low=mid;else high=mid.subtract(BigInteger.ONE);
        }
        BigDecimal maximum=new BigDecimal(low,4);
        BigDecimal quantity=requested==null?maximum:positive(requested);
        if(quantity.compareTo(source.qty())>0)throw invalid("本次数量不能超过原任务剩余数量");
        if(quantity.compareTo(maximum)>0)throw conflict("本次数量超过当前可齐套生产量 "+maximum.stripTrailingZeros().toPlainString());
        for(MaterialSlice slice:slices(context,source.offset(),quantity)) {
            Material material=context.materials().stream().filter(value->value.rootDemandId().equals(slice.rootDemandId())).findFirst().orElseThrow();
            if(slice.requiresPrior()&&material.priorIssued().compareTo(slice.priorQty())<0)
                throw conflict("本批沿用前批整包或累计计量物料，前批尚未实际领齐或已有待退申请，请先核对前批领料");
        }
        List<Line> lines=previewLines(context,quantity);
        List<ProductionDrawRequest.Summary> summaries=lines.stream().map(line->new ProductionDrawRequest.Summary(
                line.warehouseId(),line.warehouseName(),line.goodsId(),line.goodsCode(),line.goodsName(),line.colorId(),
                line.colorName(),line.unitId(),line.unitName(),line.quantity())).toList();
        List<String> parts=new ArrayList<>(List.of(source.id().toString(),Long.toString(source.version()),source.bomFingerprint(),quantity.toPlainString()));
        context.availability().forEach(value->parts.add(value.toString()));
        lines.forEach(value->parts.add(value.toString()));
        return new Preview(source.id(),source.version(),source.planId(),source.planNo(),source.code(),source.productCode(),
                source.productName(),source.unitName(),source.qty(),maximum,quantity,source.qty().subtract(quantity),
                fingerprint(parts),lines,summaries);
    }

    private List<Line> previewLines(Context context,BigDecimal quantity) {
        List<Line> result=new ArrayList<>();
        List<MaterialSlice> selected=slices(context,context.source().offset(),quantity);
        List<PreplanAnalysisPegPort.DemandSlice> requests=new ArrayList<>();
        for(MaterialSlice slice:selected) {
            if(slice.requiredQty().signum()==0)continue;
            Material material=context.materials().stream().filter(value->value.rootDemandId().equals(slice.rootDemandId())).findFirst().orElseThrow();
            requests.add(new PreplanAnalysisPegPort.DemandSlice(material.currentDemandId(),material.goodsId(),material.colorId(),slice.requiredQty()));
        }
        var prepared=preplanPeg.previewPlanDemandTransfers(context.source().analysisId(),context.source().planId(),
                context.source().warehouseId(),requests);
        requireTraceableBatchSources(prepared);
        for(MaterialSlice slice:selected) {
            if(slice.requiredQty().signum()==0)continue;
            Material material=context.materials().stream().filter(value->value.rootDemandId().equals(slice.rootDemandId())).findFirst().orElseThrow();
            var supply=context.availability().stream().filter(value->Objects.equals(value.demandId(),material.currentDemandId()))
                    .sorted(Comparator.comparing(value->value.warehouseId().toString())).toList();
            Map<UUID,BigDecimal> released=new LinkedHashMap<>();
            Map<UUID,ProductionMaterialAllocationFacade.OwnedSlice> owned=new LinkedHashMap<>();
            for(var source:prepared)if(source.demandId().equals(material.currentDemandId())) {
                released.merge(source.warehouseId(),source.qty(),BigDecimal::add);
                if(source.explicitPreference())owned.merge(source.warehouseId(),
                        new ProductionMaterialAllocationFacade.OwnedSlice(source.qty(),source.qualified()?source.qty():BigDecimal.ZERO),
                        (left,right)->new ProductionMaterialAllocationFacade.OwnedSlice(left.qty().add(right.qty()),left.qualifiedQty().add(right.qualifiedQty())));
            }
            List<UUID> normal=supply.stream().filter(ProductionExecutionReadinessService.BatchAvailability::normalWarehouse)
                    .map(ProductionExecutionReadinessService.BatchAvailability::warehouseId).toList();
            Map<UUID,BigDecimal> physical=new LinkedHashMap<>();
            BigDecimal publicFree=BigDecimal.ZERO;
            for(var warehouse:supply) {
                BigDecimal free=warehouse.publicQty().add(warehouse.qualifiedQty()).subtract(warehouse.ownedQty())
                        .add(released.getOrDefault(warehouse.warehouseId(),BigDecimal.ZERO)).max(BigDecimal.ZERO);
                physical.put(warehouse.warehouseId(),free);
                if(warehouse.normalWarehouse())publicFree=publicFree.add(free.subtract(owned.getOrDefault(warehouse.warehouseId(),
                        new ProductionMaterialAllocationFacade.OwnedSlice(BigDecimal.ZERO,BigDecimal.ZERO)).qualifiedQty()).max(BigDecimal.ZERO));
            }
            BigDecimal[] budget={MainWarehouseStockBudget.publicBudget(publicFree,supply.stream()
                    .map(ProductionExecutionReadinessService.BatchAvailability::safetyQty).max(BigDecimal::compareTo).orElse(BigDecimal.ZERO))};
            BigDecimal[] pendingUnqualified={owned.entrySet().stream().filter(entry->normal.contains(entry.getKey()))
                    .map(entry->entry.getValue().qty().subtract(entry.getValue().qualifiedQty())).reduce(BigDecimal.ZERO,BigDecimal::add)};
            var allocation=ProductionMaterialAllocationFacade.allocateByQualifiedSourceOrder(slice.requiredQty(),normal,owned,
                    (warehouse,limit,qualified,requiresProof,isOwned)->{
                        if(isOwned&&normal.contains(warehouse))pendingUnqualified[0]=pendingUnqualified[0]
                                .subtract(owned.get(warehouse).qty().subtract(owned.get(warehouse).qualifiedQty()));
                        BigDecimal free=physical.getOrDefault(warehouse,BigDecimal.ZERO);
                        BigDecimal publicLimit=requiresProof?BigDecimal.ZERO:budget[0].subtract(pendingUnqualified[0]).max(BigDecimal.ZERO);
                        BigDecimal take=ProductionMaterialAllocationFacade.allocationTake(limit,free,qualified,publicLimit);
                        physical.put(warehouse,free.subtract(take));
                        if(!requiresProof)budget[0]=budget[0].subtract(take.subtract(qualified.min(free).min(take)));
                        return take;
                    });
            if(allocation.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(slice.requiredQty())!=0)
                throw conflict("实际来源分仓物料不足，请刷新");
            for(var allocated:allocation.entrySet())if(allocated.getValue().signum()>0) {
                var warehouse=supply.stream().filter(value->value.warehouseId().equals(allocated.getKey())).findFirst().orElseThrow();
                result.add(new Line(material.rootDemandId(),warehouse.warehouseId(),warehouse.warehouseName(),material.goodsId(),
                        material.goodsCode(),material.goodsName(),material.colorId(),material.colorName(),material.unitId(),material.unitName(),allocated.getValue()));
            }
        }
        return List.copyOf(result);
    }

    static void requireTraceableBatchSources(List<PreplanAnalysisPegPort.PreviewPlanTransfer> sources) {
        if(sources.stream().anyMatch(source->!source.explicitPreference()))
            throw conflict("本次分批会使用没有来源事件的历史预留，需先核对历史占用；当前未提交领料");
    }

    private List<MaterialSlice> slices(Context context,BigDecimal offset,BigDecimal qty) {
        return context.materials().stream().map(material->{
            BigDecimal prior=material.usage().required(offset,context.product().productUnitRate());
            BigDecimal required=material.usage().required(offset.add(qty),context.product().productUnitRate()).subtract(prior);
            return new MaterialSlice(material.rootDemandId(),required,prior,
                    offset.signum()>0&&prior.signum()>0&&(material.usage().requiresExactSnapshot()
                            || required.compareTo(material.usage().required(qty,context.product().productUnitRate()))<0));
        }).toList();
    }

    private void createChild(Context context,UUID id,BigDecimal quantity,BigDecimal offset,List<MaterialSlice> slices,UUID actor) {
        String snapshot;try{snapshot=json.writeValueAsString(slices);}catch(Exception failure){throw new IllegalStateException(failure);}
        em.createNativeQuery("""
                INSERT INTO production_execution_segments(id,package_id,plan_id,source_plan_item_id,segment_no,segment_code,
                    client_segment_key,product_goods_id,product_color_id,product_unit_id,product_unit_rate,planned_qty,status,
                    workshop_department_id,team_department_id,responsible_employee_id,plan_begin_date,plan_end_date,bom_fingerprint,
                    idempotency_key,auto_promote_when_ready,material_requirement_mode,source_segment_id,split_root_segment_id,
                    split_start_qty,split_material_snapshot,created_by,updated_by)
                SELECT :id,package_id,plan_id,source_plan_item_id,
                    (SELECT COALESCE(max(segment_no),0)+1 FROM production_execution_segments WHERE package_id=source.package_id),:code,
                    :key,product_goods_id,product_color_id,product_unit_id,product_unit_rate,:quantity,'WAITING',
                    workshop_department_id,team_department_id,responsible_employee_id,plan_begin_date,plan_end_date,bom_fingerprint,
                    :key,:promote,'DEMANDED',id,:root,:offset,CAST(:snapshot AS jsonb),:actor,:actor
                FROM production_execution_segments source WHERE id=:source
                """).setParameter("id",id).setParameter("code",codes.nextCode(MasterCodePrefix.PRODUCTION_EXECUTION_SEGMENT))
                .setParameter("key","SPLIT:"+id).setParameter("quantity",quantity).setParameter("root",context.source().rootId())
                .setParameter("offset",offset).setParameter("snapshot",snapshot).setParameter("actor",actor)
                .setParameter("source",context.source().id()).setParameter("promote",true).executeUpdate();
        for(MaterialSlice slice:slices) {
            if(slice.requiredQty().signum()==0)continue;
            em.createNativeQuery("""
                    INSERT INTO production_material_demands(package_id,plan_id,execution_segment_id,source_plan_item_id,warehouse_id,
                        goods_id,color_id,unit_id,required_qty,per_product_qty,requirement_mode,required_for_product_qty,
                        requirement_fingerprint,need_date,supply_route,status,idempotency_key,split_root_demand_id,created_by,updated_by)
                    SELECT package_id,plan_id,:segment,source_plan_item_id,warehouse_id,goods_id,color_id,unit_id,:quantity,per_product_qty,
                        'EXACT_SNAPSHOT',:productQuantity,:fingerprint,need_date,supply_route,'OPEN',:key,id,:actor,:actor
                    FROM production_material_demands WHERE id=:root
                    """).setParameter("segment",id).setParameter("quantity",slice.requiredQty()).setParameter("productQuantity",quantity)
                    .setParameter("fingerprint",fingerprint(List.of("SPLIT-MATERIAL-V1",slice.rootDemandId().toString(),offset.toPlainString(),quantity.toPlainString(),slice.requiredQty().toPlainString())))
                    .setParameter("key","SPLIT:"+id+":"+slice.rootDemandId()).setParameter("actor",actor).setParameter("root",slice.rootDemandId()).executeUpdate();
        }
    }

    private void splitSalesAllocations(UUID source,UUID batch,UUID remaining,BigDecimal quantity,UUID actor) {
        BigDecimal left=quantity;
        for(Object[] row:rows("SELECT plan_order_item_link_id,sales_order_item_id,allocated_qty FROM execution_segment_sales_allocations WHERE execution_segment_id=:id ORDER BY plan_order_item_link_id",Map.of("id",source))) {
            BigDecimal amount=decimal(row[2]),take=left.min(amount);
            if(take.signum()>0)insertSales(batch,uuid(row[0]),uuid(row[1]),take,actor);
            if(amount.compareTo(take)>0)insertSales(remaining,uuid(row[0]),uuid(row[1]),amount.subtract(take),actor);
            left=left.subtract(take);
        }
    }
    private void insertSales(UUID segment,UUID link,UUID item,BigDecimal quantity,UUID actor) {
        em.createNativeQuery("INSERT INTO execution_segment_sales_allocations(execution_segment_id,plan_order_item_link_id,sales_order_item_id,allocated_qty,created_by) VALUES(:segment,:link,:item,:quantity,:actor)")
                .setParameter("segment",segment).setParameter("link",link).setParameter("item",item).setParameter("quantity",quantity).setParameter("actor",actor).executeUpdate();
    }
    private static Map<String,BigDecimal> distribution(List<ProductionDrawRequest.Summary> summaries) {
        Map<String,BigDecimal> result=new java.util.TreeMap<>();
        for(var summary:summaries)result.merge(summary.warehouseId()+"|"+summary.goodsId()+"|"+summary.colorId()+"|"+summary.unitId(),
                summary.qty().setScale(4,RoundingMode.UNNECESSARY),BigDecimal::add);
        return result;
    }
    private Source source(UUID id) {
        List<Object[]> found=rows("""
                SELECT s.id,s.plan_id,s.package_id,s.source_plan_item_id,s.status,s.lock_version,s.planned_qty,s.bom_fingerprint,
                    s.workshop_department_id,s.responsible_employee_id,plan.maker_id,plan.material_analysis_id,plan.material_analysis_item_id,
                    package.warehouse_id,plan.bill_no,s.segment_code,goods.code,goods.name,unit.name,
                    (plan.is_closed OR plan.is_canceled OR plan.is_stopped),
                    (plan.status=1 AND package.status='CONFIRMED' AND NOT package.is_deleted AND NOT plan.is_deleted),
                    COALESCE(s.split_root_segment_id,s.id),s.split_start_qty,COALESCE(root.planned_qty,s.planned_qty),s.auto_promote_when_ready
                FROM production_execution_segments s JOIN production_plans plan ON plan.id=s.plan_id
                JOIN production_planning_packages package ON package.id=s.package_id JOIN goods ON goods.id=s.product_goods_id
                LEFT JOIN units unit ON unit.id=s.product_unit_id
                LEFT JOIN production_execution_segments root ON root.id=s.split_root_segment_id
                WHERE s.id=:id AND NOT s.is_deleted
                """,Map.of("id",id));
        if(found.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"车间任务不存在");
        Object[] r=found.getFirst();return new Source(uuid(r[0]),uuid(r[1]),uuid(r[2]),uuid(r[3]),str(r[4]),((Number)r[5]).longValue(),decimal(r[6]),str(r[7]),
                uuid(r[8]),uuid(r[9]),uuid(r[10]),uuid(r[11]),uuid(r[12]),uuid(r[13]),str(r[14]),str(r[15]),str(r[16]),str(r[17]),str(r[18]),
                Boolean.TRUE.equals(r[19]),Boolean.TRUE.equals(r[20]),uuid(r[21]),decimal(r[22]),decimal(r[23]),Boolean.TRUE.equals(r[24]));
    }
    private void requireAccess(Source source) {
        if(!access.hasAuthority("production_execution:view")||!access.hasAuthority("production_execution:start"))throw new ApiException(ErrorCode.FORBIDDEN,"缺少车间分批领料权限");
        if(!membership.isWorkshopMember(source.workshopId(),source.responsibleId(),currentUser.employeeId().orElse(null)))
            access.requireScopedOperationWritable(source.makerId(),"无权为此车间任务分批领料","production_execution:start");
    }
    private List<UUID> documents(UUID segment){return NativeQueryResults.typedRows(em.createNativeQuery("SELECT document_id FROM production_planning_package_documents WHERE execution_segment_id=:id AND document_type='DRAW' ORDER BY document_id").setParameter("id",segment),UUID.class);}
    private List<Object[]> rows(String sql,Map<String,?> parameters){var query=em.createNativeQuery(sql);parameters.forEach(query::setParameter);return NativeQueryResults.objectArrayRows(query);}
    private void lock(String table,UUID id){em.createNativeQuery("SELECT id FROM "+table+" WHERE id=:id FOR UPDATE").setParameter("id",id).getSingleResult();}
    private static BigDecimal positive(BigDecimal qty){if(qty==null||qty.signum()<=0)throw invalid("本次生产数量必须大于零");try{return qty.setScale(4,RoundingMode.UNNECESSARY);}catch(ArithmeticException failure){throw invalid("本次数量最多保留四位小数");}}
    private static String fingerprint(List<String> values){return PlanningPackageFingerprint.sha256(values);}
    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static String str(Object value){return value==null?"":value.toString();}
    private static UUID uuid(Object value){return value==null?null:(UUID)value;}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private record Source(UUID id,UUID planId,UUID packageId,UUID planItemId,String status,long version,BigDecimal qty,String bomFingerprint,
                          UUID workshopId,UUID responsibleId,UUID makerId,UUID analysisId,UUID analysisItemId,UUID warehouseId,
                          String planNo,String code,String productCode,String productName,String unitName,boolean closed,boolean active,
                          UUID rootId,BigDecimal offset,BigDecimal rootQty,boolean autoPromote){}
    private record Material(UUID rootDemandId,UUID currentDemandId,UUID goodsId,String goodsCode,String goodsName,UUID colorId,String colorName,
                            UUID unitId,String unitName,BigDecimal rootRequired,BigDecimal perProduct,String route,BigDecimal priorIssued,
                            CompleteKitAllocator.MaterialUsage usage){}
    private record MaterialSlice(UUID rootDemandId,BigDecimal requiredQty,BigDecimal priorQty,boolean requiresPrior){}
    private record Context(Source source,CompleteKitAllocator.ProductLine product,List<Material> materials,
                           List<ProductionExecutionReadinessService.BatchAvailability> availability){}
}
