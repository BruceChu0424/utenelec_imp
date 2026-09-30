package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.position.PositionRepository;
import com.uten.imp.features.profilechange.ProfileChangeRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 转正闸门口径：试用期转正 / 在职未登记补登（老库重导存量，2026-09-29 实证 34 人）/ 已登记与离职拒绝。
 * 背景：active+confirmed_at 为空的员工此前 confirm 409「仅试用期员工可转正」，
 * 前端回退 PUT 又被 update 闸门拦「设置或修改转正日期请使用「转正」功能」——两道闸门互锁，无路可走。
 */
@ExtendWith(MockitoExtension.class)
class EmployeeConfirmGateTest {

    @Mock private EmployeeRepository empRepo;
    @Mock private EmployeeSensitiveRepository sensitiveRepo;
    @Mock private EmployeePiiWriter piiWriter;
    @Mock private EmployeeCompensationRepository compensationRepo;
    @Mock private EmployeeCredentialRepository credentialRepo;
    @Mock private EmployeeEducationRepository educationRepo;
    @Mock private EmploymentHistoryRepository historyRepo;
    @Mock private DepartmentRepository deptRepo;
    @Mock private PositionRepository positionRepo;
    @Mock private UserAccountRepository userRepo;
    @Mock private RefreshTokenRepository refreshTokenRepo;
    @Mock private ProfileChangeRepository profileChangeRepo;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private TxSessionVars tx;
    @Mock private EmployeeQueryService queryService;
    @Mock private EmployeeSensitiveWritePolicy sensitiveWritePolicy;

    @InjectMocks
    private EmployeeCommandService service;

    @Test
    void activeEmployeeWithoutConfirmedAtBackfillsInsteadOfDeadEnding() {
        Employee employee = employee("active", null);
        LocalDate date = LocalDate.now().minusDays(1);
        when(queryService.requireEmployee(employee.getId())).thenReturn(employee);

        service.confirm(employee.getId(), date);

        assertEquals("active", employee.getStatus());           // 补登不改状态
        assertEquals(date, employee.getConfirmedAt());
        ArgumentCaptor<EmploymentHistory> captor =
                ArgumentCaptor.forClass(EmploymentHistory.class);
        verify(historyRepo).save(captor.capture());
        assertEquals("confirm", captor.getValue().getEventType());
        assertEquals("补登转正日期", captor.getValue().getRemark());
        verify(empRepo).save(employee);
    }

    @Test
    void probationEmployeeConvertsToActive() {
        Employee employee = employee("probation", null);
        LocalDate date = LocalDate.now().minusDays(1);
        when(queryService.requireEmployee(employee.getId())).thenReturn(employee);

        service.confirm(employee.getId(), date);

        assertEquals("active", employee.getStatus());
        assertEquals(date, employee.getConfirmedAt());
        ArgumentCaptor<EmploymentHistory> captor =
                ArgumentCaptor.forClass(EmploymentHistory.class);
        verify(historyRepo).save(captor.capture());
        assertEquals("转正", captor.getValue().getRemark());
        verify(empRepo).save(employee);
    }

    @Test
    void alreadyConfirmedEmployeeRejectedWithExistingDateInMessage() {
        LocalDate confirmed = LocalDate.of(2026, 8, 1);
        Employee employee = employee("active", confirmed);
        when(queryService.requireEmployee(employee.getId())).thenReturn(employee);

        ApiException error = assertThrows(ApiException.class,
                () -> service.confirm(employee.getId(), LocalDate.now()));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("该员工已登记转正日期 " + confirmed + "，无需重复办理", error.getMessage());
        verify(empRepo, never()).save(any(Employee.class));
    }

    @Test
    void resignedEmployeeRejected() {
        Employee employee = employee("resigned", null);
        when(queryService.requireEmployee(employee.getId())).thenReturn(employee);

        ApiException error = assertThrows(ApiException.class,
                () -> service.confirm(employee.getId(), LocalDate.now()));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("员工已离职，无法办理转正", error.getMessage());
        verify(empRepo, never()).save(any(Employee.class));
    }

    private static Employee employee(String status, LocalDate confirmedAt) {
        Employee employee = new Employee();
        employee.setId(UUID.randomUUID());
        employee.setCode("UT0099");
        employee.setFullName("测试员工");
        employee.setHireDate(LocalDate.now().minusMonths(5));
        employee.setStatus(status);
        employee.setConfirmedAt(confirmedAt);
        employee.setEmploymentType("regular");
        return employee;
    }
}
