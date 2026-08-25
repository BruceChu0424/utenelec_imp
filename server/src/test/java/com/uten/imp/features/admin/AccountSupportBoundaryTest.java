package com.uten.imp.features.admin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.dto.ProvisionCandidateDto;
import com.uten.imp.features.admin.dto.UserSummary;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSensitive;
import com.uten.imp.features.org.employee.EmployeeSensitiveRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TemporaryPasswordGenerator;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.InOrder;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.domain.Pageable;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class AccountSupportBoundaryTest {

    @Mock
    private UserAccountRepository users;
    @Mock
    private EmployeeRepository employees;
    @Mock
    private EmployeeSensitiveRepository sensitive;
    @Mock
    private RefreshTokenRepository refreshTokens;
    @Mock
    private UserRoleRepository userRoles;
    @Mock
    private PasswordEncoder encoder;
    @Mock
    private TemporaryPasswordGenerator passwords;
    @Mock
    private TxSessionVars tx;
    @Mock
    private SecurityContextCurrentUser currentUser;
    @Mock
    private AdminAccountLifecycleLock accountLifecycle;

    @Test
    void accountSummaryExposesAuthoritativeEmployeeStatus() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UUID employeeId = UUID.randomUUID();
        UserAccount account = new UserAccount();
        account.setEmployeeId(employeeId);
        account.setStatus("disabled");
        Employee employee = new Employee();
        employee.setId(employeeId);
        employee.setStatus("resigned");
        employee.setCode("EMP-RESIGNED");
        employee.setFullName("离职员工");
        when(users.findByEmployeeId(employeeId)).thenReturn(Optional.of(account));
        when(employees.findById(employeeId)).thenReturn(Optional.of(employee));
        when(userRoles.findRoleCodesByUserId(account.getId())).thenReturn(List.of());

        UserSummary summary = service(support).getByEmployeeId(employeeId);

        assertEquals("disabled", summary.getStatus());
        assertEquals("resigned", summary.getEmployeeStatus());
        assertFalse(summary.isCurrentEmployee());
        assertEquals(employeeId, summary.getEmployeeId());
    }

    @Test
    void routineSupportCannotOperateOnItself() {
        AdminUserSupport support = new AdminUserSupport(users, currentUser);
        UserAccount target = new UserAccount();
        when(currentUser.requireId()).thenReturn(target.getId());

        assertThrows(
                ApiException.class,
                () -> support.requireAccountSupportTarget(target));
    }

    @Test
    void routineSupportCannotOperateOnSuperAdministrator() {
        AdminUserSupport support = new AdminUserSupport(users, currentUser);
        UserAccount target = new UserAccount();
        target.setSuperAdmin(true);

        assertThrows(
                ApiException.class,
                () -> support.requireAccountSupportTarget(target));
        verify(currentUser, never()).requireId();
    }

    @Test
    void resetUsesRandomTemporaryPasswordAndRevokesAllSessions() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setEmployeeId(UUID.randomUUID());
        UUID targetId = target.getId();
        Employee employee = activeEmployee();
        lock(target, employee);
        when(support.requireCurrentUser()).thenReturn(actor());
        when(passwords.generate()).thenReturn("Random-Temp-42!Value");
        when(encoder.encode("Random-Temp-42!Value")).thenReturn("argon2-hash");
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        String temporaryPassword = service(support).resetPassword(targetId, null);

        assertEquals("Random-Temp-42!Value", temporaryPassword);
        assertEquals("argon2-hash", target.getPasswordHash());
        assertTrue(target.isMustChangePassword());
        // V297：管理员重置的临时密码带 72h 有效期
        assertNotNull(target.getTempPasswordExpiresAt());
        assertTrue(target.getTempPasswordExpiresAt().isAfter(OffsetDateTime.now()));
        assertEquals("active", target.getStatus());
        verify(support).requireAccountSupportTarget(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
    }

    @Test
    void resetUsesAdminChosenPasswordAfterStrengthValidation() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setEmployeeId(UUID.randomUUID());
        target.setLoginAccount("13800138000");
        UUID targetId = target.getId();
        lock(target, activeEmployee());
        when(support.requireCurrentUser()).thenReturn(actor());
        when(encoder.encode("Uten2026safe")).thenReturn("argon2-hash");
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        String issued = service(support).resetPassword(targetId, " Uten2026safe ");

        // 自定义值 trim 后入库；不走随机生成器
        assertEquals("Uten2026safe", issued);
        assertEquals("argon2-hash", target.getPasswordHash());
        verify(passwords, never()).generate();
    }

    @Test
    void resetRejectsWeakAdminChosenPasswords() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setLoginAccount("13800138000");
        UUID targetId = target.getId();
        lock(target, activeEmployee());

        for (String weak : new String[]{
                "short1",               // 太短
                "onlyletters",          // 缺数字
                "12345678",             // 缺字母
                "has space1",           // 含空白
                "13800138000"}) {       // 与登录账号相同
            assertThrows(
                    ApiException.class,
                    () -> service(support).resetPassword(targetId, weak),
                    "应拒绝弱临时密码: " + weak);
        }
        // 全部在校验阶段失败，不落库、不踢会话
        verify(users, never()).save(target);
        verify(refreshTokens, never()).revokeAllByUserId(targetId);
    }

    @Test
    void resetDoesNotSilentlyEnableADisabledAccount() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setStatus("disabled");
        target.setRemoteAccess(true);
        target.setSuperAdmin(true);
        UUID targetId = target.getId();
        lock(target, resignedEmployee());
        when(support.requireCurrentUser()).thenReturn(actor());
        when(passwords.generate()).thenReturn("Random-Temp-42!Value");
        when(encoder.encode("Random-Temp-42!Value")).thenReturn("argon2-hash");
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        service(support).resetPassword(targetId, null);

        assertEquals("disabled", target.getStatus());
        assertTrue(target.isRemoteAccess());
        assertTrue(target.isSuperAdmin());
        verify(accountLifecycle, never()).requireCurrentEmployee(any());
    }

    @Test
    void disablingAccountInvalidatesAccessAndRefreshTokens() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setStatus("active");
        UUID targetId = target.getId();
        lock(target, activeEmployee());
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        service(support).setStatus(targetId, "disabled");

        assertEquals("disabled", target.getStatus());
        verify(users).save(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
    }

    @Test
    void convertingTemporaryLockToManualLockInvalidatesAllSessions() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setStatus("locked");
        target.setLockedUntil(OffsetDateTime.now().plusMinutes(10));
        UUID targetId = target.getId();
        lock(target, activeEmployee());
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        service(support).setStatus(targetId, "locked");

        assertEquals("locked", target.getStatus());
        assertNull(target.getLockedUntil());
        verify(users).save(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
    }

    @Test
    void reactivatingAccountClearsTemporaryLockAndInvalidatesAllSessions() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setEmployeeId(UUID.randomUUID());
        target.setStatus("disabled");
        target.setFailedAttempts(4);
        target.setLockedUntil(OffsetDateTime.now().plusMinutes(10));
        UUID targetId = target.getId();
        lock(target, activeEmployee());
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        service(support).setStatus(targetId, "active");

        assertEquals("active", target.getStatus());
        assertEquals(0, target.getFailedAttempts());
        assertNull(target.getLockedUntil());
        verify(users).save(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
    }

    @Test
    void repeatedAccountStatusIsANoOp() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setStatus("disabled");
        UUID targetId = target.getId();
        lock(target, activeEmployee());

        service(support).setStatus(targetId, "disabled");

        verify(users, never()).save(target);
        verify(users, never()).bumpAuthVersion(targetId);
        verify(refreshTokens, never()).revokeAllByUserId(targetId);
    }

    @Test
    void resignedDisabledAccountCannotBecomeManualLocked() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setStatus("disabled");
        UUID targetId = target.getId();
        AdminAccountLifecycleLock.LockedTarget locked =
                lock(target, resignedEmployee());
        doThrow(new ApiException(
                com.uten.imp.common.web.ErrorCode.CONFLICT,
                "离职员工必须先完成复职流程"))
                .when(accountLifecycle).requireCurrentEmployee(locked);

        assertThrows(ApiException.class,
                () -> service(support).setStatus(targetId, "locked"));

        assertEquals("disabled", target.getStatus());
        verify(users, never()).save(target);
        verify(users, never()).bumpAuthVersion(targetId);
        verify(refreshTokens, never()).revokeAllByUserId(targetId);
    }

    @Test
    void unlockInvalidatesPreviouslyIssuedAccessToken() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setEmployeeId(UUID.randomUUID());
        target.setStatus("locked");
        target.setFailedAttempts(3);
        UUID targetId = target.getId();
        lock(target, activeEmployee());
        when(users.bumpAuthVersion(targetId)).thenReturn(1);

        service(support).unlock(targetId);

        assertEquals("active", target.getStatus());
        assertEquals(0, target.getFailedAttempts());
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
    }

    @Test
    void unlockingCleanActiveAccountIsANoOp() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setStatus("active");
        UUID targetId = target.getId();
        lock(target, activeEmployee());

        service(support).unlock(targetId);

        verify(accountLifecycle).requireCurrentEmployee(any());
        verify(users, never()).save(target);
        verify(users, never()).bumpAuthVersion(targetId);
        verify(refreshTokens, never()).revokeAllByUserId(targetId);
    }

    @Test
    void remoteAccessChangeRevokesEveryRefreshSession() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setRemoteAccess(false);
        target.setStatus("active");
        AuthUser actor = new AuthUser(
                UUID.randomUUID(),
                UUID.randomUUID(),
                "super-admin",
                java.util.Set.of(),
                java.util.Set.of(),
                false,
                true,
                true);
        UUID targetId = target.getId();
        lock(target, activeEmployee());
        when(support.requireCurrentUser()).thenReturn(actor);

        service(support).setRemoteAccess(targetId, true);

        assertTrue(target.isRemoteAccess());
        InOrder order = inOrder(users, refreshTokens);
        order.verify(users).save(target);
        order.verify(refreshTokens).revokeAllByUserId(targetId);
    }

    @Test
    void repeatedRemoteAccessValueDoesNotRevokeAnUnchangedSession() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        UserAccount target = new UserAccount();
        target.setRemoteAccess(true);
        target.setStatus("active");
        UUID targetId = target.getId();
        lock(target, activeEmployee());

        service(support).setRemoteAccess(targetId, true);

        verify(users, never()).save(target);
        verify(refreshTokens, never()).revokeAllByUserId(targetId);
    }

    private Employee activeEmployee() {
        Employee employee = new Employee();
        employee.setStatus("active");
        return employee;
    }

    private Employee resignedEmployee() {
        Employee employee = new Employee();
        employee.setStatus("resigned");
        return employee;
    }

    @Test
    void provisionCandidatesReturnMinimalRowsWithCredentialFlags() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        Employee zhang = new Employee();
        zhang.setCode("UT0001");
        zhang.setFullName("张三");
        UUID zhangId = zhang.getId();
        EmployeeSensitive zhangSensitive = new EmployeeSensitive();
        zhangSensitive.setEmployeeId(zhangId);
        zhangSensitive.setPhoneEnc("enc-phone");
        zhangSensitive.setIdCardEnc("enc-id");
        when(employees.findProvisionCandidates(eq(""), any(Pageable.class)))
                .thenReturn(List.of(zhang));
        when(sensitive.findAllByEmployeeIdIn(any())).thenReturn(List.of(zhangSensitive));

        List<ProvisionCandidateDto> rows = service(support).provisionCandidates(null);

        assertEquals(1, rows.size());
        assertEquals(zhangId, rows.get(0).employeeId());
        assertEquals("张三", rows.get(0).name());
        assertTrue(rows.get(0).hasPhone());
        assertTrue(rows.get(0).hasIdCard());
    }

    @Test
    void provisionCandidatesFlagMissingPhoneOrIdCardWithoutDecrypting() {
        AdminUserSupport support = org.mockito.Mockito.mock(AdminUserSupport.class);
        Employee li = new Employee();
        li.setCode("UT0002");
        li.setFullName("李四");
        // 无敏感记录：hasPhone / hasIdCard 均为 false，前端据此置灰
        when(employees.findProvisionCandidates(eq("李"), any(Pageable.class)))
                .thenReturn(List.of(li));
        when(sensitive.findAllByEmployeeIdIn(any())).thenReturn(List.of());

        List<ProvisionCandidateDto> rows = service(support).provisionCandidates("李");

        assertEquals(1, rows.size());
        assertFalse(rows.get(0).hasPhone());
        assertFalse(rows.get(0).hasIdCard());
    }

    /** 审计写入用的操作人（resetPassword 等敏感操作的显式审计）。 */
    private AuthUser actor() {
        return new AuthUser(
                UUID.randomUUID(),
                UUID.randomUUID(),
                "hr-support",
                java.util.Set.of(),
                java.util.Set.of(),
                false,
                false,
                true);
    }

    private UserAccountAdminService service(AdminUserSupport support) {
        return new UserAccountAdminService(
                users,
                employees,
                sensitive,
                refreshTokens,
                userRoles,
                encoder,
                passwords,
                tx,
                support,
                accountLifecycle,
                mock(com.uten.imp.audit.AuditService.class));
    }

    private AdminAccountLifecycleLock.LockedTarget lock(
            UserAccount account, Employee employee) {
        AdminAccountLifecycleLock.LockedTarget locked =
                new AdminAccountLifecycleLock.LockedTarget(employee, account);
        when(accountLifecycle.lock(account.getId())).thenReturn(locked);
        return locked;
    }
}
