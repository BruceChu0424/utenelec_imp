package com.uten.imp.features.org.employee;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.dto.EmployeeOnboardingResult;
import com.uten.imp.features.org.employee.dto.OnboardingRequest;
import com.uten.imp.features.org.position.Position;
import com.uten.imp.features.org.position.PositionRepository;
import com.uten.imp.features.rbac.RoleRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class EmployeeOnboardingServiceTest {

    @Mock private EmployeeRepository empRepo;
    @Mock private EmployeeSensitiveRepository sensitiveRepo;
    @Mock private EmployeePiiWriter piiWriter;
    @Mock private EmployeeCompensationRepository compensationRepo;
    @Mock private EmployeeContractRepository contractRepo;
    @Mock private EmergencyContactRepository emergencyRepo;
    @Mock private EmployeeCredentialRepository credentialRepo;
    @Mock private EmployeeEducationRepository educationRepo;
    @Mock private EmploymentHistoryRepository historyRepo;
    @Mock private DepartmentRepository deptRepo;
    @Mock private PositionRepository positionRepo;
    @Mock private EntityManager entityManager;
    @Mock private UserAccountRepository userRepo;
    @Mock private RoleRepository roleRepo;
    @Mock private UserRoleRepository userRoleRepo;
    @Mock private PasswordEncoder passwordEncoder;
    @Mock private MasterCodeService masterCodeService;
    @Mock private TxSessionVars tx;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private EmployeeQueryService queryService;
    @Mock private EmployeeSensitiveWritePolicy sensitiveWritePolicy;
    @Mock private Query positionNameLockQuery;

    @InjectMocks
    private EmployeeOnboardingService service;

    @Test
    void alwaysAllocatesEmployeeCodeOnServerAndSkipsHistoricalCollision() {
        Department center = managementCenter();
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));
        when(masterCodeService.nextCode(MasterCodePrefix.EMPLOYEE))
                .thenReturn("UT0001", "UT0002");
        when(empRepo.existsByCode("UT0001")).thenReturn(true);
        when(empRepo.existsByCode("UT0002")).thenReturn(false);

        EmployeeOnboardingResult result = service.onboard(
                request(center.getId(), null, null, "CLIENT-SUPPLIED-CODE"));

        ArgumentCaptor<Employee> employee = ArgumentCaptor.forClass(Employee.class);
        verify(empRepo).save(employee.capture());
        assertEquals("UT0002", employee.getValue().getCode());
        assertEquals("13800000000", result.loginAccount());
    }

    @Test
    void rejectsSelectedPositionOutsideTheSelectedDepartment() {
        Department center = managementCenter();
        UUID foreignPositionId = UUID.randomUUID();
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));
        when(masterCodeService.nextCode(MasterCodePrefix.EMPLOYEE)).thenReturn("UT0003");
        when(positionRepo.findByIdAndDepartmentIdAndDeletedFalse(
                foreignPositionId, center.getId())).thenReturn(Optional.empty());

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.onboard(request(
                        center.getId(), foreignPositionId, null, "IGNORED")));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("岗位不存在、已停用或不属于所选部门", error.getMessage());
        verify(empRepo, never()).save(any(Employee.class));
    }

    @Test
    void typedPositionReusesFirstNormalizedActiveMatch() {
        Department center = managementCenter();
        Position existing = position(center, "ZW0042", "Engineer");
        stubCustomPositionLock();
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));
        when(masterCodeService.nextCode(MasterCodePrefix.EMPLOYEE)).thenReturn("UT0004");
        when(positionRepo.findFirstActiveByNormalizedName(center.getId(), "engineer"))
                .thenReturn(Optional.of(existing));

        service.onboard(request(center.getId(), null, "  Engineer  ", "IGNORED"));

        ArgumentCaptor<Employee> employee = ArgumentCaptor.forClass(Employee.class);
        verify(empRepo).save(employee.capture());
        assertSame(existing, employee.getValue().getPosition());
        verify(positionRepo, never()).save(any(Position.class));
    }

    @Test
    void typedUnknownPositionIsCreatedAsNeutralEmployeePosition() {
        Department center = managementCenter();
        stubCustomPositionLock();
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));
        when(masterCodeService.nextCode(MasterCodePrefix.EMPLOYEE)).thenReturn("UT0005");
        when(masterCodeService.nextCode(MasterCodePrefix.POSITION)).thenReturn("ZW0137");
        when(positionRepo.findFirstActiveByNormalizedName(center.getId(), "数据分析师"))
                .thenReturn(Optional.empty());
        when(positionRepo.save(any(Position.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));

        service.onboard(request(center.getId(), null, "  数据分析师  ", "IGNORED"));

        ArgumentCaptor<Position> position = ArgumentCaptor.forClass(Position.class);
        verify(positionRepo).save(position.capture());
        assertEquals("ZW0137", position.getValue().getCode());
        assertEquals("数据分析师", position.getValue().getName());
        assertEquals("员工", position.getValue().getLevel());
        assertSame(center, position.getValue().getDepartment());
    }

    private void stubCustomPositionLock() {
        when(entityManager.createNativeQuery(anyString())).thenReturn(positionNameLockQuery);
        when(positionNameLockQuery.setParameter(anyString(), any()))
                .thenReturn(positionNameLockQuery);
    }

    private static Department managementCenter() {
        Department department = new Department();
        department.setId(UUID.randomUUID());
        department.setCode("MFG_CENTER");
        department.setName("制造管理中心");
        department.setLevel("管理中心");
        return department;
    }

    private static Position position(Department department, String code, String name) {
        Position position = new Position();
        position.setCode(code);
        position.setName(name);
        position.setLevel("员工");
        position.setDepartment(department);
        return position;
    }

    private static OnboardingRequest request(
            UUID departmentId,
            UUID positionId,
            String positionName,
            String compatibilityCode) {
        return new OnboardingRequest(
                new OnboardingRequest.Profile(
                        compatibilityCode,
                        "测试员工",
                        null,
                        "其他",
                        "CARD-123456",
                        null,
                        "13800000000",
                        null,
                        null,
                        null,
                        null,
                        null,
                        null),
                new OnboardingRequest.Employment(
                        departmentId,
                        positionId,
                        null,
                        positionName,
                        LocalDate.now(),
                        "regular",
                        "active",
                        LocalDate.now(),
                        null,
                        null,
                        null,
                        null,
                        null), // +paperArchiveNo（null）
                null,
                null,
                List.of(),
                List.of(),
                List.of(),
                new OnboardingRequest.Account(List.of(), null));
    }
}
