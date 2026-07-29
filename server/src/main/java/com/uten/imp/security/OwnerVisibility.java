package com.uten.imp.security;

import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Component;

import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

/**
 * 归属可见性（按员工数据隔离）统一判定。
 *
 * <p>适用于「归属字段 + 查看全部权限点 + 数据范围授权」模型
 * （货品外贸 goods/goods:view:all、客户资料 client/client:view:all，V85/V86/V89）：
 * <ul>
 *   <li>归属列 NULL = 公共数据全员可见；</li>
 *   <li>非 NULL 仅 {本人} ∪ {user_data_scopes 授权归属人} 可见；</li>
 *   <li>超管或持 {@code *:view:all} 权限点者全见；</li>
 *   <li>无员工关联的账号兜底为「仅公共」（安全默认，显式三态）。</li>
 * </ul>
 */
@Component
public class OwnerVisibility {

    private final SecurityContextCurrentUser currentUser;
    private final EntityManager em;

    public OwnerVisibility(SecurityContextCurrentUser currentUser, EntityManager em) {
        this.currentUser = currentUser;
        this.em = em;
    }

    /**
     * 三态：seeAll=可见全部；否则 visibleOwners=可见归属人集合（本人+授权；空=仅公共数据）。
     */
    public record OwnerScope(boolean seeAll, Set<UUID> visibleOwners) {}

    /**
     * @param scope            业务范围（{@code goods} / {@code client}，对应 user_data_scopes.scope）
     * @param viewAllAuthority 「查看全部」权限点（如 {@code goods:view:all}）
     */
    public OwnerScope evaluate(String scope, String viewAllAuthority) {
        var user = currentUser.get().orElse(null);
        if (user != null && (user.isSuperAdmin() || user.getAuthorities().stream()
                .anyMatch(a -> viewAllAuthority.equals(a.getAuthority())))) {
            return new OwnerScope(true, Set.of());
        }
        Set<UUID> owners = new HashSet<>();
        if (user != null) {
            if (user.getEmployeeId() != null) owners.add(user.getEmployeeId());
            owners.addAll(grantedOwners(user.getId(), scope));
        }
        return new OwnerScope(false, owners);
    }

    /** user_data_scopes 中该用户被授权的归属人集合（查不到按空集，不报错）。 */
    @SuppressWarnings("unchecked")
    private Set<UUID> grantedOwners(UUID userId, String scope) {
        var q = em.createNativeQuery(
                        "SELECT owner_employee_id FROM user_data_scopes WHERE user_id = :uid AND scope = :scope")
                .setParameter("uid", userId).setParameter("scope", scope);
        return new HashSet<>((java.util.List<UUID>) q.getResultList());
    }
}
