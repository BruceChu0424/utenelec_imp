package com.uten.imp.features.org.employee;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.Department;
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
}
