package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.ProductionMaterialReadAccessPolicy;
import com.uten.imp.security.ProductionWorkshopAssignmentScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/** Material reads may be plan-wide; ordinary workshop writes are always checked per exact demand/segment. */
@Component
@RequiredArgsConstructor
public class ProductionMaterialTaskAccessPolicy {
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final OwnerVisibility owners;
    private final ProductionMaterialReadAccessPolicy legacyReads;

    public record ReadScope(boolean all, List<UUID> segmentIds) {}
    public record Capabilities(boolean canSettle, boolean canReverse, boolean canClose) {}

    public Capabilities capabilities(UUID planId, UUID segmentId) {
        readable(planId,segmentId);
        boolean manager=canManagePlan(planId);
        boolean writable=manager;
        if (!writable && segmentId!=null && has("production_execution:view")) {
            writable=Boolean.TRUE.equals(em.createNativeQuery("""
                    SELECT EXISTS(SELECT 1 FROM production_execution_segments segment
                    WHERE segment.plan_id=:planId AND segment.id=:segmentId AND segment.is_deleted=FALSE AND
                    """ + ProductionWorkshopAssignmentScope.predicate("segment") + ")")
                    .setParameter("planId",planId).setParameter("segmentId",segmentId)
                    .setParameter("employeeId",currentUser.requireEmployeeId()).getSingleResult());
        }
        return new Capabilities(writable && has("production_material:settle"),
                writable && has("production_material:reverse"),segmentId==null && manager && has("production_material:close"));
    }

    public ReadScope readable(UUID planId, UUID segmentId) {
        boolean all = canReadWholePlan(planId);
        if (all && segmentId == null) return new ReadScope(true,List.of());
        if (!all && !has("production_execution:view")) throw notFound();
        String filter = segmentId == null ? "" : " AND segment.id=:segmentId";
        String assignment = all ? "" : " AND " + ProductionWorkshopAssignmentScope.predicate("segment");
        var query = em.createNativeQuery("""
                SELECT segment.id FROM production_execution_segments segment
                JOIN production_plans plan ON plan.id=segment.plan_id AND plan.is_deleted=FALSE
                WHERE segment.plan_id=:planId AND segment.is_deleted=FALSE
                """ + filter + assignment + " ORDER BY segment.id",UUID.class).setParameter("planId",planId);
        if (segmentId != null) query.setParameter("segmentId",segmentId);
        if (!all) query.setParameter("employeeId",currentUser.requireEmployeeId());
        List<UUID> segments = NativeQueryResults.typedRows(query,UUID.class);
        if (segments.isEmpty()) throw notFound();
        return new ReadScope(false,segments);
    }

    /** Run with the plan locked, before replay or any mutation. Locks assignments before demand rows. */
    public void requireDemandWrite(UUID planId, List<UUID> demandIds, UUID segmentId, String authority) {
        requireAuthority(authority);
        boolean wholePlan = canManagePlan(planId);
        if (!wholePlan && !has("production_execution:view")) throw forbidden();
        em.createNativeQuery("""
                SELECT segment.id FROM production_execution_segments segment
                WHERE segment.plan_id=:planId AND segment.is_deleted=FALSE
                  AND segment.id IN (SELECT demand.execution_segment_id FROM production_material_demands demand
                                     WHERE demand.plan_id=:planId AND demand.id IN (:ids) AND demand.is_deleted=FALSE)
                ORDER BY segment.id FOR UPDATE
                """).setParameter("planId",planId).setParameter("ids",demandIds).getResultList();
        String requestedSegment = segmentId == null ? "" : " AND demand.execution_segment_id=:segmentId";
        String assigned = wholePlan ? "" : " AND segment.id IS NOT NULL AND "
                + ProductionWorkshopAssignmentScope.predicate("segment");
        var query = em.createNativeQuery("""
                SELECT demand.id FROM production_material_demands demand
                LEFT JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id AND segment.is_deleted=FALSE
                WHERE demand.plan_id=:planId AND demand.id IN (:ids) AND demand.is_deleted=FALSE
                """ + requestedSegment + assigned,UUID.class).setParameter("planId",planId).setParameter("ids",demandIds);
        if (segmentId != null) query.setParameter("segmentId",segmentId);
        if (!wholePlan) query.setParameter("employeeId",currentUser.requireEmployeeId());
        if (query.getResultList().size()!=demandIds.size()) throw forbidden();
    }

    /** Closing changes the whole plan: task membership alone is never sufficient. */
    public void requireClose(UUID planId) {
        requireAuthority("production_material:close");
        if (!canManagePlan(planId)) throw forbidden();
    }

    private boolean canManagePlan(UUID planId) {
        var rows = em.createNativeQuery("SELECT maker_id FROM production_plans WHERE id=:id AND is_deleted=FALSE")
                .setParameter("id",planId).getResultList();
        if (rows.isEmpty()) throw notFound();
        UUID owner = (UUID) rows.getFirst();
        // ADR-050: explicit full scope is writable only when intersected with the dedicated action
        // checked by each caller. Manual read sharing is absent from writableOwners.
        var scope = owners.evaluate("production_plan","production_plan:view:all");
        return owner!=null && (scope.seeAll() || scope.writableOwners().contains(owner));
    }

    private boolean canReadWholePlan(UUID planId) {
        try { legacyReads.requirePlanReadable(planId); return true; }
        catch (ApiException failure) {
            if (failure.getCode()!=ErrorCode.NOT_FOUND) throw failure;
            return false;
        }
    }
    private boolean has(String code) { return currentUser.get().map(user -> user.isSuperAdmin()
            || user.getAuthorities().stream().anyMatch(grant -> code.equals(grant.getAuthority()))).orElse(false); }
    private void requireAuthority(String code) { if (!has(code)) throw forbidden(); }
    private static ApiException notFound() { return new ApiException(ErrorCode.NOT_FOUND,"生产材料任务不存在"); }
    private static ApiException forbidden() { return new ApiException(ErrorCode.FORBIDDEN,"只能办理本人负责计划或所属车间执行任务的材料"); }
}
