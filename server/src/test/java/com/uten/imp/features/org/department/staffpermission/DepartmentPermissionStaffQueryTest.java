package com.uten.imp.features.org.department.staffpermission;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.util.List;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class DepartmentPermissionStaffQueryTest {

    @Test
    void excludedManagerPredicateAndParameterAreSharedByCountAndPage() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID departmentId = UUID.randomUUID();
        UUID managerId = UUID.randomUUID();
        var authority = new OrganizationPermissionManagementScopeService
                .StaffSearchAuthority(
                        OrganizationPermissionManagementScopeService
                                .StaffSearchScope.MANAGER_SUBTREES,
                        managerId);
        when(jdbc.queryForObject(
                anyString(), eq(Long.class), any(Object[].class)))
                .thenReturn(0L);
        when(jdbc.query(
                anyString(), any(RowMapper.class), any(Object[].class)))
                .thenReturn(List.of());
        DepartmentPermissionStaffQuery query =
                new DepartmentPermissionStaffQuery(jdbc);

        query.query(authority, departmentId, managerId, null, 1, 30);

        verify(jdbc).queryForObject(
                org.mockito.ArgumentMatchers.argThat(sql ->
                        sql.contains("authorized_departments")
                                && sql.contains("selected_departments")
                                && sql.contains("employee.id <> ?")),
                eq(Long.class),
                eq(managerId),
                eq(departmentId),
                eq(managerId));
        verify(jdbc).query(
                org.mockito.ArgumentMatchers.argThat(sql ->
                        sql.contains("employee.id <> ?")
                                && sql.contains("authorized_departments")
                                && sql.contains("selected_departments")
                                && sql.contains("LIMIT ? OFFSET ?")),
                any(RowMapper.class),
                eq(managerId),
                eq(departmentId),
                eq(managerId),
                eq(30),
                eq(0L));
    }
}
