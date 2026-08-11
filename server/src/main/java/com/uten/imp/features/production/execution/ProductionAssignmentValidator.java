package com.uten.imp.features.production.execution;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * Server-side source-of-truth validation for production workshop assignments.
 * Frontend tree filtering is only a convenience; every saved planning segment,
 * later reassignment and dispatch is checked again here.
 */
@Service
@RequiredArgsConstructor
public class ProductionAssignmentValidator {

    private static final String PRODUCTION_DEPARTMENT_CODE = "DEPT_PROD";
    private static final Set<String> ASSIGNABLE_EMPLOYEE_STATUSES =
            Set.of("active", "probation");

    private final EntityManager em;

    public void validate(Assignment assignment) {
        validateAll(List.of(assignment));
    }

    public void validateAll(List<Assignment> assignments) {
        if (assignments == null || assignments.isEmpty()) {
            return;
        }

        Set<UUID> departmentIds = new LinkedHashSet<>();
        Set<UUID> employeeIds = new LinkedHashSet<>();
        for (Assignment assignment : assignments) {
            if (assignment == null) {
                throw validation("生产安排不能为空");
            }
            validateDates(assignment.planBeginDate(), assignment.planEndDate());
            if (assignment.teamDepartmentId() != null
                    && assignment.workshopDepartmentId() == null) {
                throw validation("选择生产班组前必须先选择生产车间");
            }
            if (assignment.workshopDepartmentId() != null) {
                departmentIds.add(assignment.workshopDepartmentId());
            }
            if (assignment.teamDepartmentId() != null) {
                departmentIds.add(assignment.teamDepartmentId());
            }
            if (assignment.responsibleEmployeeId() != null) {
                employeeIds.add(assignment.responsibleEmployeeId());
            }
        }

        Map<UUID, DepartmentFact> departments = loadDepartments(departmentIds);
        Map<UUID, EmployeeFact> employees = loadEmployees(employeeIds);
        for (Assignment assignment : assignments) {
            validateAssignment(assignment, departments, employees);
        }
    }

    private Map<UUID, DepartmentFact> loadDepartments(Set<UUID> ids) {
        if (ids.isEmpty()) {
            return Map.of();
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT department.id,
                                       department.parent_id,
                                       department.path,
                                       parent.code
                                FROM departments department
                                LEFT JOIN departments parent
                                  ON parent.id = department.parent_id
                                 AND parent.is_deleted = FALSE
                                WHERE department.id IN (:ids)
                                  AND department.is_deleted = FALSE
                                """)
                        .setParameter("ids", ids));
        Map<UUID, DepartmentFact> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            result.put(
                    (UUID) row[0],
                    new DepartmentFact(
                            (UUID) row[1],
                            (String) row[2],
                            (String) row[3]));
        }
        return result;
    }

    private Map<UUID, EmployeeFact> loadEmployees(Set<UUID> ids) {
        if (ids.isEmpty()) {
            return Map.of();
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT employee.id,
                                       employee.status,
                                       department.path
                                FROM employees employee
                                JOIN departments department
                                  ON department.id = employee.department_id
                                 AND department.is_deleted = FALSE
                                WHERE employee.id IN (:ids)
                                  AND employee.is_deleted = FALSE
                                """)
                        .setParameter("ids", ids));
        Map<UUID, EmployeeFact> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            result.put(
                    (UUID) row[0],
                    new EmployeeFact((String) row[1], (String) row[2]));
        }
        return result;
    }

    private static void validateAssignment(
            Assignment assignment,
            Map<UUID, DepartmentFact> departments,
            Map<UUID, EmployeeFact> employees) {
        DepartmentFact workshop = null;
        if (assignment.workshopDepartmentId() != null) {
            workshop = departments.get(assignment.workshopDepartmentId());
            if (workshop == null
                    || !PRODUCTION_DEPARTMENT_CODE.equals(
                            workshop.parentCode())) {
                throw validation("生产车间必须是生产部直属且未删除的有效车间");
            }
        }

        DepartmentFact team = null;
        if (assignment.teamDepartmentId() != null) {
            team = departments.get(assignment.teamDepartmentId());
            if (team == null
                    || !assignment.workshopDepartmentId().equals(
                            team.parentId())) {
                throw validation("生产班组必须直属所选生产车间");
            }
        }

        if (assignment.responsibleEmployeeId() == null) {
            return;
        }
        EmployeeFact employee = employees.get(
                assignment.responsibleEmployeeId());
        if (employee == null
                || !ASSIGNABLE_EMPLOYEE_STATUSES.contains(employee.status())) {
            throw validation("生产负责人必须是未删除且在职或试用的员工");
        }

        DepartmentFact scope = team != null ? team : workshop;
        if (scope != null
                && (employee.departmentPath() == null
                        || scope.path() == null
                        || !employee.departmentPath().startsWith(
                                scope.path()))) {
            throw validation("生产负责人必须属于所选班组或车间组织范围");
        }
    }

    private static void validateDates(LocalDate begin, LocalDate end) {
        if (begin != null && end != null && end.isBefore(begin)) {
            throw validation("计划完工日期不能早于计划开工日期");
        }
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    public record Assignment(
            UUID workshopDepartmentId,
            UUID teamDepartmentId,
            UUID responsibleEmployeeId,
            LocalDate planBeginDate,
            LocalDate planEndDate) {
    }

    private record DepartmentFact(
            UUID parentId,
            String path,
            String parentCode) {
    }

    private record EmployeeFact(String status, String departmentPath) {
    }
}