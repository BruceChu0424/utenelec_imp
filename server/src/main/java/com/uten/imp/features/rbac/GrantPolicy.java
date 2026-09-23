package com.uten.imp.features.rbac;

import java.util.Collection;
import java.util.EnumSet;
import java.util.List;
import java.util.Set;

/**
 * 权限码的授权策略(ADR-109：permissions.grant_policy 是「一个码能怎么授」的唯一事实源)。
 *
 * <p>部门矩阵保存、个人覆盖、负责人页面委派、全员基础包与「全部授权」五个入口都只读这里，
 * 数据库守卫 {@code fn_guard_permission_grant_policy} 用同一份取值兜底。代码里不得再出现
 * 任何按码写死的授权名单({@code PermissionGrantPolicyContractTest} 锁定)。
 */
public enum GrantPolicy {
    /** 普通：部门、个人、负责人委派、全员基础包与「全部授权」都可以带上。 */
    NORMAL,
    /** 不随「全部授权 / 本模块 / 本组」批量发放，必须逐项勾选(对象全量范围、商业敏感信息)。 */
    BULK_EXCLUDED,
    /** 只能由超级管理员逐人授予：不进部门矩阵、不可委派、不随批量。 */
    INDIVIDUAL_ONLY,
    /** 组织负责人不能在页面上转授(超级管理员仍可按部门或个人显式授予)。 */
    NON_DELEGABLE,
    /** 只随超级管理员身份生效：任何入口都不能授出。 */
    SUPERADMIN_ONLY;

    public static Set<GrantPolicy> parse(String[] raw) {
        return parse(raw == null ? List.of() : List.of(raw));
    }

    public static Set<GrantPolicy> parse(Collection<String> raw) {
        EnumSet<GrantPolicy> values = EnumSet.noneOf(GrantPolicy.class);
        if (raw != null) {
            for (String value : raw) {
                values.add(GrantPolicy.valueOf(value));
            }
        }
        if (values.isEmpty()) {
            values.add(NORMAL);
        }
        return values;
    }

    /** 能否配置给整个部门。 */
    public static boolean departmentGrantable(Set<GrantPolicy> policy) {
        return !policy.contains(INDIVIDUAL_ONLY) && !policy.contains(SUPERADMIN_ONLY);
    }

    /** 能否由超级管理员对个人加授。 */
    public static boolean individuallyGrantable(Set<GrantPolicy> policy) {
        return !policy.contains(SUPERADMIN_ONLY);
    }

    /** 能否由组织负责人在页面上转授。 */
    public static boolean delegable(Set<GrantPolicy> policy) {
        return !policy.contains(NON_DELEGABLE)
                && !policy.contains(INDIVIDUAL_ONLY)
                && !policy.contains(SUPERADMIN_ONLY);
    }

    /** 能否被「全部授权 / 本模块 / 本组」批量带上。 */
    public static boolean bulkEligible(Set<GrantPolicy> policy) {
        return !policy.contains(BULK_EXCLUDED)
                && !policy.contains(INDIVIDUAL_ONLY)
                && !policy.contains(SUPERADMIN_ONLY);
    }

    /** 能否放进全员基础包(与数据库 permissions_baseline_policy_chk 同口径)。 */
    public static boolean baselineEligible(Set<GrantPolicy> policy) {
        return bulkEligible(policy);
    }

    /** 不能部门授权的原因(面向管理员的中文大白话)。 */
    public static String departmentRefusal(Set<GrantPolicy> policy) {
        return policy.contains(SUPERADMIN_ONLY)
                ? "这项权限只随超级管理员身份生效，不能配置给部门"
                : "这项高风险权限只能逐人授予，不能配置给整个部门";
    }

    /** 不能由负责人转授的原因(面向负责人的中文大白话)。 */
    public static String delegationRefusal(Set<GrantPolicy> policy) {
        if (policy.contains(SUPERADMIN_ONLY)) {
            return "这项权限只随超级管理员身份生效，不能转授";
        }
        if (policy.contains(INDIVIDUAL_ONLY)) {
            return "这项高风险权限只能由超级管理员在全局权限页逐人授予";
        }
        return "这项权限不能由负责人转授，请联系超级管理员在全局权限页配置";
    }
}
