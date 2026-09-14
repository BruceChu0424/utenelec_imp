package com.uten.imp.features.production.analysis;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static com.uten.imp.features.production.analysis.PreplanFutureSupplyTransfer.*;

@Service
@RequiredArgsConstructor
public class PreplanFutureSupplyTransferService {
    private final EntityManager em;
    private final MaterialAnalysisService analyses;
    private final ProductionDocumentAccessPolicy access;
    private final SecurityContextCurrentUser user;
    private final TxSessionVars tx;
    private final FulfillmentMutationLocks locks;
    private final ProductionMutationFootprintPort footprints;

    @Transactional(readOnly=true)
    public List<Source> sources(UUID targetAnalysis,UUID targetMaterial) {
        requireAuthority();var target=header(targetAnalysis);requireWritable(target);
        MaterialView material=material(analyses.detailInternal(targetAnalysis,false),targetMaterial);
        // 2026-09-13 起调入方放开到采购/委外/自制（车间）：外部在途按同主仓、
        // 同货品/颜色/单位匹配，不再要求与目标路线一致，也不看子层级。
        // 目标行形态不变量与 V574 库侧守卫逐条对齐，避免「列出来却存不进去」。
        if(!eligibleTarget(material))return List.of();
        LocalDate need=needDate(targetMaterial);
        List<Source> result=new ArrayList<>();
        for(Object[] row:rows(SOURCE_SQL+"""
                AND allocation.analysis_id<>:target AND source_material.goods_id=:goods
                AND source_material.color_id IS NOT DISTINCT FROM CAST(:color AS uuid) AND source_material.unit_id=:unit
                AND action.route IN ('BUY','SUBCONTRACT') AND fn_warehouse_same_main(analysis.warehouse_id,:warehouse)
                ORDER BY eta.expected_date NULLS LAST,allocation.created_at,allocation.id
                """,Map.of("target",targetAnalysis,"goods",material.goodsId(),"color",nullable(material.colorId()),
                        "unit",material.unitId(),"warehouse",target.warehouseId()))) {
            if(!access.canWrite(uuid(row[4]),access.scope()) || decimal(row[13]).signum()<=0)continue;
            result.add(source(row,need,target.version(),target.fingerprint(),material.additionalSupplyRecommendedQty()));
        }
        return List.copyOf(result);
    }

