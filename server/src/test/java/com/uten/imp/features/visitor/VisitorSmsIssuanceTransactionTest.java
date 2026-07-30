package com.uten.imp.features.visitor;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class VisitorSmsIssuanceTransactionTest {

    private VisitorSmsCodeRepository repository;
    private SystemSettingsService settings;
    private TxSessionVars tx;
    private VisitorSmsSendLock lock;
    private VisitorSmsIssuanceTransaction issuance;

    @BeforeEach
    void setUp() {
        repository = mock(VisitorSmsCodeRepository.class);
        settings = mock(SystemSettingsService.class);
        tx = mock(TxSessionVars.class);
        lock = mock(VisitorSmsSendLock.class);
        issuance = new VisitorSmsIssuanceTransaction(repository, settings, tx, lock);

        when(tx.hmac("visitor-sms-send:v1:13800138000")).thenReturn("phone-key");
        when(tx.hmac("visitor-otp:v1:13800138000:login:123456"))
                .thenReturn("otp-hmac");
        when(repository.findTopByPhoneOrderByCreatedAtDesc("13800138000"))
                .thenReturn(Optional.empty());
        when(repository.countByPhoneAndCreatedAtAfter(eq("13800138000"), any()))
                .thenReturn(0L);
        when(settings.readInt("sms_send_interval_seconds", 60)).thenReturn(60);
        when(settings.readInt("sms_daily_limit", 10)).thenReturn(10);
        when(settings.readInt("sms_code_ttl_minutes", 5)).thenReturn(5);
    }

    @Test
    void locksBeforeCheckingAndPersistsOnlyTheOtpMac() {
        VisitorSmsIssuanceTransaction.Issuance result =
                issuance.prepare("13800138000", "login", "123456");

        InOrder order = inOrder(lock, repository);
        order.verify(lock).lock("phone-key");
        order.verify(repository)
                .findTopByPhoneOrderByCreatedAtDesc("13800138000");
        order.verify(repository).save(any(VisitorSmsCode.class));

        ArgumentCaptor<VisitorSmsCode> saved =
                ArgumentCaptor.forClass(VisitorSmsCode.class);
        verify(repository).save(saved.capture());
        assertEquals("13800138000", saved.getValue().getPhone());
        assertEquals("otp-hmac", saved.getValue().getCodeHash());
        assertFalse(saved.getValue().getCodeHash().contains("123456"));
        assertEquals(saved.getValue().getId(), result.id());
        assertEquals(1, result.getClass().getRecordComponents().length);
        assertEquals("id", result.getClass().getRecordComponents()[0].getName());
        assertFalse(result.toString().contains("123456"));
    }

    @Test
    void dailyLimitUsesTheAsiaShanghaiCalendarBoundary() {
        ArgumentCaptor<OffsetDateTime> boundary =
                ArgumentCaptor.forClass(OffsetDateTime.class);

        issuance.prepare("13800138000", "login", "123456");

        verify(repository).countByPhoneAndCreatedAtAfter(
                eq("13800138000"),
                boundary.capture());
        assertEquals(ZoneOffset.ofHours(8), boundary.getValue().getOffset());
        assertEquals(0, boundary.getValue().getHour());
        assertEquals(0, boundary.getValue().getMinute());
        assertEquals(0, boundary.getValue().getSecond());
    }

    @Test
    void refusesNonCanonicalPhoneBeforeTakingTheDatabaseLock() {
        assertThrows(
                ApiException.class,
                () -> issuance.prepare("+86 138-0013-8000", "login", "123456"));

        verify(lock, never()).lock(any());
        verify(repository, never()).save(any());
    }

    @Test
    void recentIssuanceIsRejectedAfterTakingThePerPhoneLock() {
        VisitorSmsCode recent = new VisitorSmsCode();
        recent.setCreatedAt(OffsetDateTime.now());
        when(repository.findTopByPhoneOrderByCreatedAtDesc("13800138000"))
                .thenReturn(Optional.of(recent));

        assertThrows(
                ApiException.class,
                () -> issuance.prepare("13800138000", "login", "123456"));

        verify(lock).lock("phone-key");
        verify(repository, never()).save(any());
    }

    @Test
    void definitiveRejectionDeletesOnlyThePreparedIssuance() {
        UUID id = UUID.randomUUID();

        issuance.reject(id);

        verify(repository).deleteById(id);
    }
}
