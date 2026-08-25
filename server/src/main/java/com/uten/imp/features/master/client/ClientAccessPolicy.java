package com.uten.imp.features.master.client;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import jakarta.persistence.criteria.Subquery;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Customer object access is stricter than the legacy generic owner policy:
 * owner-less customers are an assignment queue, and per-customer grants are
 * read-only. Functional permissions are still enforced by the controllers.
 */
@Component
@RequiredArgsConstructor
public class ClientAccessPolicy {

    public static final String SCOPE = "client";
    public static final String VIEW_ALL = "client:view:all";
    public static final String ASSIGN = "client:assign";

    public static final String ACCESS_REASON_UNASSIGNED = "UNASSIGNED";
    public static final String ACCESS_REASON_MANAGEABLE = "MANAGEABLE";
    public static final String ACCESS_REASON_SHARED = "SHARED";
    public static final String ACCESS_REASON_OWNER_SCOPE_READ_ONLY = "OWNER_SCOPE_READ_ONLY";

    private static final String OWNER_PARAMETER = "__clientOwnerEmployees";
    private static final String VIEWER_PARAMETER = "__clientViewerEmployee";

    private final OwnerVisibility ownerVisibility;
    private final SecurityContextCurrentUser currentUser;
    private final EntityManager em;

    /** Resolve once per service operation so list/count/facets use one scope snapshot. */
    public ClientScope evaluate() {
        OwnerVisibility.OwnerScope ownerScope = ownerVisibility.evaluate(SCOPE, VIEW_ALL);
        var user = currentUser.get().orElse(null);
        boolean canAssign = hasAssignAuthority();
        UUID employeeId = user == null ? null : user.getEmployeeId();
        // Shared rows stay in PostgreSQL. List/count/dict use EXISTS and a single
        // object lookup probes one row, avoiding unbounded UUID IN expansion.
        return new ClientScope(ownerScope, Set.of(), employeeId, canAssign);
    }

    public UUID requireCurrentEmployeeId() {
        return currentUser.requireEmployeeId();
    }

    public boolean hasAssignAuthority() {
        var user = currentUser.get().orElse(null);
        return user != null && (user.isSuperAdmin() || user.getAuthorities().stream()
                .anyMatch(authority -> ASSIGN.equals(authority.getAuthority())));
    }

    public Predicate readablePredicate(
            Root<Client> root,
            CriteriaQuery<?> query,
            CriteriaBuilder cb,
            ClientScope scope) {
        if (scope.ownerScope().seeAll()) {
            return cb.conjunction();
        }
        List<Predicate> allowed = new ArrayList<>();
        if (!scope.ownerScope().visibleOwners().isEmpty()) {
            allowed.add(root.get("ownerEmployeeId").in(scope.ownerScope().visibleOwners()));
        }
        if (scope.canAssign()) {
            allowed.add(cb.isNull(root.get("ownerEmployeeId")));
        }
        if (scope.viewerEmployeeId() != null) {
            Subquery<Integer> shared = query.subquery(Integer.class);
            Root<ClientVisibilityGrant> grant = shared.from(ClientVisibilityGrant.class);
            shared.select(cb.literal(1));
            shared.where(
                    cb.equal(grant.get("clientId"), root.get("id")),
                    cb.equal(grant.get("granteeEmployeeId"), scope.viewerEmployeeId()),
                    cb.isTrue(grant.get("active")));
            allowed.add(assignedOwnerOnly(root, cb, cb.exists(shared)));
        }
        // Compatibility for explicit in-memory scopes used by focused tests/callers.
        if (!scope.sharedClientIds().isEmpty()) {
            allowed.add(assignedOwnerOnly(
                    root, cb, root.get("id").in(scope.sharedClientIds())));
        }
        return allowed.isEmpty()
                ? cb.disjunction()
                : cb.or(allowed.toArray(Predicate[]::new));
    }

    public NativeReadScope nativeReadScope(String tableAlias, ClientScope scope) {
        if (scope.ownerScope().seeAll()) {
            return new NativeReadScope("1=1", null, Set.of(), null, null);
        }
        String prefix = tableAlias == null || tableAlias.isBlank()
                ? "clients." : tableAlias + ".";
        List<String> allowed = new ArrayList<>();
        String ownerParameter = null;
        if (!scope.ownerScope().visibleOwners().isEmpty()) {
            ownerParameter = OWNER_PARAMETER;
            allowed.add(prefix + "owner_employee_id IN (:" + ownerParameter + ")");
        }
        if (scope.canAssign()) {
            allowed.add(prefix + "owner_employee_id IS NULL");
        }
        String viewerParameter = null;
        if (scope.viewerEmployeeId() != null) {
            viewerParameter = VIEWER_PARAMETER;
            allowed.add("(" + prefix + "owner_employee_id IS NOT NULL AND EXISTS "
                    + "(SELECT 1 FROM client_visibility_grants grant_row "
                    + "WHERE grant_row.client_id = " + prefix + "id "
                    + "AND grant_row.grantee_employee_id = :" + viewerParameter + " "
                    + "AND grant_row.active = TRUE))");
        }
        return new NativeReadScope(
                allowed.isEmpty() ? "1=0" : "(" + String.join(" OR ", allowed) + ")",
                ownerParameter, scope.ownerScope().visibleOwners(),
                viewerParameter, scope.viewerEmployeeId());
    }

