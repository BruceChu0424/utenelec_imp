package com.uten.imp.common.platformcolumns;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * Explicit domain registration. Never derive a table name or permission code from caller text.
 * Implementations must use the domain's existing functional permission and row-data-scope policies.
 */
public interface PlatformColumnResourceAdapter {
    String scope();
    String label();

    /** A definition belongs to the resource; creating one requires its edit authority. */
    void requireDefinitionAccess(boolean write);

    /** Functional capability only; each row is independently authorized below. */
    boolean canWrite();
    boolean canViewPrice();
    default boolean canCreate() { return false; }

    /** Aggregated reports have no stable row identity and therefore store definitions only. */
    default boolean supportsValues() { return true; }

    /** Only master-data adapters opt in; commercial annotations are cleared by a business reset. */
    default boolean preserveValuesOnReset() { return false; }

    /** Aggregate/report formulas are private display settings, never a shared business dictionary. */
    default boolean personalDefinitions() { return false; }

    /** Fixed numeric business facts usable only in display calculations. No caller-provided SQL. */
    default List<FactDefinition> facts() { return List.of(); }

    /**
     * Fail closed if any requested id is absent, deleted, or outside the current user's read scope.
     * For write=true, lock the real resource/header BEFORE reading lifecycle/data-scope state,
     * reject forbidden/frozen rows, and hold that lock until the enclosing transaction commits.
     * Read access must include canWrite=false for approved/history/ledger rows that are immutable.
     */
    Map<UUID, RecordAccess> authorize(Set<UUID> recordIds, boolean write);

    /** Acquire the domain's complete request-aware lock prefix before the snapshot takes its header lock. */
    default void lockDocumentSave(UUID documentId,Object request) { }

    /**
     * Save-bridge snapshot: lock the parent and return all live detail ids only after checking
     * the parent's and every returned row's read scope. Fail closed if any live row is hidden;
     * silently omitting it could discard its saved fields. This does not grant field writes.
     */
    default Set<UUID> recordIdsForDocument(UUID documentId) {
        throw new UnsupportedOperationException("This platform resource has no document save bridge");
    }

    /** Pre-save write guard, including empty documents and new or removed detail rows. */
    default void requireDocumentFieldWrite(UUID documentId) {
        throw new UnsupportedOperationException("Document field write authorization is not registered");
    }

    /** Atomic create bridge only; this does not authorize editing existing resources. */
    default void requireDocumentSaveAccess(boolean create) { requireDefinitionAccess(true); }
    default Map<UUID,RecordAccess> authorizeCreated(Set<UUID> recordIds) { return authorize(recordIds,true); }
    /** Fixed-domain parent lookup for an already authorized save result, never a caller-supplied parent. */
    default Map<UUID,UUID> parentDocuments(Set<UUID> recordIds) {
        throw new UnsupportedOperationException("Document parent binding is not registered");
    }

    record FactDefinition(String key, String name, boolean priceProtected) { }
    record RecordAccess(boolean canWrite, boolean priceVisible, Map<String, BigDecimal> facts) {
        public RecordAccess { facts = Map.copyOf(facts == null ? Map.of() : facts); }
        public RecordAccess(boolean canWrite, boolean priceVisible) { this(canWrite, priceVisible, Map.of()); }
    }
}
