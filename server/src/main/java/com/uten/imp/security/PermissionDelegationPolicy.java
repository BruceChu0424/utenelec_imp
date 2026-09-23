package com.uten.imp.security;

import com.uten.imp.features.rbac.GrantPolicy;
import com.uten.imp.features.rbac.PermissionGrantPolicyCatalog;
import org.springframework.stereotype.Component;

import java.util.Set;

/**
 * 组织负责人页面委派的唯一判定：只读 permissions.grant_policy(ADR-109)。
 *
 * <p>含 NON_DELEGABLE / INDIVIDUAL_ONLY / SUPERADMIN_ONLY 的码一律不可委派；
 * 目录里不存在的码同样不可委派(fail closed)。这里不再维护任何按码写死的名单。
 */
@Component
public class PermissionDelegationPolicy {

    private final PermissionGrantPolicyCatalog catalog;

    public PermissionDelegationPolicy(PermissionGrantPolicyCatalog catalog) {
        this.catalog = catalog;
    }

    public boolean isDelegable(String permissionCode) {
        return catalog.policyOf(permissionCode)
                .map(GrantPolicy::delegable)
                .orElse(false);
    }

    public String nonDelegableReason(String permissionCode) {
        return catalog.policyOf(permissionCode)
                .map(GrantPolicy::delegationRefusal)
                .orElse("这项权限已不在权限目录里，不能转授");
    }

    /** 码的授权策略；目录里没有这个码时返回空集合。 */
    public Set<GrantPolicy> policyOf(String permissionCode) {
        return catalog.policyOf(permissionCode).orElse(Set.of());
    }
}
