package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.CredentialIssuancePolicy;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TemporaryPasswordGenerator;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Independent public-entry regression: identity review must precede account and employment effects. */
@ExtendWith(MockitoExtension.class)
class EmployeeExistingIdentityReactivationTest {
    @Mock EmployeeRepository empRepo;
    @Mock EmployeeSensitiveRepository sensitiveRepo;
    @Mock UserAccountRepository userRepo;
    @Mock EmploymentHistoryRepository historyRepo;
    @Mock EmployeeExistingIdentityGuard existingIdentities;
    @Mock TxSessionVars tx;
    @Mock PasswordEncoder passwordEncoder;
    @Mock TemporaryPasswordGenerator passwordGenerator;
    @Mock CredentialIssuancePolicy credentialIssuance;
    @Mock SystemSettingsService settings;
    @Mock SecurityContextCurrentUser currentUser;
    @Mock EmployeeQueryService queryService;
    @InjectMocks EmployeeOnboardingService onboarding;
    @InjectMocks EmployeeCommandService commands;

    @Test void nullHashHistoricalDuplicateCannotProvisionASecondAccountOrDeriveCredentials() {
        Employee employee=employee("active");
        EmployeeSensitive sensitive=sensitive(employee);
        stubEmployee(employee,sensitive);
        when(tx.decrypt("phone-cipher")).thenReturn("13800000001");
        var conflict=new ApiException(ErrorCode.CONFLICT,"该身份已有保留档案，请先核对重复档案");
        doThrow(conflict).when(existingIdentities).requireCanActivate(employee,sensitive);

        assertThat(assertThrows(ApiException.class,()->onboarding.provisionAccount(employee.getId()))).isSameAs(conflict);
        assertThat(sensitive.getIdCardHash()).isNull();
        assertThat(employee.getStatus()).isEqualTo("active");
        assertNoEffects();
        verify(existingIdentities).requireCanActivate(employee,sensitive);
        verify(tx,never()).decrypt("historical-identity-without-hash");
    }

