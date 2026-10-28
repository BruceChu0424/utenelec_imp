package com.uten.imp.features.org.employee;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.dto.EmployeeAccountReadiness;
import com.uten.imp.features.org.employee.dto.EmployeeOnboardingResult;
import com.uten.imp.features.org.employee.dto.IdNumberIssue;
import com.uten.imp.features.org.employee.dto.OnboardingRequest;
import com.uten.imp.features.org.position.Position;
import com.uten.imp.features.org.position.PositionRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TemporaryPasswordGenerator;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class EmployeeOnboardingServiceTest {

    @Mock private EmployeeRepository empRepo;
    @Mock private EmployeeSensitiveRepository sensitiveRepo;
    @Mock private EmployeePiiWriter piiWriter;
    @Mock private EmployeeExistingIdentityGuard existingIdentityGuard;
    @Mock private EmployeeCodeAllocator employeeCodeAllocator;
    @Mock private EmployeeNameReviewPolicy employeeNameReviewPolicy;
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
    @Mock private PasswordEncoder passwordEncoder;
    @Mock private MasterCodeService masterCodeService;
    @Mock private TxSessionVars tx;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private EmployeeQueryService queryService;
    @Mock private EmployeeSensitiveWritePolicy sensitiveWritePolicy;
    @Mock private com.uten.imp.features.admin.systemsetting.SystemSettingsService settings;
    @Mock private com.uten.imp.features.auth.CredentialIssuancePolicy credentialIssuance;
    @Mock private TemporaryPasswordGenerator passwordGenerator;
    @Mock private com.uten.imp.features.auth.model.RefreshTokenRepository refreshTokenRepo;
    @Mock private com.uten.imp.features.auth.AuthSessionService sessions;
    @Mock private Query positionNameLockQuery;
    @Mock private Query dataScopesQuery;
    @Mock private Query templateBindingsQuery;
    @Mock private Query templateAppliesQuery;

    @InjectMocks
    private EmployeeOnboardingService service;

    @BeforeEach
    void authorizedCredentialIssuer() {
        org.mockito.Mockito.lenient().when(currentUser.get()).thenReturn(Optional.of(
                new com.uten.imp.security.AuthUser(UUID.randomUUID(), UUID.randomUUID(), "fixture-admin",
                        java.util.Set.of("employee:create", "employee:pii:edit", "account:support"), false, true, true)));
    }

    @ParameterizedTest(name = "onboarding requires {0}, openAccount={2}, value={1}")
    @MethodSource("missingPrimaryIdentityRequests")
    void optionalSensitiveColumnsDoNotPermitIncompleteOnboarding(
            String field, String missing, boolean openAccount) {
        OnboardingRequest valid = request(UUID.randomUUID(), null, null, "IGNORED");
        OnboardingRequest.Profile p = valid.profile();
        OnboardingRequest.Profile incomplete = new OnboardingRequest.Profile(
                p.code(), p.fullName(), p.gender(),
                "idType".equals(field) ? missing : p.idType(),
                "idNumber".equals(field) ? missing : p.idNumber(), p.birthDate(),
                "phone".equals(field) ? missing : p.phone(), p.email(), p.ethnicity(),
                p.politicalStatus(), p.maritalStatus(), p.hujiAddress(), p.residenceAddress());
        OnboardingRequest input = new OnboardingRequest(
                incomplete, valid.employment(), valid.compensation(), valid.contract(),
                valid.emergencyContacts(), valid.certificates(), valid.educations(),
                new OnboardingRequest.Account("custom.hr_1", openAccount));

        ApiException rejected = assertThrows(ApiException.class, () -> service.onboard(input));

        assertEquals(ErrorCode.VALIDATION_FAILED, rejected.getCode());
        verifyNoInteractions(empRepo, sensitiveRepo, piiWriter, compensationRepo, contractRepo,
                emergencyRepo, credentialRepo, educationRepo, historyRepo, deptRepo, positionRepo,
                userRepo, masterCodeService, passwordEncoder, passwordGenerator,
                credentialIssuance, queryService, refreshTokenRepo, sessions);
    }

    private static Stream<Arguments> missingPrimaryIdentityRequests() {
        return Stream.of("idType", "idNumber", "phone").flatMap(field ->
                blankPrimaryValues().flatMap(value -> Stream.of(true, false)
                        .map(openAccount -> Arguments.of(field, value, openAccount))));
    }

    private static Stream<String> blankPrimaryValues() {
        return Stream.of(null, "", " \t ");
    }

    @ParameterizedTest
    @MethodSource("blankPrimaryValues")
    void provisioningRequiresAStoredPhoneBeforeCredentialsAreIssued(String savedPhone) {
        Employee employee = new Employee();
        employee.setStatus("active");
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setEmployeeId(employee.getId());
        sensitive.setPhoneEnc("phone-cipher");
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(sensitive));
        when(tx.decrypt("phone-cipher")).thenReturn(savedPhone);

        ApiException rejected = assertThrows(ApiException.class,
                () -> service.provisionAccount(employee.getId()));

        assertEquals(ErrorCode.VALIDATION_FAILED, rejected.getCode());
        verify(tx, never()).tryDecrypt(any());
        verify(empRepo, never()).save(any(Employee.class));
        verify(userRepo, never()).save(any(UserAccount.class));
        verifyNoInteractions(passwordEncoder, passwordGenerator, credentialIssuance,
                queryService, refreshTokenRepo, sessions);
    }

    @Test
    void aValidPhoneAndExplicitCustomLoginStillProvisionTheRequestedAccount() {
        Department center = managementCenter();
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));
        when(employeeCodeAllocator.nextForNewEmployee(any(UUID.class))).thenReturn("UT0008");
        OnboardingRequest valid = request(center.getId(), null, null, "IGNORED");
        OnboardingRequest input = new OnboardingRequest(
                valid.profile(), valid.employment(), valid.compensation(), valid.contract(),
                valid.emergencyContacts(), valid.certificates(), valid.educations(),
                new OnboardingRequest.Account("custom.hr_1", true));

        EmployeeOnboardingResult result = service.onboard(input);

        assertEquals("custom.hr_1", result.loginAccount());
        verify(userRepo).existsByLoginAccount("custom.hr_1");
        verify(userRepo, never()).existsByLoginAccount("13800000000");
    }

    @Test
    void alwaysUsesUuidBoundSharedAllocationAndIgnoresClientCode() {
        Department center = managementCenter();
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));
        when(employeeCodeAllocator.nextForNewEmployee(any(UUID.class)))
                .thenReturn("UT0002");

        EmployeeOnboardingResult result = service.onboard(
                request(center.getId(), null, null, "CLIENT-SUPPLIED-CODE"));

        ArgumentCaptor<Employee> employee = ArgumentCaptor.forClass(Employee.class);
        verify(empRepo).save(employee.capture());
        assertEquals("UT0002", employee.getValue().getCode());
        verify(employeeCodeAllocator).nextForNewEmployee(employee.getValue().getId());
        assertEquals("13800000000", result.loginAccount());
    }

    @Test
    void onboardingUsesNormalizedIdLastSixWithExpiryAndForcedChange() {
        Department center = managementCenter();
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));
        when(employeeCodeAllocator.nextForNewEmployee(any(UUID.class))).thenReturn("UT0006");
        when(settings.readInt(com.uten.imp.features.admin.systemsetting.SystemSettingKey.TEMP_PASSWORD_TTL_HOURS))
                .thenReturn(72);
        when(passwordEncoder.encode("31002X")).thenReturn("argon2-encoded");

        EmployeeOnboardingResult result = service.onboard(request(
                center.getId(), null, null, "IGNORED", "身份证", " 11010519491231002x "));

        ArgumentCaptor<UserAccount> account = ArgumentCaptor.forClass(UserAccount.class);
        verify(userRepo).save(account.capture());
        // 新账号沿规范身份证末六位，仍保留 72 小时过期及首登强制改密。
        verify(passwordEncoder).encode("31002X");
        assertEquals("31002X", result.temporaryPassword());
        assertEquals("argon2-encoded", account.getValue().getPasswordHash());
        assertTrue(account.getValue().isMustChangePassword());
        assertEquals("active", account.getValue().getStatus());
        assertTrue(account.getValue().getTempPasswordExpiresAt().isAfter(
                java.time.OffsetDateTime.now().plusHours(71)));
        assertTrue(account.getValue().getTempPasswordExpiresAt().isBefore(
                java.time.OffsetDateTime.now().plusHours(73)));
    }

    @Test
    void provisionedAccountUsesStoredIdentityLastSixWithExpiryAndForcedChange() {
        Employee employee = new Employee();
        employee.setStatus("active");
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setEmployeeId(employee.getId());
        sensitive.setPhoneEnc("phone-cipher");
        sensitive.setIdCardEnc("id-cipher");
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(sensitive));
        when(tx.decrypt("phone-cipher")).thenReturn("13800000001");
        when(tx.tryDecrypt("id-cipher")).thenReturn(Optional.of("CARD-123456"));
        when(settings.readInt(com.uten.imp.features.admin.systemsetting.SystemSettingKey.TEMP_PASSWORD_TTL_HOURS))
                .thenReturn(72);
        when(passwordEncoder.encode("123456")).thenReturn("argon2-provisioned");

        EmployeeOnboardingResult result = service.provisionAccount(employee.getId());

        ArgumentCaptor<UserAccount> account = ArgumentCaptor.forClass(UserAccount.class);
        verify(userRepo).save(account.capture());
        // 仅在实际开户注册时解密证件，候选查询仍不返回 PII。
        verify(tx).tryDecrypt("id-cipher");
        assertEquals("123456", result.temporaryPassword());
        assertEquals("13800000001", result.loginAccount());
        assertEquals("argon2-provisioned", account.getValue().getPasswordHash());
        assertTrue(account.getValue().isMustChangePassword());
        assertTrue(account.getValue().getTempPasswordExpiresAt().isAfter(
                java.time.OffsetDateTime.now().plusHours(71)));
        // 与重置密码同一道闸: 按新账号的有效权限判定是否只有超管能开 (ADR-110)
        verify(credentialIssuance).requireCanIssueCredentials(account.getValue());
    }

    @Test
    void provisioningAHighRiskEmployeeByNonSuperAdminIsRefused() {
        Employee employee = new Employee();
        employee.setStatus("active");
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setEmployeeId(employee.getId());
        sensitive.setPhoneEnc("phone-cipher");
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(sensitive));
        when(tx.decrypt("phone-cipher")).thenReturn("13800000002");
        sensitive.setIdCardEnc("id-cipher");
        when(tx.tryDecrypt("id-cipher")).thenReturn(Optional.of("CARD-123456"));
        when(settings.readInt(com.uten.imp.features.admin.systemsetting.SystemSettingKey.TEMP_PASSWORD_TTL_HOURS))
                .thenReturn(72);
        when(passwordEncoder.encode("123456")).thenReturn("argon2-provisioned");
        org.mockito.Mockito.doThrow(new ApiException(ErrorCode.FORBIDDEN, "只有超级管理员能开通"))
                .when(credentialIssuance).requireCanIssueCredentials(any(UserAccount.class));

        ApiException refused = assertThrows(ApiException.class,
                () -> service.provisionAccount(employee.getId()));

        // 抛错即整个事务回滚 (开号不落库), 明文临时密码不会交出去
        assertEquals(ErrorCode.FORBIDDEN, refused.getCode());
        verify(queryService, never()).detail(employee.getId());
    }

    @Test
    void rejectsSelectedPositionOutsideTheSelectedDepartment() {
        Department center = managementCenter();
        UUID foreignPositionId = UUID.randomUUID();
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));
        when(employeeCodeAllocator.nextForNewEmployee(any(UUID.class))).thenReturn("UT0003");
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
        when(employeeCodeAllocator.nextForNewEmployee(any(UUID.class))).thenReturn("UT0004");
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
        when(employeeCodeAllocator.nextForNewEmployee(any(UUID.class))).thenReturn("UT0005");
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

    @Test
    void onboardingAccountCarriesNoRoleOrPermissionAssignment() {
        // 角色体系已删除(ADR-109)：入职只建登录账号，权限只来自全员基础包与所在部门配置。
        Department center = managementCenter();
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));
        when(employeeCodeAllocator.nextForNewEmployee(any(UUID.class))).thenReturn("UT0007");

        service.onboard(request(center.getId(), null, null, "IGNORED"));

        ArgumentCaptor<UserAccount> account = ArgumentCaptor.forClass(UserAccount.class);
        verify(userRepo).save(account.capture());
        assertEquals("13800000000", account.getValue().getLoginAccount());
        assertFalse(account.getValue().isSuperAdmin());
    }

    @Test
    void idSuffixPasswordPreservesLeadingZeroesAndNormalizesIdentityX() {
        assertEquals(Optional.of("001234"), EmployeeOnboardingService.idSuffixPassword("其他", "AB001234"));
        assertEquals(Optional.of("31002X"),
                EmployeeOnboardingService.idSuffixPassword("身份证", " 11010519491231002x "));
    }

    @Test
    void idSuffixPasswordEmptyForMissingOrShort() {
        for (String value : new String[] {null, "", "  ", "12345"}) {
            assertEquals(Optional.empty(), EmployeeOnboardingService.idSuffixPassword("其他", value));
            assertEquals(Optional.empty(), EmployeeOnboardingService.idSuffixPassword("身份证", value));
        }
        // 18 位但校验不通过的身份证号：仍取档案号码后六位 (只提醒不阻塞)。
        assertEquals(Optional.of("310021"),
                EmployeeOnboardingService.idSuffixPassword("身份证", "110105194912310021"));
        // 不足 18 位但够六位：同样取后六位。
        assertEquals(Optional.of("231002"),
                EmployeeOnboardingService.idSuffixPassword("身份证", "11010519491231002"));
    }

    @Test
    void existingAccountCannotBeReprovisionedOrHaveItsPasswordChanged() {
        Employee employee = new Employee();
        employee.setStatus("active");
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        UserAccount existing = new UserAccount();
        existing.setEmployeeId(employee.getId());
        when(userRepo.findRetainedIdByEmployeeId(employee.getId())).thenReturn(Optional.of(existing.getId()));
        when(userRepo.findByIdForUpdate(existing.getId())).thenReturn(Optional.of(existing));
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class,
                () -> service.provisionAccount(employee.getId())).getCode());
        verify(sensitiveRepo, never()).findByEmployeeId(employee.getId());
        verify(passwordEncoder, never()).encode(anyString());
        verify(userRepo, never()).save(any(UserAccount.class));
    }

    @Test
    void retainedUnopenedAccountReusesIdentityAndRevokesAllOldSessions() {
        Employee employee = new Employee();
        employee.setStatus("active");
        UserAccount retained = new UserAccount();
        retained.setEmployeeId(employee.getId());
        retained.setDeleted(true);
        retained.setStatus("disabled");
        retained.setRemoteAccess(true);
        retained.setFailedAttempts(7);
        retained.setLockedUntil(java.time.OffsetDateTime.now().plusDays(1));
        retained.setDeletedAt(java.time.OffsetDateTime.now().minusDays(1));
        UUID originalId = retained.getId();
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setPhoneEnc("phone-cipher");
        sensitive.setIdCardEnc("id-cipher");
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        when(userRepo.findRetainedIdByEmployeeId(employee.getId())).thenReturn(Optional.of(originalId));
        when(userRepo.findByIdForUpdate(originalId)).thenReturn(Optional.of(retained));
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(sensitive));
        when(tx.decrypt("phone-cipher")).thenReturn("13800000006");
        when(tx.tryDecrypt("id-cipher")).thenReturn(Optional.of("CARD-123456"));
        when(settings.readInt(com.uten.imp.features.admin.systemsetting.SystemSettingKey.TEMP_PASSWORD_TTL_HOURS))
                .thenReturn(72);
        when(passwordEncoder.encode("123456")).thenReturn("argon2-reopened");
        when(entityManager.createNativeQuery("DELETE FROM user_permission_template_bindings WHERE user_id IN (SELECT id FROM users WHERE employee_id=:source)"))
                .thenReturn(templateBindingsQuery);
        when(templateBindingsQuery.setParameter("source",employee.getId())).thenReturn(templateBindingsQuery);
        when(entityManager.createNativeQuery("DELETE FROM permission_template_applies WHERE user_id IN (SELECT id FROM users WHERE employee_id=:source)"))
                .thenReturn(templateAppliesQuery);
        when(templateAppliesQuery.setParameter("source",employee.getId())).thenReturn(templateAppliesQuery);
        when(entityManager.createNativeQuery(org.mockito.ArgumentMatchers.contains("UPDATE user_permission_overrides")))
                .thenReturn(positionNameLockQuery);
        when(positionNameLockQuery.setParameter("source", employee.getId())).thenReturn(positionNameLockQuery);
        when(entityManager.createNativeQuery("DELETE FROM user_data_scopes WHERE user_id=:userId"))
                .thenReturn(dataScopesQuery);
        when(dataScopesQuery.setParameter("userId", originalId)).thenReturn(dataScopesQuery);

        EmployeeOnboardingResult result = service.provisionAccount(employee.getId());

        assertEquals(originalId, retained.getId());
        assertEquals(employee.getId(), retained.getEmployeeId());
        assertFalse(retained.isDeleted());
        assertNull(retained.getDeletedAt());
        assertFalse(retained.isRemoteAccess());
        assertTrue(retained.isMustChangePassword());
        assertEquals("active", retained.getStatus());
        assertEquals("argon2-reopened", retained.getPasswordHash());
        assertEquals("13800000006", retained.getLoginAccount());
        assertEquals("123456", result.temporaryPassword());
        assertEquals(0, retained.getFailedAttempts());
        assertNull(retained.getLockedUntil());
        assertTrue(retained.getTempPasswordExpiresAt().isAfter(java.time.OffsetDateTime.now().plusHours(71)));
        verify(userRepo, never()).save(any(UserAccount.class));
        var order = org.mockito.Mockito.inOrder(empRepo, userRepo, entityManager, credentialIssuance);
        order.verify(empRepo).findByIdForUpdate(employee.getId());
        order.verify(userRepo).findRetainedIdByEmployeeId(employee.getId());
        order.verify(userRepo).findByIdForUpdate(originalId);
        order.verify(userRepo).saveAndFlush(retained);
        order.verify(entityManager).refresh(retained);
        order.verify(credentialIssuance).requireCanIssueCredentials(retained);
        verify(refreshTokenRepo).revokeAllByUserId(originalId);
        verify(positionNameLockQuery).executeUpdate();
        verify(templateBindingsQuery).executeUpdate();
        verify(templateAppliesQuery).executeUpdate();
        verify(dataScopesQuery).executeUpdate();
        verify(sessions).revokeAllForUser(originalId,
                com.uten.imp.features.auth.AuthSessionService.REASON_ACCOUNT_STATUS);
    }

    @Test
    void changedBindingAndSuperAdminRetainedIdentityCannotBeReopened() {
        Employee employee = new Employee();
        employee.setStatus("active");
        UserAccount retained = new UserAccount();
        retained.setEmployeeId(UUID.randomUUID());
        retained.setDeleted(true);
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        when(userRepo.findRetainedIdByEmployeeId(employee.getId())).thenReturn(Optional.of(retained.getId()));
        when(userRepo.findByIdForUpdate(retained.getId())).thenReturn(Optional.of(retained));
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class,
                () -> service.provisionAccount(employee.getId())).getCode());
        retained.setEmployeeId(employee.getId());
        retained.setSuperAdmin(true);
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class,
                () -> service.provisionAccount(employee.getId())).getCode());
        verify(passwordEncoder, never()).encode(anyString());
        verify(userRepo, never()).saveAndFlush(any());
    }

    @Test
    void missingProvisionIdentityStillCreatesAccountWithRandomPassword() {
        Employee employee = new Employee();
        employee.setStatus("active");
        employee.setIdType("身份证");
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setPhoneEnc("phone-cipher");
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(sensitive));
        when(tx.decrypt("phone-cipher")).thenReturn("13800000001");
        when(passwordGenerator.generate()).thenReturn("Rnd-Temp-Pass-20ch!x");
        when(passwordEncoder.encode("Rnd-Temp-Pass-20ch!x")).thenReturn("argon2-random");

        EmployeeOnboardingResult result = service.provisionAccount(employee.getId());

        ArgumentCaptor<UserAccount> account = ArgumentCaptor.forClass(UserAccount.class);
        verify(userRepo).save(account.capture());
        verify(passwordEncoder).encode("Rnd-Temp-Pass-20ch!x");
        assertEquals("Rnd-Temp-Pass-20ch!x", result.temporaryPassword());
        assertEquals("argon2-random", account.getValue().getPasswordHash());
        assertTrue(account.getValue().isMustChangePassword());
        verify(credentialIssuance).requireCanIssueCredentials(account.getValue());
    }

    @Test
    void invalidResidentIdentityStillProvisionsWithTheStoredLastSix() {
        Employee employee = new Employee();
        employee.setStatus("active");
        employee.setIdType("身份证");
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setPhoneEnc("phone-cipher");
        sensitive.setIdCardEnc("id-cipher");
        sensitive.setIdCardCheck("check_digit");
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(sensitive));
        when(tx.decrypt("phone-cipher")).thenReturn("13800000003");
        when(tx.tryDecrypt("id-cipher")).thenReturn(Optional.of("110105194912310021"));
        when(passwordEncoder.encode("310021")).thenReturn("argon2-suffix");

        EmployeeOnboardingResult result = service.provisionAccount(employee.getId());

        // 只提醒不阻塞：仍按档案号码后六位开号，不改用随机密码。
        assertEquals("310021", result.temporaryPassword());
        assertEquals("13800000003", result.loginAccount());
        verify(passwordGenerator, never()).generate();
        verify(userRepo).save(any(UserAccount.class));
    }

    /** 证件号密文解不开 (数据损坏、缺旧密钥) 也不拦开号：按派生不出来处理，改用随机临时密码。 */
    @Test
    void undecryptableIdentityStillProvisionsWithARandomPassword() {
        Employee employee = new Employee();
        employee.setStatus("active");
        employee.setIdType("身份证");
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setPhoneEnc("phone-cipher");
        sensitive.setIdCardEnc("corrupt-cipher");
        sensitive.setIdCardCheck("unchecked");
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(sensitive));
        when(tx.decrypt("phone-cipher")).thenReturn("13800000005");
        when(tx.tryDecrypt("corrupt-cipher")).thenReturn(Optional.empty());
        when(passwordGenerator.generate()).thenReturn("Rnd-Unreadable-20ch!");
        when(passwordEncoder.encode("Rnd-Unreadable-20ch!")).thenReturn("argon2-unreadable");

        EmployeeOnboardingResult result = service.provisionAccount(employee.getId());

        ArgumentCaptor<UserAccount> account = ArgumentCaptor.forClass(UserAccount.class);
        verify(userRepo).save(account.capture());
        assertEquals("Rnd-Unreadable-20ch!", result.temporaryPassword());
        assertEquals("13800000005", result.loginAccount());
        assertEquals("argon2-unreadable", account.getValue().getPasswordHash());
        assertTrue(account.getValue().isMustChangePassword());
        verify(credentialIssuance).requireCanIssueCredentials(account.getValue());
        // 只走不会让事务作废的解密；严格解密碰都不碰证件密文。
        verify(tx, never()).decrypt("corrupt-cipher");
    }

    @Test
    void loginConflictIsReportedBeforeAnyPasswordIsDerived() {
        Employee employee = new Employee();
        employee.setStatus("active");
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setPhoneEnc("phone-cipher");
        sensitive.setIdCardEnc("id-cipher");
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(sensitive));
        when(tx.decrypt("phone-cipher")).thenReturn("13800000004");
        when(userRepo.existsByLoginAccount("13800000004")).thenReturn(true);

        ApiException conflict = assertThrows(ApiException.class,
                () -> service.provisionAccount(employee.getId()));

        assertEquals(ErrorCode.CONFLICT, conflict.getCode());
        verify(tx, never()).tryDecrypt("id-cipher");
        verify(passwordGenerator, never()).generate();
        verify(passwordEncoder, never()).encode(anyString());
        verify(userRepo, never()).save(any(UserAccount.class));
    }

    @Test
    void missingPhoneStillBlocksProvisioning() {
        Employee employee = new Employee();
        employee.setStatus("active");
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setIdCardEnc("id-cipher");
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(sensitive));

        ApiException missing = assertThrows(ApiException.class,
                () -> service.provisionAccount(employee.getId()));

        assertEquals(ErrorCode.VALIDATION_FAILED, missing.getCode());
        assertEquals("该员工缺少手机号，无法开通账号", missing.getMessage());
        verify(tx, never()).tryDecrypt("id-cipher");
        verify(userRepo, never()).save(any(UserAccount.class));
    }

    @Test
    void onboardingWithShortNonResidentDocumentUsesRandomPassword() {
        Department center = managementCenter();
        when(deptRepo.findById(center.getId())).thenReturn(Optional.of(center));
        when(employeeCodeAllocator.nextForNewEmployee(any(UUID.class))).thenReturn("UT0008");
        when(passwordGenerator.generate()).thenReturn("Onboard-Random-20ch!");

        EmployeeOnboardingResult result = service.onboard(request(
                center.getId(), null, null, "IGNORED", "其他", "A1234"));

        verify(passwordEncoder).encode("Onboard-Random-20ch!");
        assertEquals("Onboard-Random-20ch!", result.temporaryPassword());
    }

    @Test
    void onboardingStillRejectsAnInvalidResidentIdentityWithTheSpecificReason() {
        ApiException error = assertThrows(ApiException.class, () -> service.onboard(request(
                UUID.randomUUID(), null, null, "IGNORED", "身份证", "11010519491231002")));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals("身份证号应为18位，当前为17位", error.getMessage());
        verify(empRepo, never()).save(any(Employee.class));
        verify(userRepo, never()).save(any(UserAccount.class));
        verify(passwordGenerator, never()).generate();
    }

    @Test
    void readinessReportsPhoneAndTheStoredIdentityProblemWithoutDecrypting() {
        Employee employee = new Employee();
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setPhoneEnc("phone-cipher");
        sensitive.setIdCardEnc("id-cipher");
        sensitive.setIdCardCheck("length:17");
        when(empRepo.findById(employee.getId())).thenReturn(Optional.of(employee));
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(sensitive));

        EmployeeAccountReadiness readiness = service.accountReadiness(employee.getId());

        assertTrue(readiness.hasPhone());
        assertEquals(new IdNumberIssue("invalid", "身份证号应为18位，当前为17位"), readiness.idNumberIssue());
        verify(tx, never()).decrypt(anyString());
        verify(tx, never()).tryDecrypt(anyString());
    }

    @Test
    void readinessWithoutSensitiveRowReportsMissingPhoneAndIdentity() {
        Employee employee = new Employee();
        when(empRepo.findById(employee.getId())).thenReturn(Optional.of(employee));

        EmployeeAccountReadiness readiness = service.accountReadiness(employee.getId());

        assertFalse(readiness.hasPhone());
        assertEquals("missing", readiness.idNumberIssue().kind());
        assertEquals("档案里没有证件号码", readiness.idNumberIssue().reason());
    }

    @Test
    void readinessSkipsSuperAdminIdentityAndRejectsUnknownEmployees() {
        Employee employee = new Employee();
        UserAccount superAdmin = new UserAccount();
        superAdmin.setSuperAdmin(true);
        when(empRepo.findById(employee.getId())).thenReturn(Optional.of(employee));
        when(userRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(superAdmin));

        assertNull(service.accountReadiness(employee.getId()).idNumberIssue());

        UUID unknown = UUID.randomUUID();
        assertEquals(ErrorCode.NOT_FOUND, assertThrows(ApiException.class,
                () -> service.accountReadiness(unknown)).getCode());
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
        return request(
                departmentId,
                positionId,
                positionName,
                compatibilityCode,
                "其他",
                "CARD-123456");
    }

    private static OnboardingRequest request(
            UUID departmentId,
            UUID positionId,
            String positionName,
            String compatibilityCode,
            String idType,
            String idNumber) {
        return new OnboardingRequest(
                new OnboardingRequest.Profile(
                        compatibilityCode,
                        "测试员工",
                        null,
                        idType,
                        idNumber,
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
                new OnboardingRequest.Account(null, null));
    }
}