    @Transactional
    public AnalysisView create(UUID targetAnalysis,Create request) {
        requireAuthority();validate(request.qty(),request.reason(),request.idempotencyKey());tx.bind();
        String reason=normalizedReason(request.reason());
        String hash=fingerprint(List.of("FUTURE-TRANSFER",targetAnalysis.toString(),request.sourceAllocationId().toString(),
                request.targetMaterialId().toString(),positive(request.qty()).toPlainString(),Objects.toString(request.sourceVersion(),""),
                Objects.toString(request.sourceFingerprint(),""),Objects.toString(request.targetVersion(),""),Objects.toString(request.targetFingerprint(),""),
                Boolean.toString(request.allowLateSupply()),reason));
        lockKey("CREATE",request.idempotencyKey());
        var prior=rows("SELECT id,request_hash,target_analysis_id,source_analysis_id FROM preplan_future_supply_transfers WHERE created_by=:actor AND idempotency_key=:key",
                Map.of("actor",user.requireId(),"key",request.idempotencyKey()));
        UUID sourceAnalysis=prior.isEmpty()?uuid(sourceRow(request.sourceAllocationId())[1]):uuid(prior.getFirst()[3]);
        var guard=locks.acquire(()->footprints.forAnalyses(List.of(sourceAnalysis,targetAnalysis)));
        var headers=lockHeaders(sourceAnalysis,targetAnalysis);headers.values().forEach(this::requireWritable);
        if(!prior.isEmpty()) {
            if(!hash.equals(prior.getFirst()[1]) || !targetAnalysis.equals(prior.getFirst()[2]))throw conflict("相同幂等键对应不同在途归属调整");
            return analyses.detailInternal(targetAnalysis,false);
        }
        analyses.requireCurrent(headers.get(sourceAnalysis),request.sourceVersion(),request.sourceFingerprint());
        analyses.requireCurrent(headers.get(targetAnalysis),request.targetVersion(),request.targetFingerprint());
        guard.verifyUnchanged();
        analyses.refreshLocked(sourceAnalysis);analyses.refreshLocked(targetAnalysis);
        Object[] source=sourceRow(request.sourceAllocationId());
        MaterialView target=material(analyses.detailInternal(targetAnalysis,false),request.targetMaterialId());
        // 外部在途按货品维度流转：来源必须是另一计划的采购/委外份额，目标
        // 可以是采购、委外或自制（车间）物料；同货品、颜色、单位即可。
        if(sourceAnalysis.equals(targetAnalysis) || !Objects.equals(uuid(source[8]),target.goodsId())
                || !Objects.equals(uuid(source[11]),target.colorId()) || !Objects.equals(uuid(source[12]),target.unitId())
                || !Set.of("BUY","SUBCONTRACT").contains(Objects.toString(source[5],"")))
            throw invalid("只能调整另一计划同货品、颜色、单位的外部在途（采购或委外份额）");
        if(!eligibleTarget(target))
            throw invalid("目标物料必须是已确认采购/委外/自制路线、且不在参考或发货段的生效需求行");
        LocalDate need=needDate(request.targetMaterialId()),eta=date(source[15]);
        if(need!=null && (eta==null || eta.isAfter(need)) && !request.allowLateSupply())throw conflict("供给交期晚于目标需期或尚未确定，请明确确认后再采用");
        BigDecimal qty=positive(request.qty());
        if(qty.compareTo(decimal(source[13]))>0)throw conflict("原计划当前未实收且可转拨的专属在途不足，请刷新");
        if(qty.compareTo(target.additionalSupplyRecommendedQty())>0)throw conflict("转入数量超过目标扣除有效在途后的待补量，请刷新");
        UUID transfer=UUID.randomUUID(),action=UUID.randomUUID(),allocation=UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO preplan_future_supply_transfers(id,source_allocation_id,source_analysis_id,source_material_id,
                    target_analysis_id,target_material_id,target_action_id,target_allocation_id,external_item_id,qty,
                    source_version,source_fingerprint,target_version,target_fingerprint,expected_date,target_need_date,
                    allow_late_supply,reason,idempotency_key,request_hash,created_by)
                VALUES(:id,:sourceAllocation,:sourceAnalysis,:sourceMaterial,:targetAnalysis,:targetMaterial,:action,:allocation,:external,:qty,
                    :sourceVersion,:sourceFingerprint,:targetVersion,:targetFingerprint,:eta,:need,:late,:reason,:key,:hash,:actor)
                """).setParameter("id",transfer).setParameter("sourceAllocation",request.sourceAllocationId())
                .setParameter("sourceAnalysis",sourceAnalysis).setParameter("sourceMaterial",source[2]).setParameter("targetAnalysis",targetAnalysis)
                .setParameter("targetMaterial",request.targetMaterialId()).setParameter("action",action).setParameter("allocation",allocation)
                .setParameter("external",source[18]).setParameter("qty",qty).setParameter("sourceVersion",request.sourceVersion())
                .setParameter("sourceFingerprint",request.sourceFingerprint()).setParameter("targetVersion",request.targetVersion())
                .setParameter("targetFingerprint",request.targetFingerprint()).setParameter("eta",eta).setParameter("need",need)
                .setParameter("late",request.allowLateSupply()).setParameter("reason",reason).setParameter("key",request.idempotencyKey())
                .setParameter("hash",hash).setParameter("actor",user.requireId()).executeUpdate();
        // 新动作沿用来源路线（外部在途本身是采购/委外份额）；代次序列按
        // (analysis, group, route) 取号，跨路线调入（如自制目标）时也按来源
        // 路线取号，避免与同组既有动作撞唯一索引。
        Number generation=(Number)em.createNativeQuery("SELECT COALESCE(max(generation),0)+1 FROM preplan_supply_actions WHERE analysis_id=:id AND action_group_key=:group AND route=:route")
                .setParameter("id",targetAnalysis).setParameter("group",target.actionGroupKey()).setParameter("route",text(source[5])).getSingleResult();
        em.createNativeQuery("""
                INSERT INTO preplan_supply_actions(id,analysis_id,warehouse_id,goods_id,color_id,unit_id,need_date,route,requested_qty,status,
                    external_document_type,external_document_id,external_document_no,operation_type,claim_source_action_id,
                    idempotency_key,action_group_key,request_business_key,generation,request_hash,created_by)
                SELECT :id,:analysis,:warehouse,goods_id,color_id,unit_id,:need,route,:qty,'CREATED',
                    external_document_type,external_document_id,external_document_no,'FUTURE_TRANSFER',id,
                    :key,:group,:business,:generation,:hash,:actor FROM preplan_supply_actions WHERE id=:source
                """).setParameter("id",action).setParameter("analysis",targetAnalysis).setParameter("warehouse",headers.get(targetAnalysis).warehouseId())
                .setParameter("need",need).setParameter("qty",qty).setParameter("key","FUTURE:"+transfer).setParameter("group",target.actionGroupKey())
                .setParameter("business",fingerprint(List.of("FUTURE-SUPPLY",transfer.toString()))).setParameter("generation",generation.intValue())
                .setParameter("hash",hash).setParameter("actor",user.requireId()).setParameter("source",source[19]).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty,external_item_id,created_by)
                VALUES(:id,:analysis,:action,:material,:qty,:external,:actor)
                """).setParameter("id",allocation).setParameter("analysis",targetAnalysis).setParameter("action",action)
                .setParameter("material",request.targetMaterialId()).setParameter("qty",qty).setParameter("external",source[18]).setParameter("actor",user.requireId()).executeUpdate();
        analyses.refreshLocked(sourceAnalysis);analyses.refreshLocked(targetAnalysis);
        return analyses.detailInternal(targetAnalysis,false);
    }

    @Transactional(readOnly=true)
    public List<Transfer> list(UUID analysis,UUID materialId) {
        requireView();requireReadable(header(analysis));
        String filter=materialId==null?"":" AND (state.source_material_id=:material OR state.target_material_id=:material)";
        Map<String,Object> parameters=new HashMap<>();parameters.put("id",analysis);if(materialId!=null)parameters.put("material",materialId);
        Map<UUID,AnalysisView> sourceViews=new HashMap<>();
        return rows(STATE_SQL+" WHERE (:id=state.source_analysis_id OR :id=state.target_analysis_id)"+filter+" ORDER BY state.created_at,state.id",parameters).stream().map(row->transfer(row,analysis,sourceViews)).toList();
    }

    @Transactional
    public AnalysisView cancel(UUID analysis,UUID transferId,Cancel request) {
        requireAuthority();validate(request.qty(),request.reason(),request.idempotencyKey());tx.bind();lockKey("CANCEL",request.idempotencyKey());
        Object[] initial=state(transferId);UUID source=uuid(initial[2]),target=uuid(initial[5]);
        if(!analysis.equals(source)&&!analysis.equals(target))throw new ApiException(ErrorCode.NOT_FOUND,"在途归属调整不存在");
        var guard=locks.acquire(()->footprints.forAnalyses(List.of(source,target)));
        var headers=lockHeaders(source,target);headers.values().forEach(this::requireWritable);
        String hash=fingerprint(List.of("FUTURE-CANCEL",transferId.toString(),positive(request.qty()).toPlainString(),
                Objects.toString(request.sourceVersion(),""),Objects.toString(request.sourceFingerprint(),""),
                Objects.toString(request.targetVersion(),""),Objects.toString(request.targetFingerprint(),""),
                request.reason().strip(),Boolean.toString(request.acceptPublicRelease())));
        var prior=rows("SELECT transfer_id,request_hash FROM preplan_future_supply_transfer_cancellations WHERE created_by=:actor AND idempotency_key=:key",
                Map.of("actor",user.requireId(),"key",request.idempotencyKey()));
        if(!prior.isEmpty()) {if(!transferId.equals(prior.getFirst()[0])||!hash.equals(prior.getFirst()[1]))throw conflict("相同幂等键对应不同撤销请求");return analyses.detailInternal(analysis,false);}
        analyses.requireCurrent(headers.get(source),request.sourceVersion(),request.sourceFingerprint());
        analyses.requireCurrent(headers.get(target),request.targetVersion(),request.targetFingerprint());guard.verifyUnchanged();
        em.createNativeQuery("SELECT id FROM preplan_future_supply_transfers WHERE id=:id FOR UPDATE").setParameter("id",transferId).getSingleResult();
        Object[] current=state(transferId);if(request.qty().compareTo(decimal(current[12]))>0)throw conflict("只能撤销尚未实际合格入库的剩余份额");
        analyses.refreshLocked(source);analyses.refreshLocked(target);
        BigDecimal restored=request.qty().min(restorableQty(current,analyses.detailInternal(source,false)));
        BigDecimal released=request.qty().subtract(restored);
        if(released.signum()>0&&!request.acceptPublicRelease())throw conflict("本次撤销有 "+released.stripTrailingZeros().toPlainString()+" 超出原计划净待补量，请确认该部分转为公共在途供给");
        em.createNativeQuery("INSERT INTO preplan_future_supply_transfer_cancellations(transfer_id,qty,restore_to_source_qty,public_release_qty,reason,idempotency_key,request_hash,created_by) VALUES(:id,:qty,:restored,:released,:reason,:key,:hash,:actor)")
                .setParameter("id",transferId).setParameter("qty",positive(request.qty())).setParameter("reason",request.reason().strip())
                .setParameter("restored",restored).setParameter("released",released)
                .setParameter("key",request.idempotencyKey()).setParameter("hash",hash).setParameter("actor",user.requireId()).executeUpdate();
        analyses.refreshLocked(source);analyses.refreshLocked(target);return analyses.detailInternal(analysis,false);
    }

    @Transactional(readOnly=true)
    public CrossReallocationReplenishmentView replenishment(UUID analysis,UUID transferId) {
        requireView();Object[] row=state(transferId);UUID source=uuid(row[2]);
        if(!analysis.equals(source)&&!analysis.equals(row[5]))throw new ApiException(ErrorCode.NOT_FOUND,"在途归属调整不存在");
        var sourceHeader=header(source);requireReadable(sourceHeader);var view=analyses.detailInternal(source,false);var material=material(view,uuid(row[3]));
        BigDecimal transferred=decimal(row[9]).subtract(decimal(row[10]));
        BigDecimal remaining=material.additionalSupplyRecommendedQty().min(transferred).max(BigDecimal.ZERO);
        String route=material.sourceConfirmed();
        boolean writable=access.canWrite(sourceHeader.makerId(),access.scope()) && view.allowedActions().contains("NOTIFY_SUPPLY");
        String blocked=transferred.signum()==0?"该在途归属调整已撤销，无需补供":remaining.signum()==0?"原计划已有其它供给覆盖，请跟进已安排任务":!writable?"当前账号没有原计划补供权限":null;
        return new CrossReallocationReplenishmentView(transferId,view,material.materialLineId(),uuid(row[5]),transferred,
                remaining,remaining,remaining,route,writable&&remaining.signum()>0?List.of(route):List.of(),"NOTIFY_SUPPLY",
                writable&&remaining.signum()>0&&access.hasAuthority("production_material_analysis:over_supply"),false,null,
                "BUY".equals(route)?material.mainWarehouseSafetyReplenishmentGapQty():BigDecimal.ZERO,blocked);
    }

    @Transactional(readOnly=true)
    public CrossReallocationReplenishmentView replenishmentByKey(UUID source,String key) {
        requireView();requireReadable(header(source));
        var ids=NativeQueryResults.typedRows(em.createNativeQuery("SELECT id FROM preplan_future_supply_transfers WHERE source_analysis_id=:source AND created_by=:actor AND idempotency_key=:key")
                .setParameter("source",source).setParameter("actor",user.requireId()).setParameter("key",key),UUID.class);
        if(ids.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"本次在途归属调整不存在");
        return replenishment(source,ids.getFirst());
    }

    private static final String SOURCE_SQL="""
            SELECT allocation.id,allocation.analysis_id,allocation.analysis_material_id,source_item.source_ref,analysis.maker_id,
                   action.route,analysis.warehouse_id,warehouse.name,action.goods_id,goods.code,goods.name,action.color_id,action.unit_id,
                   fn_preplan_future_source_available_qty(allocation.id),fn_preplan_allocation_received_qty(allocation.id),eta.expected_date,
                   analysis.version,analysis.fingerprint,allocation.external_item_id,action.id,unit.name,
                   eta.bill_no,eta.header_id,eta.doc_route
            FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id
            JOIN production_material_analyses analysis ON analysis.id=allocation.analysis_id AND NOT analysis.is_deleted AND analysis.status<>'CANCELLED'
            JOIN production_material_analysis_materials source_material ON source_material.id=allocation.analysis_material_id AND source_material.active
            JOIN production_material_analysis_items source_item ON source_item.id=source_material.analysis_item_id
            JOIN goods ON goods.id=action.goods_id LEFT JOIN units unit ON unit.id=action.unit_id LEFT JOIN warehouses warehouse ON warehouse.id=analysis.warehouse_id
            LEFT JOIN LATERAL (
                SELECT expected_date,bill_no,header_id,doc_route FROM (
                    SELECT COALESCE(item.deliver_date,header.deliver_date) expected_date,header.bill_no,header.id header_id,'PURCHASE' doc_route
                    FROM purchase_order_item_sources link
                    JOIN purchase_order_items item ON item.id=link.order_item_id AND NOT item.is_deleted
                    JOIN purchase_orders header ON header.id=item.order_id AND header.status=1 AND NOT header.is_deleted
                    WHERE action.route='BUY' AND link.request_item_id=allocation.external_item_id
                      AND ((NOT header.is_closed AND fn_procurement_order_source_remaining_qty('PURCHASE',item.id,link.request_item_id)>0)
                           OR fn_procurement_order_source_pending_qty('PURCHASE',item.id,link.request_item_id)>0)
                    UNION ALL
                    SELECT COALESCE(item.deliver_date,header.deliver_date),header.bill_no,header.id,'SUBCONTRACT'
                    FROM subcontract_order_item_sources link
                    JOIN subcontract_order_items item ON item.id=link.order_item_id AND NOT item.is_deleted
                    JOIN subcontract_orders header ON header.id=item.order_id AND header.status=1 AND NOT header.is_deleted
                    WHERE action.route='SUBCONTRACT' AND link.application_item_id=allocation.external_item_id
                      AND ((NOT header.is_closed AND fn_procurement_order_source_remaining_qty('SUBCONTRACT',item.id,link.application_item_id)>0)
                           OR fn_procurement_order_source_pending_qty('SUBCONTRACT',item.id,link.application_item_id)>0)
                ) dates ORDER BY expected_date NULLS LAST LIMIT 1
            ) eta ON TRUE
            WHERE action.operation_type='SUPPLY' AND action.status<>'CANCELLED' AND action.route IN('BUY','SUBCONTRACT')
            """;
    private static final String STATE_SQL="""
            SELECT state.id,state.source_allocation_id,state.source_analysis_id,state.source_material_id,source_item.source_ref,
                   state.target_analysis_id,state.target_material_id,target_item.source_ref,action.route,
                   state.qty,state.cancelled_qty,state.received_qty,state.remaining_qty,state.status,state.expected_date,state.target_need_date,state.allow_late_supply,
                   a.version,a.fingerprint,b.version,b.fingerprint,a.maker_id,b.maker_id,state.reason,
                   GREATEST(fn_preplan_public_source_private_open_qty(allocation.action_id,allocation.external_item_id)
                       -fn_preplan_external_expected_qty(allocation.action_id,allocation.external_item_id),0)::numeric,
                   COALESCE(creator_employee.full_name,creator.login_account),state.created_at
            FROM v_preplan_future_supply_transfer_state state JOIN preplan_supply_action_allocations allocation ON allocation.id=state.source_allocation_id
            JOIN preplan_supply_actions action ON action.id=allocation.action_id
            JOIN production_material_analyses a ON a.id=state.source_analysis_id JOIN production_material_analyses b ON b.id=state.target_analysis_id
            JOIN production_material_analysis_materials source_material ON source_material.id=state.source_material_id
            JOIN production_material_analysis_items source_item ON source_item.id=source_material.analysis_item_id
            JOIN production_material_analysis_materials target_material ON target_material.id=state.target_material_id
            JOIN production_material_analysis_items target_item ON target_item.id=target_material.analysis_item_id
            JOIN users creator ON creator.id=state.created_by
            LEFT JOIN employees creator_employee ON creator_employee.id=creator.employee_id
            """;
    private Object[] sourceRow(UUID id){var rows=rows(SOURCE_SQL+" AND allocation.id=:id",Map.of("id",id));if(rows.size()!=1)throw conflict("原专属在途来源不存在或已失效");return rows.getFirst();}
    private Object[] state(UUID id){var rows=rows(STATE_SQL+" WHERE state.id=:id",Map.of("id",id));if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"在途归属调整不存在");return rows.getFirst();}
    private Source source(Object[] row,LocalDate need,long targetVersion,String targetFingerprint,BigDecimal targetUncovered){LocalDate eta=date(row[15]);return new Source(uuid(row[0]),uuid(row[1]),uuid(row[2]),text(row[3]),text(row[5]),uuid(row[6]),text(row[7]),uuid(row[8]),text(row[9]),text(row[10]),uuid(row[11]),uuid(row[12]),text(row[20]),decimal(row[13]),decimal(row[14]),eta,need,need!=null&&(eta==null||eta.isAfter(need)),decimal(row[14]).signum()>0?"PARTIAL_STOCK_IN":"IN_TRANSIT_OR_PENDING_STOCK_IN",((Number)row[16]).longValue(),text(row[17]),targetVersion,targetFingerprint,targetUncovered,text(row[21]),uuid(row[22]),text(row[23]));}
    private Transfer transfer(Object[] row,UUID context,Map<UUID,AnalysisView> sourceViews){
        boolean authorized=access.hasAuthority("production_material_analysis:cross_reallocate")
                &&access.canWrite(uuid(row[21]),access.scope())&&access.canWrite(uuid(row[22]),access.scope());
        BigDecimal cancelable=authorized?decimal(row[12]):BigDecimal.ZERO;
        BigDecimal restored=cancelable.signum()>0
                ?restorableQty(row,sourceViews.computeIfAbsent(uuid(row[2]),id->analyses.detailInternal(id,false))):BigDecimal.ZERO;
        boolean canCancel=cancelable.signum()>0;
        String blocked=canCancel?null:decimal(row[12]).signum()<=0?"没有尚未实收的可撤销份额":"缺少双方调整权限";
        BigDecimal shortfall=decimal(row[24]);
        return new Transfer(uuid(row[0]),uuid(row[1]),uuid(row[2]),uuid(row[3]),text(row[4]),uuid(row[5]),uuid(row[6]),text(row[7]),text(row[8]),decimal(row[9]),decimal(row[10]),decimal(row[11]),decimal(row[12]),text(row[13]),date(row[14]),date(row[15]),Boolean.TRUE.equals(row[16]),((Number)row[17]).longValue(),text(row[18]),((Number)row[19]).longValue(),text(row[20]),canCancel,text(row[23]),context.equals(row[2])?"OUT":"IN",blocked,cancelable,restored,cancelable.subtract(restored),shortfall,
                shortfall.signum()>0?"原外单的预计供给不足，请跟进补供或撤销尚未实收的转拨份额":null,
                text(row[25]),MaterialAnalysisService.offsetDateTime(row[26]));
    }
    private BigDecimal restorableQty(Object[] row,AnalysisView sourceView){
        return decimal(row[12]).min(material(sourceView,uuid(row[3])).additionalSupplyRecommendedQty()).max(BigDecimal.ZERO);
    }
    private MaterialAnalysisService.AnalysisHeader header(UUID id){var rows=rows("SELECT id,warehouse_id,status,version,fingerprint,analyzed_at,maker_id FROM production_material_analyses WHERE id=:id AND NOT is_deleted",Map.of("id",id));if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"物料分析不存在");var row=rows.getFirst();return new MaterialAnalysisService.AnalysisHeader(uuid(row[0]),uuid(row[1]),text(row[2]),((Number)row[3]).longValue(),text(row[4]),MaterialAnalysisService.offsetDateTime(row[5]),uuid(row[6]));}
    private Map<UUID,MaterialAnalysisService.AnalysisHeader> lockHeaders(UUID... ids){Map<UUID,MaterialAnalysisService.AnalysisHeader> headers=new LinkedHashMap<>();Arrays.stream(ids).distinct().sorted().forEach(id->headers.put(id,analyses.headerAfterPrelock(id)));return headers;}
    private void requireAuthority(){if(!access.hasAuthority("production_material_analysis:view")||!access.hasAuthority("production_material_analysis:cross_reallocate"))throw new ApiException(ErrorCode.FORBIDDEN,"缺少在途归属调整权限");}
    private void requireView(){if(!access.hasAuthority("production_material_analysis:view"))throw new ApiException(ErrorCode.FORBIDDEN,"缺少物料分析查看权限");}
    private void requireReadable(MaterialAnalysisService.AnalysisHeader header){access.requireReadable(header.makerId(),"物料分析不存在",access.scope());}
    private void requireWritable(MaterialAnalysisService.AnalysisHeader header){access.requireWritable(header.makerId(),"无权调整此物料分析的在途归属",access.scope());}
    private MaterialView material(AnalysisView view,UUID id){return view.flatMaterials().stream().filter(row->row.materialLineId().equals(id)).findFirst().orElseThrow(()->conflict("目标物料节点已变化，请刷新"));}
    private LocalDate needDate(UUID material){return date(em.createNativeQuery("SELECT source.delivery_date FROM production_material_analysis_materials material JOIN production_material_analysis_items source ON source.id=material.analysis_item_id WHERE material.id=:id").setParameter("id",material).getSingleResult());}
    private List<Object[]> rows(String sql,Map<String,?> parameters){var query=em.createNativeQuery(sql);parameters.forEach((key,value)->query.setParameter(key,value==Null.VALUE?null:value));return NativeQueryResults.objectArrayRows(query);}
    private void lockKey(String operation,String key){em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,569))").setParameter("key",user.requireId()+":"+operation+":"+key).getSingleResult();}
    private static void validate(BigDecimal qty,String reason,String key){positive(qty);normalizedReason(reason);if(key==null||!key.matches("[A-Za-z0-9._:-]{8,128}"))throw invalid("请填写有效数量及幂等键");}

    /**
     * 调入目标行形态不变量，与 V574 的 fn_guard_preplan_future_transfer 一一对应：
     * 路线已确认为三条主路线之一，且不是只作参考或发货段的行（这两段不产生
     * 需要外部供给的净需求）。列表与写入共用同一判定，不会出现「能选不能存」。
     */
    private static boolean eligibleTarget(MaterialView material){
        return TARGET_ROUTES.contains(Objects.toString(material.sourceConfirmed(),""))
                && !EXCLUDED_TARGET_STAGES.contains(Objects.toString(material.controlStage(),""));
    }

    private static final Set<String> TARGET_ROUTES=Set.of("BUY","SUBCONTRACT","MAKE");
    private static final Set<String> EXCLUDED_TARGET_STAGES=Set.of("SHIP","REFERENCE");

    /** 业务原因 2026-09-13 起可选：空/缺省写空串，保留去空格与长度上限。 */
    private static String normalizedReason(String reason){
        if(reason==null)return "";
        String stripped=reason.strip();
        if(stripped.length()>1000)throw invalid("业务原因不能超过 1000 字");
        return stripped;
    }
    private static BigDecimal positive(BigDecimal qty){if(qty==null||qty.signum()<=0)throw invalid("数量必须大于0");try{return qty.setScale(4,RoundingMode.UNNECESSARY);}catch(ArithmeticException e){throw invalid("数量最多4位小数");}}
    private enum Null { VALUE }
    private static Object nullable(Object value){return value==null?Null.VALUE:value;}
    private static String fingerprint(List<String> values){return PlanningPackageFingerprint.sha256(values);}
    private static UUID uuid(Object value){return value==null?null:(UUID)value;}
    private static String text(Object value){return value==null?"":value.toString();}
    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static LocalDate date(Object value){return value==null?null:value instanceof LocalDate date?date:((java.sql.Date)value).toLocalDate();}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
