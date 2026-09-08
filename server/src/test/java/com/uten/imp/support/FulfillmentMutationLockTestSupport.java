package com.uten.imp.support;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.util.List;
import java.util.UUID;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Isolates unrelated service unit tests; real lock behavior has PostgreSQL tests. */
public final class FulfillmentMutationLockTestSupport {
    private FulfillmentMutationLockTestSupport() {}

    public static FulfillmentMutationLocks locks() {
        var locks = mock(FulfillmentMutationLocks.class);
        when(locks.acquire(any())).thenReturn(mock(FulfillmentMutationLocks.Guard.class));
        return locks;
    }

    /** Unrelated unit/query fixtures do not replace the real PostgreSQL lock integration suites. */
    public static com.uten.imp.common.concurrency.ProcurementMutationLocks procurementLocks() {
        return mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class,
                org.mockito.Answers.RETURNS_DEEP_STUBS);
    }

    /** Unit fixtures with no real execution graph still exercise the original business guards. */
    public static void emptyExecutionGraph(EntityManager em) {
        Query empty = mock(Query.class);
        when(empty.setParameter(anyString(), any())).thenReturn(empty);
        when(empty.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString(), eq(UUID.class))).thenReturn(empty);
        when(em.createNativeQuery(argThat((String sql) -> sql != null
                && (sql.contains("WHERE document.id IN (:documentIds)")
                    || sql.contains("WHERE item.doc_id IN (:documentIds)"))
                && sql.contains("FOR UPDATE")))).thenReturn(empty);
    }
}
