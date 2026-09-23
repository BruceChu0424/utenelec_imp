package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.PermissionBulkScopeDto;
import com.uten.imp.features.admin.dto.PermissionChangeDto;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.GrantPolicy;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Arrays;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * 部门权限矩阵差量保存(permissions-02/03、audit-retention-settings-03)：只校验本次新增，
 * 不可再授但已存在的保留，收回一律允许，无改动 0 写入 0 审计；全部授权按 grant_policy 过滤。
 */
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
    @Mock
    private PermissionChangeAudit changeAudit;

    private DepartmentPermissionAdminService service;
    private final UUID departmentId = UUID.randomUUID();

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
                refreshTokenRepo,
                changeAudit);
    }

    @ParameterizedTest
    @EnumSource(value = GrantPolicy.class, names = {"INDIVIDUAL_ONLY", "SUPERADMIN_ONLY"})
    void newlyAddedIndividualOrSuperAdminOnlyCodeIsRejectedWithoutAnyWrite(GrantPolicy policy) {
        givenDepartment();
        Permission risky = permission("audit_log:view", policy);
        when(departmentPermissionRepo.findPermissionCodesByDepartmentId(departmentId))
                .thenReturn(List.of("employee:view"));
        when(permissionRepo.findByCodeIn(anyCollection())).thenReturn(List.of(risky));

        ApiException exception = assertThrows(ApiException.class,
                () -> service.setDepartmentPermissions(departmentId,
                        List.of("employee:view", "audit_log:view")));

        assertEquals(ErrorCode.BUSINESS, exception.getCode());
        assertThat(exception.getMessage()).contains("audit_log:view");
        verify(departmentPermissionRepo, never()).insertGrants(any(), anyCollection(), any());
        verify(departmentPermissionRepo, never()).deleteGrants(any(), anyCollection());
        verifyNoInteractions(changeAudit);
    }

    @Test
    void existingNonGrantableCodeIsKeptAndOnlyTheNewCodeIsInsertedAndAudited() {
        givenDepartment();
        // 财务部历史上持有的「不可再授」码原样保留：不校验、不删除(permissions-02 根因)。
        when(departmentPermissionRepo.findPermissionCodesByDepartmentId(departmentId))
                .thenReturn(List.of("finance:view:all", "legacy:individual_only"));
        Permission added = permission("settlement_method:view", GrantPolicy.NORMAL);
        when(permissionRepo.findByCodeIn(anyCollection())).thenReturn(List.of(added));
        when(employeeRepo.findUserIdsByDepartmentSubtree(departmentId)).thenReturn(List.of());

        PermissionChangeDto change = service.setDepartmentPermissions(departmentId, List.of(
                "finance:view:all", "legacy:individual_only", "settlement_method:view"));

        assertEquals(List.of("settlement_method:view"), change.added());
        assertThat(change.removed()).isEmpty();
        verify(departmentPermissionRepo).insertGrants(eq(departmentId),
                eq(Set.of("settlement_method:view")), any());
        verify(departmentPermissionRepo, never()).deleteGrants(any(), anyCollection());
        verify(changeAudit).record(eq("department_permission_change"), eq("departments"),
                eq(departmentId.toString()), eq(Set.of("settlement_method:view")), eq(Set.of()), any());
    }

    @Test
    void revokingAnySuperAdminOnlyCodeIsAllowed() {
        givenDepartment();
        Permission legacy = permission("authorization:manage", GrantPolicy.SUPERADMIN_ONLY);
        when(departmentPermissionRepo.findPermissionCodesByDepartmentId(departmentId))
                .thenReturn(List.of("employee:view", "authorization:manage"));
        when(permissionRepo.findByCodeIn(anyCollection())).thenReturn(List.of(legacy));
        when(employeeRepo.findUserIdsByDepartmentSubtree(departmentId)).thenReturn(List.of());

        PermissionChangeDto change = service.setDepartmentPermissions(
                departmentId, List.of("employee:view"));

        assertEquals(List.of("authorization:manage"), change.removed());
        verify(departmentPermissionRepo).deleteGrants(departmentId, List.of(legacy.getId()));
        verify(departmentPermissionRepo, never()).insertGrants(any(), anyCollection(), any());
    }

    @Test
    void savingLocksTheDepartmentRowBeforeReadingTheCurrentMatrix() {
        givenDepartment();
        when(departmentPermissionRepo.findPermissionCodesByDepartmentId(departmentId))
                .thenReturn(List.of("employee:view"));

        service.setDepartmentPermissions(departmentId, List.of("employee:view"));

        var order = org.mockito.Mockito.inOrder(departmentPermissionRepo);
        order.verify(departmentPermissionRepo).lockLiveDepartment(departmentId);
        order.verify(departmentPermissionRepo).findPermissionCodesByDepartmentId(departmentId);
    }

    @Test
    void writeCountThatDisagreesWithTheDeltaIsRejectedWithoutAudit() {
        givenDepartment();
        when(departmentPermissionRepo.findPermissionCodesByDepartmentId(departmentId))
                .thenReturn(List.of("employee:view"));
        when(permissionRepo.findByCodeIn(anyCollection()))
                .thenReturn(List.of(permission("goods:view", GrantPolicy.NORMAL)));
        // 有人绕过本服务先插了同一行：ON CONFLICT DO NOTHING 实际写入 0 行。
        org.mockito.Mockito.doReturn(0).when(departmentPermissionRepo).insertGrants(any(), anyCollection(), any());

        ApiException exception = assertThrows(ApiException.class, () -> service.setDepartmentPermissions(
                departmentId, List.of("employee:view", "goods:view")));

        assertEquals(ErrorCode.CONFLICT, exception.getCode());
        verifyNoInteractions(changeAudit);
    }

    @Test
    void missingOrDeletedDepartmentIsNotFound() {
        when(departmentPermissionRepo.lockLiveDepartment(departmentId)).thenReturn(Optional.empty());

        ApiException exception = assertThrows(ApiException.class,
                () -> service.setDepartmentPermissions(departmentId, List.of()));

        assertEquals(ErrorCode.NOT_FOUND, exception.getCode());
    }

    @Test
    void unchangedMatrixWritesNothingAndRecordsNoAudit() {
        givenDepartment();
        when(departmentPermissionRepo.findPermissionCodesByDepartmentId(departmentId))
                .thenReturn(List.of("employee:view", "finance:view:all"));

        PermissionChangeDto change = service.setDepartmentPermissions(
                departmentId, List.of("finance:view:all", "employee:view"));

        assertThat(change.isEmpty()).isTrue();
        verify(permissionRepo, never()).findByCodeIn(anyCollection());
        verify(departmentPermissionRepo, never()).insertGrants(any(), anyCollection(), any());
        verify(departmentPermissionRepo, never()).deleteGrants(any(), anyCollection());
        verifyNoInteractions(changeAudit, refreshTokenRepo, employeeRepo);
    }

    @Test
    void grantAllSkipsBulkExcludedIndividualSuperAdminAndAlreadyHeldCodes() {
        givenDepartment();
        when(departmentPermissionRepo.findPermissionCodesByDepartmentId(departmentId))
                .thenReturn(List.of("goods:view"));
        when(permissionRepo.findAll()).thenReturn(List.of(
                permission("goods:view", GrantPolicy.NORMAL),
                permission("goods:edit", GrantPolicy.NORMAL),
                permission("payroll:export", GrantPolicy.NON_DELEGABLE),
                permission("goods:view:all", GrantPolicy.BULK_EXCLUDED, GrantPolicy.NON_DELEGABLE),
                permission("goods:price:view", GrantPolicy.BULK_EXCLUDED),
                permission("stock:balance:adjust", GrantPolicy.INDIVIDUAL_ONLY),
                permission("authorization:manage", GrantPolicy.SUPERADMIN_ONLY)));
        when(employeeRepo.findUserIdsByDepartmentSubtree(departmentId)).thenReturn(List.of());

        PermissionChangeDto change = service.grantAll(departmentId, PermissionBulkScopeDto.everything());

        assertEquals(List.of("goods:edit", "payroll:export"), change.added());
        verify(departmentPermissionRepo).insertGrants(eq(departmentId),
                eq(Set.of("goods:edit", "payroll:export")), any());
    }

    @Test
    void catalogPublishesGrantPolicyAndBaselineFlags() {
        Permission view = permission("goods:view", GrantPolicy.NORMAL);
        view.setActionType("VIEW");
        view.setDescription("查看货品主档");
        Permission all = permission("goods:view:all", GrantPolicy.BULK_EXCLUDED, GrantPolicy.NON_DELEGABLE);
        Permission notice = permission("notice:read", GrantPolicy.NORMAL);
        notice.setBaseline(true);
        when(permissionRepo.findAll()).thenReturn(List.of(view, all, notice));

        var items = service.catalog().stream().flatMap(group -> group.permissions().stream()).toList();

        assertThat(items).anySatisfy(item -> {
            assertEquals("goods:view:all", item.code());
            assertEquals(List.of("BULK_EXCLUDED", "NON_DELEGABLE"), item.grantPolicy());
        });
        assertThat(items).anySatisfy(item -> {
            assertEquals("notice:read", item.code());
            assertThat(item.baseline()).isTrue();
        });
    }

    @Test
    void baselineRejectsBulkExcludedCodeAndWritesOnlyTheDifference() {
        when(permissionRepo.findBaselineCodes()).thenReturn(List.of("notice:read", "visitor:host_confirm"));
        Permission price = permission("goods:price:view", GrantPolicy.BULK_EXCLUDED);
        when(permissionRepo.findByCodeIn(anyCollection())).thenReturn(List.of(price));

        ApiException exception = assertThrows(ApiException.class, () -> service.setBaseline(
                List.of("notice:read", "visitor:host_confirm", "goods:price:view")));
        assertEquals(ErrorCode.BUSINESS, exception.getCode());
        verify(permissionRepo, never()).updateBaseline(anyCollection(), eq(true), any());

        PermissionChangeDto removal = service.setBaseline(List.of("notice:read"));
        assertEquals(List.of("visitor:host_confirm"), removal.removed());
        verify(permissionRepo).updateBaseline(eq(Set.of("visitor:host_confirm")), eq(false), any());
        verify(changeAudit).record(eq("permission_baseline_change"), anyString(), anyString(),
                eq(Set.of()), eq(Set.of("visitor:host_confirm")), any());
    }

    private void givenDepartment() {
        // 保存先锁部门行(不存在即 404)；部门行已锁时真实写入行数等于算出的差量。
        when(departmentPermissionRepo.lockLiveDepartment(departmentId))
                .thenReturn(Optional.of(departmentId.toString()));
        org.mockito.Mockito.lenient().when(departmentPermissionRepo.insertGrants(any(), anyCollection(), any()))
                .thenAnswer(invocation -> ((java.util.Collection<?>) invocation.getArgument(1)).size());
        org.mockito.Mockito.lenient().when(departmentPermissionRepo.deleteGrants(any(), anyCollection()))
                .thenAnswer(invocation -> ((java.util.Collection<?>) invocation.getArgument(1)).size());
    }

    private static Permission permission(String code, GrantPolicy... policy) {
        Permission permission = new Permission();
        permission.setId(UUID.randomUUID());
        permission.setCode(code);
        permission.setName(code);
        permission.setModule("基础资料");
        permission.setCategory("货品资料");
        permission.setGrantPolicy(Arrays.stream(policy).map(Enum::name).toArray(String[]::new));
        return permission;
    }
}
