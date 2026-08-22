package com.uten.imp.features.org.employee;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.employee.dto.UpdateEmployeeRequest;
import com.uten.imp.features.org.position.Position;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class EmployeeLifecycleGuardTest {

    @Test
    void employeeUpdateCannotBypassTransferHistory() {
        Department current = new Department();
        current.setId(UUID.randomUUID());
        Employee employee = new Employee();
        employee.setDepartment(current);

        assertDoesNotThrow(() ->
                EmployeeCommandService.assertDepartmentChangeUsesTransfer(employee, null));
        assertDoesNotThrow(() ->
                EmployeeCommandService.assertDepartmentChangeUsesTransfer(employee, current.getId()));

        ApiException error = assertThrows(
                ApiException.class,
                () -> EmployeeCommandService.assertDepartmentChangeUsesTransfer(
                        employee,
                        UUID.randomUUID()));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals(
                "调整员工部门请使用「调岗」功能，以保留完整任职记录",
                error.getMessage());
    }

    @Test
    void ordinaryEditCannotConfirmProbationEmployee() {
        Employee employee = employee("probation", null, null);

        ApiException error = assertThrows(
                ApiException.class,
                () -> EmployeeCommandService.assertLifecycleFieldsUseDedicatedCommands(
                        employee,
                        update("active", null, null)));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals(
                "试用员工转为在职请使用「转正」功能，以记录转正日期",
                error.getMessage());
    }

    @Test
    void ordinaryEditCannotChangeConfirmedAt() {
        LocalDate confirmedAt = LocalDate.of(2026, 8, 1);
        Employee employee = employee("active", confirmedAt, null);

        ApiException error = assertThrows(
                ApiException.class,
                () -> EmployeeCommandService.assertLifecycleFieldsUseDedicatedCommands(
                        employee,
                        update(null, confirmedAt.plusDays(1), null)));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals("设置或修改转正日期请使用「转正」功能", error.getMessage());
    }

    @Test
    void ordinaryEditCannotChangePosition() {
        Position position = new Position();
        position.setId(UUID.randomUUID());
        Employee employee = employee("active", null, position);

        ApiException error = assertThrows(
                ApiException.class,
                () -> EmployeeCommandService.assertLifecycleFieldsUseDedicatedCommands(
                        employee,
                        update(null, null, UUID.randomUUID())));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals(
                "调整员工岗位请使用「调岗」功能，以保留完整任职记录",
                error.getMessage());
    }

    @Test
    void ordinaryEditAcceptsSameLifecycleValuesForOldClients() {
        LocalDate confirmedAt = LocalDate.of(2026, 8, 1);
        Position position = new Position();
        position.setId(UUID.randomUUID());
        Employee employee = employee("active", confirmedAt, position);

        assertDoesNotThrow(() ->
                EmployeeCommandService.assertLifecycleFieldsUseDedicatedCommands(
                        employee,
                        update("active", confirmedAt, position.getId())));
    }

    @Test
    void onboardingCannotCreateImmediatelyActiveFutureEmployee() {
        assertDoesNotThrow(() ->
                EmployeeOnboardingService.assertHireDateNotFuture(BusinessTime.today()));

        ApiException error = assertThrows(
                ApiException.class,
                () -> EmployeeOnboardingService.assertHireDateNotFuture(
                        BusinessTime.today().plusDays(1)));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals("入职日期不能晚于今天", error.getMessage());
    }

    private static Employee employee(
            String status,
            LocalDate confirmedAt,
            Position position) {
        Employee employee = new Employee();
        employee.setStatus(status);
        employee.setConfirmedAt(confirmedAt);
        employee.setPosition(position);
        return employee;
    }

    private static UpdateEmployeeRequest update(
            String status,
            LocalDate confirmedAt,
            UUID positionId) {
        return new UpdateEmployeeRequest(
                null, null, null, null, null, null, null, null,
                null, positionId, null, null, null, null, null, null,
                null, status, null, confirmedAt,
                null, null, null, null, null, null, null, null, null, null,
                null, null, null, null);
    }
}
