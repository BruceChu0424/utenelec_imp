package com.uten.imp.features.visitor;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class VisitorAdmissionPolicyTest {
    private VisitorApplicationRepository applications;
    private VisitorAccountRepository accounts;
    private VisitorApplicationService appService;
    private VisitorGateService gate;
    private VisitorApplication app;
    private VisitorAccount account;

    @BeforeEach
    void setUp() {
        applications = mock(VisitorApplicationRepository.class);
        accounts = mock(VisitorAccountRepository.class);
        appService = mock(VisitorApplicationService.class);
        var mapper = mock(VisitorApplicationMapper.class);
        var tx = mock(TxSessionVars.class);
        var current = mock(SecurityContextCurrentUser.class);
        when(mapper.hostInfo(any())).thenReturn(new String[]{"host", "department"});
        when(tx.hmac(anyString())).thenReturn("a".repeat(64));
        when(current.id()).thenReturn(Optional.of(UUID.randomUUID()));
        gate = new VisitorGateService(applications, accounts, appService, mapper,
                mock(VisitorGuard.class), tx, current, new ObjectMapper());
        account = new VisitorAccount();
        app = new VisitorApplication();
        app.setVisitorAccountId(account.getId());
        app.setStatus("approved");
        app.setApprovedAt(OffsetDateTime.now());
        app.setPlannedVisitAt(OffsetDateTime.now());
        app.setPasscode("123456");
        app.setQrToken(gate.genQr(app.getId()));
        when(applications.findById(app.getId())).thenReturn(Optional.of(app));
        when(applications.findByPasscode("123456")).thenReturn(Optional.of(app));
        when(appService.loadForUpdate(app.getId())).thenReturn(app);
        when(appService.accountOf(app)).thenReturn(account);
    }

    @Test
    void approvedActiveVisitorCanUseEitherCredentialAndCheckInOnlyOnce() {
        assertThat(gate.verify(app.getQrToken(), null).valid()).isTrue();
        assertThat(gate.verify(null, "123456").valid()).isTrue();
        assertThat(gate.checkIn(app.getId()).valid()).isTrue();
        var admittedAt = app.getCheckInAt();
        assertThat(gate.checkIn(app.getId()).reason()).isEqualTo("used");
        assertThat(app.getCheckInAt()).isEqualTo(admittedAt);
        verify(applications, times(1)).save(app);
    }

    @Test
    void expiredApprovalCannotBeBypassedWithShortCodeOrDirectCheckIn() {
        app.setApprovedAt(OffsetDateTime.now().minusDays(8));
        assertDeniedEverywhere("expired");
    }

    @Test
    void plannedDepartureBoundsBothCredentialsAndFinalAdmission() {
        app.setPlannedLeaveAt(OffsetDateTime.now().minusMinutes(1));
        assertDeniedEverywhere("expired");
    }

    @Test
    void blacklistedAccountCannotUsePreviouslyApprovedCredentials() {
        account.setStatus("blocked");
        assertDeniedEverywhere("blocked");
    }

    @Test
    void legacyApprovalUsesItsExistingSignedExpiryWithoutInventingANewWindow() {
        app.setApprovedAt(null);
        assertThat(gate.verify(null, "123456").valid()).isTrue();
        app.setQrToken(null);
        assertThat(gate.verify(null, "123456").reason()).isEqualTo("expired");
    }

    @Test
    void blacklistLocksTheAccountAndPreservesAlreadyAdmittedHistory() {
        app.setStatus("checkedIn");
        OffsetDateTime admittedAt = OffsetDateTime.now().minusHours(1);
        app.setCheckInAt(admittedAt);
        when(accounts.findAndLockById(account.getId())).thenReturn(Optional.of(account));
        gate.blacklist(account.getId());
        assertThat(account.getStatus()).isEqualTo("blocked");
        assertThat(app.getStatus()).isEqualTo("checkedIn");
        assertThat(app.getCheckInAt()).isEqualTo(admittedAt);
        verify(accounts).findAndLockById(account.getId());
        verify(applications, never()).save(any());
    }

    @Test
    void mutationLookupLocksAccountBeforeApplicationWithoutCachingAnUnlockedEntity() {
        var identity = mock(VisitorApplicationRepository.ApplicationIdentity.class);
        when(identity.getVisitorAccountId()).thenReturn(account.getId());
        when(applications.findIdentityById(app.getId())).thenReturn(Optional.of(identity));
        when(accounts.findAndLockById(account.getId())).thenReturn(Optional.of(account));
        when(applications.findAndLockById(app.getId())).thenReturn(Optional.of(app));
        var service = new VisitorApplicationService(applications, mock(VisitorApprovalStepRepository.class),
                accounts, mock(EmployeeRepository.class), mock(VisitorApplicationMapper.class),
                mock(TxSessionVars.class), mock(SecurityContextCurrentUser.class));
        assertThat(service.loadForUpdate(app.getId())).isSameAs(app);
        var ordered = inOrder(applications, accounts);
        ordered.verify(applications).findIdentityById(app.getId());
        ordered.verify(accounts).findAndLockById(account.getId());
        ordered.verify(applications).findAndLockById(app.getId());
        verify(applications, never()).findById(any());
    }

    private void assertDeniedEverywhere(String reason) {
        assertThat(gate.verify(app.getQrToken(), null).reason()).isEqualTo(reason);
        assertThat(gate.verify(null, "123456").reason()).isEqualTo(reason);
        assertThat(gate.checkIn(app.getId()).reason()).isEqualTo(reason);
        assertThat(app.getStatus()).isEqualTo("approved");
        assertThat(app.getCheckInAt()).isNull();
        verify(applications, never()).save(any());
    }
}
