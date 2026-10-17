package com.uten.imp.features.master;

import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.search.MasterColumnSearch;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Expression;
import org.hibernate.query.criteria.HibernateCriteriaBuilder;
import org.hibernate.query.criteria.JpaExpression;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MasterColumnSearchTest {
    @Test
    void distinctColumnsAndEveryWordAreBoundAndWildcardCharactersAreLiteral() {
        HibernateCriteriaBuilder cb = mock(HibernateCriteriaBuilder.class);
        Expression<?> id = mock(Expression.class);
        when(cb.value(anyString())).thenAnswer(ignored -> mock(JpaExpression.class));
        var searches = new LinkedHashMap<String, String>();
        searches.put("name", "开关 10%_");
        searches.put("spec", "250V");
        MasterColumnSearch.predicate(cb, id, MasterColumnSearch.Domain.GOODS, searches);
        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        var arguments = org.mockito.ArgumentCaptor.forClass(Expression[].class);
        verify(cb).sql(sql.capture(), eq(Boolean.class), arguments.capture());
        assertTrue(sql.getValue().startsWith("(? IN (SELECT master.id FROM goods master"));
        assertEquals(2, sql.getValue().split("master.name ILIKE \\?", -1).length - 1);
        assertTrue(sql.getValue().contains("master.spec ILIKE ?"));
        assertFalse(sql.getValue().contains("250V"));
        assertEquals(4, arguments.getValue().length);
        assertSame(id, arguments.getValue()[0]);
        verify(cb).value("%10\\%\\_%");
        verify(cb).value("%250v%");
    }

    @Test
    void unsupportedAndNumericColumnsFailBeforeAnySql() {
        CriteriaBuilder cb = mock(CriteriaBuilder.class);
        Expression<?> id = mock(Expression.class);
        for (String field : List.of("id", "category.name", "price", "stockQty", "discount", "status")) {
            assertThrows(ApiException.class, () -> MasterColumnSearch.predicate(cb, id,
                    MasterColumnSearch.Domain.GOODS, Map.of(field, "x")));
        }
        verifyNoInteractions(cb);
    }

    @Test
    void mouldSeriesSearchUsesRealCategoryNameWithoutSynthesizingASeriesColumn() {
        HibernateCriteriaBuilder cb = mock(HibernateCriteriaBuilder.class);
        Expression<?> id = mock(Expression.class);
        when(cb.value(anyString())).thenAnswer(ignored -> mock(JpaExpression.class));
        MasterColumnSearch.predicate(cb, id, MasterColumnSearch.Domain.MOULD,
                Map.of("categoryName", "Q7 系列", "name", "开关"));
        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        verify(cb).sql(sql.capture(), eq(Boolean.class), any(Expression[].class));
        assertTrue(sql.getValue().contains("SELECT name FROM mould_categories WHERE id = master.category_id AND NOT is_deleted"));
        assertTrue(sql.getValue().contains("master.name ILIKE ?"));
        assertFalse(sql.getValue().contains("master.series"));
        verify(cb).value("%q7%");
        verify(cb).value("%系列%");
        verify(cb).value("%开关%");
    }

    @Test
    void sensitiveColumnSearchAcceptsBodyAndRejectsUrl() {
        var request = new MockHttpServletRequest();
        request.addParameter("search.name", "电器");
        assertEquals(Map.of("name", "电器", "mobile", "13800"),
                ColumnKeywordSearch.contactRequestValues(request, Map.of("mobile", "13800")));
        request.addParameter("search.mobile", "13800");
        assertThrows(ApiException.class, () -> ColumnKeywordSearch.contactRequestValues(request, null));
    }
}
