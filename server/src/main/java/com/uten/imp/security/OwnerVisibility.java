package com.uten.imp.security;

import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Component;

import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

/**
 * 归属可见性（按员工数据隔离）统一判定。
 *
 * <p>适用于「归属字段 + 查看全部权限点 + 数据范围授权」模型：
 * 手工数据范围只增加查看；正式交接才把来源员工的历史归属加入可写集合。
 */
@Component
public class OwnerVisibility {

    private final SecurityContextCurrentUser currentUser;
    private final EntityManager em;
    private final EmployeeHandoverVisibility handoverVisibility;

    public OwnerVisibility(SecurityContextCurrentUser currentUser, EntityManager em,
                           EmployeeHandoverVisibility handoverVisibility) {
        this.currentUser = currentUser;
        this.em = em;
        this.handoverVisibility = handoverVisibility;
    }

    public record OwnerScope(
            boolean seeAll,
            Set<UUID> visibleOwners,
            Set<UUID> writableOwners) {

        public OwnerScope {
            visibleOwners = Set.copyOf(visibleOwners == null ? Set.of() : visibleOwners);
            writableOwners = Set.copyOf(writableOwners == null ? Set.of() : writableOwners);
        }

        /** Compatibility constructor for explicit bypasses and existing tests. */
        public OwnerScope(boolean seeAll, Set<UUID> visibleOwners) {
            this(seeAll, visibleOwners, visibleOwners);
        }
    }

    public OwnerScope evaluate(String scope, String viewAllAuthority) {
        var user = currentUser.get().orElse(null);
        if (user != null && (user.isSuperAdmin() || user.getAuthorities().stream()
                .anyMatch(a -> viewAllAuthority.equals(a.getAuthority())))) {
            return new OwnerScope(true, Set.of(), Set.of());
        }
        Set<UUID> visibleOwners = new HashSet<>();
        Set<UUID> writableOwners = new HashSet<>();
        if (user != null) {
            if (user.getEmployeeId() != null) {
                visibleOwners.add(user.getEmployeeId());
                writableOwners.add(user.getEmployeeId());
                Set<UUID> handedOverOwners = handoverVisibility.inheritedOwners(
                        user.getEmployeeId(), scope);
                visibleOwners.addAll(handedOverOwners);
                writableOwners.addAll(handedOverOwners);
            }
            visibleOwners.addAll(grantedOwners(user.getId(), scope));
        }
        return new OwnerScope(false, visibleOwners, writableOwners);
    }

    public UUID currentResponsible(String scope, UUID historicalOwnerId) {
        return handoverVisibility.currentResponsible(scope, historicalOwnerId);
    }

    /** user_data_scopes 中该用户被授权的归属人集合（查不到按空集，不报错）。 */
    @SuppressWarnings("unchecked")
    private Set<UUID> grantedOwners(UUID userId, String scope) {
        var q = em.createNativeQuery("""
                        SELECT data_scope.owner_employee_id
                        FROM user_data_scopes data_scope
                        WHERE data_scope.user_id=:uid AND data_scope.scope=:scope
                          AND data_scope.owner_employment_generation=(
                              SELECT count(*) FROM employment_history history
                              WHERE history.employee_id=data_scope.owner_employee_id
                                AND history.event_type='rehire')
                        """)
                .setParameter("uid", userId).setParameter("scope", scope);
        return new HashSet<>((java.util.List<UUID>) q.getResultList());
    }
}
