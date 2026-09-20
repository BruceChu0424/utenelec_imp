package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.application.port.ProductionDrawInstructionNoticePort;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Immutable adjustments of picking instructions when their exact material changes custody. */
@Service
@RequiredArgsConstructor
public class ProductionMaterialReturnDrawInstructionService {
    private final EntityManager em;
    private final SecurityContextCurrentUser user;
    private final ProductionDrawInstructionNoticePort notices;

    @Transactional(propagation=Propagation.MANDATORY)
    public void adjust(UUID documentId,boolean reverse) {
        List<Object[]> confirmations=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT confirmation.id,request.execution_segment_id,confirmation.source_warehouse_id,confirmation.received_warehouse_id
                FROM production_material_return_receiving_confirmations confirmation
                JOIN production_material_return_requests request ON request.id=confirmation.return_request_id
                WHERE confirmation.stock_document_id=:document
                """).setParameter("document",documentId));
        if(confirmations.isEmpty())return;
        Object[] context=confirmations.getFirst(); UUID confirmation=(UUID)context[0],segment=(UUID)context[1];
        UUID source=(UUID)context[2],received=(UUID)context[3];
        if(source.equals(received))return;
        List<Object[]> budgets=NativeQueryResults.objectArrayRows(em.createNativeQuery(reverse?"""
                SELECT demand.id,SUM(item.qty_base) FROM production_material_return_request_items item
                JOIN production_material_return_requests request ON request.id=item.request_id
                LEFT JOIN production_material_stock_postings issue ON issue.id=item.issue_posting_id
                LEFT JOIN production_workshop_direct_transfer_items direct ON direct.id=item.direct_transfer_item_id
                JOIN production_material_demands demand ON demand.execution_segment_id=request.execution_segment_id
                  AND (demand.id=issue.demand_id OR direct.to_demand_id IN(demand.id,demand.split_root_demand_id))
                WHERE request.id=:document GROUP BY demand.id ORDER BY demand.id
                """:"""
                SELECT reservation.demand_id,SUM(slice.qty_base) FROM production_workshop_material_return_slices slice
                JOIN production_material_return_request_items item ON item.id=slice.request_item_id
                JOIN production_workshop_direct_source_allocations allocation ON allocation.id=slice.source_allocation_id
                JOIN stock_reservations reservation ON reservation.id=allocation.stock_reservation_id
                WHERE item.request_id=:document GROUP BY reservation.demand_id ORDER BY reservation.demand_id
                """).setParameter("document",documentId));
        Map<UUID,BigDecimal> reductions=new LinkedHashMap<>(); List<UUID> affected=new ArrayList<>();
        for(Object[] budget:budgets) {
            List<PendingDraw> pending=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT item.id,document.id,fn_production_draw_item_effective_qty(item.id)-COALESCE(item.issued_qty,0),
                        COALESCE(item.unit_rate,1)
                    FROM production_planning_package_document_items mapping
                    JOIN stock_document_items item ON item.id=mapping.document_item_id AND NOT item.is_deleted
                    JOIN stock_documents document ON document.id=item.doc_id AND document.doc_type='DRAW'
                      AND document.status IN(0,1) AND NOT document.is_deleted
                    WHERE mapping.demand_id=:demand AND mapping.document_type='DRAW' AND document.warehouse_id=:warehouse
                    ORDER BY document.id,item.id FOR UPDATE OF document,item
                    """).setParameter("demand",budget[0]).setParameter("warehouse",reverse?received:source)).stream()
                    .map(row->new PendingDraw((UUID)row[0],(UUID)row[1],decimal(row[2]),decimal(row[3]))).toList();
            Map<UUID,BigDecimal> selected=exactReductions(decimal(budget[1]),pending);
            reductions.putAll(selected);
            pending.stream().filter(row->selected.containsKey(row.itemId())).map(PendingDraw::documentId).forEach(affected::add);
        }
        if(!reductions.isEmpty())insertReduction(confirmation,segment,reverse,affected,reductions);
        if(reverse) {
            List<UUID> restored=NativeQueryResults.typedRows(em.createNativeQuery("""
                    SELECT DISTINCT unnest(draw_document_ids) FROM production_execution_segment_events
                    WHERE receiving_confirmation_id=:confirmation AND action='MATERIAL_RETURN_DRAW_REDUCE' AND receiving_direction=1
                    """,UUID.class).setParameter("confirmation",confirmation),UUID.class);
            em.createNativeQuery("""
                    INSERT INTO production_execution_segment_events(execution_segment_id,action,idempotency_key,request_hash,
                      expected_version,resulting_version,created_by,draw_document_ids,draw_item_quantities,
                      receiving_confirmation_id,receiving_direction,counter_event_id)
                    SELECT original.execution_segment_id,'MATERIAL_RETURN_DRAW_RESTORE',:key,:hash,
                      segment.lock_version,segment.lock_version,:actor,original.draw_document_ids,original.draw_item_quantities,
                      original.receiving_confirmation_id,-1,original.id
                    FROM production_execution_segment_events original JOIN production_execution_segments segment ON segment.id=original.execution_segment_id
                    WHERE original.receiving_confirmation_id=:confirmation AND original.action='MATERIAL_RETURN_DRAW_REDUCE'
                      AND original.receiving_direction=1
                    """).setParameter("confirmation",confirmation).setParameter("key","MATERIAL-RETURN:"+confirmation+":RESTORE")
                    .setParameter("hash",CanonicalFingerprint.sha256(List.of(confirmation.toString(),"RESTORE")))
                    .setParameter("actor",user.requireId()).executeUpdate();
            affected.addAll(restored);
        }
        affected.stream().distinct().forEach(id->notices.notifyProductionDrawInstructionsChanged(id,confirmation,reverse));
    }

    record PendingDraw(UUID itemId,UUID documentId,BigDecimal qty,BigDecimal rate) {}

    /** A free lot has no instruction to withdraw; an existing instruction must be reduced exactly. */
    static Map<UUID,BigDecimal> exactReductions(BigDecimal budget,List<PendingDraw> pending) {
        BigDecimal total=BigDecimal.ZERO;
        for(PendingDraw row:pending) {
            if(row.rate().signum()<=0)throw new ApiException(ErrorCode.CONFLICT,"原领料单单位换算无效，请先由仓库核对");
            total=total.add(row.qty().max(BigDecimal.ZERO).multiply(row.rate()));
        }
        BigDecimal target=budget.min(total).max(BigDecimal.ZERO);
        if(target.signum()==0)return Map.of();
        for(PendingDraw row:pending) {
            BigDecimal exact=target.divide(row.rate(),4,RoundingMode.DOWN);
            if(exact.compareTo(row.qty())<=0 && exact.multiply(row.rate()).compareTo(target)==0)
                return Map.of(row.itemId(),exact);
        }
        // Bounded deterministic alternatives, not an exponential subset search
        // over potentially thousands of picking lines with historical units.
        List<List<PendingDraw>> orders=List.of(pending,
                pending.stream().sorted(java.util.Comparator.comparing(PendingDraw::rate)).toList(),
                pending.stream().sorted(java.util.Comparator.comparing(PendingDraw::rate).reversed()).toList());
        for(List<PendingDraw> order:orders) {
            Map<UUID,BigDecimal> selected=tryExactReductions(target,order);
            if(selected!=null)return selected;
        }
        throw new ApiException(ErrorCode.CONFLICT,
                "本次退料数量按当前领料单的单位组合无法自动精确撤减，请调整退料数量或由仓库核对单位换算");
    }

    private static Map<UUID,BigDecimal> tryExactReductions(BigDecimal remaining,List<PendingDraw> pending) {
        Map<UUID,BigDecimal> selected=new LinkedHashMap<>();
        for(PendingDraw row:pending) {
            if(remaining.signum()<=0)break;
            BigDecimal take=remaining.divide(row.rate(),4,RoundingMode.DOWN).min(row.qty()).max(BigDecimal.ZERO);
            if(take.signum()==0)continue;
            selected.put(row.itemId(),take);
            remaining=remaining.subtract(take.multiply(row.rate()));
        }
        return remaining.signum()==0?selected:null;
    }

    private void insertReduction(UUID confirmation,UUID segment,boolean reverse,List<UUID> documents,Map<UUID,BigDecimal> quantities) {
        String json="{"+quantities.entrySet().stream().map(entry->"\""+entry.getKey()+"\":"+entry.getValue().toPlainString())
                .collect(java.util.stream.Collectors.joining(","))+"}";
        String documentIds="{"+documents.stream().distinct().sorted().map(UUID::toString).collect(java.util.stream.Collectors.joining(","))+"}";
        em.createNativeQuery("""
                INSERT INTO production_execution_segment_events(execution_segment_id,action,idempotency_key,request_hash,
                  expected_version,resulting_version,created_by,draw_document_ids,draw_item_quantities,receiving_confirmation_id,receiving_direction)
                SELECT segment.id,'MATERIAL_RETURN_DRAW_REDUCE',:key,:hash,segment.lock_version,segment.lock_version,:actor,
                  CAST(:documents AS uuid[]),CAST(:quantities AS jsonb),:confirmation,:direction
                FROM production_execution_segments segment WHERE segment.id=:segment
                """).setParameter("segment",segment).setParameter("confirmation",confirmation).setParameter("direction",reverse?-1:1)
                .setParameter("key","MATERIAL-RETURN:"+confirmation+":"+(reverse?"REVERSE":"RECEIVE"))
                .setParameter("hash",CanonicalFingerprint.sha256(List.of(confirmation.toString(),Boolean.toString(reverse),json)))
                .setParameter("actor",user.requireId()).setParameter("documents",documentIds).setParameter("quantities",json).executeUpdate();
    }
    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
}
