package com.uten.imp.features.sales.order;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.delivery.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class SalesOrderDeliveryServiceTest {
    @Test void legacyNewAndExistingLinesKeepAssembledDefaultWithoutReadingUnrelatedBom() {
        BomDeliveryService boms=mock(BomDeliveryService.class);
        SalesOrderDeliveryService service=new SalesOrderDeliveryService(boms,mock(SalesOrderItemRepository.class),
                mock(EntityManager.class),new ObjectMapper());
        var request=new OrderItemLine(); var stored=new SalesOrderItem();
        assertThat(service.forSave(request,null)).isEqualTo(DeliveryPlan.assembled());
        assertThat(service.forSave(request,stored)).isEqualTo(DeliveryPlan.assembled());
        verifyNoInteractions(boms);
    }
    @Test void omittedDeliveryFromOlderClientPreservesStoredConfiguredIntent() {
        BomDeliveryService boms=mock(BomDeliveryService.class);
        SalesOrderDeliveryService service=new SalesOrderDeliveryService(boms,mock(SalesOrderItemRepository.class),
                mock(EntityManager.class),new ObjectMapper());
        var plan=new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,List.of(),List.of(),"frozen");
        var stored=new SalesOrderItem();stored.setDeliveryPlan(plan);
        var request=new OrderItemLine();request.setGoodsId(UUID.randomUUID());request.setQty(new BigDecimal("10"));
        stored.setGoodsId(request.getGoodsId());
        when(boms.requireResolved(request.getGoodsId(),null,null,request.getQty(),plan,false))
                .thenReturn(new DeliveryBom.Preview(plan,"frozen",null,List.of(),List.of()));
        assertThat(service.forSave(request,stored)).isEqualTo(plan);
        verify(boms).requireResolved(request.getGoodsId(),null,null,request.getQty(),plan,false);
    }
    @Test void changedPlanCannotOverwriteAnyExistingPlanningOrShipmentFact() {
        BomDeliveryService boms=mock(BomDeliveryService.class);
        SalesOrderDeliveryService service=new SalesOrderDeliveryService(boms,mock(SalesOrderItemRepository.class),
                mock(EntityManager.class),new ObjectMapper());
        var request=new OrderItemLine();request.setDeliveryPlan(new DeliveryPlan(1,DeliveryPlan.Mode.BOM,
                DeliveryPlan.Packaging.ORIGINAL,List.of(),List.of(),"new"));
        var stored=new SalesOrderItem();stored.setPlannedQty(BigDecimal.ONE);
        when(boms.requireResolved(null,null,null,null,request.getDeliveryPlan(),false))
                .thenReturn(new DeliveryBom.Preview(request.getDeliveryPlan(),"new",null,List.of(),List.of()));
        assertThatThrownBy(()->service.forSave(request,stored)).isInstanceOf(ApiException.class).hasMessageContaining("已有排产");
    }
    @Test void unknownJsonImplementationPropertiesAreNotProducedAndRoundTripKeepsPathDecisions() throws Exception {
        var plan=new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.PENDING,
                List.of(new DeliveryPlan.NodeMode(List.of(UUID.randomUUID()),DeliveryPlan.NodeDelivery.CHILDREN)),
                List.of(new DeliveryPlan.Process(List.of(),DeliveryPlan.Operation.LASER,true)),"fingerprint");
        var mapper=new ObjectMapper(); var json=mapper.writeValueAsString(plan);
        SalesOrderDeliveryService service=new SalesOrderDeliveryService(mock(BomDeliveryService.class),mock(SalesOrderItemRepository.class),
                mock(EntityManager.class),mapper);
        assertThat(service.parsePlan(json)).isEqualTo(plan);
        assertThat(json).doesNotContain("\"bom\"");
    }
    @Test void defaultAssembledOrdersCannotSkipNewMasterRequiredWork() {
        BomDeliveryService boms=mock(BomDeliveryService.class);
        SalesOrderDeliveryService service=new SalesOrderDeliveryService(boms,mock(SalesOrderItemRepository.class),
                mock(EntityManager.class),new ObjectMapper());
        var requested=new OrderItemLine();requested.setGoodsId(UUID.randomUUID());requested.setQty(BigDecimal.TEN);
        var mandatory=new DeliveryPlan(1,DeliveryPlan.Mode.ASSEMBLED,DeliveryPlan.Packaging.ORIGINAL,List.of(),
                List.of(new DeliveryPlan.Process(List.of(UUID.randomUUID()),DeliveryPlan.Operation.LASER,true)),"master");
        var preview=new DeliveryBom.Preview(mandatory,"master",null,List.of(),List.of());
        when(boms.hasRequiredOperations(requested.getGoodsId())).thenReturn(true);
        when(boms.resolve(requested.getGoodsId(),null,null,BigDecimal.TEN,DeliveryPlan.assembled())).thenReturn(preview);
        when(boms.requireResolved(requested.getGoodsId(),null,null,BigDecimal.TEN,mandatory,false)).thenReturn(preview);
        assertThat(service.forSave(requested,null)).isEqualTo(mandatory);
        var oldOrder=new SalesOrderItem();oldOrder.setGoodsId(requested.getGoodsId());
        when(boms.hasRequiredOperationsAdmitted(any(DeliveryBom.AdmittedSource.class))).thenReturn(true);
        assertThatThrownBy(()->service.validateApproval(List.of(oldOrder))).isInstanceOf(ApiException.class).hasMessageContaining("新增了必要加工");
    }
    @Test void reservedOnlyOrdinaryToPhysicalReleasesOnlyItsOriginalRowButProducedSourceCannotBeRewritten() {
        var boms=mock(BomDeliveryService.class);var em=mock(EntityManager.class);var query=mock(jakarta.persistence.Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.getSingleResult()).thenReturn(0L);
        var reservations=mock(com.uten.imp.features.stock.StockReservationService.class);
        var service=new SalesOrderDeliveryService(boms,mock(SalesOrderItemRepository.class),em,new ObjectMapper());service.setReservations(reservations);
        var stored=new SalesOrderItem();stored.setReservedQty(new BigDecimal("5"));
        var request=new OrderItemLine();var plan=new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,List.of(),List.of(),"f");
        request.setDeliveryPlan(plan);when(boms.requireResolved(null,null,null,null,plan,false)).thenReturn(new DeliveryBom.Preview(plan,"f",null,List.of(),List.of()));
        assertThat(service.forSave(request,stored)).isEqualTo(plan);assertThat(stored.getReservedQty()).isZero();
        verify(reservations).releaseByOrderItems(List.of(stored.getId()));
        var produced=new SalesOrderItem();produced.setReservedQty(new BigDecimal("5"));produced.setProducedQty(BigDecimal.ONE);
        assertThatThrownBy(()->service.forSave(request,produced)).isInstanceOf(ApiException.class).hasMessageContaining("已有排产");
        verify(reservations,never()).releaseByOrderItems(List.of(produced.getId()));
        var ordinary=new SalesOrderItem();ordinary.setReservedQty(new BigDecimal("5"));service.forSave(new OrderItemLine(),ordinary);
        verify(reservations,never()).releaseByOrderItems(List.of(ordinary.getId()));
    }
    @Test void ordinaryHistoricalSourceWithoutSnapshotDoesNotAcquireTodaysMasterProcessingRules() {
        var boms=mock(BomDeliveryService.class);var service=new SalesOrderDeliveryService(boms,mock(SalesOrderItemRepository.class),mock(EntityManager.class),new ObjectMapper());
        service.requireNoUnreviewedWork(new SalesOrderItem());verifyNoInteractions(boms);
    }
}
