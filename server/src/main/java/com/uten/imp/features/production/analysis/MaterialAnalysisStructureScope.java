package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.ProductionMutationFootprintPort.AnalysisStructureScope;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import org.springframework.orm.jpa.EntityManagerHolder;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.Collection;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

/**
 * A checked, transaction-owned interval for the static part of a plan batch.
 * This is deliberately separate from the live commercial/execution footprint.
 */
final class MaterialAnalysisStructureScope implements AnalysisStructureScope, TransactionSynchronization {
    private static final Object RESOURCE = new Object();
    record Row(UUID id, UUID goodsId, UUID colorId, String hash) {
        static Row from(Object[] values) {
            return new Row((UUID) values[0], (UUID) values[1], (UUID) values[2], (String) values[3]);
        }
        Object[] values() { return new Object[] {id, goodsId, colorId, hash}; }
    }
    record Snapshot(List<UUID> roots, List<Row> materials, List<Row> bom,
            String fingerprint, Set<InventoryDimension> inventoryDimensions) {
        Snapshot(List<UUID> roots, List<Row> materials, List<Row> bom) {
            this(List.copyOf(roots), List.copyOf(materials), List.copyOf(bom),
                    fingerprint(roots, materials, bom), dimensions(materials, bom));
        }
        private static String fingerprint(List<UUID> roots, List<Row> materials, List<Row> bom) {
            var parts = new ArrayList<String>(roots.size() + materials.size() + bom.size());
            roots.forEach(root -> parts.add("root:" + root));
            materials.forEach(row -> parts.add("material:" + java.util.Arrays.toString(row.values())));
            bom.forEach(row -> parts.add("bom:" + java.util.Arrays.toString(row.values())));
            return CanonicalFingerprint.sha256(parts);
        }
        private static Set<InventoryDimension> dimensions(List<Row> materials, List<Row> bom) {
            return java.util.stream.Stream.concat(materials.stream(), bom.stream())
                    .filter(row -> row.goodsId() != null)
                    .map(row -> new InventoryDimension(row.goodsId(), row.colorId()))
                    .collect(java.util.stream.Collectors.toUnmodifiableSet());
        }
    }

    private final EntityManager em;
    private final EntityManagerHolder owner;
    private final UUID analysisId;
    private final Supplier<Snapshot> reader;
    private final Snapshot snapshot;
    private boolean closed;

    private MaterialAnalysisStructureScope(EntityManager em, EntityManagerHolder owner, UUID analysisId,
            Supplier<Snapshot> reader, Snapshot snapshot) {
        this.em = em; this.owner = owner; this.analysisId = analysisId;
        this.reader = reader; this.snapshot = snapshot;
    }

    static AnalysisStructureScope open(EntityManager em, UUID analysisId, Supplier<Snapshot> reader,
            Runnable requireAlreadyCovered) {
        EntityManagerHolder owner = owner(em);
        if (owner == null || TransactionSynchronizationManager.hasResource(RESOURCE)) {
            throw new IllegalStateException("Analysis structure scope requires one active, non-nested JPA transaction");
        }
        var scope = new MaterialAnalysisStructureScope(em, owner, Objects.requireNonNull(analysisId), reader, reader.get());
        TransactionSynchronizationManager.bindResource(RESOURCE, scope);
        TransactionSynchronizationManager.registerSynchronization(scope);
        try {
            // Binding does not grant any lock. Validate the complete current
            // dynamic footprint against locks the outer command already owns.
            requireAlreadyCovered.run();
            return scope;
        } catch (RuntimeException | Error failure) {
            scope.abort(failure);
            throw failure;
        }
    }

    static Snapshot current(EntityManager em, Collection<UUID> analyses) {
        var value = TransactionSynchronizationManager.getResource(RESOURCE);
        if (!(value instanceof MaterialAnalysisStructureScope scope) || scope.closed
                || scope.owner != owner(em) || analyses.size() != 1 || !analyses.contains(scope.analysisId)) return null;
        return scope.snapshot;
    }

    private static EntityManagerHolder owner(EntityManager em) {
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.isSynchronizationActive()) return null;
        Object resource = TransactionSynchronizationManager.getResource(em.getEntityManagerFactory());
        return resource instanceof EntityManagerHolder holder ? holder : null;
    }

    @Override public void close() {
        if (closed) return;
        try {
            if (owner != owner(em) || TransactionSynchronizationManager.getResource(RESOURCE) != this
                    || !snapshot.equals(reader.get())) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "物料或 BOM 在批量下达期间发生变化，请刷新后重新提交；本次下达已回滚");
            }
        } catch (RuntimeException | Error failure) {
            abort(failure);
            throw failure;
        } finally {
            closed = true;
            unbind();
        }
    }

    private void abort(Throwable original) {
        // Use the actual transaction-owned EM, not the shared proxy. Even a
        // caller that catches a conflict cannot commit half of the plan batch.
        try { owner.getEntityManager().getTransaction().setRollbackOnly(); }
        catch (RuntimeException | Error cleanupFailure) { original.addSuppressed(cleanupFailure); }
        finally { closed = true; unbind(); }
    }

    private void unbind() {
        if (TransactionSynchronizationManager.getResource(RESOURCE) == this) {
            TransactionSynchronizationManager.unbindResource(RESOURCE);
        }
    }

    @Override public void beforeCommit(boolean readOnly) {
        if (!closed) {
            var failure = new IllegalStateException("Analysis structure scope must close before transaction commit");
            abort(failure);
            throw failure;
        }
    }
    @Override public void suspend() { unbind(); }
    @Override public void resume() {
        if (!closed) TransactionSynchronizationManager.bindResource(RESOURCE, this);
    }
    @Override public void afterCompletion(int status) { closed = true; unbind(); }
}
