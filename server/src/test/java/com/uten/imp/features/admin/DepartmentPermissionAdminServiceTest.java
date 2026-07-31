package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class DepartmentPermissionAdminServiceTest {

    @Mock
    private PermissionRepository permissionRepo;
    @Mock
    private DepartmentRepository departmentRepo;
    @Mock
    private DepartmentPermissionRepository departmentPermissionRepo;
    @Mock
    private PermissionResolver permissionResolver;
    @Mock
    private TxSessionVars tx;
    @Mock
    private SecurityContextCurrentUser currentUser;
    @Mock
    private AdminUserSupport support;
    @Mock
    private EmployeeRepository employeeRepo;
    @Mock
    private RefreshTokenRepository refreshTokenRepo;

    private DepartmentPermissionAdminService service;

    @BeforeEach
    void setUp() {
        service = new DepartmentPermissionAdminService(
                permissionRepo,
                departmentRepo,
                departmentPermissionRepo,
                permissionResolver,
                tx,
                currentUser,
                support,
                employeeRepo,
                refreshTokenRepo);
    }

    @ParameterizedTest
    @ValueSource(strings = {"audit_log:view", "audit_log:export"})
    void auditPermissionsCannotBeGrantedToAnEntireDepartment(String permissionCode) {
        UUID departmentId = UUID.randomUUID();
        when(departmentRepo.findById(departmentId))
                .thenReturn(Optional.of(new Department()));

        ApiException exception = assertThrows(
                ApiException.class,
                () -> service.setDepartmentPermissions(
                        departmentId,
                        List.of("employee:view", permissionCode)));

        assertEquals(ErrorCode.BUSINESS, exception.getCode());
        assertEquals("审计权限仅允许个人授权", exception.getMessage());
        verify(permissionRepo, never()).findByCodeIn(anyCollection());
        verify(departmentPermissionRepo, never())
                .deleteByIdDepartmentId(departmentId);
    }
}
