package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.dto.TransferRequest;
import com.uten.imp.features.org.employee.dto.UpdateEmployeeRequest;
import com.uten.imp.features.org.position.PositionRepository;
import com.uten.imp.features.profilechange.ProfileChangeRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.LocalDate;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class EmployeeCommandPositionGuardTest {

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
    void updateRejectsPositionChangeAndRequiresTransferWorkflow() {
        Department current = department("MFG_CENTER", "管理中心");
        Employee employee = employee(current);
        UUID positionId = UUID.randomUUID();
        when(queryService.requireEmployee(employee.getId())).thenReturn(employee);
        ApiException error = assertThrows(
                ApiException.class,
                () -> service.update(employee.getId(), updatePosition(positionId)));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals("调整员工岗位请使用「调岗」功能，以保留完整任职记录", error.getMessage());
        verify(positionRepo, never()).findByIdAndDepartmentIdAndDeletedFalse(
                any(UUID.class), any(UUID.class));
        verify(empRepo, never()).save(any(Employee.class));
    }

    @Test
    void transferRejectsPositionOutsideTargetDepartmentInsteadOfClearingIt() {
        Department current = department("OLD_DEPT", "一级部门");
        Department target = department("NEW_CENTER", "管理中心");
        Employee employee = employee(current);
        UUID positionId = UUID.randomUUID();
        when(queryService.requireEmployee(employee.getId())).thenReturn(employee);
        when(historyRepo.findFirstByEmployeeIdOrderByEventDateDescCreatedAtDesc(
                employee.getId())).thenReturn(Optional.empty());
        when(deptRepo.findById(target.getId())).thenReturn(Optional.of(target));
        when(positionRepo.findByIdAndDepartmentIdAndDeletedFalse(
                positionId, target.getId())).thenReturn(Optional.empty());

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.transfer(
                        employee.getId(),
                        new TransferRequest(
                                target.getId(),
                                positionId,
                                null,
                                LocalDate.now(),
                                null)));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("岗位不存在、已停用或不属于目标部门", error.getMessage());
        verify(historyRepo, never()).save(any(EmploymentHistory.class));
        verify(empRepo, never()).save(any(Employee.class));
    }

    private static Department department(String code, String level) {
        Department department = new Department();
        department.setCode(code);
        department.setName(code);
        department.setLevel(level);
        return department;
    }

    private static Employee employee(Department department) {
        Employee employee = new Employee();
        employee.setCode("UT0099");
        employee.setFullName("测试员工");
        employee.setDepartment(department);
        employee.setHireDate(LocalDate.now().minusDays(1));
        employee.setStatus("active");
        employee.setEmploymentType("regular");
        return employee;
    }

    private static UpdateEmployeeRequest updatePosition(UUID positionId) {
        return new UpdateEmployeeRequest(
                null, null, null, null, null, null, null, null,
                null, positionId, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null,
                null, null); // vehicles, phones（ADR-021，null）
    }
}
