package com.uten.imp.common.finance;

import com.uten.imp.common.report.ReportQueryKit.WhereBuilder;
import com.uten.imp.security.DocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class ProcurementDeliveryDifferenceReadTest {
    private static class Line extends ProcurementSourceOrderDifferenceResponse {
        private final UUID orderItemId;
        Line(UUID orderItemId) { this.orderItemId=orderItemId; }
        @Override public UUID getOrderItemId() { return orderItemId; }
    }

    @Test void sourceOrderPermissionIsRequiredBeforeAnyQuery() {
        var em=mock(EntityManager.class);var access=mock(DocumentAccessPolicy.class);
        var line=new Line(UUID.randomUUID());
        ProcurementDeliveryDifferenceRead.enrich(em,access,"PURCHASE",List.of(line));
        assertThat(line.getSourceOrderDifferenceQtyExact()).isNull();
        verifyNoInteractions(em);
        var join=ProcurementDeliveryDifferenceRead.reportJoin(access,"PURCHASE",new WhereBuilder("WHERE TRUE"));
        assertThat(join).contains("NULL::numeric", "NULL::text").doesNotContain("purchase_order_items");
    }

    @Test void oneBatchKeepsExactFactsSourceUnitsAndBoundOwnerScope() {
        var em=mock(EntityManager.class);var access=mock(DocumentAccessPolicy.class);var query=mock(Query.class);
        UUID source=UUID.randomUUID(), unknown=UUID.randomUUID(), inaccessible=UUID.randomUUID(), unit=UUID.randomUUID(), owner=UUID.randomUUID();
        when(access.hasAuthority("purchase_order:view")).thenReturn(true);
        when(access.nativeReadScope("source_order.maker_id","sourceDifferenceOwners"))
                .thenReturn(new DocumentAccessPolicy.NativeReadScope("source_order.maker_id IN (:sourceDifferenceOwners)","sourceDifferenceOwners",Set.of(owner)));
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.setParameter(anyString(),any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(new Object[]{source,new BigDecimal("-9007199254740993.0001"),unit},new Object[]{unknown,null,unit}));
        var first=new Line(source);var duplicate=new Line(source);var missing=new Line(inaccessible);var noLink=new Line(null);var unknownLine=new Line(unknown);
        ProcurementDeliveryDifferenceRead.enrich(em,access,"PURCHASE",List.of(first,duplicate,missing,noLink,unknownLine));
        assertThat(first.getSourceOrderDifferenceQtyExact()).isEqualTo("-9007199254740993.0001");
        assertThat(duplicate.getSourceOrderDifferenceQtyExact()).isEqualTo(first.getSourceOrderDifferenceQtyExact());
        assertThat(first.getSourceOrderDifferenceUnitId()).isEqualTo(unit);
        assertThat(missing.getSourceOrderDifferenceQtyExact()).isNull();assertThat(noLink.getSourceOrderDifferenceQtyExact()).isNull();
        assertThat(unknownLine.getSourceOrderDifferenceQtyExact()).isNull();
        verify(query).setParameter("ids",List.of(source,inaccessible,unknown));
        verify(query).setParameter("sourceDifferenceOwners",Set.of(owner));
        var sql=ArgumentCaptor.forClass(String.class);verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue()).contains("NOT item.is_deleted", "NOT source_order.is_deleted", "source_order.maker_id IN (:sourceDifferenceOwners)")
                .doesNotContain("settled_loss", "termination_case", "gift_received_qty");
    }

    @Test void reportProjectionUsesTheSameFormulaAndItsOwnUnitWithBoundScope() {
        var access=mock(DocumentAccessPolicy.class);var owner=UUID.randomUUID();
        when(access.hasAuthority("subcontract_order:view")).thenReturn(true);
        when(access.nativeReadScope("source_order.maker_id","sourceDifferenceOwners"))
                .thenReturn(new DocumentAccessPolicy.NativeReadScope("source_order.maker_id IN (:sourceDifferenceOwners)","sourceDifferenceOwners",Set.of(owner)));
        var where=new WhereBuilder("WHERE TRUE");
        var join=ProcurementDeliveryDifferenceRead.reportJoin(access,"SUBCONTRACT",where);
        assertThat(join).contains("source_item.id=i.order_item_id", "source_unit.id=source_item.unit_id", "source_order.maker_id IN (:sourceDifferenceOwners)",
                ProcurementDeliveryDifference.sql("source_item.qty","source_item.received_qty","source_item.returned_qty"));
        assertThat(where.build(null).params()).containsEntry("sourceDifferenceOwners",Set.of(owner));
    }

    @Test void priceMaskingKeepsSourceOrderQuantityFactsAcrossAllFourDocumentTypes() throws Exception {
        for(String feature:List.of("purchase","subcontract")) for(String type:List.of("receipt","ret")) {
            String name=type.equals("receipt")?"Receipt":"Return";
            String prefix="com.uten.imp.features."+feature+"."+type+".";
            Class<?> dtoClass=Class.forName(prefix+"dto."+name+"ItemDto");
            var constructor=dtoClass.getConstructors()[0];
            var dto=(ProcurementSourceOrderDifferenceResponse)constructor.newInstance(new Object[constructor.getParameterCount()]);
            UUID unit=UUID.randomUUID();dto.setSourceOrderDifferenceQty(new BigDecimal("-6.0001"));dto.setSourceOrderDifferenceUnitId(unit);
            Class<?> service=Class.forName(prefix+(feature.equals("purchase")?"Purchase":"Subcontract")+name+"Service");
            var mask=service.getDeclaredMethod("maskItemPrices",dtoClass);mask.setAccessible(true);
            var masked=(ProcurementSourceOrderDifferenceResponse)mask.invoke(null,dto);
            assertThat(masked.getSourceOrderDifferenceQtyExact()).as(feature+" "+type).isEqualTo("-6.0001");
            assertThat(masked.getSourceOrderDifferenceUnitId()).isEqualTo(unit);
        }
    }
}
