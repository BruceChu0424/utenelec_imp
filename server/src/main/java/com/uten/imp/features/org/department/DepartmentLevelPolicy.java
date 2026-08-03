package com.uten.imp.features.org.department;

import java.util.Set;

/**
 * Central organization-level rules shared by employee, position and department writes.
 *
 * <p>A management center is structurally fixed in the tree, but it is still an operating
 * organization: it may own employees, positions and an explicitly selected manager. Company and
 * decision-layer nodes remain grouping-only nodes.</p>
 */
public final class DepartmentLevelPolicy {

    private static final Set<String> EMPLOYEE_HOST_LEVELS = Set.of(
            "管理中心",
            "一级部门",
            "二级班组",
            "三级科室");

    private static final Set<String> IMMUTABLE_PARENT_LEVELS = Set.of(
            "公司",
            "决策层",
            "管理中心");

    private DepartmentLevelPolicy() {
    }

    /** Whether this organization node may directly own employees, positions and a manager. */
    public static boolean canHostEmployees(String level) {
        return EMPLOYEE_HOST_LEVELS.contains(level);
    }

    /** Whether the node's parent is controlled by migrations rather than ordinary editing. */
    public static boolean hasImmutableParent(String level) {
        return IMMUTABLE_PARENT_LEVELS.contains(level);
    }
}
