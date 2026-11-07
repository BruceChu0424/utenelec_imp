package com.uten.imp.features.workbench.badge;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;

import java.util.ArrayList;
import java.util.List;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Mock-based badge fixtures: the per-source statement time limit reads and restores one setting. */
final class BadgeStatementBudgetStubs {
    private BadgeStatementBudgetStubs() {}

    /** Every limit/restore round trip, in order, as the SQL text the service issued. */
    static List<String> accept(EntityManager entityManager) {
        List<String> issued = new ArrayList<>();
        when(entityManager.createNativeQuery(anyString())).thenAnswer(call -> {
            String sql = call.getArgument(0);
            issued.add(sql);
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenReturn(query);
            when(query.getSingleResult()).thenReturn(sql.contains("WITH previous")
                    ? new Object[]{"1min", "5000"} : "1min");
            return query;
        });
        return issued;
    }
}
