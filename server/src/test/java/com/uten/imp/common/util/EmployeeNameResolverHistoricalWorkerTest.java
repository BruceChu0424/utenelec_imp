package com.uten.imp.common.util;

import com.uten.imp.common.util.EmployeeNameResolver.HistoricalWorkerRole;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.mockito.ArgumentCaptor;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class EmployeeNameResolverHistoricalWorkerTest {
    @ParameterizedTest
    @EnumSource(HistoricalWorkerRole.class)
    void everyHistoricalRoleUsesOneBoundReadAndGuardsTheSealedResolverWithoutReadingPrivateAliases(HistoricalWorkerRole role) throws Exception {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.setMaxResults(2)).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of("Historical worker(UT0192)"));
        UUID document = UUID.randomUUID();
        assertThat(new EmployeeNameResolver(em).historicalWorkerNameWithCodeOf(null, document, 42, role))
                .isEqualTo("Historical worker(UT0192)");
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue()).contains("count(*) AS exact_count FROM employees candidate",
                "CASE WHEN legacy_identity.exact_count <= 1", "fn_employee_identity_from_legacy_worker",
                "ELSE NULL::uuid END", "document.id = :documentId", "document.legacy_id = :documentLegacyId")
                .doesNotContain("employee_legacy_identity_aliases", "LIMIT 1", "limit 1");
        var capture = java.nio.file.Path.of(System.getProperty("uten.build.directory", "target"),
                "historical-worker-sql", role.name() + ".sql");
        java.nio.file.Files.createDirectories(capture.getParent());
        java.nio.file.Files.writeString(capture, sql.getValue(), java.nio.charset.StandardCharsets.UTF_8);
        verify(query).setParameter("documentId", document);
        verify(query).setParameter("documentLegacyId", 42);
        verify(query).getResultList();
        verifyNoMoreInteractions(em);
    }

    @Test void missingHistoricalScopeStillPerformsNoQuery() {
        EntityManager em = mock(EntityManager.class);
        EmployeeNameResolver names = new EmployeeNameResolver(em);
        UUID document = UUID.randomUUID();
        assertThat(names.historicalWorkerNameWithCodeOf(null, null, 42, HistoricalWorkerRole.SALES_ORDER_SELLER)).isNull();
        assertThat(names.historicalWorkerNameWithCodeOf(null, document, 0, HistoricalWorkerRole.SALES_ORDER_SELLER)).isNull();
        assertThat(names.historicalWorkerNameWithCodeOf(null, document, 42, null)).isNull();
        verifyNoInteractions(em);
    }
}