    @Test void nullHashHistoricalDuplicateCannotRehireOrAppendAFalseEmploymentEvent() {
        Employee employee=employee("resigned");
        EmployeeSensitive sensitive=sensitive(employee);
        stubEmployee(employee,sensitive);
        int beforeVersion=employee.getVersion();
        var conflict=new ApiException(ErrorCode.CONFLICT,"该身份已有保留档案，请先核对重复档案");
        doThrow(conflict).when(existingIdentities).requireCanActivate(employee,sensitive);

        assertThat(assertThrows(ApiException.class,()->commands.rehire(employee.getId()))).isSameAs(conflict);
        assertThat(employee.getStatus()).isEqualTo("resigned");
        assertThat(employee.getVersion()).isEqualTo(beforeVersion);
        assertNoEffects();
        verify(existingIdentities).requireCanActivate(employee,sensitive);
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void clearedActivationCheckKeepsMissingAndUnreadableDocumentProvisioningCompatible(boolean unreadable) {
        Employee employee=employee("active");
        EmployeeSensitive sensitive=sensitive(employee);
        sensitive.setIdCardEnc(unreadable?"unreadable-identity":null);
        stubEmployee(employee,sensitive);
        when(tx.decrypt("phone-cipher")).thenReturn("13800000001");
        when(tx.tryDecrypt(unreadable?"unreadable-identity":null)).thenReturn(Optional.empty());
        when(passwordGenerator.generate()).thenReturn("Synthetic-Temporary-123!");
        when(passwordEncoder.encode("Synthetic-Temporary-123!")).thenReturn("fixture-argon2");

        var result=onboarding.provisionAccount(employee.getId());

        assertThat(result.loginAccount()).isEqualTo("13800000001");
        assertThat(result.temporaryPassword()).isEqualTo("Synthetic-Temporary-123!");
        verify(existingIdentities).requireCanActivate(employee,sensitive);
        ArgumentCaptor<UserAccount> created=ArgumentCaptor.forClass(UserAccount.class);
        verify(userRepo).save(created.capture());
        assertThat(created.getValue().getEmployeeId()).isEqualTo(employee.getId());
        assertThat(created.getValue().isMustChangePassword()).isTrue();
        verify(credentialIssuance).requireCanIssueCredentials(created.getValue());
        verify(historyRepo,never()).save(any());
    }

    @Test void clearedActivationCheckReusesTheExistingEmployeeOnRehireWithoutIssuingAnAccount() {
        Employee employee=employee("resigned");
        EmployeeSensitive sensitive=sensitive(employee);
        stubEmployee(employee,sensitive);
        int beforeVersion=employee.getVersion();

        commands.rehire(employee.getId());

        assertThat(employee.getStatus()).isEqualTo("active");
        assertThat(employee.getVersion()).isEqualTo(beforeVersion+1);
        verify(existingIdentities).requireCanActivate(employee,sensitive);
        verify(empRepo).save(employee);
        ArgumentCaptor<EmploymentHistory> event=ArgumentCaptor.forClass(EmploymentHistory.class);
        verify(historyRepo).save(event.capture());
        assertThat(event.getValue().getEmployee()).isSameAs(employee);
        assertThat(event.getValue().getEventType()).isEqualTo("rehire");
        verify(userRepo,never()).save(any());
        verify(userRepo,never()).saveAndFlush(any());
        verifyNoInteractions(passwordEncoder,passwordGenerator);
    }

    @Test void historicalDocumentWithoutLookupHashIsStillFoundAfterTheFirstPageAndNormalizedBeforeComparison() {
        Employee employee=employee("active");
        EmployeeSensitive details=sensitive(employee);
        var jdbc=mock(JdbcTemplate.class);
        var directory=mock(EmployeeIdentityDirectory.class);
        var guard=new EmployeeExistingIdentityGuard(jdbc,tx,directory,sensitiveRepo);
        when(directory.canonicalEmployeeId(employee.getId())).thenReturn(employee.getId());
        stubDecryption(Map.of("historical-identity-without-hash","11010519491231002X",
                "second-page-noncanonical-cipher"," 11010519491231002x "));
        when(tx.hmac("11010519491231002X")).thenReturn("normalized-document-claim");
        List<LegacyEvidence> first=new ArrayList<>();
        for(int i=1;i<=100;i++)first.add(new LegacyEvidence(new UUID(0,i),"身份证",null,null));
        scriptCandidates(jdbc,List.of(first,List.of(new LegacyEvidence(new UUID(0,101),"其他",
                "second-page-noncanonical-cipher",null))));

        ApiException conflict=assertThrows(ApiException.class,()->guard.requireCanActivate(employee,details));

        assertThat(conflict.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(conflict.getMessage()).contains("证件信息").doesNotContain("11010519491231002");
        verify(sensitiveRepo).lockIdentityHash("normalized-document-claim");
        verify(jdbc).query(anyString(),org.mockito.ArgumentMatchers.<RowMapper<Object>>any(),
                eq(new UUID(0,100)),eq(employee.getId()),eq(100));
        assertNoEffects();
    }

    @Test void unreadableDocumentDoesNotHideAnExactNormalizedHistoricalPrimaryPhoneConflict() {
        Employee employee=employee("active");
        EmployeeSensitive details=sensitive(employee);
        var jdbc=mock(JdbcTemplate.class);
        var directory=mock(EmployeeIdentityDirectory.class);
        var guard=new EmployeeExistingIdentityGuard(jdbc,tx,directory,sensitiveRepo);
        when(directory.canonicalEmployeeId(employee.getId())).thenReturn(employee.getId());
        stubDecryption(Map.of("phone-cipher","13800000001",
                "legacy-phone-with-country-prefix","+86 (138) 0000-0001"));
        when(tx.hmac("13800000001")).thenReturn("normalized-phone-claim");
        scriptCandidates(jdbc,List.of(List.of(new LegacyEvidence(new UUID(0,1),"身份证",null,
                "legacy-phone-with-country-prefix"))));

        ApiException conflict=assertThrows(ApiException.class,()->guard.requireCanActivate(employee,details));

        assertThat(conflict.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(conflict.getMessage()).contains("主手机号").doesNotContain("13800000001");
        verify(sensitiveRepo).lockPrimaryPhoneHash("normalized-phone-claim");
        verify(sensitiveRepo,never()).lockIdentityHash(any());
        assertNoEffects();
    }

    @Test void matchingDisplayNamesCannotReplaceDistinctDocumentAndPhoneEvidence() {
        Employee employee=employee("active");
        employee.setFullName("同名核对测试");
        EmployeeSensitive details=sensitive(employee);
        var jdbc=mock(JdbcTemplate.class);
        var directory=mock(EmployeeIdentityDirectory.class);
        var guard=new EmployeeExistingIdentityGuard(jdbc,tx,directory,sensitiveRepo);
        when(directory.canonicalEmployeeId(employee.getId())).thenReturn(employee.getId());
        // Both are valid resident documents. The comparison query intentionally
        // does not project or filter names, so a shared display name cannot merge people.
        assertThat(com.uten.imp.common.util.IdCardUtil.isValid("110105194912310011")).isTrue();
        stubDecryption(Map.of("historical-identity-without-hash","11010519491231002X",
                "other-person-document","110105194912310011","phone-cipher","13800000001",
                "other-person-phone","13800000002"));
        when(tx.hmac("11010519491231002X")).thenReturn("normalized-document-claim");
        when(tx.hmac("13800000001")).thenReturn("normalized-phone-claim");
        scriptCandidates(jdbc,List.of(List.of(new LegacyEvidence(new UUID(0,1),"身份证",
                "other-person-document","other-person-phone"))));

        assertDoesNotThrow(()->guard.requireCanActivate(employee,details));

        var order=inOrder(sensitiveRepo);
        order.verify(sensitiveRepo).lockIdentityHash("normalized-document-claim");
        order.verify(sensitiveRepo).lockPrimaryPhoneHash("normalized-phone-claim");
        assertNoEffects();
        verify(tx,never()).encrypt(any());
    }

    private record LegacyEvidence(UUID id,String idType,String documentCipher,String phoneCipher) { }
    private void stubDecryption(Map<String,String> evidence) {
        when(tx.tryDecrypt(org.mockito.ArgumentMatchers.nullable(String.class))).thenAnswer(invocation -> {
            String cipher=invocation.getArgument(0);
            return cipher==null?Optional.empty():Optional.ofNullable(evidence.get(cipher));
        });
    }
    private static void scriptCandidates(JdbcTemplate jdbc,List<List<LegacyEvidence>> pages) {
        var pageIndex=new AtomicInteger();
        when(jdbc.query(anyString(),org.mockito.ArgumentMatchers.<RowMapper<Object>>any(),
                any(UUID.class),any(UUID.class),anyInt())).thenAnswer(invocation -> {
            RowMapper<?> mapper=invocation.getArgument(1);
            List<Object> result=new ArrayList<>();
            for(LegacyEvidence evidence:pages.get(pageIndex.getAndIncrement())) {
                ResultSet row=mock(ResultSet.class);
                when(row.getObject(1,UUID.class)).thenReturn(evidence.id());
                when(row.getString(2)).thenReturn(evidence.idType());
                when(row.getString(3)).thenReturn(evidence.documentCipher());
                when(row.getString(4)).thenReturn(evidence.phoneCipher());
                result.add(mapper.mapRow(row,result.size()));
            }
            return result;
        });
    }

    private void assertNoEffects() {
        verify(empRepo,never()).save(any());
        verify(historyRepo,never()).save(any());
        verify(userRepo,never()).save(any());
        verify(userRepo,never()).saveAndFlush(any());
        verifyNoInteractions(passwordEncoder,passwordGenerator,credentialIssuance,queryService);
    }
    private void stubEmployee(Employee employee,EmployeeSensitive sensitive) {
        when(empRepo.findByIdForUpdate(employee.getId())).thenReturn(Optional.of(employee));
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(sensitive));
    }
    private static Employee employee(String status) {
        Employee result=new Employee();result.setFullName("同人核对测试");result.setIdType("身份证");result.setStatus(status);
        return result;
    }
    private static EmployeeSensitive sensitive(Employee employee) {
        EmployeeSensitive result=new EmployeeSensitive();result.setEmployeeId(employee.getId());
        result.setIdCardEnc("historical-identity-without-hash");result.setPhoneEnc("phone-cipher");
        return result;
    }
}
