package com.uten.imp.features.sales.order;

import com.uten.imp.common.delivery.BomDeliveryService;
import com.uten.imp.common.delivery.DeliveryPlan;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/** Sales persistence adapter. Planning consumers already authorize their admitted source rows. */
@Service
@RequiredArgsConstructor
public class SalesOrderDeliveryService implements com.uten.imp.application.port.SalesOrderDeliverySourcePort {
    private com.uten.imp.features.stock.StockReservationService reservations;
    @org.springframework.beans.factory.annotation.Autowired
    public void setReservations(com.uten.imp.features.stock.StockReservationService service){reservations=service;}
    private final BomDeliveryService boms;
    private final SalesOrderItemRepository items;
    private final EntityManager em;
    private final com.fasterxml.jackson.databind.ObjectMapper mapper;

    @Transactional(readOnly = true)
    public Map<UUID,DeliveryPlan> planForOrderItems(Collection<UUID> ids) {
        if (ids == null || ids.isEmpty()) return Map.of();
        if (ids.size() > 500) throw new ApiException(ErrorCode.VALIDATION_FAILED, "单次最多读取500个订单来源");
        Map<UUID,DeliveryPlan> result = new LinkedHashMap<>();
        for (SalesOrderItem item : items.findAllById(ids)) {
            if (item.isDeleted()) continue;
            result.put(item.getId(), effective(item.getDeliveryPlan()));
        }
        if (result.size() != new HashSet<>(ids).size()) throw new ApiException(ErrorCode.CONFLICT, "销售订单来源已变化，请重新选择");
        return Map.copyOf(result);
    }
    @Override
    @Transactional(readOnly=true)
    public Map<UUID,com.uten.imp.common.delivery.DeliveryBom.AdmittedSource> admittedSources(Collection<UUID> ids) {
        if(ids==null||ids.isEmpty())return Map.of();
        if(ids.size()>500)throw new ApiException(ErrorCode.VALIDATION_FAILED,"单次最多读取500个订单来源");
        Map<UUID,com.uten.imp.common.delivery.DeliveryBom.AdmittedSource> result=new LinkedHashMap<>();
        for(SalesOrderItem item:items.findAllById(ids))if(!item.isDeleted())result.put(item.getId(),
                new com.uten.imp.common.delivery.DeliveryBom.AdmittedSource(item.getGoodsId(),item.getUnitId(),item.getUnitRate(),
                        item.getQty(),effective(item.getDeliveryPlan()),item.getDeliveryBomSnapshot()));
        if(result.size()!=new HashSet<>(ids).size())throw new ApiException(ErrorCode.CONFLICT,"已准入的销售来源已经变化，请重新核对");
        return Map.copyOf(result);
    }
    public DeliveryPlan forSave(com.uten.imp.features.sales.order.dto.OrderItemLine requested, SalesOrderItem retained) {
        DeliveryPlan plan = requested.getDeliveryPlan() == null
                ? retained == null ? DeliveryPlan.assembled() : effective(retained.getDeliveryPlan()) : requested.getDeliveryPlan();
        if(retained!=null && (plan.requiresPhysicalFulfillment() || effective(retained.getDeliveryPlan()).requiresPhysicalFulfillment())
                && (!Objects.equals(retained.getGoodsId(),requested.getGoodsId()) || !Objects.equals(retained.getColorId(),requested.getColorId())
                    || !Objects.equals(retained.getUnitId(),requested.getUnitId()) || !sameNumber(retained.getUnitRate(),requested.getUnitRate())))
            requireNoDownstream(retained);
        // Legacy clients/default assembled orders do not suddenly depend on having a product BOM.
        if(plan.equals(DeliveryPlan.assembled()) && requested.getGoodsId()!=null && boms.hasRequiredOperations(requested.getGoodsId()))
            plan=boms.resolve(requested.getGoodsId(),requested.getUnitId(),requested.getUnitRate(),requested.getQty(),plan).deliveryPlan();
        if (!plan.equals(DeliveryPlan.assembled())) plan = boms.requireResolved(requested.getGoodsId(),
                requested.getUnitId(), requested.getUnitRate(), requested.getQty(), plan, false).deliveryPlan();
        if (retained != null && !effective(retained.getDeliveryPlan()).equals(plan)) {
            requireNoDownstream(retained);
            if(plan.requiresPhysicalFulfillment() && !effective(retained.getDeliveryPlan()).requiresPhysicalFulfillment()
                    && positive(retained.getReservedQty())) {
                if(reservations==null)throw new ApiException(ErrorCode.CONFLICT,"原订单预留服务不可用，请重试");
                // The approved revision may already have released these exact rows. Never release a guessed new quantity.
                reservations.releaseByOrderItems(List.of(retained.getId()));
                retained.setReservedQty(java.math.BigDecimal.ZERO);
            }
        }
        return plan;
    }
    public void applyForSave(com.uten.imp.features.sales.order.dto.OrderItemLine requested,
            SalesOrderItem target, SalesOrderItem retained) {
        DeliveryPlan plan = forSave(requested, retained);
        target.setDeliveryPlan(plan);
        if (plan.bomFingerprint() != null) {
            var snapshot = boms.snapshot(requested.getGoodsId());
            if (!plan.bomFingerprint().equals(snapshot.bomFingerprint()))
                throw new ApiException(ErrorCode.CONFLICT, "保存期间BOM已变化，请重新核对");
            target.setDeliveryBomSnapshot(snapshot);
        } else target.setDeliveryBomSnapshot(null);
    }
    public void validateApproval(List<SalesOrderItem> lines) {
        for (SalesOrderItem line : lines) {
            DeliveryPlan plan = effective(line.getDeliveryPlan());
            var source=new com.uten.imp.common.delivery.DeliveryBom.AdmittedSource(line.getGoodsId(),line.getUnitId(),line.getUnitRate(),
                    line.getQty(),plan,line.getDeliveryBomSnapshot());
            if(plan.equals(DeliveryPlan.assembled()) && boms.hasRequiredOperationsAdmitted(source))
                throw new ApiException(ErrorCode.CONFLICT,"货品新增了必要加工工序，请销售重新核对交付方案后提交审核");
            if (!plan.equals(DeliveryPlan.assembled())) boms.requireResolvedAdmitted(source,true);
        }
    }
    public void validateOrderApproval(UUID orderId) {
        validateApproval(items.findByOrderIdAndDeletedFalseOrderByLineNoAsc(orderId));
    }
    public DeliveryPlan parsePlan(Object json) {
        if (json == null) return DeliveryPlan.assembled();
        try { return mapper.readValue(json.toString(),DeliveryPlan.class); }
        catch (Exception ex) { throw new ApiException(ErrorCode.CONFLICT, "保存的交付方案无效，请重新核对"); }
    }
    public void requireUncommittedDecrease(UUID itemId) {
        Number frozen=(Number)em.createNativeQuery("""
            SELECT (SELECT count(*) FROM production_material_analysis_items ai
                JOIN production_material_analyses a ON a.id=ai.analysis_id
                WHERE ai.sales_order_item_id=:id AND NOT ai.is_deleted AND NOT a.is_deleted AND a.status<>'CANCELLED')
              +(SELECT count(*) FROM sales_shipment_delivery_components c
                JOIN sales_shipments s ON s.id=c.shipment_id
                WHERE c.order_item_id=:id AND c.movement_id IS NULL
                  AND (c.processing_started_at IS NOT NULL OR c.processing_completed_qty>0
                    OR EXISTS(SELECT 1 FROM stock_reservations r WHERE r.owner_type='SALES_DELIVERY_PROCESSING'
                        AND r.owner_id=c.id AND r.status=0 AND NOT r.is_deleted)))
            """).setParameter("id",itemId).getSingleResult();
        if(frozen.longValue()>0)throw new ApiException(ErrorCode.CONFLICT,
                "该交付行已有分析快照或加工实物占用，请先受控撤回后减量");
    }
    /** Caller retains its shipment/analysis object-scope admission and locks; rowQty is in the order row's unit. */
    @Transactional
    public com.uten.imp.common.delivery.DeliveryBom.Preview resolveOrderItem(SalesOrderItem item,
            java.math.BigDecimal rowQty) {
        if (item == null || item.isDeleted()) throw new ApiException(ErrorCode.CONFLICT, "销售订单行已删除或不存在");
        return boms.requireResolvedAdmitted(new com.uten.imp.common.delivery.DeliveryBom.AdmittedSource(
                item.getGoodsId(),item.getUnitId(),item.getUnitRate(),rowQty,effective(item.getDeliveryPlan()),item.getDeliveryBomSnapshot()),true);
    }
    /** New work only. Historical reads/reversals retain their original evidence and do not call this gate. */
    public void requireNoUnreviewedWork(SalesOrderItem item) {
        if(item==null||item.isDeleted())throw new ApiException(ErrorCode.CONFLICT,"原订单来源已变化");
        var plan=effective(item.getDeliveryPlan());
        // An old ordinary order without a snapshot cannot be reconstructed from today's rules or updated_at.
        // New saves/reviews adopt current mandatory work; existing ordinary fulfillment retains its actual saved intent.
        if(plan.equals(DeliveryPlan.assembled())&&item.getDeliveryBomSnapshot()==null)return;
        boms.requireCurrentAdmittedFingerprint(new com.uten.imp.common.delivery.DeliveryBom.AdmittedSource(
                item.getGoodsId(),item.getUnitId(),item.getUnitRate(),item.getQty(),plan,item.getDeliveryBomSnapshot()));
    }
    private void requireNoDownstream(SalesOrderItem item) {
        if (positive(item.getPlannedQty()) || positive(item.getProducedQty()) || positive(item.getShippedQty())
                || positive(item.getReturnedQty()) || positive(item.getInboundQty()))
            throw new ApiException(ErrorCode.CONFLICT, "该行已有排产、生产或发货事实，不能直接更换交付方案");
        Number count = (Number) em.createNativeQuery("""
            SELECT (SELECT count(*) FROM production_material_analysis_items ai
                JOIN production_material_analyses a ON a.id=ai.analysis_id
                WHERE ai.sales_order_item_id=:id AND NOT ai.is_deleted AND NOT a.is_deleted AND a.status<>'CANCELLED')
              +(SELECT count(*) FROM sales_shipment_items si JOIN sales_shipments s ON s.id=si.shipment_id
                WHERE si.order_item_id=:id AND NOT si.is_deleted AND NOT s.is_deleted AND s.status<>-1)
              +(SELECT count(*) FROM plan_order_item_links l WHERE l.order_item_id=:id AND NOT l.is_deleted)
            """).setParameter("id", item.getId()).getSingleResult();
        if (count.longValue() > 0) throw new ApiException(ErrorCode.CONFLICT, "该行已有下游分析、排产或出货作业，请先受控撤回后修改交付方案");
    }
    public static DeliveryPlan effective(DeliveryPlan plan) { return plan == null ? DeliveryPlan.assembled() : plan; }
    private static boolean positive(java.math.BigDecimal value) { return value != null && value.signum() != 0; }
    private static boolean sameNumber(java.math.BigDecimal a,java.math.BigDecimal b) {
        return a==null?b==null:b!=null&&a.compareTo(b)==0;
    }
}
