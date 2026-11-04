package com.uten.imp.features.admin.impersonation;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.org.employee.EmployeeQueryService;
import com.uten.imp.features.org.employee.dto.EmployeeListItem;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.verifyNoMoreInteractions;

class ImpersonationTargetDirectoryTest {
    @Test
    void pageLoadsOneOriginalHrPageWithoutDroppingAccountFacts() {
        var query = mock(EmployeeQueryService.class);
        UUID department = UUID.randomUUID();
        var row = employee(UUID.randomUUID(), department);
        when(query.list(3, 20, "张", Set.of("active"), department, true, null, null))
                .thenReturn(new PageResponse<>(List.of(row), 3, 20, 41, 3));
        var service = new ImpersonationService(null, null, null, null, null, query);
        var result = service.targetsPage("张", 3, 20, department, true);
        assertEquals(41, result.getTotal());
        assertEquals("locked", result.getItems().getFirst().accountStatus());
        assertEquals(department, result.getItems().getFirst().departmentId());
        verify(query).list(3, 20, "张", Set.of("active"), department, true, null, null);
        verifyNoMoreInteractions(query);
    }
    @Test
    void directoryLoadsLaterPagesAndRetainsDistinctDepartmentIdentities() {
        var query = mock(EmployeeQueryService.class);
        var first = employee(UUID.randomUUID(), UUID.randomUUID());
        var second = employee(UUID.randomUUID(), UUID.randomUUID());
        when(query.list(1, 100, null, Set.of("active"), null, false, null, null))
                .thenReturn(new PageResponse<>(List.of(first), 1, 100, 2, 2));
        when(query.list(2, 100, null, Set.of("active"), null, false, null, null))
                .thenReturn(new PageResponse<>(List.of(second), 2, 100, 2, 2));
        var service = new ImpersonationService(null, null, null, null, null, query);

        var rows = service.listTargets(null);

        assertEquals(List.of(first.getId(), second.getId()),
                rows.stream().map(row -> row.employeeId()).toList());
        assertEquals(List.of(first.getDepartmentId(), second.getDepartmentId()),
                rows.stream().map(row -> row.departmentId()).toList());
        assertEquals(List.of("locked", "locked"), rows.stream().map(row -> row.accountStatus()).toList());
        assertEquals(List.of("active", "active"), rows.stream().map(row -> row.employmentStatus()).toList());
        verify(query).list(2, 100, null, Set.of("active"), null, false, null, null);
    }

    private EmployeeListItem employee(UUID id, UUID departmentId) {
        return new EmployeeListItem(id, "UT-" + id, "同名员工", null,
                "同名部门", null, "active", null, null, null, false, 0,
                departmentId, null, "locked");
    }
}
