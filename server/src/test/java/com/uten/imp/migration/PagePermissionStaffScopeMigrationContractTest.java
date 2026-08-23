package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PagePermissionStaffScopeMigrationContractTest {

    private static final Path V329 = Path.of(
            "src/main/resources/db/migration",
            "V329__employee_permission_staff_global_page_index.sql");
    private static final Path STAFF_QUERY = Path.of(
            "src/main/java/com/uten/imp/features/org/department/staffpermission",
            "DepartmentPermissionStaffQuery.java");

    @Test
    void v329AddsThePartialCoveringIndexForEmptyDepartmentPaging()
            throws Exception {
        String sql = normalize(Files.readString(V329, StandardCharsets.UTF_8));

        assertThat(sql)
                .contains("create index idx_employees_current_name_code_page")
                .contains("on employees(full_name, code, id)")
                .contains("include (department_id, position_id)")
                .contains("where is_deleted = false")
                .contains("status in ('active', 'probation', 'onleave')")
                .contains("comment on index idx_employees_current_name_code_page is");
    }

    @Test
    void staffSqlRechecksManagerScopeAndIntersectsAnOptionalSelectedSubtree()
            throws Exception {
        String source = normalize(Files.readString(
                STAFF_QUERY, StandardCharsets.UTF_8));

        assertThat(source)
                .contains("company_authority as")
                .contains("office.code = 'gm'")
                .contains("office.manager_id = manager.id")
                .contains("manager.department_id = office.id")
                .contains("company.level = '公司'")
                .contains("company.parent_id is null")
                .contains("authorized_departments(id) as")
                .contains("root.manager_id = manager.id")
                .contains("join authorized_departments parent")
                .contains("selected_departments(id) as")
                .contains("join selected_departments parent")
                .contains("department.id in (select id from authorized_departments)")
                .contains("department.id in (select id from selected_departments)")
                .contains("department.level in ('管理中心', '一级部门', '二级班组', '三级科室')")
                .contains("department.id as department_id")
                .contains("department.name as department_name")
                .contains("limit ? offset ?");
    }

    private static String normalize(String value) {
        return value.toLowerCase(java.util.Locale.ROOT)
                .replaceAll("\\s+", " ")
                .trim();
    }
}
