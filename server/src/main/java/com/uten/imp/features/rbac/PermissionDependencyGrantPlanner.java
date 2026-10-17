package com.uten.imp.features.rbac;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Predicate;
import java.util.stream.Collectors;

/** Enforces hard reads and assists navigation without widening explicit revokes or grant ceilings. */
public final class PermissionDependencyGrantPlanner {
    private PermissionDependencyGrantPlanner() {}

    public static Set<String> configured(PermissionResolver.PermBreakdown state) {
        Set<String> configured = new LinkedHashSet<>(state.baselinePermissions());
        configured.addAll(state.departmentPermissions());
        configured.addAll(state.grants());
        configured.addAll(state.managerGrants());
        configured.removeAll(state.revokes());
        return configured;
    }

    public static Set<String> additions(Collection<Permission> permissions, Collection<String> enabled,
            Collection<String> available, Collection<String> blocked, Predicate<Permission> grantable,
            String entryPoint) {
        Map<String, Permission> catalog = permissions.stream().collect(Collectors.toMap(
                Permission::getCode, value -> value, (left, right) -> left, LinkedHashMap::new));
        PermissionDependencyCatalog dependencies = new PermissionDependencyCatalog(permissions);
        Set<String> held = new LinkedHashSet<>(available);
        held.addAll(enabled);
        Set<String> added = new LinkedHashSet<>();
        Predicate<String> autoGrantable = code -> !blocked.contains(code)
                && ordinaryGrantableRead(catalog.get(code), grantable);
        boolean changed;
        do {
            changed = false;
            for (String action : enabled) {
                for (String required : dependencies.missingHardDependencies(action, held, autoGrantable)) {
                    Permission permission = catalog.get(required);
                    String label = permission == null ? required : permission.getName();
                    String actionLabel = catalog.containsKey(action) ? catalog.get(action).getName() : action;
                    if (blocked.contains(required)) {
                        throw new ApiException(ErrorCode.BUSINESS, "无法启用“" + actionLabel + "”：所需查看权限“"
                                + label + "”已被明确收回。请先由有权管理员处理该项收回，或一并关闭依赖它的动作");
                    }
                    if (!ordinaryGrantableRead(permission, grantable)) {
                        throw new ApiException(ErrorCode.BUSINESS, "无法启用“" + actionLabel + "”：所需查看权限“"
                                + label + "”不能通过" + entryPoint + "自动授予，请在允许的授权入口单独确认");
                    }
                    if (held.add(required)) {
                        added.add(required);
                        changed = true;
                    }
                }
            }
        } while (changed);
        // Navigation is helpful, not an extra authorization gate for independent
        // consumers of the same action. Leave unavailable reads in missing metadata.
        for (String action : enabled) {
            for (String required : dependencies.missingDependencies(action, held)) {
                if (autoGrantable.test(required) && held.add(required)) added.add(required);
            }
        }
        return Set.copyOf(added);
    }

    private static boolean ordinaryGrantableRead(Permission permission, Predicate<Permission> grantable) {
        return permission != null && "VIEW".equals(permission.getActionType())
                && "NORMAL".equals(permission.getSensitivity())
                && GrantPolicy.bulkEligible(permission.grantPolicies()) && grantable.test(permission);
    }

    public static Map<String, List<String>> requirements(Collection<Permission> permissions, Collection<String> configured) {
        PermissionDependencyCatalog dependencies = new PermissionDependencyCatalog(permissions);
        Map<String, List<String>> result = new LinkedHashMap<>();
        for (Permission permission : permissions) {
            List<String> required = dependencies.requiredPermissions(permission.getCode(), configured);
            if (!required.isEmpty()) result.put(permission.getCode(), required);
        }
        return Map.copyOf(result);
    }

    public static Map<String, List<String>> missing(Collection<Permission> permissions, Collection<String> configured) {
        PermissionDependencyCatalog dependencies = new PermissionDependencyCatalog(permissions);
        Map<String, List<String>> result = new LinkedHashMap<>();
        for (String code : configured) {
            List<String> missing = dependencies.missingDependencies(code, configured);
            if (!missing.isEmpty()) result.put(code, missing);
        }
        return Map.copyOf(result);
    }
}
