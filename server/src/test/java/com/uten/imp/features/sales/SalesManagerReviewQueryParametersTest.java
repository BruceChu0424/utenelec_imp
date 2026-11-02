package com.uten.imp.features.sales;

import com.uten.imp.application.port.SalesManagerReviewerEligibilityPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class SalesManagerReviewQueryParametersTest {
    @Mock private EntityManager em;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private SalesManagerReviewerEligibilityPort reviewers;
    @InjectMocks private SalesManagerReviewService service;

    @ParameterizedTest
    @CsvSource({"quote,pending,PENDING", "order,approved,APPROVED", "all,rejected,REJECTED"})
    void countAndRowsBindTheSameStateAndSearchValues(String kind,String state,String normalized) {
        authorize(kind);
        Query count=mock(Query.class,RETURNS_SELF), rows=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(count,rows);
        when(count.getSingleResult()).thenReturn(0L);
        when(rows.getResultList()).thenReturn(List.of());

        service.list(kind,state,"x' OR 1=1 --",1,20,Map.of("client","O'Brien"));

        verify(count).setParameter("managerState",normalized);
        verify(rows).setParameter("managerState",normalized);
        verify(count).setParameter(eq("keyword"),eq("x' or 1=1 --"));
        verify(rows).setParameter(eq("keyword"),eq("x' or 1=1 --"));
        var sql=ArgumentCaptor.forClass(String.class);
        verify(em,org.mockito.Mockito.times(2)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).allSatisfy(value -> {
            assertThat(value).contains("o.manager_review_state=:managerState")
                    .doesNotContain("x' OR 1=1 --", "O'Brien", "manager_review_state='"+normalized+"'");
            if("all".equals(kind)) assertThat(value).contains("'quote' AS kind","'order' AS kind","UNION ALL");
            else assertThat(value).contains("'"+kind+"' AS kind");
        });
    }

    @Test
    void historyUsesBothCompletedStatesWithoutBindingAnAbsentParameter() {
        authorize("all");
        Query count=mock(Query.class,RETURNS_SELF), rows=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(count,rows);
        when(count.getSingleResult()).thenReturn(0L);
        when(rows.getResultList()).thenReturn(List.of());

        service.list("all","history",null,1,20);

        verify(count,never()).setParameter(eq("managerState"),anyString());
        verify(rows,never()).setParameter(eq("managerState"),anyString());
        var sql=ArgumentCaptor.forClass(String.class);
        verify(em,org.mockito.Mockito.times(2)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).allSatisfy(value -> assertThat(value)
                .contains("o.manager_review_state IN ('APPROVED','REJECTED')")
                .doesNotContain(":managerState"));
    }

    @Test
    void invalidStateCannotReachEitherQuery() {
        authorize("order");
        assertThatThrownBy(() -> service.list("order","PENDING' OR 1=1 --",null,1,20))
                .isInstanceOf(ApiException.class);
        verify(em,never()).createNativeQuery(anyString());
    }

    private void authorize(String kind) {
        UUID user=UUID.randomUUID();
        when(currentUser.requireId()).thenReturn(user);
        for(String value:"all".equals(kind)?List.of("quote","order"):List.of(kind))
            when(reviewers.eligible(user,value,"view")).thenReturn(true);
    }
}
