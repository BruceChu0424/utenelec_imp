package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Real component custody covers its original preparation path while processing is in progress. */
@org.springframework.stereotype.Component
@lombok.RequiredArgsConstructor
final class SalesDeliveryCustodyCoverage {
    private final EntityManager em;

    List<MaterialAnalysisService.FormalMaterialCoverage> read(UUID analysisId) {
        var rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT component.id,allocation.id,allocation.analysis_id,allocation.analysis_item_id,material.node_key,
                    component.required_qty,kit.order_qty,allocation.order_qty,
                    COALESCE((SELECT sum(held.qty-held.consumed_qty-held.released_qty) FROM stock_reservations held
                       WHERE held.owner_type='SALES_DELIVERY_PROCESSING' AND held.owner_id=component.id AND held.status=0 AND NOT held.is_deleted),0),
                    COALESCE((SELECT sum(held.qty-held.consumed_qty-held.released_qty)
                       FROM sales_delivery_entitlement_handoffs handoff JOIN stock_reservations held ON held.id=handoff.target_reservation_id
                       WHERE handoff.component_id=component.id AND handoff.allocation_id=allocation.id
                         AND held.status=0 AND NOT held.is_deleted
                         AND NOT EXISTS(SELECT 1 FROM sales_delivery_entitlement_restores restored WHERE restored.handoff_id=handoff.id)),0)
                FROM sales_delivery_fulfillment_groups kit
                JOIN sales_delivery_fulfillment_allocations allocation ON allocation.shipment_item_id=kit.shipment_item_id
                JOIN sales_shipment_delivery_components component ON component.shipment_item_id=kit.shipment_item_id AND component.movement_id IS NULL
                JOIN production_material_analysis_materials material ON material.analysis_id=allocation.analysis_id
                  AND material.analysis_item_id=allocation.analysis_item_id AND material.delivery_frontier
                  AND material.goods_id=component.goods_id AND material.color_id IS NOT DISTINCT FROM component.color_id
                  AND material.unit_id=component.unit_id AND material.node_key=(SELECT string_agg(path.value,'/' ORDER BY path.position)
                    FROM jsonb_array_elements_text(component.bom_path) WITH ORDINALITY path(value,position))
                WHERE kit.state='PREPARED' AND EXISTS(SELECT 1 FROM sales_delivery_fulfillment_allocations selected
                    WHERE selected.shipment_item_id=kit.shipment_item_id AND selected.analysis_id=:id)
                ORDER BY component.id,allocation.position,allocation.id
                """).setParameter("id",analysisId));
        var result=new ArrayList<MaterialAnalysisService.FormalMaterialCoverage>();
        UUID component=null;BigDecimal preceding=BigDecimal.ZERO,publicLeft=BigDecimal.ZERO;
        for(Object[] row:rows) {
            if(!Objects.equals(component,row[0])) {component=(UUID)row[0];preceding=BigDecimal.ZERO;publicLeft=decimal(row[8]);}
            BigDecimal next=preceding.add(decimal(row[7]));
            BigDecimal capacity=SalesDeliveryFulfillmentService.proportionalSlice(decimal(row[5]),preceding,next,decimal(row[6]));
            preceding=next;
            BigDecimal owned=decimal(row[9]).min(capacity);
            BigDecimal publicTake=publicLeft.min(capacity.subtract(owned).max(BigDecimal.ZERO));
            publicLeft=publicLeft.subtract(publicTake);
            BigDecimal covered=owned.add(publicTake);
            if(analysisId.equals(row[2])&&covered.signum()>0)result.add(new MaterialAnalysisService.FormalMaterialCoverage(
                    component,(UUID)row[3],(String)row[4],covered,null));
        }
        return List.copyOf(result);
    }
    private static BigDecimal decimal(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
}
