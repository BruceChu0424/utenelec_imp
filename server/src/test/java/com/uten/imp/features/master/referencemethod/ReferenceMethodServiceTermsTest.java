package com.uten.imp.features.master.referencemethod;

import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * V453 结算方式账期策略维护的服务端校验：
 * 系统角色（CASH/MONTHLY）口径锁定拒绝；枚举/范围/固定日形态镜像 V330 CHECK；
 * 新建可随带账期；改名查重排除自身。
 */
@ExtendWith(MockitoExtension.class)
class ReferenceMethodServiceTermsTest {
    @Mock private SettlementMethodRepository settlementMethods;
    @Mock private FinancePaymentMethodRepository financeMethods;
    @Mock private MasterCodeService masterCodeService;
    @Mock private TxSessionVars tx;

    private ReferenceMethodService service;

    @BeforeEach
    void setUp() {
        service = new ReferenceMethodService(
                settlementMethods, financeMethods, masterCodeService, tx);
    }

    private SettlementMethod method(String systemRole, UUID id) {
        SettlementMethod m = new SettlementMethod();
        m.setId(id);
        m.setName("月结60");
        m.setCode("JS0009");
        m.setStatus("使用");
        m.setSystemRole(systemRole);
        m.setTermsBase("RECEIPT_DATE");
        m.setDueRule("NET_DAYS");
        m.setDefaultDueDays(0);
        m.setMonthsAhead(0);
        return m;
    }

    private SettlementMethodTermsRequest terms(
            String name, String base, String rule, Integer days,
            Integer fixedDay, Integer months) {
        return new SettlementMethodTermsRequest(name, base, rule, days, fixedDay, months);
    }

    @Test
    void systemRoleTermsAreLocked() {
        UUID id = UUID.randomUUID();
        SettlementMethod cash = method("CASH", id);
        when(settlementMethods.findById(id)).thenReturn(Optional.of(cash));

        ApiException error = assertThrows(ApiException.class, () -> service.updateTerms(
                id, terms(null, "STATEMENT_END", "NET_DAYS", 30, null, 0)));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertTrue(error.getMessage().contains("系统角色"));
    }

    @Test
    void missingMethodIsNotFound() {
        UUID id = UUID.randomUUID();
        when(settlementMethods.findById(id)).thenReturn(Optional.empty());

        ApiException error = assertThrows(ApiException.class, () -> service.updateTerms(
                id, terms(null, "RECEIPT_DATE", "NET_DAYS", 0, null, 0)));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
    }

    @Test
    void unknownTermsBaseIsRejected() {
        SettlementMethod m = method(null, null);
        UUID id = UUID.randomUUID();
        m.setId(id);
        when(settlementMethods.findById(id)).thenReturn(Optional.of(m));

        ApiException error = assertThrows(ApiException.class, () -> service.updateTerms(
                id, terms(null, "SHIPPED_DATE", "NET_DAYS", 0, null, 0)));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void dueDaysRangeIsMirrored() {
        SettlementMethod m = method(null, null);
        UUID id = UUID.randomUUID();
        m.setId(id);
        when(settlementMethods.findById(id)).thenReturn(Optional.of(m));

        ApiException error = assertThrows(ApiException.class, () -> service.updateTerms(
                id, terms(null, "RECEIPT_DATE", "NET_DAYS", 3651, null, 0)));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void fixedDayIsRequiredOnlyForFixedRule() {
        SettlementMethod m = method(null, null);
        UUID id = UUID.randomUUID();
        m.setId(id);
        when(settlementMethods.findById(id)).thenReturn(Optional.of(m));

        ApiException missing = assertThrows(ApiException.class, () -> service.updateTerms(
                id, terms(null, "STATEMENT_END", "FIXED_DAY_OF_MONTH", 0, null, 0)));
        assertEquals(ErrorCode.VALIDATION_FAILED, missing.getCode());

        SettlementMethod m2 = method(null, null);
        UUID id2 = UUID.randomUUID();
        m2.setId(id2);
        when(settlementMethods.findById(id2)).thenReturn(Optional.of(m2));
        ApiException extra = assertThrows(ApiException.class, () -> service.updateTerms(
                id2, terms(null, "RECEIPT_DATE", "NET_DAYS", 30, 15, 0)));
        assertEquals(ErrorCode.VALIDATION_FAILED, extra.getCode());
    }

    @Test
    void validTermsPersistAndOptionalRenameApplies() {
        SettlementMethod m = method(null, null);
        UUID id = UUID.randomUUID();
        m.setId(id);
        when(settlementMethods.findById(id)).thenReturn(Optional.of(m));
        when(settlementMethods.existsByNameIgnoreCaseAndDeletedFalseAndIdNot(
                "月结60天", id)).thenReturn(false);

        SettlementMethodAdminItem updated = service.updateTerms(
                id, terms("月结60天", "STATEMENT_END", "EOM_PLUS_DAYS", 15, null, 1));

        assertEquals("月结60天", updated.name());
        assertEquals("STATEMENT_END", updated.termsBase());
        assertEquals("EOM_PLUS_DAYS", updated.dueRule());
        assertEquals(15, updated.defaultDueDays());
        assertEquals(1, updated.monthsAhead());
        verify(settlementMethods).save(m);
    }

    @Test
    void renameToExistingNameIsRejected() {
        SettlementMethod m = method(null, null);
        UUID id = UUID.randomUUID();
        m.setId(id);
        when(settlementMethods.findById(id)).thenReturn(Optional.of(m));
        when(settlementMethods.existsByNameIgnoreCaseAndDeletedFalseAndIdNot(
                "现金", id)).thenReturn(true);

        ApiException error = assertThrows(ApiException.class, () -> service.updateTerms(
                id, terms("现金", "RECEIPT_DATE", "NET_DAYS", 0, null, 0)));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(settlementMethods, never()).save(any());
    }

    @Test
    void createWithoutTermsKeepsDatabaseDefaults() {
        when(settlementMethods.existsByNameIgnoreCaseAndDeletedFalse("预付")).thenReturn(false);
        when(masterCodeService.nextCode(any())).thenReturn("JS0099");

        service.create(new SettlementMethodSaveRequest("预付", null));

        verify(settlementMethods).save(any(SettlementMethod.class));
    }

    @Test
    void createWithValidTermsAppliesThem() {
        when(settlementMethods.existsByNameIgnoreCaseAndDeletedFalse("月结90")).thenReturn(false);
        when(masterCodeService.nextCode(any())).thenReturn("JS0100");

        service.create(new SettlementMethodSaveRequest(
                "月结90",
                terms(null, "STATEMENT_END", "NET_DAYS", 90, null, 0)));

        var captor = org.mockito.ArgumentCaptor.forClass(SettlementMethod.class);
        verify(settlementMethods).save(captor.capture());
        assertEquals("STATEMENT_END", captor.getValue().getTermsBase());
        assertEquals(Integer.valueOf(90), captor.getValue().getDefaultDueDays());
    }

    @Test
    void createWithInvalidTermsFailsClosed() {
        when(settlementMethods.existsByNameIgnoreCaseAndDeletedFalse("坏账期")).thenReturn(false);
        lenient().when(masterCodeService.nextCode(any())).thenReturn("JS0101");

        ApiException error = assertThrows(ApiException.class, () -> service.create(
                new SettlementMethodSaveRequest(
                        "坏账期",
                        terms(null, "RECEIPT_DATE", "FIXED_DAY_OF_MONTH", 0, null, 0))));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        verify(settlementMethods, never()).save(any());
    }
}
