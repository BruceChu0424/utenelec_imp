package com.uten.imp.features.profilechange;

import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.profilechange.dto.ProfileChangeDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** HR 队列部门筛选与筛选桶（2026-09-10 表头筛选接后端）。 */
class ProfileChangeQueryServiceTest {

    private ProfileChangeRepository repo;
    private ProfileChangeMapper mapper;
    private ProfileChangeAccess access;
    private ProfileChangeQueryService service;

    @BeforeEach
    void setUp() {
        repo = mock(ProfileChangeRepository.class);
        mapper = mock(ProfileChangeMapper.class);
        access = mock(ProfileChangeAccess.class);
        when(access.requireHr()).thenReturn(mock(AuthUser.class));
        service = new ProfileChangeQueryService(
                repo,
                mapper,
                mock(ProfileChangeSnapshotCodec.class),
                access,
                mock(TxSessionVars.class),
                mock(HrNoticePort.class));
    }

    @Test
    void hrListWithDepartmentUsesDepartmentScopedQueryAndDefaultsToPending() {
        UUID departmentId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        UUID batchId = UUID.randomUUID();
        ProfileChangeRequest first = request(employeeId, batchId, "phone");
        ProfileChangeRequest second = request(employeeId, batchId, "email");
        Page<ProfileChangeRequest> page = new PageImpl<>(List.of(first, second));
        when(repo.findByStatusAndDepartmentOrderBySubmittedAtDesc(
                eq("pending"), eq(departmentId), any(Pageable.class))).thenReturn(page);

        Department department = mock(Department.class);
        when(department.getName()).thenReturn("研发部");
        Employee employee = mock(Employee.class);
        when(employee.getFullName()).thenReturn("王小明");
        when(employee.getCode()).thenReturn("UT0001");
        when(employee.getDepartment()).thenReturn(department);
        when(mapper.employeesById(any())).thenReturn(Map.of(employeeId, employee));
        when(mapper.aggregateStatus(any())).thenReturn("pending");

        ProfileChangeDto.Page<ProfileChangeDto.HrListItem> result =
                service.hrList(1, 20, null, null, departmentId);

        assertEquals(1, result.items().size(), "同批两字段折叠为一行");
        ProfileChangeDto.HrListItem item = result.items().get(0);
        assertEquals(batchId, item.batchId());
        assertEquals("研发部", item.departmentName());
        assertEquals(List.of("phone", "email"), item.fieldCodes());
        verify(repo, never()).findByStatusOrderBySubmittedAtDesc(anyString(), any(Pageable.class));
        verify(access).requireHr();
    }

    @Test
    void hrListWithDepartmentAndStatusPassesStatusThrough() {
        UUID departmentId = UUID.randomUUID();
        when(repo.findByStatusAndDepartmentOrderBySubmittedAtDesc(
                anyString(), any(UUID.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        when(mapper.employeesById(any())).thenReturn(Map.of());

        service.hrList(2, 20, "applied", null, departmentId);

        ArgumentCaptor<Pageable> pageable = ArgumentCaptor.forClass(Pageable.class);
        verify(repo).findByStatusAndDepartmentOrderBySubmittedAtDesc(
                eq("applied"), eq(departmentId), pageable.capture());
        assertEquals(1, pageable.getValue().getPageNumber(), "对外页码从 1 起");
    }

    @Test
    void hrListWithoutDepartmentKeepsStatusQuery() {
        when(repo.findByStatusOrderBySubmittedAtDesc(eq("pending"), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        when(mapper.employeesById(any())).thenReturn(Map.of());

        service.hrList(1, 20, null, null, null);

        verify(repo).findByStatusOrderBySubmittedAtDesc(eq("pending"), any(Pageable.class));
        verify(repo, never()).findByStatusAndDepartmentOrderBySubmittedAtDesc(
                anyString(), any(UUID.class), any(Pageable.class));
    }

    @Test
    void hrFacetsMapDepartmentRowsAndDefaultToPending() {
        UUID departmentId = UUID.randomUUID();
        when(repo.countBatchesByDepartment("pending")).thenReturn(List.of(
                new Object[]{departmentId, "研发部", 3L},
                new Object[]{null, null, 1L}));

        ProfileChangeDto.Facets facets = service.hrFacets(" ");

        assertEquals(1, facets.departments().size(), "无部门的行不进桶");
        ProfileChangeDto.FacetBucket bucket = facets.departments().get(0);
        assertEquals(departmentId.toString(), bucket.value());
        assertEquals("研发部", bucket.label());
        assertEquals(3L, bucket.count());
        assertTrue(facets.departments().stream().noneMatch(b -> b.value().isBlank()));
    }

    private static ProfileChangeRequest request(UUID employeeId, UUID batchId, String fieldCode) {
        ProfileChangeRequest r = new ProfileChangeRequest();
        r.setEmployeeId(employeeId);
        r.setBatchId(batchId);
        r.setFieldCode(fieldCode);
        r.setFieldLabel(fieldCode);
        r.setFieldGroup("contact");
        r.setNewValueEnc("x");
        r.setSubmittedBy(employeeId);
        r.setSubmittedAt(OffsetDateTime.now());
        return r;
    }
}
