package com.uten.imp.features.org.department;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.dto.DepartmentDetail;
import com.uten.imp.features.org.department.dto.DepartmentSaveRequest;
import com.uten.imp.features.org.department.dto.DepartmentUpdateRequest;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;

import java.lang.reflect.Method;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class DepartmentServiceTest {

    @Mock
    private DepartmentRepository deptRepo;
    @Mock
    private EmployeeRepository empRepo;
    @Mock
    private EntityManager em;
    @Mock
    private TxSessionVars tx;
    @Mock
    private jakarta.persistence.Query hierarchyLockQuery;

    @Test
    void employeePickerTreeKeepsHierarchyButOnlyUsesMinimalPickerDto() {
        Department company = department("UTEN", "公司", "/UTEN/");
        Department production = department(
                "DEPT_PROD", "一级部门", "/UTEN/DEPT_PROD/");
        production.setParent(company);
        production.setHeadcount(80);
        Employee manager = new Employee();
        manager.setId(UUID.randomUUID());
        manager.setFullName("不应进入选择器树的负责人");
        production.setManager(manager);
        when(deptRepo.findByDeletedFalseOrderBySortOrderAscNameAsc())
                .thenReturn(List.of(company, production));

        var result = service().employeePickerTree();

        assertThat(result).hasSize(1);
        assertThat(result.getFirst().code()).isEqualTo("UTEN");
        assertThat(result.getFirst().children()).hasSize(1);
        var child = result.getFirst().children().getFirst();
        assertThat(child.code()).isEqualTo("DEPT_PROD");
        assertThat(child.parentId()).isEqualTo(company.getId());
        assertThat(child.children()).isEmpty();
    }

    @Test
    void unchangedParentDoesNotCheckForCycleOrRebuildV175ManagementCenter() {
        stubHierarchyLock();
        Department company = department("UTEN", "公司", "/UTEN/");
        Department center = department(
                "MKT_CENTER", "管理中心", "/UTEN/MKT_CENTER/");
        center.setParent(company);
        DepartmentUpdateRequest request = updateRequest("营销管理中心", company.getId());
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));

        DepartmentDetail result = service().update(center.getId(), request);

        assertEquals("营销管理中心", result.getName());
        assertEquals("管理中心", result.getLevel());
        assertEquals("/UTEN/MKT_CENTER/", result.getPath());
        assertEquals(company.getId(), result.getParentId());
        assertSame(company, center.getParent());
        verify(deptRepo, never()).isDescendant(center.getId(), company.getId());
        verify(deptRepo, never()).rebuildSubtreeHierarchy(center.getId());
    }

    @ParameterizedTest
    @ValueSource(strings = {"公司", "决策层", "管理中心"})
    void structureNodesCannotChangeParent(String level) {
        stubHierarchyLock();
        Department originalParent = level.equals("公司")
                ? null
                : department("ORIGINAL", "公司", "/ORIGINAL/");
        Department requestedParent = department("TARGET", "管理中心", "/TARGET/");
        Department department = department("SKELETON", level, "/SKELETON/");
        department.setParent(originalParent);
        DepartmentUpdateRequest request = updateRequest("组织骨架", requestedParent.getId());
        when(deptRepo.findById(department.getId())).thenReturn(Optional.of(department));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(department.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("公司、决策层和管理中心等组织骨架节点不可修改上级", error.getMessage());
        assertSame(originalParent, department.getParent());
        verify(deptRepo, never()).isDescendant(department.getId(), requestedParent.getId());
        verify(deptRepo, never()).findById(requestedParent.getId());
        verify(deptRepo, never()).save(org.mockito.ArgumentMatchers.any());
        verify(deptRepo, never()).rebuildSubtreeHierarchy(department.getId());
        verify(em, never()).flush();
    }

    @Test
    void businessDepartmentMoveStillChecksCycleAndRebuildsNonLeafSubtree() {
        stubHierarchyLock();
        Department originalParent = department(
                "MKT_CENTER", "管理中心", "/UTEN/MKT_CENTER/");
        Department requestedParent = department(
                "DEPT_SALES", "一级部门", "/UTEN/MKT_CENTER/DEPT_SALES/");
        Department department = department(
                "DEPT_CHANNEL", "一级部门", "/UTEN/MKT_CENTER/DEPT_CHANNEL/");
        department.setParent(originalParent);
        DepartmentUpdateRequest request = updateRequest("渠道营销部", requestedParent.getId());
        when(deptRepo.findById(department.getId())).thenReturn(Optional.of(department));
        when(deptRepo.findById(requestedParent.getId())).thenReturn(Optional.of(requestedParent));
        when(deptRepo.isDescendant(department.getId(), requestedParent.getId()))
                .thenReturn(false);
        // 返回 2 表示 CTE 同时更新移动根节点和至少一个后代。
        when(deptRepo.rebuildSubtreeHierarchy(department.getId())).thenReturn(2);

        DepartmentDetail result = service().update(department.getId(), request);

        assertEquals(requestedParent.getId(), result.getParentId());
        assertSame(requestedParent, department.getParent());
        verify(deptRepo).isDescendant(department.getId(), requestedParent.getId());
        verify(deptRepo).rebuildSubtreeHierarchy(department.getId());
        verify(deptRepo, never()).findSubtree(department.getId());

        var order = inOrder(em, hierarchyLockQuery, deptRepo);
        order.verify(em).createNativeQuery(org.mockito.ArgumentMatchers.contains(
                "DEPARTMENT_HIERARCHY"));
        order.verify(hierarchyLockQuery).getSingleResult();
        order.verify(deptRepo).findById(department.getId());
        order.verify(deptRepo).isDescendant(department.getId(), requestedParent.getId());
    }

    @Test
    void managementCenterCanReceiveDirectActiveManagerOnUpdate() {
        Department center = department(
                "MFG_CENTER", "管理中心", "/UTEN/MFG_CENTER/");
        DepartmentUpdateRequest request = updateRequest("制造管理中心", null);
        UUID managerId = UUID.randomUUID();
        request.setManagerId(managerId);
        Employee manager = new Employee();
        manager.setId(managerId);
        manager.setFullName("制造中心负责人");
        manager.setDepartment(center);
        manager.setStatus("active");
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));
        when(empRepo.findById(managerId)).thenReturn(Optional.of(manager));

        DepartmentDetail result = service().update(center.getId(), request);

        assertSame(manager, center.getManager());
        assertEquals(managerId, result.getManagerId());
        verify(deptRepo).save(center);
    }

    @ParameterizedTest
    @ValueSource(strings = {"公司", "决策层"})
    void nonOperatingNodeCannotReceiveNonNullManagerOnUpdate(String level) {
        Department node = department("SKELETON", level, "/SKELETON/");
        DepartmentUpdateRequest request = updateRequest("组织骨架", null);
        UUID managerId = UUID.randomUUID();
        request.setManagerId(managerId);
        when(deptRepo.findById(node.getId())).thenReturn(Optional.of(node));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service().update(node.getId(), request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("公司和决策层节点不能设置部门负责人", error.getMessage());
        verify(empRepo, never()).findById(managerId);
        verify(deptRepo, never()).save(org.mockito.ArgumentMatchers.any());
    }

    @ParameterizedTest
    @ValueSource(strings = {"公司", "决策层"})
    void nonOperatingNodeCannotReceiveNonNullManagerOnCreate(String level) {
        DepartmentSaveRequest request = new DepartmentSaveRequest();
        request.setCode("NEW_SKELETON");
        request.setName("新组织骨架");
        request.setLevel(level);
        UUID managerId = UUID.randomUUID();
        request.setManagerId(managerId);

        ApiException error = assertThrows(ApiException.class, () -> service().create(request));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("公司和决策层节点不能设置部门负责人", error.getMessage());
        verify(empRepo, never()).findById(managerId);
        verify(deptRepo, never()).save(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void hierarchyRebuildUsesOneRecursiveUpdateForLevelsAndPaths() throws Exception {
        Method method = DepartmentRepository.class.getMethod(
                "rebuildSubtreeHierarchy", UUID.class);
        Query query = method.getAnnotation(Query.class);
        Modifying modifying = method.getAnnotation(Modifying.class);
        String sql = query.value().toLowerCase().replaceAll("\\s+", " ");

        assertThat(sql)
                .contains("with recursive rebuilt")
                .contains("join rebuilt parent on child.parent_id = parent.id")
                .contains("set level = rebuilt.new_level, path = rebuilt.new_path")
                .contains("not child.id = any(parent.visited)")
                .doesNotContain("order by");
        assertThat(modifying.flushAutomatically()).isTrue();
        assertThat(modifying.clearAutomatically()).isTrue();
    }

    private DepartmentService service() {
        return new DepartmentService(deptRepo, empRepo, em, tx);
    }

    private void stubHierarchyLock() {
        when(em.createNativeQuery(org.mockito.ArgumentMatchers.contains(
                "DEPARTMENT_HIERARCHY"))).thenReturn(hierarchyLockQuery);
    }

    private static Department department(String code, String level, String path) {
        Department department = new Department();
        department.setId(UUID.randomUUID());
        department.setCode(code);
        department.setName(level);
        department.setLevel(level);
        department.setPath(path);
        return department;
    }

    private static DepartmentUpdateRequest updateRequest(String name, UUID parentId) {
        DepartmentUpdateRequest request = new DepartmentUpdateRequest();
        request.setName(name);
        request.setParentId(parentId);
        return request;
    }
}
