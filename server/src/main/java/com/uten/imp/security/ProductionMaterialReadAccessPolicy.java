package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.UUID;

/**
 * Object-level read guard for production material subresources.
 *
 * <p>A production plan or its linked DRAW rows may be read through these
 * cross-module endpoints only when the current subject can normally read the
 * owning document, or when a warehouse employee is serving the explicit
 * production-stock task pool. A known but unreachable UUID is reported as
 * {@code NOT_FOUND} so these subresources cannot be used as an existence
 * oracle around the normal document policies.
 */
@Component
@RequiredArgsConstructor
public class ProductionMaterialReadAccessPolicy {

    private static final String PLAN_SCOPE = "production_plan";
    private static final String PLAN_VIEW = "production_plan:view";
    private static final String PLAN_VIEW_ALL = "production_plan:view:all";
    private static final String STOCK_SCOPE = "stock_doc";
    private static final String STOCK_VIEW = "stock_doc:view";
    private static final String STOCK_VIEW_ALL = "stock_doc:view:all";

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final OwnerVisibility ownerVisibility;
    private final ProductionStockTaskAccessPolicy productionStockTaskAccess;

    public void requirePlanReadable(UUID planId) {
        UUID ownerId = planOwner(planId);
        if (canUseWarehousePool()
                || hasAuthority(PLAN_VIEW)
                && canReadOwner(ownerId, PLAN_SCOPE, PLAN_VIEW_ALL)) {
            return;
        }
        throw new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在");
    }

    public void requireDrawReadable(UUID drawId) {
        DrawOwner draw = drawOwner(drawId);
        if (draw.productionLinked() && canUseWarehousePool()
                || hasAuthority(STOCK_VIEW)
                && canReadOwner(
                        draw.ownerId(), STOCK_SCOPE, STOCK_VIEW_ALL)) {
            return;
        }
        throw new ApiException(ErrorCode.NOT_FOUND, "生产领料单不存在");
    }

    private UUID planOwner(UUID planId) {
        List<?> rows = em.createNativeQuery("""
                        SELECT id, maker_id
                        FROM production_plans
                        WHERE id = :id
                          AND is_deleted = FALSE
                        """)
                .setParameter("id", planId)
                .getResultList();
        return (UUID) row(rows, "生产计划不存在")[1];
    }

    private DrawOwner drawOwner(UUID drawId) {
        List<?> rows = em.createNativeQuery("""
                        SELECT id, maker_id,
                               fn_is_production_linked_stock_document(id)
                        FROM stock_documents
                        WHERE id = :id
                          AND doc_type = 'DRAW'
                          AND is_deleted = FALSE
                        """)
                .setParameter("id", drawId)
                .getResultList();
        Object[] row = row(rows, "生产领料单不存在");
        if (row.length < 3) {
            throw new ApiException(
                    ErrorCode.NOT_FOUND, "生产领料单不存在");
        }
        return new DrawOwner(
                (UUID) row[1], Boolean.TRUE.equals(row[2]));
    }

    private Object[] row(List<?> rows, String notFoundMessage) {
        if (rows.size() != 1 || !(rows.getFirst() instanceof Object[] row)
                || row.length < 2) {
            throw new ApiException(ErrorCode.NOT_FOUND, notFoundMessage);
        }
        return row;
    }

    private boolean canReadOwner(
            UUID ownerId, String scope, String viewAllAuthority) {
        OwnerVisibility.OwnerScope ownerScope =
                ownerVisibility.evaluate(scope, viewAllAuthority);
        return ownerScope.seeAll()
                || ownerId == null
                || ownerScope.visibleOwners().contains(ownerId);
    }

    private boolean canUseWarehousePool() {
        return hasAuthority(STOCK_VIEW)
                && productionStockTaskAccess.canAccessWarehouseTasks();
    }

    private boolean hasAuthority(String authority) {
        return currentUser.get()
                .map(user -> user.isSuperAdmin()
                        || user.getAuthorities().stream()
                        .anyMatch(granted -> authority.equals(
                                granted.getAuthority())))
                .orElse(false);
    }

    private record DrawOwner(UUID ownerId, boolean productionLinked) {
    }
}
