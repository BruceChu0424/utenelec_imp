package com.uten.imp.features.org.department.myview;

import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.DepartmentService;
import com.uten.imp.features.org.department.dto.DepartmentNode;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * &quot;我的部门&quot; 通讯录子树聚合的单元测试（2026-08-06 修复）。
 *
 * <p>根因：旧 roster 只取直属成员，中心层（纯分组节点）不挂人 → admin 默认选 FIN_CENTER 必然空。
 * 修复后 roster 按所选节点子树取人。这里用 Mockito 验证：选中心节点时调用的是子树聚合方法
 * （{@code findByDepartmentIdInAndDeletedFalseOrderByFullNameAsc}，传入中心+下级 id 集），
 * 而非旧的直属查询；且返回非空（中心节点不再"无员工"）。
 */
@ExtendWith(MockitoExtension.class)
class MyDepartmentServiceTest {

    @Mock private EmployeeRepository employeeRepo;
    @Mock private EmployeeSensitiveRepository sensitiveRepo;
    @Mock private DepartmentRepository departmentRepo;
    @Mock private DepartmentService departmentService;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private TxSessionVars tx;

    @org.mockito.InjectMocks
    private MyDepartmentService service;

    @Test
    void rosterForCenterNodeAggregatesSubtreeStaffInsteadOfDirectOnly() {
        // 组织树：公司 → 管理中心(中心) → 一级部门(下级)。我在下级部门，分支根=中心。
        UUID companyId = UUID.randomUUID();
        UUID centerId = UUID.randomUUID();
        UUID subDeptId = UUID.randomUUID();
        UUID meId = UUID.randomUUID();
        UUID subEmployeeId = UUID.randomUUID();
        UUID centerEmployeeId = UUID.randomUUID();

        Department company = department(companyId, "UTEN", "公司", null);
        Department center = department(centerId, "FIN_CENTER", "管理中心", company);
        Department subDept = department(subDeptId, "DEPT_HR", "一级部门", center);

        Employee me = employee(meId, subDept);
        // 下级部门 1 名员工 + 中心本身 1 名员工（中心直属，子树聚合都应覆盖）。
        Employee subEmployee = activeEmployee(subEmployeeId, subDept, "张三");
        Employee centerEmployee = activeEmployee(centerEmployeeId, center, "李四");

        when(currentUser.requireEmployeeId()).thenReturn(meId);
        when(employeeRepo.findById(meId)).thenReturn(Optional.of(me));
        // myBranchRoot 上溯到中心；roster 对分支鉴权和取人都调 departmentService.subtree(中心)。
        when(departmentService.subtree(centerId)).thenReturn(List.of(
                node(centerId, List.of(node(subDeptId, List.of())))));
        when(departmentRepo.findById(centerId)).thenReturn(Optional.of(center));
        when(employeeRepo.findByDepartmentIdInAndDeletedFalseOrderByFullNameAsc(
                argThat((java.util.Collection<UUID> ids) ->
                        ids.contains(centerId) && ids.contains(subDeptId))))
                .thenReturn(List.of(subEmployee, centerEmployee));
        when(sensitiveRepo.findAllByEmployeeIdIn(any())).thenReturn(List.of());

        // 选中心节点（旧实现这里返回空 → "无员工" bug）
        var roster = service.roster(centerId);

        assertThat(roster.staff()).hasSize(2);
        assertThat(roster.staff()).extracting(s -> s.fullName()).containsExactlyInAnyOrder("张三", "李四");
        assertThat(roster.staff()).extracting(s -> s.departmentId())
                .containsExactlyInAnyOrder(subDeptId, centerId);
        // 关键：用的是子树聚合方法（新），不是旧的直属查询。
        verify(employeeRepo).findByDepartmentIdInAndDeletedFalseOrderByFullNameAsc(any());
        verify(employeeRepo, never()).findByDepartmentIdAndDeletedFalseOrderByFullNameAsc(any());
    }

    private static Department department(UUID id, String code, String level, Department parent) {
        Department department = new Department();
        department.setId(id);
        department.setCode(code);
        department.setName(code);
        department.setLevel(level);
        department.setParent(parent);
        return department;
    }

    private static Employee employee(UUID id, Department department) {
        Employee employee = new Employee();
        employee.setId(id);
        employee.setDepartment(department);
        return employee;
    }

    private static Employee activeEmployee(UUID id, Department department, String fullName) {
        Employee employee = employee(id, department);
        employee.setStatus("active");
        employee.setFullName(fullName);
        return employee;
    }

    private static DepartmentNode node(UUID id, List<DepartmentNode> children) {
        DepartmentNode node = new DepartmentNode();
        node.setId(id);
        node.setChildren(children);
        return node;
    }
}
