package com.uten.imp.features.finance.bank_transfer;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class FinanceBankTransferServiceTest {

    private FinanceBankTransferRepository transferRepo;
    private FinanceBankTransferLineRepository lineRepo;
    private SecurityContextCurrentUser currentUser;
    private GlPostingService glPosting;
    private EntityManager em;
    private Query accountLock;
    private Query postingCount;
    private Query outgoingUpdate;
    private Query incomingUpdate;
    private Query reconciliationInsert;
    private Query reconciliationDelete;
    private FinanceBankTransferService service;

    @BeforeEach
    void setUp() {
        transferRepo = mock(FinanceBankTransferRepository.class);
        lineRepo = mock(FinanceBankTransferLineRepository.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        EmployeeNameResolver names = mock(EmployeeNameResolver.class);
        DocNumberService numbers = mock(DocNumberService.class);
        FinanceDocumentAccessPolicy access = mock(FinanceDocumentAccessPolicy.class);
        glPosting = mock(GlPostingService.class);
        em = mock(EntityManager.class);

        accountLock = query();
        postingCount = query();
        outgoingUpdate = query();
        incomingUpdate = query();
        reconciliationInsert = query();
        reconciliationDelete = query();
        when(outgoingUpdate.executeUpdate()).thenReturn(1);
        when(incomingUpdate.executeUpdate()).thenReturn(1);
        when(reconciliationInsert.executeUpdate()).thenReturn(1);
        when(reconciliationDelete.executeUpdate()).thenReturn(2);

        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("FROM accounts a")) {
                return accountLock;
            }
            if (sql.contains("SELECT COUNT(*)")) {
                return postingCount;
            }
            if (sql.contains("payments_total")) {
                return outgoingUpdate;
            }
            if (sql.contains("receipts_total")) {
                return incomingUpdate;
            }
            if (sql.contains("INSERT INTO finance_reconciliations")) {
                return reconciliationInsert;
            }
            if (sql.contains("DELETE FROM finance_reconciliations")) {
                return reconciliationDelete;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });

        service = new FinanceBankTransferService(
                transferRepo, lineRepo, tx, currentUser, names, numbers, em, access, glPosting);
    }

    @Test
    void approvePostsBothAccountsAndPersistsConvertedAmount() {
        UUID outAccount = UUID.randomUUID();
        UUID inAccount = UUID.randomUUID();
        UUID outCurrency = UUID.randomUUID();
        UUID inCurrency = UUID.randomUUID();
        FinanceBankTransfer transfer =
                transfer((short) 0, outAccount, outCurrency, "2.000000");
        FinanceBankTransferLine line = line(
                transfer.getId(), inAccount, "100.0000", null);
        UUID approver = UUID.randomUUID();

        when(transferRepo.findById(transfer.getId()))
                .thenReturn(Optional.of(transfer));
        when(lineRepo.findByTransferIdOrderByLineNoAsc(transfer.getId()))
                .thenReturn(List.of(line));
        when(accountLock.getResultList()).thenReturn(List.of(
                new Object[] {outAccount, outCurrency, new BigDecimal("2.000000")},
                new Object[] {inAccount, inCurrency, new BigDecimal("4.000000")}));
        when(postingCount.getSingleResult()).thenReturn(0L);
        when(currentUser.requireEmployeeId()).thenReturn(approver);

        service.approve(transfer.getId());

        assertEquals(0, new BigDecimal("50.0000").compareTo(line.getAmountOriginal()));
        assertEquals(0, new BigDecimal("100.0000").compareTo(transfer.getAmountLocal()));
        assertEquals(0, new BigDecimal("50.0000").compareTo(transfer.getAmountOriginal()));
        assertEquals((short) 1, transfer.getStatus());
        assertSame(approver, transfer.getApproverId());
        verify(lineRepo).save(line);
        verify(outgoingUpdate).setParameter("amount", new BigDecimal("100.0000"));
        verify(incomingUpdate).setParameter("amount", new BigDecimal("50.0000"));
        verify(reconciliationInsert, org.mockito.Mockito.times(2)).executeUpdate();
        verify(glPosting).lockAutoProjectionPeriod(transfer.getBillDate());
    }

    @Test
    void reverseUsesPersistedConversionInsteadOfCurrentCurrencyRates() {
        UUID outAccount = UUID.randomUUID();
        UUID inAccount = UUID.randomUUID();
        UUID outCurrency = UUID.randomUUID();
        UUID inCurrency = UUID.randomUUID();
        FinanceBankTransfer transfer =
                transfer((short) 1, outAccount, outCurrency, "0");
        transfer.setAmountLocal(new BigDecimal("100.0000"));
        transfer.setAmountOriginal(new BigDecimal("50.0000"));
        FinanceBankTransferLine line = line(
                transfer.getId(), inAccount, "100.0000", "50.0000");

        when(transferRepo.findById(transfer.getId()))
                .thenReturn(Optional.of(transfer));
        when(lineRepo.findByTransferIdOrderByLineNoAsc(transfer.getId()))
                .thenReturn(List.of(line));
        when(accountLock.getResultList()).thenReturn(List.of(
                new Object[] {outAccount, outCurrency, null},
                new Object[] {inAccount, inCurrency, null}));
        when(postingCount.getSingleResult()).thenReturn(2L);

        service.reverse(transfer.getId());

        assertEquals((short) -1, transfer.getStatus());
        verify(lineRepo, never()).save(line);
        verify(outgoingUpdate).setParameter("amount", new BigDecimal("-100.0000"));
        verify(incomingUpdate).setParameter("amount", new BigDecimal("-50.0000"));
        verify(reconciliationDelete).executeUpdate();
        verify(glPosting).removeAutoProjection(
                "BANK_TRANSFER", transfer.getId(), transfer.getBillNo(), transfer.getBillDate());
    }

    @Test
    void approveRejectsWhenApproverIsMaker() {
        UUID outAccount = UUID.randomUUID();
        UUID inAccount = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        FinanceBankTransfer transfer = transfer((short) 0, outAccount, currency, "1.000000");
        UUID maker = UUID.randomUUID();
        transfer.setMakerId(maker); // 制单=审核 同一人
        FinanceBankTransferLine line = line(transfer.getId(), inAccount, "100.0000", null);

        when(transferRepo.findById(transfer.getId())).thenReturn(Optional.of(transfer));
        when(lineRepo.findByTransferIdOrderByLineNoAsc(transfer.getId())).thenReturn(List.of(line));
        when(accountLock.getResultList()).thenReturn(List.of(
                new Object[] {outAccount, currency, new BigDecimal("1.000000")},
                new Object[] {inAccount, currency, new BigDecimal("1.000000")}));
        when(postingCount.getSingleResult()).thenReturn(0L);
        when(currentUser.requireEmployeeId()).thenReturn(maker); // 审核人=制单人

        com.uten.imp.common.web.ApiException ex = assertThrows(
                com.uten.imp.common.web.ApiException.class,
                () -> service.approve(transfer.getId()));
        // 职责分离：自审自批被拒；状态仍为草稿（事务回滚，未变已审）
        assertEquals(com.uten.imp.common.web.ErrorCode.BUSINESS, ex.getCode());
        assertEquals((short) 0, transfer.getStatus());
    }

    private static FinanceBankTransfer transfer(
            short status,
            UUID outAccount,
            UUID currency,
            String exchangeRate) {
        FinanceBankTransfer transfer = new FinanceBankTransfer();
        transfer.setBillNo("YC-TEST");
        transfer.setBillDate(LocalDate.of(2026, 7, 30));
        transfer.setOutAccountId(outAccount);
        transfer.setCurrencyId(currency);
        transfer.setExchangeRate(new BigDecimal(exchangeRate));
        transfer.setStatus(status);
        return transfer;
    }

    private static FinanceBankTransferLine line(
            UUID transferId,
            UUID inAccount,
            String amountLocal,
            String amountOriginal) {
        FinanceBankTransferLine line = new FinanceBankTransferLine();
        line.setTransferId(transferId);
        line.setInAccountId(inAccount);
        line.setAmountLocal(new BigDecimal(amountLocal));
        if (amountOriginal != null) {
            line.setAmountOriginal(new BigDecimal(amountOriginal));
        }
        return line;
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }
}
