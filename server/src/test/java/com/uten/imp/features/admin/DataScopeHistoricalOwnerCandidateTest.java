package com.uten.imp.features.admin;

import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class DataScopeHistoricalOwnerCandidateTest {

    @Test
    void resignedOwnerWithRawRowsIsReturnedAsHistoricalOnly() {
        UUID owner = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(
                List.<Object[]>of(new Object[]{owner, "离职业务员", "resigned", 7L}));
        DataScopeAdminService service = new DataScopeAdminService(
                em, mock(TxSessionVars.class), mock(AdminUserSupport.class),
                mock(SecurityContextCurrentUser.class), mock(DataScopeCasGuard.class));

        List<Map<String, Object>> rows = service.ownerCandidates("sales");

        assertThat(rows).containsExactly(Map.of(
                "employeeId", owner,
                "name", "离职业务员",
                "status", "resigned",
                "historicalOnly", true,
                "count", 7L));
    }
}
