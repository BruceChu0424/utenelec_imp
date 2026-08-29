package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
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
import static org.assertj.core.api.Assertions.assertThat;
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
    @ValueSource(strings = {
            "audit_log:view",
            "audit_log:export",
            "account:balance:adjust"
    })
    void individualOnlyPermissionsCannotBeGrantedToAnEntireDepartment(
            String permissionCode) {
        UUID departmentId = UUID.randomUUID();
        when(departmentRepo.findById(departmentId))
                .thenReturn(Optional.of(new Department()));

        ApiException exception = assertThrows(
                ApiException.class,
                () -> service.setDepartmentPermissions(
                        departmentId,
                        List.of("employee:view", permissionCode)));

        assertEquals(ErrorCode.BUSINESS, exception.getCode());
        assertEquals("该高风险权限仅允许个人授权", exception.getMessage());
        verify(permissionRepo, never()).findByCodeIn(anyCollection());
        verify(departmentPermissionRepo, never())
                .deleteByIdDepartmentId(departmentId);
    }

    @Test
    void catalogReturnsOnlyActivePermissionsWithActionMetadata() {
        Permission active = permission("goods:view", true, true);
        active.setActionType("VIEW");
        active.setDescription("查看货品主档");
        Permission retired = permission("goods:legacy", false, false);
        when(permissionRepo.findAllByActiveTrue()).thenReturn(List.of(active));

        var catalog = service.catalog();

        assertThat(catalog).hasSize(1);
        assertThat(catalog.getFirst().permissions()).singleElement()
                .satisfies(item -> {
                    assertEquals("goods:view", item.code());
                    assertEquals("VIEW", item.actionType());
                    assertEquals("查看货品主档", item.description());
                    assertThat(item.assignable()).isTrue();
                });
    }

    @Test
    void inactiveOrNonAssignablePermissionCannotBeWrittenToDepartment() {
        UUID departmentId = UUID.randomUUID();
        Permission permission = permission("goods:legacy", true, false);
        when(departmentRepo.findById(departmentId))
                .thenReturn(Optional.of(new Department()));
        when(permissionRepo.findByCodeIn(anyCollection()))
                .thenReturn(List.of(permission));

        ApiException exception = assertThrows(
                ApiException.class,
                () -> service.setDepartmentPermissions(
                        departmentId,
                        List.of(permission.getCode())));

        assertEquals(ErrorCode.BUSINESS, exception.getCode());
        assertThat(exception.getMessage()).contains("不可再分配");
        verify(departmentPermissionRepo, never())
                .deleteByIdDepartmentId(departmentId);
    }

    private Permission permission(
            String code,
            boolean active,
            boolean assignable) {
        Permission permission = new Permission();
        permission.setId(UUID.randomUUID());
        permission.setCode(code);
        permission.setName(code);
        permission.setModule("基础资料");
        permission.setCategory("货品资料");
        permission.setActive(active);
        permission.setAssignable(assignable);
        return permission;
    }
}
