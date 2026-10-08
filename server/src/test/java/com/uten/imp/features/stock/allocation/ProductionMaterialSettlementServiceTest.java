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
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionMaterialSettlementServiceTest {

    @Test
    void dailyReportCommandAndReplayKeepAuthorizationAndExactPostingWithoutBuildingClearance() {
        var fixture=commandFixture();
        fixture.service().postForDailyReport(fixture.plan(),fixture.request(),fixture.actor());
        fixture.service().postForDailyReport(fixture.plan(),fixture.request(),fixture.actor());
        verify(fixture.access(),times(2)).requireDemandWrite(fixture.plan(),List.of(fixture.demand()),null,"production_material:settle");
        verify(fixture.access(),times(2)).readable(fixture.plan(),null);
        verify(fixture.value(),times(1)).settled(any(UUID.class),eq(fixture.actor()));
        verify(fixture.em(),times(1)).createNativeQuery(contains("INSERT INTO production_material_settlement_postings"));
        verify(fixture.em(),never()).createNativeQuery(contains("FROM v_production_material_clearance"));
        fixture.request().setReason("同键改变了实际耗用理由");
        assertThrows(ApiException.class,()->fixture.service().postForDailyReport(fixture.plan(),fixture.request(),fixture.actor()));
    }

    @Test
    void existingMaterialPageCommandStillReturnsItsClearanceProjection() {
        var fixture=commandFixture();
        fixture.service().post(fixture.plan(),fixture.request(),fixture.actor());
        verify(fixture.em()).createNativeQuery(contains("FROM v_production_material_clearance"));
    }

    @Test
    void reportReversalRetainsItsOwnPermissionAndIdempotencyWithoutBuildingClearance() {
        var fixture=commandFixture();fixture.request().getLines().getFirst().setSourcePostingId(UUID.randomUUID());
        fixture.service().reverseForDailyReport(fixture.plan(),fixture.request(),fixture.actor());
        fixture.service().reverseForDailyReport(fixture.plan(),fixture.request(),fixture.actor());
        verify(fixture.access(),times(2)).requireDemandWrite(fixture.plan(),List.of(fixture.demand()),null,"production_material:reverse");
        verify(fixture.access(),times(2)).readable(fixture.plan(),null);
        verify(fixture.value()).settled(any(UUID.class),eq(fixture.actor()));
        verify(fixture.em(),never()).createNativeQuery(contains("FROM v_production_material_clearance"));
    }

    @Test
    void reportCommandStillRejectsBothWriteAndReadScopeDenialsBeforeWriting() {
        for(boolean denyRead:List.of(false,true)) {
            var fixture=commandFixture();
            var denied=new ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN,"测试授权拒绝");
            if(denyRead)when(fixture.access().readable(fixture.plan(),null)).thenThrow(denied);
            else doThrow(denied).when(fixture.access()).requireDemandWrite(fixture.plan(),List.of(fixture.demand()),null,"production_material:settle");
            assertThrows(ApiException.class,()->fixture.service().postForDailyReport(fixture.plan(),fixture.request(),fixture.actor()));
            verify(fixture.em(),never()).createNativeQuery(contains("INSERT INTO production_material_settlement_events"));
        }
    }

    private static CommandFixture commandFixture() {
        var em=mock(jakarta.persistence.EntityManager.class);var access=mock(ProductionMaterialTaskAccessPolicy.class);
        var footprint=mock(com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService.class);
        var guard=mock(com.uten.imp.application.concurrency.FulfillmentMutationLocks.Guard.class);
        var value=mock(com.uten.imp.features.stock.valuation.ProductionInventoryValueService.class);
        UUID plan=UUID.randomUUID(),demand=UUID.randomUUID(),issue=UUID.randomUUID(),actor=UUID.randomUUID(),event=UUID.randomUUID();
        when(footprint.beginPlan(eq(plan),anyList())).thenReturn(guard);
        when(access.readable(plan,null)).thenReturn(new ProductionMaterialTaskAccessPolicy.ReadScope(true,List.of()));
        var stored=new java.util.HashMap<String,Object>();
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);var parameters=new java.util.HashMap<String,Object>();
            var query=mock(jakarta.persistence.Query.class);
            when(query.setParameter(anyString(),any())).thenAnswer(binding->{parameters.put(binding.getArgument(0),binding.getArgument(1));return query;});
            when(query.getResultList()).thenAnswer(ignored->{
                if(sql.contains("FROM v_production_material_clearance"))return List.of();
                if(sql.contains("FROM production_plans"))return List.of(plan);
                if(sql.contains("FROM production_material_settlement_events")&&stored.containsKey("requestHash"))
                    return java.util.Collections.singletonList(new Object[]{event,stored.get("requestHash")});
                if(sql.contains("FROM production_material_stock_postings"))
                    return java.util.Collections.singletonList(new Object[]{demand,issue,BigDecimal.ONE});
                if(sql.startsWith("SELECT issue_posting_id,qty_base FROM production_material_settlement_postings"))
                    return java.util.Collections.singletonList(new Object[]{issue,BigDecimal.ONE});
                return List.of();
            });
            when(query.executeUpdate()).thenAnswer(ignored->{
                if(sql.contains("INSERT INTO production_material_settlement_events"))stored.putAll(parameters);
                return 1;
            });return query;
        });
        var locked=mock(jakarta.persistence.Query.class);
        when(locked.setParameter(anyString(),any())).thenReturn(locked);when(locked.getResultList()).thenReturn(List.of(demand));
        when(em.createNativeQuery(anyString(),eq(UUID.class))).thenReturn(locked);
        var request=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        request.setIdempotencyKey("report-command");request.setReason("本批实际用料");
        var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
        line.setDemandId(demand);line.setQtyBase(BigDecimal.ONE);line.setSettlementType("CONSUMED");request.setLines(List.of(line));
        var service=new ProductionMaterialSettlementService(em,mock(com.uten.imp.security.TxSessionVars.class),access,value,footprint);
        return new CommandFixture(service,em,access,value,request,plan,demand,actor);
    }

    private record CommandFixture(ProductionMaterialSettlementService service,jakarta.persistence.EntityManager em,
                                  ProductionMaterialTaskAccessPolicy access,
                                  com.uten.imp.features.stock.valuation.ProductionInventoryValueService value,
                                  com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest request,
                                  UUID plan,UUID demand,UUID actor) { }

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
