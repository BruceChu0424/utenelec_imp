package com.uten.imp.features.org.department;

import java.util.List;
import java.util.Set;

/**
 * Central organization-level rules shared by employee, position and department writes.
 *
 * <p>A management center is structurally fixed in the tree, but it is still an operating
 * organization: it may own employees, positions and an explicitly selected manager. Company and
 * decision-layer nodes remain grouping-only nodes.</p>
 */
public final class DepartmentLevelPolicy {

    public static final String COMPANY_LEVEL = "公司";
    public static final String MANAGEMENT_CENTER_LEVEL = "管理中心";
    public static final String COMPANY_EXECUTIVE_OFFICE_CODE = "GM";

    private static final List<String> EMPLOYEE_HOST_LEVEL_LIST = List.of(
            "管理中心",
            "一级部门",
            "二级班组",
            "三级科室");

    private static final Set<String> EMPLOYEE_HOST_LEVELS =
            Set.copyOf(EMPLOYEE_HOST_LEVEL_LIST);

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

    /** Stable ordered values for parameterized SQL scope queries. */
    public static List<String> employeeHostLevels() {
        return EMPLOYEE_HOST_LEVEL_LIST;
    }

    public static boolean isManagementCenter(String level) {
        return MANAGEMENT_CENTER_LEVEL.equals(level);
    }

    public static boolean isCompanyRoot(Department department) {
        return department != null
                && !department.isDeleted()
                && COMPANY_LEVEL.equals(department.getLevel())
                && department.getParent() == null;
    }

    /**
     * Canonical company leadership office. Its mutable display name never
     * participates in authorization.
     */
    public static boolean isCompanyExecutiveOffice(Department department) {
        return department != null
                && !department.isDeleted()
                && COMPANY_EXECUTIVE_OFFICE_CODE.equals(department.getCode())
                && canHostEmployees(department.getLevel())
                && isCompanyRoot(department.getParent());
    }

    public static boolean isCompanyExecutiveOfficeCode(String code) {
        return COMPANY_EXECUTIVE_OFFICE_CODE.equals(code);
    }

    /** Whether the node's parent is controlled by migrations rather than ordinary editing. */
    public static boolean hasImmutableParent(String level) {
        return IMMUTABLE_PARENT_LEVELS.contains(level);
    }
}
