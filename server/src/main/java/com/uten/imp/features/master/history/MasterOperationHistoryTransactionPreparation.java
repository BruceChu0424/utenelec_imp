package com.uten.imp.features.master.history;

import com.uten.imp.application.port.TransactionWritePreparationPort;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Set;

/** Take the personal command lock before any domain or numbering row lock. */
@Component
@RequiredArgsConstructor
public class MasterOperationHistoryTransactionPreparation implements TransactionWritePreparationPort {
    private static final String PREFIX = "/api/master/";
    private static final Set<String> WRITES = Set.of("POST", "PUT", "PATCH", "DELETE");
    private static final Set<String> ENTITIES = Set.of(
            "clients", "suppliers", "moulds", "colors", "units", "currencies", "warehouses", "accounts",
            "client-categories", "supplier-categories", "mould-categories", "payment-styles",
            "reference-methods", "operation-history");
    private static final Set<String> INLINE_ENTITIES = Set.of(
            "colors", "units", "currencies", "moulds", "accounts", "reference-methods", "clients", "suppliers", "warehouses");
    private final EntityManager em;

    @Override
    public void prepare(String path, String method) {
        if (method == null || !WRITES.contains(method) || path == null || !path.startsWith(PREFIX)) return;
        String resource = path.substring(PREFIX.length());
        boolean managed = resource.startsWith("inline-edit/")
                ? INLINE_ENTITIES.contains(firstSegment(resource.substring("inline-edit/".length())))
                : ENTITIES.contains(firstSegment(resource));
        if (!managed) return;
        // Goods/BOM has its own history coordination. Only this feature's
        // domains depend on its schema; the database still owns the precise
        // route allowlist. A missing required function must fail the write.
        em.createNativeQuery("SELECT fn_begin_master_history_request()").getSingleResult();
    }

    private static String firstSegment(String path) {
        int separator = path.indexOf('/');
        return separator < 0 ? path : path.substring(0, separator);
    }
}
