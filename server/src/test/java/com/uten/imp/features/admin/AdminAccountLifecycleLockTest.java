package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InOrder;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class AdminAccountLifecycleLockTest {

    @Mock
    private EmployeeRepository employees;
    @Mock
    private UserAccountRepository users;

    @Test
    void lockUsesEmployeeThenUserAndRechecksTheBinding() {
        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        UserAccountRepository.AccountState initial = mock(
                UserAccountRepository.AccountState.class);
        when(initial.getEmployeeId()).thenReturn(employeeId);
        Employee employee = employee(employeeId, "active");
        UserAccount account = account(userId, employeeId, "active");
        when(users.findAccountStateById(userId)).thenReturn(Optional.of(initial));
        when(employees.findByIdForUpdate(employeeId)).thenReturn(Optional.of(employee));
        when(users.findByIdForUpdate(userId)).thenReturn(Optional.of(account));

        AdminAccountLifecycleLock.LockedTarget locked =
                new AdminAccountLifecycleLock(employees, users).lock(userId);

        assertEquals(employee, locked.employee());
        assertEquals(account, locked.account());
        InOrder order = inOrder(users, employees);
        order.verify(users).findAccountStateById(userId);
        order.verify(employees).findByIdForUpdate(employeeId);
        order.verify(users).findByIdForUpdate(userId);
    }

    @Test
    void changedAccountEmployeeBindingFailsClosedAfterBothLocks() {
        UUID userId = UUID.randomUUID();
        UUID initialEmployeeId = UUID.randomUUID();
        UUID changedEmployeeId = UUID.randomUUID();
        UserAccountRepository.AccountState initial = mock(
                UserAccountRepository.AccountState.class);
        when(initial.getEmployeeId()).thenReturn(initialEmployeeId);
        Employee employee = employee(initialEmployeeId, "active");
        UserAccount account = account(userId, changedEmployeeId, "active");
        when(users.findAccountStateById(userId)).thenReturn(Optional.of(initial));
        when(employees.findByIdForUpdate(initialEmployeeId))
                .thenReturn(Optional.of(employee));
        when(users.findByIdForUpdate(userId)).thenReturn(Optional.of(account));

        assertThrows(ApiException.class,
                () -> new AdminAccountLifecycleLock(employees, users).lock(userId));
    }

    @Test
    void resignedEmployeeAndDisabledAccountCannotReceiveElevatedCapability() {
        AdminAccountLifecycleLock lifecycle =
                new AdminAccountLifecycleLock(employees, users);
        AdminAccountLifecycleLock.LockedTarget resigned =
                new AdminAccountLifecycleLock.LockedTarget(
                        employee(UUID.randomUUID(), "resigned"),
                        account(UUID.randomUUID(), UUID.randomUUID(), "disabled"));

        assertThrows(ApiException.class,
                () -> lifecycle.requireCurrentEmployee(resigned));
        assertThrows(ApiException.class,
                () -> lifecycle.requireActiveAccount(resigned));
    }

    private static Employee employee(UUID id, String status) {
        Employee employee = new Employee();
        employee.setId(id);
        employee.setStatus(status);
        return employee;
    }

    private static UserAccount account(
            UUID id, UUID employeeId, String status) {
        UserAccount account = new UserAccount();
        account.setId(id);
        account.setEmployeeId(employeeId);
        account.setStatus(status);
        return account;
    }
}
