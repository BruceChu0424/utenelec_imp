package com.uten.imp.security;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/**
 * Object scope for production-generated warehouse tasks.
 *
 * <p>ADR-149: the warehouse data scope is resolved in exactly one place
 * ({@link WarehouseTaskScopePort#access()}, database function {@code fn_user_warehouse_access}).
 * A participant is a warehouse supervisor (super admin, warehouse department manager, keeper of the
 * main warehouse), a registered sub-warehouse keeper, or a member of the {@code SUB_WH} department
 * subtree (primary or secondary department). Which warehouses each participant sees in task lists is
 * decided by the same port; action permissions remain a separate gate.</p>
 */
@Component
@RequiredArgsConstructor
public class ProductionStockTaskAccessPolicy {

    private final SecurityContextCurrentUser currentUser;
    private final WarehouseTaskScopePort warehouseScopes;

    public boolean canAccessWarehouseTasks() {
        AuthUser actor = currentUser.get().orElse(null);
        if (actor == null || actor.isVisitor()) return false;
        if (actor.isSuperAdmin()) return true;
        if (actor.getEmployeeId() == null) return false;
        return warehouseScopes.access().warehouseParticipant();
    }

    public void requireWarehouseTaskAccess(String message) {
        if (!canAccessWarehouseTasks()) {
            throw new ApiException(ErrorCode.FORBIDDEN, message);
        }
    }
}
