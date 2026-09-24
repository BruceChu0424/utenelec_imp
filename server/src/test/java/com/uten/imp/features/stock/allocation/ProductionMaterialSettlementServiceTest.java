package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.sql.Timestamp;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ProductionMaterialSettlementServiceTest {

    @Test
    void materialWriteAcquiresTheSharedPlanPrefixBeforePlanRowsAndVerifiesBeforeItsFirstWrite() {
        var em=org.mockito.Mockito.mock(jakarta.persistence.EntityManager.class);
        var access=org.mockito.Mockito.mock(ProductionMaterialTaskAccessPolicy.class);
        var footprints=org.mockito.Mockito.mock(com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService.class);
        var guard=org.mockito.Mockito.mock(com.uten.imp.application.concurrency.FulfillmentMutationLocks.Guard.class);
        UUID plan=UUID.randomUUID(),demand=UUID.randomUUID();
        org.mockito.Mockito.when(footprints.beginPlan(org.mockito.ArgumentMatchers.eq(plan),org.mockito.ArgumentMatchers.anyList())).thenReturn(guard);
        org.mockito.Mockito.when(em.createNativeQuery(org.mockito.ArgumentMatchers.anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);
            var query=org.mockito.Mockito.mock(jakarta.persistence.Query.class);
            org.mockito.Mockito.when(query.setParameter(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.any())).thenReturn(query);
            org.mockito.Mockito.when(query.getResultList()).thenReturn(sql.contains("FROM production_plans")?List.of(plan):List.of());
            if(sql.contains("INSERT INTO production_material_settlement_events"))
                org.mockito.Mockito.when(query.executeUpdate()).thenThrow(new IllegalStateException("write boundary"));
            return query;
        });
        var demands=org.mockito.Mockito.mock(jakarta.persistence.Query.class);
        org.mockito.Mockito.when(demands.setParameter(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.any())).thenReturn(demands);
        org.mockito.Mockito.when(demands.getResultList()).thenReturn(List.of(demand));
        org.mockito.Mockito.when(em.createNativeQuery(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.eq(UUID.class))).thenReturn(demands);
        var request=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        request.setIdempotencyKey("shared-material-lock-order");request.setReason("实际耗用");
        var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
        line.setDemandId(demand);line.setSettlementType("CONSUMED");line.setQtyBase(BigDecimal.ONE);request.setLines(List.of(line));
        var service=new ProductionMaterialSettlementService(em,org.mockito.Mockito.mock(com.uten.imp.security.TxSessionVars.class),
                access,org.mockito.Mockito.mock(com.uten.imp.features.stock.valuation.ProductionInventoryValueService.class),footprints);
        assertThrows(IllegalStateException.class,()->service.post(plan,request,UUID.randomUUID()));
        var order=org.mockito.Mockito.inOrder(footprints,em,guard);
        order.verify(footprints).beginPlan(org.mockito.ArgumentMatchers.eq(plan),org.mockito.ArgumentMatchers.anyList());
        order.verify(em).createNativeQuery(org.mockito.ArgumentMatchers.argThat(sql->sql.contains("FROM production_plans")&&sql.contains("FOR UPDATE")));
        order.verify(guard).verifyUnchanged();
        order.verify(em).createNativeQuery(org.mockito.ArgumentMatchers.argThat(sql->sql.contains("INSERT INTO production_material_settlement_events")));
    }

    @Test
    void nativeTimestampProjectionAcceptsHibernateUtcTypes() {
        Instant instant = Instant.parse("2026-08-01T10:15:30Z");
        OffsetDateTime expected = instant.atOffset(ZoneOffset.UTC);

        assertEquals(expected,
                ProductionMaterialSettlementService.offsetDateTime(instant));
        assertEquals(expected, ProductionMaterialSettlementService.offsetDateTime(
                Timestamp.from(instant)));
        assertEquals(expected,
                ProductionMaterialSettlementService.offsetDateTime(expected));
        assertThrows(ApiException.class,
                () -> ProductionMaterialSettlementService.offsetDateTime("not-a-time"));
    }
}
