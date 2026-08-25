package com.uten.imp.features.admin;

import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class DataScopeOwnerCandidateSqlContractTest {

    @Test
    void everyCandidateCountUsesLiveRowsAndClientCountExcludesFinanceStubs() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        DataScopeAdminService service = new DataScopeAdminService(
                em,
                mock(TxSessionVars.class),
                mock(AdminUserSupport.class),
                mock(SecurityContextCurrentUser.class),
                mock(DataScopeCasGuard.class));

        for (String scope : List.of(
                "goods", "client", "sales", "finance", "purchase",
                "subcontract", "production_plan", "stock_doc")) {
            service.ownerCandidates(scope);
        }

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        org.mockito.Mockito.verify(em, org.mockito.Mockito.times(8))
                .createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).allSatisfy(statement ->
                assertThat(statement).contains("is_deleted=FALSE"));

        String clients = sql.getAllValues().get(1);
        assertThat(clients)
                .contains("owner_employee_id IS NOT NULL")
                .contains("lower(code) NOT LIKE 'legacy-fin-cl-%'");

        String production = sql.getAllValues().get(6);
        assertThat(production)
                .contains("production_plans")
                .contains("production_daily_reports")
                .contains("production_material_analyses");
    }
}
