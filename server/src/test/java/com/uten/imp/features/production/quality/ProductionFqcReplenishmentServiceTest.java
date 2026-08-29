package com.uten.imp.features.production.quality;

import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionFqcReplenishmentServiceTest {

    @Test
    void pendingQuerySeparatesAllOwnerPredicatesFromWhere() {
        assertPendingSql(
                new NativeReadScope("1=1", null, Set.of()),
                "WHERE 1=1",
                "WHERE1=1");
        assertPendingSql(
                new NativeReadScope(
                        "report.maker_id IS NULL", null, Set.of()),
                "WHERE report.maker_id IS NULL",
                "WHEREreport.maker_id");
    }

    private static void assertPendingSql(
            NativeReadScope scope,
            String expected,
            String malformed) {
        EntityManager em = mock(EntityManager.class);
        Query countQuery = mock(Query.class);
        Query pageQuery = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(countQuery, pageQuery);
        when(countQuery.getSingleResult()).thenReturn(0L);
        when(pageQuery.setParameter(anyString(), any()))
                .thenReturn(pageQuery);
        when(pageQuery.getResultList()).thenReturn(List.of());
        ProductionDocumentAccessPolicy productionAccess =
                mock(ProductionDocumentAccessPolicy.class);
        when(productionAccess.nativeReadScope(
                anyString(), anyString(), any(String[].class)))
                .thenReturn(scope);
        ProductionFqcReplenishmentService service =
                new ProductionFqcReplenishmentService(
                        em,
                        mock(MaterialAnalysisService.class),
                        productionAccess,
                        mock(SecurityContextCurrentUser.class),
                        mock(TxSessionVars.class));

        assertThat(service.pending(1, 20).getTotal()).isZero();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(2)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).allSatisfy(statement -> {
            String compact = statement.replaceAll("\\s+", " ").trim();
            assertThat(compact)
                    .contains(expected)
                    .doesNotContain(malformed);
        });
    }
}
