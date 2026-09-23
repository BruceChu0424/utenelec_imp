package com.uten.imp.features.admin;

import com.uten.imp.application.port.AccountSecurityNoticePort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.ProvisionCandidateDto;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.AuthSessionService;
import com.uten.imp.features.auth.CredentialIssuancePolicy;
import com.uten.imp.features.auth.PermissionResolver;
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
import static org.mockito.ArgumentMatchers.contains;
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
    @Mock
    private AuthSessionService sessions;
    @Mock
    private SystemSettingsService settings;
    @Mock
    private AccountSecurityNoticePort accountNotice;
    @Mock
    private AuditService audit;
    @Mock
    private PermissionResolver permissionResolver;
    @Mock
    private org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate jdbc;

    /** 高危判定走真实策略; 权限目录的 high_risk 标记由桩按「持有的权限里有没有付款审批」回答。 */
    private CredentialIssuancePolicy credentialPolicy() {
        return new CredentialIssuancePolicy(jdbc, permissionResolver, currentUser);
    }

    private void highRiskCatalogContains(String code) {
        when(jdbc.queryForObject(any(String.class),
                any(org.springframework.jdbc.core.namedparam.SqlParameterSource.class), eq(Boolean.class)))
                .thenAnswer(invocation -> {
                    var params = (org.springframework.jdbc.core.namedparam.MapSqlParameterSource)
                            invocation.getArgument(1);
                    return ((java.util.Collection<?>) params.getValue("held")).contains(code);
                });
    }

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
        AdminUserSupport support = new AdminUserSupport(users, currentUser, credentialPolicy());
        UserAccount target = new UserAccount();
        when(currentUser.requireId()).thenReturn(target.getId());

        assertThrows(
                ApiException.class,
                () -> support.requireAccountSupportTarget(target));
    }

    @Test
    void routineSupportCannotOperateOnSuperAdministrator() {
        AdminUserSupport support = new AdminUserSupport(users, currentUser, credentialPolicy());
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
        when(settings.readInt(SystemSettingKey.TEMP_PASSWORD_TTL_HOURS)).thenReturn(24);

        String temporaryPassword = service(support).resetPassword(targetId);

        assertEquals("Random-Temp-42!Value", temporaryPassword);
        assertEquals("argon2-hash", target.getPasswordHash());
        assertTrue(target.isMustChangePassword());
        // 临时密码有效期读系统设置「临时密码有效期」(这里设成 24 小时)
        assertNotNull(target.getTempPasswordExpiresAt());
        assertTrue(target.getTempPasswordExpiresAt().isAfter(OffsetDateTime.now().plusHours(23)));
        assertTrue(target.getTempPasswordExpiresAt().isBefore(OffsetDateTime.now().plusHours(25)));
        assertEquals("active", target.getStatus());
        verify(support).requirePasswordResetAllowed(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
        verify(sessions).revokeAllForUser(targetId, AuthSessionService.REASON_PASSWORD_RESET);
        // security-02: 目标本人收到通知, 并留下语义化业务事件 (正文不含临时密码)
        verify(accountNotice).notifyAccountHolder(eq(targetId), eq("你的登录密码已被重置"),
                org.mockito.ArgumentMatchers.argThat(body -> !body.contains("Random-Temp-42!Value")));
        verify(audit).logCommitted(any(), any(), eq("password_temporary_reset"), eq("user"),
                eq(targetId.toString()), eq("success"));
    }

    @Test
    void highRiskTargetCanOnlyBeResetBySuperAdministrator() {
        AdminUserSupport support = new AdminUserSupport(users, currentUser, credentialPolicy());
        UserAccount target = new UserAccount();
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        when(currentUser.get()).thenReturn(Optional.of(actor()));
        // 付款审批人: 账号支持人员重置后拿到明文临时密码就能冒充他付款 (security-02 评审补例)
        when(permissionResolver.permsOf(target))
                .thenReturn(java.util.Set.of("notice:read", "finance_payment:approve"));
        highRiskCatalogContains("finance_payment:approve");

        ApiException denied = assertThrows(ApiException.class,
                () -> support.requirePasswordResetAllowed(target));

        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
    }

    @Test
    void superAdministratorMayResetHighRiskTarget() {
        AdminUserSupport support = new AdminUserSupport(users, currentUser, credentialPolicy());
        UserAccount target = new UserAccount();
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        when(currentUser.get()).thenReturn(Optional.of(superActor()));

        support.requirePasswordResetAllowed(target);

        verify(permissionResolver, never()).permsOf(any());
    }

    @Test
    void ordinaryTargetMayBeResetByAccountSupport() {
        AdminUserSupport support = new AdminUserSupport(users, currentUser, credentialPolicy());
        UserAccount target = new UserAccount();
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        when(currentUser.get()).thenReturn(Optional.of(actor()));
        when(permissionResolver.permsOf(target)).thenReturn(java.util.Set.of("notice:read", "expense:apply"));
        highRiskCatalogContains("finance_payment:approve");

        support.requirePasswordResetAllowed(target);
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
        when(settings.readInt(SystemSettingKey.TEMP_PASSWORD_TTL_HOURS)).thenReturn(72);

        service(support).resetPassword(targetId);

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
        when(support.requireCurrentUser()).thenReturn(actor());

        service(support).setStatus(targetId, "disabled");

        assertEquals("disabled", target.getStatus());
        verify(users).save(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
        verify(sessions).revokeAllForUser(targetId, AuthSessionService.REASON_ACCOUNT_STATUS);
        verify(audit).logCommitted(any(), any(), eq("account_disable"), eq("user"),
                eq(targetId.toString()), eq("success"));
        verify(accountNotice).notifyAccountHolder(eq(targetId), eq("你的登录账号已被停用"), contains("停用"));
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
        when(support.requireCurrentUser()).thenReturn(actor());

        service(support).setStatus(targetId, "locked");

        assertEquals("locked", target.getStatus());
        assertNull(target.getLockedUntil());
        verify(users).save(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
        verify(audit).logCommitted(any(), any(), eq("account_lock"), eq("user"),
                eq(targetId.toString()), eq("success"));
        verify(accountNotice).notifyAccountHolder(eq(targetId), eq("你的登录账号已被锁定"), any());
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
        when(support.requireCurrentUser()).thenReturn(actor());

        service(support).setStatus(targetId, "active");

        assertEquals("active", target.getStatus());
        assertEquals(0, target.getFailedAttempts());
        assertNull(target.getLockedUntil());
        verify(users).save(target);
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
        verify(audit).logCommitted(any(), any(), eq("account_enable"), eq("user"),
                eq(targetId.toString()), eq("success"));
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
        verify(accountNotice, never()).notifyAccountHolder(any(), any(), any());
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
        when(support.requireCurrentUser()).thenReturn(actor());

        service(support).unlock(targetId);

        assertEquals("active", target.getStatus());
        assertEquals(0, target.getFailedAttempts());
        verify(users).bumpAuthVersion(targetId);
        verify(refreshTokens).revokeAllByUserId(targetId);
        verify(audit).logCommitted(any(), any(), eq("account_unlock"), eq("user"),
                eq(targetId.toString()), eq("success"));
        verify(accountNotice).notifyAccountHolder(eq(targetId), eq("你的登录账号已解锁"), any());
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
        InOrder order = inOrder(users, refreshTokens, sessions);
        order.verify(users).save(target);
        order.verify(refreshTokens).revokeAllByUserId(targetId);
        order.verify(sessions).revokeAllForUser(targetId, AuthSessionService.REASON_REMOTE_ACCESS);
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

    private AuthUser superActor() {
        return new AuthUser(
                UUID.randomUUID(),
                UUID.randomUUID(),
                "super-admin",
                java.util.Set.of(),
                java.util.Set.of(),
                false,
                true,
                true);
    }

    /** 审计写入用的操作人（resetPassword 等敏感操作的显式审计）。非超管的账号支持人员。 */
    private AuthUser actor() {
        return new AuthUser(
                UUID.randomUUID(),
                UUID.randomUUID(),
                "hr-support",
                java.util.Set.of(),
                java.util.Set.of(),
                false,
                true,
                false);
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
                audit,
                sessions,
                settings,
                accountNotice);
    }

    private AdminAccountLifecycleLock.LockedTarget lock(
            UserAccount account, Employee employee) {
        AdminAccountLifecycleLock.LockedTarget locked =
                new AdminAccountLifecycleLock.LockedTarget(employee, account);
        when(accountLifecycle.lock(account.getId())).thenReturn(locked);
        return locked;
    }
}
