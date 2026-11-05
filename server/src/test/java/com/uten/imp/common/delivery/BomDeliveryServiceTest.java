package com.uten.imp.common.delivery;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.application.port.BomGraphLockPort;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class BomDeliveryServiceTest {
    @Test void alternateOrderUnitIsResolvedByServerAndStaleFingerprintIsRejected() {
        UUID goods=UUID.randomUUID(),unit=UUID.randomUUID();
        MasterReferenceValidationPort references=mock(MasterReferenceValidationPort.class);
        when(references.resolveVisibleActiveGoodsUnit(goods,unit,new BigDecimal("12"),1))
                .thenReturn(new MasterReferenceValidationPort.ResolvedLineUnit(unit,new BigDecimal("12")));
        BomDeliveryService service=spy(new BomDeliveryService(mock(EntityManager.class),references,mock(BomGraphLockPort.class),new ObjectMapper()));
        var root=new DeliveryBom.Node(List.of(),null,goods,"FG","Product",unit,"个",null,null,"","自制","1","PER_UNIT","1",true,
                DeliveryBom.ChildrenState.NONE,false,DeliveryBom.MaterialRole.PART,List.of(),List.of());
        doReturn(new DeliveryBom.Snapshot(1,goods,"current",root)).when(service).snapshot(goods);
        var preview=service.resolve(goods,unit,new BigDecimal("12"),new BigDecimal("2"),DeliveryPlan.assembled());
        assertThat(preview.items().getFirst().quantity()).isEqualByComparingTo("24");
        var stale=new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,List.of(),List.of(),"old");
        assertThatThrownBy(()->service.resolve(goods,unit,new BigDecimal("12"),BigDecimal.ONE,stale)).isInstanceOf(ApiException.class)
                .hasMessageContaining("已变化");
        var unconfirmed=new DeliveryPlan(1,DeliveryPlan.Mode.BOM,DeliveryPlan.Packaging.ORIGINAL,List.of(),List.of(),null);
        assertThatThrownBy(()->service.requireResolved(goods,unit,new BigDecimal("12"),BigDecimal.ONE,unconfirmed,false))
                .isInstanceOf(ApiException.class).hasMessageContaining("先预览");
    }
    @Test void admittedWarehouseContinuationUsesFrozenEvidenceWithoutGrantingTheExternalGoodsPicker() {
        UUID goods=UUID.randomUUID(),unit=UUID.randomUUID();
        var refs=mock(MasterReferenceValidationPort.class);var em=mock(EntityManager.class);
        Query edges=mock(Query.class,RETURNS_SELF),root=mock(Query.class,RETURNS_SELF);
        when(edges.getResultList()).thenReturn(List.of());
        when(root.getSingleResult()).thenReturn(new Object[]{goods,"CURRENT","Current master label","",unit,"个",null,null,"自制",false,false,0L});
        when(em.createNativeQuery(anyString())).thenAnswer(call->call.<String>getArgument(0).contains("WITH RECURSIVE")?edges:root);
        var service=new BomDeliveryService(em,refs,mock(BomGraphLockPort.class),new ObjectMapper());
        var current=service.snapshot(goods);var n=current.root();
        var frozenNode=new DeliveryBom.Node(n.path(),n.edgeId(),n.goodsId(),"FROZEN","Original reviewed name",n.unitId(),n.unitName(),n.colorId(),
                n.colorName(),n.spec(),n.sourceType(),n.qtyExact(),n.consumptionBasis(),n.basisOutputQtyExact(),n.allowPartialPackage(),
                n.childrenState(),n.mandatoryAssembly(),n.materialRole(),n.requiredOperations(),n.children());
        var frozen=new DeliveryBom.Snapshot(1,goods,current.bomFingerprint(),frozenNode);
        var plan=new DeliveryPlan(1,DeliveryPlan.Mode.ASSEMBLED,DeliveryPlan.Packaging.ORIGINAL,List.of(),
                List.of(new DeliveryPlan.Process(List.of(),DeliveryPlan.Operation.LASER,true)),current.bomFingerprint());
        clearInvocations(refs);
        doThrow(new ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND,"货品不可见")).when(refs).requireVisibleGoods(goods);
        when(refs.resolveVisibleActiveGoodsUnit(goods,unit,BigDecimal.ONE,1))
                .thenThrow(new ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND,"货品不可见"));
        when(refs.resolveAdmittedSourceGoodsUnit(goods,unit,BigDecimal.ONE,1))
                .thenReturn(new MasterReferenceValidationPort.ResolvedLineUnit(unit,BigDecimal.ONE));
        assertThatThrownBy(()->service.snapshot(goods)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.resolve(goods,unit,BigDecimal.ONE,BigDecimal.TEN,plan)).isInstanceOf(ApiException.class);
        var result=service.requireResolvedAdmitted(new DeliveryBom.AdmittedSource(goods,unit,BigDecimal.ONE,BigDecimal.TEN,plan,frozen),true);
        assertThat(result.items()).singleElement().satisfies(item->{
            assertThat(item.name()).isEqualTo("Original reviewed name");assertThat(item.operations()).contains(DeliveryPlan.Operation.LASER);
        });
        verify(refs).resolveAdmittedSourceGoodsUnit(goods,unit,BigDecimal.ONE,1);
        verify(refs).requireAdmittedSourceActiveGoods(goods);
        verify(refs,never()).requireVisibleGoodsBatch(anyCollection());
        verify(refs,never()).requireVisibleActiveGoods(any());
        assertThat(java.util.Arrays.stream(com.uten.imp.features.sales.order.SalesOrderDeliveryController.PreviewRequest.class.getRecordComponents())
                .map(java.lang.reflect.RecordComponent::getName)).doesNotContain("frozenSnapshot","admittedSource","requireVisibility");
    }
}
