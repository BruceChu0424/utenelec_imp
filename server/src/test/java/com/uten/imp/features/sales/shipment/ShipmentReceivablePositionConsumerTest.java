package com.uten.imp.features.sales.shipment;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.ShipmentReceivablePositionPort;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.shipment.dto.ShipmentQueryFilter;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.HeaderColumnFilter;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import jakarta.persistence.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class ShipmentReceivablePositionConsumerTest {
    private final UUID shipment=UUID.randomUUID(),ledger=UUID.randomUUID(),currency=UUID.randomUUID();
    private ShipmentReceivablePositionPort.Position current(){return new ShipmentReceivablePositionPort.Position(
            ledger,currency,"人民币","1000","1000","300","100","400","0","0","0","600","2026-12-01",0,"READY",true,List.of());}
    private SalesShipmentService service(Set<String> permissions,ShipmentReceivablePositionPort money){
        var service=mock(SalesShipmentService.class,CALLS_REAL_METHODS);var access=mock(SalesDocumentAccessPolicy.class);
        when(access.hasAuthority(anyString())).thenAnswer(call->permissions.contains(call.getArgument(0)));
        ReflectionTestUtils.setField(service,"accessPolicy",access);ReflectionTestUtils.setField(service,"shipmentReceivables",money);
        return service;
    }
    @Test void warehouseOperationalAccessDoesNotQueryOrSerializeFinancialFacts(){
        var money=mock(ShipmentReceivablePositionPort.class);var service=service(Set.of("warehouse_sales_outbound:view"),money);
        Map<UUID,ShipmentReceivablePositionPort.Position> result=ReflectionTestUtils.invokeMethod(service,"shipmentReceivablePositions",List.of(shipment));
        assertThat(result).isEmpty();verifyNoInteractions(money);
    }
    @Test void warehouseCannotProbeDebtThroughEitherTheListOrItsFacetCounts(){
        var money=mock(ShipmentReceivablePositionPort.class);var service=service(Set.of("warehouse_sales_outbound:view"),money);
        var filter=new ShipmentQueryFilter(null,null,null,null,null,null,null,null,null,null,null,null,null).withReceivableState("OPEN");
        assertThatThrownBy(()->service.list(filter,1,20,null,null)).isInstanceOf(ApiException.class).hasMessageContaining("无权按本批款项筛选");
        assertThatThrownBy(()->service.facets(filter)).isInstanceOf(ApiException.class).hasMessageContaining("无权按本批款项筛选");
        verifyNoInteractions(money);
    }
    @Test void debtQuerySurvivesTheExistingHistoryAndHeaderAdaptersWithoutChangingTheirContracts(){
        var filter=new ShipmentQueryFilter(null,null,null,null,null,null,null,null,null,null,null,null,null)
                .withReceivableState(" open ").withHeaders(HeaderColumnFilter.EMPTY).withHistory(true,false);
        assertThat(filter.receivableState()).isEqualTo("OPEN");assertThat(filter.includeDeleted()).isTrue();
        assertThat(filter.withHeaders(HeaderColumnFilter.EMPTY).receivableState()).isEqualTo("OPEN");
        assertThat(filter.withReceivableState(null).receivableState()).isNull();
    }
    @Test void financeReadWithoutCommercialPriceGetsOnlyTheBoundedVisibleShipmentProjection(){
        for(String permission:List.of("sales_shipment_finance:view","sales_order_finance:view","finance:view:all")){
            var money=mock(ShipmentReceivablePositionPort.class);when(money.read(List.of(shipment))).thenReturn(Map.of(shipment,current()));
            var service=service(Set.of(permission),money);
            Map<UUID,ShipmentReceivablePositionPort.Position> result=ReflectionTestUtils.invokeMethod(service,"shipmentReceivablePositions",List.of(shipment));
            assertThat(result.get(shipment).confirmedPaidOriginal()).isEqualTo("400");assertThat(result.get(shipment).balanceOriginal()).isEqualTo("600");
            verify(money).read(List.of(shipment));verifyNoMoreInteractions(money);
        }
    }
    @Test void oldNotPostedReleaseEvidenceNeverReplacesTheCurrentDebt(){
        var money=mock(ShipmentReceivablePositionPort.class);when(money.read(List.of(shipment))).thenReturn(Map.of(shipment,current()));
        var service=service(Set.of("sales_shipment_finance:view"),money);
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class);when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(),any())).thenReturn(query);when(query.getResultList()).thenReturn(List.of("{\"state\":\"NOT_POSTED\",\"balanceOriginal\":null,\"complete\":true}"));
        ReflectionTestUtils.setField(service,"em",em);
        var source=new SalesShipment();source.setId(shipment);source.setFinanceReleaseEventId(UUID.randomUUID());
        JsonNode frozen=ReflectionTestUtils.invokeMethod(service,"frozenShipmentReceivable",source);
        assertThat(frozen.path("state").asText()).isEqualTo("NOT_POSTED");assertThat(frozen.path("balanceOriginal").isNull()).isTrue();
        ShipmentReceivablePositionPort.Position live=ReflectionTestUtils.invokeMethod(service,"shipmentReceivableFact",shipment);
        assertThat(live.balanceOriginal()).isEqualTo("600");assertThat(live.state()).isEqualTo("READY");
    }
    @Test void eachPublicConsumerOwnsTheRepeatableReadSnapshotRequiredByTheFinancePort(){
        var annotations=new AnnotationTransactionAttributeSource();int checked=0;
        for(var method:SalesShipmentService.class.getDeclaredMethods()){
            if(java.lang.reflect.Modifier.isPublic(method.getModifiers())&&Set.of("list","detail","detailHistory","financeAuditInfo").contains(method.getName())){
                var attribute=annotations.getTransactionAttribute(method,SalesShipmentService.class);
                assertThat(attribute).isNotNull();assertThat(attribute.getIsolationLevel()).as(method.getName()).isEqualTo(TransactionDefinition.ISOLATION_REPEATABLE_READ);checked++;
            }
        }
        assertThat(checked).isEqualTo(4);
    }
}
