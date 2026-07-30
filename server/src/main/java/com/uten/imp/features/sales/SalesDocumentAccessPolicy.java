package com.uten.imp.features.sales;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.Query;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Arrays;
import java.util.Set;
import java.util.UUID;

/**
 * Sales-document row access policy.
 *
 * <p>Read semantics intentionally preserve migrated legacy rows: a {@code null}
 * owner is readable but never writable by an ordinary user. Non-null owners are
 * limited to the current employee plus explicitly delegated sales data scopes.
 * Super administrators, {@code sales:view:all}, and a caller-supplied
 * operation-specific authority can bypass the owner restriction.
 */
@Component
@RequiredArgsConstructor
public class SalesDocumentAccessPolicy {

    public static final String SCOPE = "sales";
    public static final String VIEW_ALL = "sales:view:all";

    private final OwnerVisibility ownerVisibility;
    private final SecurityContextCurrentUser currentUser;

    public OwnerVisibility.OwnerScope scope(String... operationAuthorities) {
        boolean operationBypass = operationAuthorities != null && operationAuthorities.length > 0
                && currentUser.get().stream()
                .flatMap(user -> user.getAuthorities().stream())
                .anyMatch(authority -> Arrays.asList(operationAuthorities).contains(authority.getAuthority()));
        if (operationBypass) {
            return new OwnerVisibility.OwnerScope(true, Set.of());
        }
        return ownerVisibility.evaluate(SCOPE, VIEW_ALL);
    }

    public boolean hasAuthority(String authority) {
        return currentUser.get()
                .map(user -> user.isSuperAdmin() || user.getAuthorities().stream()
                        .anyMatch(granted -> authority.equals(granted.getAuthority())))
                .orElse(false);
    }

    public Predicate readablePredicate(Root<?> root, CriteriaBuilder cb, String ownerAttribute,
                                       String... operationAuthorities) {
        return readablePredicate(root, cb, ownerAttribute, scope(operationAuthorities));
    }

    public Predicate readablePredicate(Root<?> root, CriteriaBuilder cb, String ownerAttribute,
                                       OwnerVisibility.OwnerScope scope) {
        if (scope.seeAll()) {
            return cb.conjunction();
        }
        Predicate legacyPublic = cb.isNull(root.get(ownerAttribute));
        return scope.visibleOwners().isEmpty()
                ? legacyPublic
                : cb.or(legacyPublic, root.get(ownerAttribute).in(scope.visibleOwners()));
    }

    public NativeReadScope nativeReadScope(String ownerColumn, String parameterName,
                                           String... operationAuthorities) {
        return nativeReadScope(ownerColumn, parameterName, scope(operationAuthorities));
    }

    public NativeReadScope nativeReadScope(String ownerColumn, String parameterName,
                                           OwnerVisibility.OwnerScope scope) {
        if (scope.seeAll()) {
            return new NativeReadScope("1=1", null, Set.of());
        }
        if (scope.visibleOwners().isEmpty()) {
            return new NativeReadScope(ownerColumn + " IS NULL", null, Set.of());
        }
        return new NativeReadScope(
                "(" + ownerColumn + " IS NULL OR " + ownerColumn + " IN (:" + parameterName + "))",
                parameterName,
                scope.visibleOwners());
    }

    /**
     * Owner scope for an aggregate that stores legacy {@code NULL} owners as a
     * non-null sentinel (for example a concurrently refreshable materialized
     * view whose unique key must be entirely non-null).
     */
    public NativeReadScope nativeReadScopeWithLegacySentinel(
            String ownerColumn,
            String parameterName,
            UUID legacyOwnerSentinel,
            OwnerVisibility.OwnerScope scope) {
        if (scope.seeAll()) {
            return new NativeReadScope("1=1", null, Set.of());
        }
        String legacyPublic = ownerColumn + " = '" + legacyOwnerSentinel + "'::uuid";
        if (scope.visibleOwners().isEmpty()) {
            return new NativeReadScope(legacyPublic, null, Set.of());
        }
        return new NativeReadScope(
                "(" + legacyPublic + " OR " + ownerColumn + " IN (:" + parameterName + "))",
                parameterName,
                scope.visibleOwners());
    }

    public boolean canRead(UUID ownerEmployeeId, String... operationAuthorities) {
        return canRead(ownerEmployeeId, scope(operationAuthorities));
    }

    public boolean canRead(UUID ownerEmployeeId, OwnerVisibility.OwnerScope scope) {
        return scope.seeAll()
                || ownerEmployeeId == null
                || scope.visibleOwners().contains(ownerEmployeeId);
    }

    public void requireReadable(UUID ownerEmployeeId, String notFoundMessage,
                                String... operationAuthorities) {
        requireReadable(ownerEmployeeId, notFoundMessage, scope(operationAuthorities));
    }

    public void requireReadable(UUID ownerEmployeeId, String notFoundMessage,
                                OwnerVisibility.OwnerScope scope) {
        if (!canRead(ownerEmployeeId, scope)) {
            // Do not reveal whether an inaccessible document exists.
            throw new ApiException(ErrorCode.NOT_FOUND, notFoundMessage);
        }
    }

    public void requireWritable(UUID ownerEmployeeId, String forbiddenMessage,
                                String... operationAuthorities) {
        requireWritable(ownerEmployeeId, forbiddenMessage, scope(operationAuthorities));
    }

    public void requireWritable(UUID ownerEmployeeId, String forbiddenMessage,
                                OwnerVisibility.OwnerScope scope) {
        if (!canWrite(ownerEmployeeId, scope)) {
            throw new ApiException(ErrorCode.FORBIDDEN, forbiddenMessage);
        }
    }

    public boolean canWrite(UUID ownerEmployeeId, String... operationAuthorities) {
        return canWrite(ownerEmployeeId, scope(operationAuthorities));
    }

    public boolean canWrite(UUID ownerEmployeeId, OwnerVisibility.OwnerScope scope) {
        // Migrated owner-less documents stay readable for compatibility, but
        // are immutable until an administrator explicitly assigns ownership.
        return scope.seeAll()
                || ownerEmployeeId != null && scope.visibleOwners().contains(ownerEmployeeId);
    }

    /** New documents always have an owner; an upstream owner wins when present. */
    public UUID ownerForNewDocument(UUID upstreamOwnerEmployeeId) {
        return upstreamOwnerEmployeeId != null
                ? upstreamOwnerEmployeeId
                : currentUser.requireEmployeeId();
    }

    public record NativeReadScope(String predicate, String parameterName, Set<UUID> owners) {
        public void bind(Query query) {
            if (parameterName != null) {
                query.setParameter(parameterName, owners);
            }
        }
    }
}
