package com.uten.imp.common.web;

import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Map;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class HeaderColumnFilterTest {
    @Test void maskedAmountAndNullProbesFailBeforeParsingOrTouchingAnyJpaProperty() {
        for (var values : java.util.List.of(Map.of("amountMin", "NaN"), Map.of("amountNull", "true"))) {
            var root = mock(Root.class);var builder = mock(CriteriaBuilder.class);
            var filter = new HeaderColumnFilter(values);
            var failure = assertThrows(ApiException.class, () -> filter.apply(root,builder,new ArrayList<>(),"totalLocal",false,null,false,null,false));
            assertEquals(ErrorCode.FORBIDDEN,failure.getCode());verifyNoInteractions(root,builder);
        }
    }
    @Test void unknownPropertiesNeverBecomeAnArbitraryJpaOrSqlSelector() {
        assertThrows(ApiException.class,()->HeaderColumnFilter.from(Map.of("hf.makerId", "someone")));
        assertThrows(ApiException.class,()->HeaderColumnFilter.from(Map.of("hf.amountMin;DELETE", "1")));
        assertEquals(HeaderColumnFilter.EMPTY,HeaderColumnFilter.from(Map.of("keyword","normal legacy search")));
    }
    @Test @SuppressWarnings("unchecked") void finiteDecimalBoundsPreserveLargeFractionalValueExactly() {
        Root<?> root=mock(Root.class);CriteriaBuilder builder=mock(CriteriaBuilder.class);
        var field=mock(jakarta.persistence.criteria.Path.class);doReturn(field).when(root).get("amountLocal");
        String value="9876543210123.123456789012345678901234";
        new HeaderColumnFilter(Map.of("amountMin",value)).apply(root,builder,new ArrayList<>(),"amountLocal",true,null,false,null,false);
        verify(builder).greaterThanOrEqualTo((Expression<BigDecimal>)field,new BigDecimal(value));
    }
    @Test void unknownWeightCannotBeConflatedWithRealZeroOrSimultaneouslyBound() {
        Root<?> root=mock(Root.class);CriteriaBuilder builder=mock(CriteriaBuilder.class);
        var field=mock(jakarta.persistence.criteria.Path.class);doReturn(field).when(root).get("totalWeight");
        new HeaderColumnFilter(Map.of("weightNull","true")).apply(root,builder,new ArrayList<>(),null,false,null,false,"totalWeight",false);
        verify(builder).isNull(field);verify(builder,never()).equal(any(),eq(BigDecimal.ZERO));
        assertThrows(ApiException.class,()->new HeaderColumnFilter(Map.of("weightNull","true","weightMin","0"))
                .apply(root,builder,new ArrayList<>(),null,false,null,false,"totalWeight",false));
    }
    @Test void deliveryAndOriginControlsHaveFixedDomainSemantics() {
        Root<?> root=mock(Root.class);CriteriaBuilder builder=mock(CriteriaBuilder.class);
        var date=mock(jakarta.persistence.criteria.Path.class);doReturn(date).when(root).get("deliverDate");
        new HeaderColumnFilter(Map.of("deliverFrom","2026-10-01")).apply(root,builder,new ArrayList<>(),null,false,"deliverDate",false,null,false);
        verify(root).get("deliverDate");verify(root,never()).get("validUntil");
        assertThrows(ApiException.class,()->new HeaderColumnFilter(Map.of("recordOrigin","invented"))
                .apply(root,builder,new ArrayList<>(),null,false,null,false,null,true));
    }
    @Test void oldEmptyQueryDoesNotAddPredicatesAndUnsupportedControlsFailClosed() {
        var root=mock(Root.class);var builder=mock(CriteriaBuilder.class);var predicates=new ArrayList<Predicate>();
        HeaderColumnFilter.EMPTY.apply(root,builder,predicates,null,false,null,false,null,false);
        assertTrue(predicates.isEmpty());verifyNoInteractions(root,builder);
        assertThrows(ApiException.class,()->new HeaderColumnFilter(Map.of("apPosted","true"))
                .apply(root,builder,predicates,null,false,null,false,null,false));
    }
}
