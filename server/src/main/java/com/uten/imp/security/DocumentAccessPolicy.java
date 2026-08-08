package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.Query;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;

import java.util.Arrays;
import java.util.Set;
import java.util.UUID;

/**
 * 平台级单据行级访问策略（按归属人 owner 做对象级授权）。
 *
 * <p>把销售归属隔离模型（V91 {@code SalesDocumentAccessPolicy}）泛化到每个业务模块：
 * 单据的归属人（通常是制单人 maker）决定行可见性。归属列为 NULL 的老数据保持
 * 「可读但普通用户不可写」（兼容迁移数据）。超级管理员、本模块的 {@code *:view:all}
 * 权限点，以及调用方传入的操作级 authority 可旁路归属限制。
 *
 * <p>每个模块提供一个薄 {@code @Component} 子类，固定 {@code scope}（与
 * {@code user_data_scopes.scope} 对应）和 {@code viewAllAuthority} 权限码。feature 包
 * 依赖本 foundation 类（不产生 architecture-boundary 边）。
 *
 * <p>不可达对象返回 404（不泄露存在性）；归属不匹配的写操作返回 403。
 */
public abstract class DocumentAccessPolicy {

    private final String scope;
    private final String viewAllAuthority;
    private final OwnerVisibility ownerVisibility;
    private final SecurityContextCurrentUser currentUser;

    protected DocumentAccessPolicy(String scope, String viewAllAuthority,
                                   OwnerVisibility ownerVisibility,
                                   SecurityContextCurrentUser currentUser) {
        this.scope = scope;
        this.viewAllAuthority = viewAllAuthority;
        this.ownerVisibility = ownerVisibility;
        this.currentUser = currentUser;
    }

    /** 当前用户在本模块的归属可见范围；操作级 authority 命中则旁路（全见）。 */
    public OwnerVisibility.OwnerScope scope(String... operationAuthorities) {
        boolean operationBypass = operationAuthorities != null && operationAuthorities.length > 0
                && currentUser.get().stream()
                .flatMap(user -> user.getAuthorities().stream())
                .anyMatch(authority -> Arrays.asList(operationAuthorities).contains(authority.getAuthority()));
        if (operationBypass) {
            return new OwnerVisibility.OwnerScope(true, Set.of());
        }
        return ownerVisibility.evaluate(scope, viewAllAuthority);
    }

    /** 当前用户是否超管或持指定 authority（用于按钮/字段能力下发，非行过滤）。 */
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
     * 归属列存储 legacy {@code NULL} 归属为非 NULL 哨兵的聚合（例如唯一键须全非空的
     * 可刷新物化视图）时的可见范围。
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
            // 不泄露不可达单据是否存在。
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
        // 迁移来的无归属单据保持可读以兼容，但在管理员显式指派归属前不可写。
        return scope.seeAll()
                || ownerEmployeeId != null && scope.visibleOwners().contains(ownerEmployeeId);
    }

    /** 新单据总有归属人；上游归属人存在时优先取上游。 */
    public UUID ownerForNewDocument(UUID upstreamOwnerEmployeeId) {
        return upstreamOwnerEmployeeId != null
                ? upstreamOwnerEmployeeId
                : currentUser.requireEmployeeId();
    }

    /** 原生 SQL 读范围的谓词片段 + 绑定参数。 */
    public record NativeReadScope(String predicate, String parameterName, Set<UUID> owners) {
        public void bind(Query query) {
            if (parameterName != null) {
                query.setParameter(parameterName, owners);
            }
        }
    }
}
