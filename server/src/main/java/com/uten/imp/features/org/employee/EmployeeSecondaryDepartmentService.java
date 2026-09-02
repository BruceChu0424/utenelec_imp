package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 兼职部门维护（V459）：员工编辑页的「兼职部门」多选。
 *
 * <p>兼职不是调岗（不写 employment_history 轨迹，变更走审计触发器）；
 * 全量替换语义（先清后写）与前端多选保存一致。校验：部门存在且未删、
 * 不等于主部门（数据库触发器兜底）、列表内去重。
 */
@Service
public class EmployeeSecondaryDepartmentService {

    private final EmployeeRepository employeeRepo;
    private final DepartmentRepository deptRepo;
    private final EmployeeSecondaryDepartmentRepository secondaryRepo;

    public EmployeeSecondaryDepartmentService(
            EmployeeRepository employeeRepo,
            DepartmentRepository deptRepo,
            EmployeeSecondaryDepartmentRepository secondaryRepo) {
        this.employeeRepo = employeeRepo;
        this.deptRepo = deptRepo;
        this.secondaryRepo = secondaryRepo;
    }

    @Transactional(readOnly = true)
    public List<SecondaryDepartmentDto> listForEmployee(UUID employeeId) {
        Map<UUID, Department> deptById = new LinkedHashMap<>();
        for (Department d : deptRepo.findByDeletedFalseOrderBySortOrderAscNameAsc()) {
            deptById.put(d.getId(), d);
        }
        List<SecondaryDepartmentDto> result = new ArrayList<>();
        for (EmployeeSecondaryDepartment s
                : secondaryRepo.findByEmployeeIdOrderByCreatedAtAscIdAsc(employeeId)) {
            Department d = deptById.get(s.getDepartmentId());
            if (d == null) {
                continue;
            }
            result.add(new SecondaryDepartmentDto(
                    s.getId(), d.getId(), d.getName(), s.getStartedOn(), s.getNote()));
        }
        return result;
    }

    @Transactional
    public List<SecondaryDepartmentDto> replace(UUID employeeId, List<SecondaryDepartmentInput> items) {
        Employee e = employeeRepo.findById(employeeId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工不存在"));
        UUID primaryDeptId = e.getDepartment() == null ? null : e.getDepartment().getId();

        Set<UUID> seen = new LinkedHashSet<>();
        for (SecondaryDepartmentInput item : items == null ? List.<SecondaryDepartmentInput>of() : items) {
            if (item.departmentId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "兼职部门不能为空");
            }
            if (!seen.add(item.departmentId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "兼职部门存在重复项");
            }
            if (item.departmentId().equals(primaryDeptId)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED, "兼职部门不能与主部门相同（调岗请使用「调岗」功能）");
            }
            Department d = deptRepo.findById(item.departmentId())
                    .filter(x -> !x.isDeleted())
                    .orElseThrow(() -> new ApiException(ErrorCode.VALIDATION_FAILED, "部门不存在或已删除"));
            if (item.note() != null && item.note().length() > 200) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "兼职备注过长（≤200 字）");
            }
            if (item.startedOn() != null && item.startedOn().isAfter(LocalDate.now())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "兼职开始日期不能晚于今天");
            }
        }

        secondaryRepo.deleteAllByEmployeeId(employeeId);
        secondaryRepo.flush();
        for (UUID departmentId : seen) {
            SecondaryDepartmentInput src = items.stream()
                    .filter(x -> x.departmentId().equals(departmentId))
                    .findFirst().orElseThrow();
            EmployeeSecondaryDepartment s = new EmployeeSecondaryDepartment();
            s.setEmployeeId(employeeId);
            s.setDepartmentId(departmentId);
            s.setStartedOn(src.startedOn());
            s.setNote(src.note() == null || src.note().isBlank() ? null : src.note().strip());
            secondaryRepo.save(s);
        }
        return listForEmployee(employeeId);
    }

    public record SecondaryDepartmentInput(
            UUID departmentId, LocalDate startedOn, String note) {
    }

    public record SecondaryDepartmentDto(
            UUID id, UUID departmentId, String departmentName,
            LocalDate startedOn, String note) {
    }
}
