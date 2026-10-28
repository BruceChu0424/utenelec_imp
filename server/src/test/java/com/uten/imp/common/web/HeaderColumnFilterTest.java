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
    @Test void callerMapsAndReturnedViewsCannotChangeTheAcceptedQuery() {
        var input = new java.util.LinkedHashMap<>(Map.of("amountMin", "1.20"));
        var filter = new HeaderColumnFilter(input);
        input.put("amountMin", "999.00");
        assertEquals("1.20", filter.values().get("amountMin"));
        assertThrows(UnsupportedOperationException.class,
                () -> filter.values().put("amountMin", "0"));
        assertThrows(UnsupportedOperationException.class,
                () -> filter.values().entrySet().iterator().next().setValue("0"));
        assertEquals(Map.of("amountMin", "1.20"), filter.values());
    }
    @Test void explicitValueObjectKeepsEqualityAndItsOriginalJsonShape() throws Exception {
        var filter = new HeaderColumnFilter(Map.of("amountMin", " 1.20 "));
        var equivalent = HeaderColumnFilter.from(Map.of("hf.amountMin", "1.20"));
        assertNotSame(filter, equivalent);
        assertEquals(filter, equivalent);
        assertEquals(filter.hashCode(), equivalent.hashCode());
        assertEquals(1, new java.util.HashSet<>(java.util.List.of(filter, equivalent)).size());
        assertEquals(HeaderColumnFilter.EMPTY, new HeaderColumnFilter(null));
        assertNotEquals(filter, HeaderColumnFilter.EMPTY);
        assertEquals("HeaderColumnFilter[values={amountMin=1.20}]", filter.toString());
        var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
        var json = mapper.writeValueAsString(filter);
        assertEquals(mapper.readTree("{\"values\":{\"amountMin\":\"1.20\"}}"), mapper.readTree(json));
        var restored = mapper.readValue(json, HeaderColumnFilter.class);
        assertEquals(filter, restored);
        assertThrows(UnsupportedOperationException.class, () -> restored.values().clear());
    }
    @Test void maskedAmountAndNullProbesFailBeforeParsingOrTouchingAnyJpaProperty() {
        for (var values : java.util.List.of(Map.of("amountMin", "NaN"), Map.of("amountNull", "true"),
                Map.of("search.total","NaN"), Map.of("search.amount",">1"))) {
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
        for (String column : java.util.List.of("totalLocal", "bill_date", "deliverDate", "status", "makerId", "billNo);DELETE"))
            assertThrows(ApiException.class, () -> HeaderColumnFilter.from(Map.of("search." + column, "x")));
    }
    @Test void typedColumnsRemainExplicitAndProtectedSortsFailBeforeAnyPropertyAccess() {
        var filter=HeaderColumnFilter.from(Map.of("search.billDate","2026-10","search.total",">0","search.weight","1..2"));
        assertTrue(filter.hasAmount());assertTrue(filter.hasAmountRange());
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,
                ()->HeaderColumnFilter.requireAmountSortVisible("total",false)).getCode());
        assertDoesNotThrow(()->HeaderColumnFilter.requireAmountSortVisible("billDate",false));
        var root=mock(Root.class);var builder=mock(CriteriaBuilder.class);
        assertThrows(ApiException.class,()->filter.applySearch(root,null,builder,new ArrayList<>(),Map.of()));
        verifyNoInteractions(root,builder);
    }
    @Test void columnSearchHasItsOwnWhitelistedNamespaceAndCannotBecomeAnExactIdFilter() {
        var filters = HeaderColumnFilter.from(Map.of("search.billNo", " CD2026 ", "search.supplier", "华东",
                "supplierId", "exact-uuid", "hf.amountMin", "5"));
        assertEquals(Map.of("search.billNo", "CD2026", "search.supplier", "华东", "amountMin", "5"), filters.values());
        assertTrue(filters.hasAmount());
        assertThrows(ApiException.class, () -> filters.requireAmountVisible(false));
        var root = mock(Root.class); var builder = mock(CriteriaBuilder.class);
        assertThrows(ApiException.class, () -> filters.applySearch(root, null, builder, new ArrayList<>(),
                Map.of("billNo", HeaderColumnFilter.SearchField.text("billNo"))));
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