    public boolean canRead(Client client, ClientScope scope) {
        return client != null && canRead(client.getId(), client.getOwnerEmployeeId(), scope);
    }

    public boolean canRead(UUID clientId, UUID ownerEmployeeId, ClientScope scope) {
        if (scope.ownerScope().seeAll()) return true;
        if (ownerEmployeeId == null) return scope.canAssign();
        return scope.ownerScope().visibleOwners().contains(ownerEmployeeId)
                || scope.sharedClientIds().contains(clientId)
                || scope.viewerEmployeeId() != null
                && hasActiveShare(clientId, scope.viewerEmployeeId());
    }

    public boolean canWrite(Client client, ClientScope scope) {
        if (client == null) return false;
        if (scope.ownerScope().seeAll()) return true;
        UUID ownerEmployeeId = client.getOwnerEmployeeId();
        return ownerEmployeeId != null
                && scope.ownerScope().writableOwners().contains(ownerEmployeeId);
    }

    /** Object capability for the dedicated owner/viewer settings action. */
    public boolean canManageAccess(Client client, ClientScope scope) {
        if (client == null || scope == null || !scope.canAssign()) return false;
        UUID ownerEmployeeId = client.getOwnerEmployeeId();
        return scope.ownerScope().seeAll()
                || ownerEmployeeId == null
                || scope.ownerScope().writableOwners().contains(ownerEmployeeId);
    }

    /** Server-authoritative explanation for the detail page's object capability. */
    public String accessReason(Client client, ClientScope scope) {
        UUID ownerEmployeeId = client == null ? null : client.getOwnerEmployeeId();
        if (ownerEmployeeId == null) return ACCESS_REASON_UNASSIGNED;
        if (canWrite(client, scope)) return ACCESS_REASON_MANAGEABLE;
        if (scope != null && scope.ownerScope().visibleOwners().contains(ownerEmployeeId)) {
            return ACCESS_REASON_OWNER_SCOPE_READ_ONLY;
        }
        // A readable owned customer outside the owner scope can only come from an
        // explicit per-customer viewer grant. Those grants are always read-only.
        return ACCESS_REASON_SHARED;
    }

    public void requireReadable(Client client, ClientScope scope) {
        if (!canRead(client, scope)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        }
    }

    public void requireWritable(Client client, ClientScope scope) {
        if (!canWrite(client, scope)) {
            // Keep object existence private even when the caller has a functional edit authority.
            throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        }
    }

    private boolean hasActiveShare(UUID clientId, UUID employeeId) {
        if (clientId == null || employeeId == null) return false;
        return !em.createNativeQuery("""
                        SELECT 1
                        FROM client_visibility_grants grant_row
                        WHERE grant_row.client_id = :clientId
                          AND grant_row.grantee_employee_id = :employeeId
                          AND grant_row.active = TRUE
                        LIMIT 1
                        """)
                .setParameter("clientId", clientId)
                .setParameter("employeeId", employeeId)
                .getResultList().isEmpty();
    }

    private static Predicate assignedOwnerOnly(
            Root<Client> root, CriteriaBuilder cb, Predicate predicate) {
        return cb.and(cb.isNotNull(root.get("ownerEmployeeId")), predicate);
    }

    public record ClientScope(
            OwnerVisibility.OwnerScope ownerScope,
            Set<UUID> sharedClientIds,
            UUID viewerEmployeeId,
            boolean canAssign) {
        public ClientScope {
            sharedClientIds = sharedClientIds == null ? Set.of() : Set.copyOf(sharedClientIds);
        }

        public ClientScope(OwnerVisibility.OwnerScope ownerScope,
                           Set<UUID> sharedClientIds, boolean canAssign) {
            this(ownerScope, sharedClientIds, null, canAssign);
        }
    }

    public record NativeReadScope(
            String predicate,
            String ownerParameter,
            Set<UUID> ownerEmployees,
            String viewerParameter,
            UUID viewerEmployeeId) {
        public void bind(Query query) {
            if (ownerParameter != null) query.setParameter(ownerParameter, ownerEmployees);
            if (viewerParameter != null) query.setParameter(viewerParameter, viewerEmployeeId);
        }
    }
}
