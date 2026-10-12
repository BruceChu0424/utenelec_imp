package com.uten.imp.common.platformcolumns;

import java.util.UUID;
import java.util.Map;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Domain-only scope, opened after the reviewer's exact document and snapshot are authorized. */
public final class PlatformColumnReviewedSave implements AutoCloseable {
    private record Identity(String scope, UUID documentId, UUID actorId, Map<Object, Object> resources) { }
    private static final ThreadLocal<Identity> CURRENT = new ThreadLocal<>();
    private final Identity previous;
    private PlatformColumnReviewedSave(String scope, UUID documentId, UUID actorId) {
        previous = CURRENT.get();
        CURRENT.set(new Identity(scope, documentId, actorId, Map.copyOf(TransactionSynchronizationManager.getResourceMap())));
    }
    public static PlatformColumnReviewedSave begin(String scope, UUID documentId, UUID actorId) {
        if (scope == null || documentId == null || actorId == null) throw new IllegalArgumentException("Missing reviewed document identity");
        if (!TransactionSynchronizationManager.isActualTransactionActive() || TransactionSynchronizationManager.getResourceMap().isEmpty())
            throw new IllegalStateException("Reviewed fields require the already authorized document transaction");
        return new PlatformColumnReviewedSave(scope, documentId, actorId);
    }
    static boolean matchesScope(String scope, UUID actorId) {
        Identity identity = CURRENT.get();
        return identity != null && identity.scope().equals(scope) && identity.actorId().equals(actorId)
                && TransactionSynchronizationManager.isActualTransactionActive()
                && identity.resources().entrySet().stream().allMatch(entry -> TransactionSynchronizationManager.getResource(entry.getKey()) == entry.getValue());
    }
    static boolean matches(String scope, UUID documentId, UUID actorId) {
        Identity identity = CURRENT.get();
        return matchesScope(scope, actorId) && identity.documentId().equals(documentId);
    }
    /** Domain lock bridges may recognize only this already authorized exact transaction. */
    public static boolean isActiveFor(String scope, UUID documentId, UUID actorId) {
        return matches(scope, documentId, actorId);
    }
    @Override public void close() {
        if (previous == null) CURRENT.remove(); else CURRENT.set(previous);
    }
}
