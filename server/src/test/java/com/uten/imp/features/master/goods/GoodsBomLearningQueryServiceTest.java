package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsBomLearningQueryServiceTest {
    final EntityManager em=mock(EntityManager.class);
    final MasterReferenceValidationPort references=mock(MasterReferenceValidationPort.class);
    final MasterObjectAccess access=mock(MasterObjectAccess.class);
    final GoodsBomLearningQueryService service=new GoodsBomLearningQueryService(em,references,access);

    @Test void invisibleParentIsRejectedBeforeAnyLearningQuery() {
        UUID parent=UUID.randomUUID();
        doThrow(new ApiException(ErrorCode.NOT_FOUND,"货品不存在")).when(references).requireVisibleGoods(parent);
        assertThrows(ApiException.class,()->service.summary(parent));verifyNoInteractions(em,access);
    }

    @Test void normalUnenrolledGoodsHasNoInventedLearningHistory() {
        Query profile=query(List.of());when(em.createNativeQuery(anyString())).thenReturn(profile);
        var result=service.summary(UUID.randomUUID());
        assertFalse(result.active());assertEquals(0,result.sampleCount());assertTrue(result.materials().isEmpty());
        verifyNoInteractions(access);verify(em,times(1)).createNativeQuery(anyString());
    }

    @Test void summaryUsesWeightedParentTotalAndRespectsComponentOwnerVisibility() {
        UUID visible=UUID.randomUUID(),hidden=UUID.randomUUID(),component=UUID.randomUUID();
        Query profile=query(Collections.singletonList(new Object[]{true,new BigDecimal("400"),2L,null,"个"}));
        Query materials=query(List.of(
                new Object[]{component,"P01","塑料",null,null,UUID.randomUUID(),"千克",new BigDecimal("110"),visible},
                new Object[]{UUID.randomUUID(),"SECRET","不可见材料",null,null,UUID.randomUUID(),"千克",new BigDecimal("20"),hidden}));
        when(em.createNativeQuery(anyString())).thenReturn(profile,materials);
        when(access.visibleGoodsOwner()).thenReturn(visible::equals);
        var result=service.summary(UUID.randomUUID());
        assertTrue(result.active());assertEquals(1,result.materials().size());
        assertEquals(component,result.materials().getFirst().goodsId());
        assertEquals(0,new BigDecimal("0.275").compareTo(result.materials().getFirst().averageQty()));
        verify(em,times(2)).createNativeQuery(anyString());
    }

    private Query query(List<?> rows) {
        Query query=mock(Query.class);when(query.setParameter(eq("goods"),any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);return query;
    }
}
