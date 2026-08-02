package com.uten.imp.features.org.department.myview;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.DepartmentService;
import com.uten.imp.features.org.department.dto.DepartmentNode;
import com.uten.imp.features.org.department.myview.dto.MyDepartmentRosterDto;
import com.uten.imp.features.org.department.myview.dto.MyDepartmentRosterDto.Row;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * "我的部门"工作台卡片（问题 #20）——任意在职员工都能看的只读组织架构 + 本人所在
 * "大部门"（管理中心/直属公司的一级部门）范围内的通讯录，字段刻意收窄成安全字段。
 *
 * <p>不复用 {@code department:view}/{@code employee:view} 网关的既有接口：那两个权限点
 * 只授给人事/管理层，普通员工没有，会直接 403，看不到自己部门——这正是这个功能要解决的缺口。
 * 授权边界改成"只能看自己所在大部门分支"，天然收在数据范围内，不需要额外权限点。
 */
@Service
@RequiredArgsConstructor
public class MyDepartmentService {

    private static final String COMPANY_LEVEL = "公司";
    private static final Set<String> CURRENT_STATUSES = Set.of("active", "probation", "onLeave");

    private final EmployeeRepository employeeRepo;
    private final DepartmentRepository departmentRepo;
    private final DepartmentService departmentService;
    private final SecurityContextCurrentUser currentUser;

    /** 当前登录人所在"大部门"（管理中心，或直属公司的一级部门）整棵子树。 */
    @Transactional(readOnly = true)
    public List<DepartmentNode> myBranchTree() {
        Department branch = myBranchRoot();
        return departmentService.subtree(branch.getId());
    }

    /** 某部门（必须落在当前登录人所在大部门分支内）的安全字段通讯录。 */
    @Transactional(readOnly = true)
    public MyDepartmentRosterDto roster(UUID departmentId) {
        UUID myEmployeeId = currentUser.requireEmployeeId();
        Department branch = myBranchRoot();
        Set<UUID> branchIds = collectIds(departmentService.subtree(branch.getId()));
        if (!branchIds.contains(departmentId)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "只能查看本人所在部门分支内的通讯录");
        }
        String deptName = departmentRepo.findById(departmentId)
                .map(Department::getName)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "部门不存在"));
        List<Employee> staff = employeeRepo
                .findByDepartmentIdAndDeletedFalseOrderByFullNameAsc(departmentId)
                .stream()
                .filter(e -> CURRENT_STATUSES.contains(e.getStatus()))
                .toList();
        List<Row> rows = staff.stream()
                .map(e -> new Row(
                        e.getId(),
                        e.getCode(),
                        e.getFullName(),
                        e.getPosition() == null ? null : e.getPosition().getName(),
                        e.getOfficePhone(),
                        e.getEmail(),
                        e.getDepartment() != null
                                && e.getDepartment().getManager() != null
                                && e.getDepartment().getManager().getId().equals(e.getId()),
                        e.getId().equals(myEmployeeId)))
                .toList();
        return new MyDepartmentRosterDto(departmentId, deptName, rows);
    }

    /** 当前登录人所在部门，沿 parent 向上走到"父级即公司根"那一层（管理中心/直属一级部门）。 */
    private Department myBranchRoot() {
        UUID employeeId = currentUser.requireEmployeeId();
        Employee me = employeeRepo.findById(employeeId)
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "当前账号未绑定有效员工档案"));
        Department d = me.getDepartment();
        if (d == null) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前员工未分配部门");
        }
        while (d.getParent() != null && !COMPANY_LEVEL.equals(d.getParent().getLevel())) {
            d = d.getParent();
        }
        return d;
    }

    private Set<UUID> collectIds(List<DepartmentNode> nodes) {
        Set<UUID> out = new HashSet<>();
        collectIdsInto(nodes, out);
        return out;
    }

    private void collectIdsInto(List<DepartmentNode> nodes, Set<UUID> out) {
        for (DepartmentNode n : nodes) {
            out.add(n.getId());
            collectIdsInto(n.getChildren(), out);
        }
    }
}
