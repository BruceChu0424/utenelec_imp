package com.uten.imp.features.finance.receipt;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.arap.ArApLedger;
import com.uten.imp.features.finance.arap.ArApLedgerRepository;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptDetail;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptLineInput;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class FinanceReceiptSettlementTest {

    private static final UUID CLIENT_ID = UUID.fromString("10000000-0000-0000-0000-000000000001");
    private static final UUID ACCOUNT_ID = UUID.fromString("20000000-0000-0000-0000-000000000002");
    private static final UUID CURRENCY_ID = UUID.fromString("30000000-0000-0000-0000-000000000003");
    private static final UUID MAKER_ID = UUID.fromString("40000000-0000-0000-0000-000000000004");
    private static final UUID APPROVER_ID = UUID.fromString("50000000-0000-0000-0000-000000000005");
    private static final UUID EXPENSE_STYLE_ID = UUID.fromString("60000000-0000-0000-0000-000000000006");

    private FinanceReceiptRepository receiptRepo;
    private FinanceReceiptLineRepository lineRepo;
    private ArApLedgerRepository ledgerRepo;
    private ArApLedgerService arApService;
    private SecurityContextCurrentUser currentUser;
    private EntityManager em;
    private Query postingCount;
    private Query accountLock;
    private Query accountUpdate;
    private Query reconciliationInsert;
    private Query reconciliationDelete;
    private Query hierarchyLock;
    private final ArrayDeque<Long> postingCounts = new ArrayDeque<>();
    private final Map<UUID, FinanceReceipt> receipts = new HashMap<>();
    private final Map<UUID, List<FinanceReceiptLine>> linesByReceipt = new HashMap<>();
    private final Map<UUID, ArApLedger> ledgers = new HashMap<>();
    private final List<String> nativeSql = new ArrayList<>();
    private FinanceReceiptService service;
    private GlPostingService glPosting;

    @BeforeEach
    void setUp() {
        receiptRepo = mock(FinanceReceiptRepository.class);
        lineRepo = mock(FinanceReceiptLineRepository.class);
        ledgerRepo = mock(ArApLedgerRepository.class);
        arApService = mock(ArApLedgerService.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        EmployeeNameResolver names = mock(EmployeeNameResolver.class);
        DocNumberService numbers = mock(DocNumberService.class);
        FinanceDocumentAccessPolicy access = mock(FinanceDocumentAccessPolicy.class);
        glPosting = mock(GlPostingService.class);
        em = mock(EntityManager.class);

        when(receiptRepo.save(any(FinanceReceipt.class))).thenAnswer(invocation -> {
            FinanceReceipt receipt = invocation.getArgument(0);
            receipts.put(receipt.getId(), receipt);
            return receipt;
        });
        when(receiptRepo.findById(any(UUID.class))).thenAnswer(invocation ->
                Optional.ofNullable(receipts.get(invocation.getArgument(0))));
        when(receiptRepo.findByBillNo(anyString())).thenAnswer(invocation -> receipts.values().stream()
                .filter(receipt -> invocation.getArgument(0).equals(receipt.getBillNo()))
                .findFirst());

        when(lineRepo.save(any(FinanceReceiptLine.class))).thenAnswer(invocation -> {
            FinanceReceiptLine line = invocation.getArgument(0);
            List<FinanceReceiptLine> stored = linesByReceipt.computeIfAbsent(
                    line.getReceiptId(), ignored -> new ArrayList<>());
            stored.removeIf(existing -> existing.getId().equals(line.getId()));
            stored.add(line);
            return line;
        });
        when(lineRepo.findByReceiptIdOrderByLineNoAsc(any(UUID.class))).thenAnswer(invocation ->
                linesByReceipt.getOrDefault(invocation.getArgument(0), List.of()).stream()
                        .sorted(Comparator.comparing(FinanceReceiptLine::getLineNo))
                        .toList());
        doAnswer(invocation -> {
            linesByReceipt.remove((UUID) invocation.getArgument(0));
            return null;
        }).when(lineRepo).deleteByReceiptId(any(UUID.class));

        when(ledgerRepo.findById(any(UUID.class))).thenAnswer(invocation ->
                Optional.ofNullable(ledgers.get(invocation.getArgument(0))));
        when(ledgerRepo.findAllByIdInForUpdate(any())).thenAnswer(invocation -> {
            @SuppressWarnings("unchecked")
            Collection<UUID> ids = invocation.getArgument(0);
            return ids.stream().map(ledgers::get).filter(java.util.Objects::nonNull)
                    .sorted(Comparator.comparing(ArApLedger::getId)).toList();
        });
        when(ledgerRepo.save(any(ArApLedger.class))).thenAnswer(invocation -> {
            ArApLedger ledger = invocation.getArgument(0);
            ledgers.put(ledger.getId(), ledger);
            return ledger;
        });

        postingCount = query();
        accountLock = query();
        accountUpdate = query();
        reconciliationInsert = query();
        reconciliationDelete = query();
        Query clientLookup = query();
        Query expenseStyleCount = query();
        hierarchyLock = query();
        when(postingCount.getSingleResult()).thenAnswer(ignored ->
                postingCounts.isEmpty() ? 0L : postingCounts.removeFirst());
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[] {CURRENCY_ID, "USD", "美元"}));
        when(accountUpdate.executeUpdate()).thenReturn(1);
        when(reconciliationInsert.executeUpdate()).thenReturn(1);
        when(reconciliationDelete.executeUpdate()).thenReturn(1);
        when(clientLookup.getSingleResult()).thenReturn("测试客户");
        when(expenseStyleCount.getSingleResult()).thenReturn(1L);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            nativeSql.add(sql);
            if (sql.contains("PAYMENT_STYLE_HIERARCHY")) {
                return hierarchyLock;
            }
            if (sql.contains("FROM finance_reconciliations") && sql.contains("COUNT(*)")) {
                return postingCount;
            }
            if (sql.contains("FROM accounts account") && sql.contains("FOR UPDATE OF account")) {
                return accountLock;
            }
            if (sql.contains("UPDATE accounts")) {
                return accountUpdate;
            }
            if (sql.contains("INSERT INTO finance_reconciliations")) {
                return reconciliationInsert;
            }
            if (sql.contains("DELETE FROM finance_reconciliations")) {
                return reconciliationDelete;
            }
            if (sql.contains("SELECT name FROM clients")) {
                return clientLookup;
            }
            if (sql.contains("FROM payment_styles") && sql.contains("COUNT(*)")) {
                return expenseStyleCount;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });

        AtomicInteger sequence = new AtomicInteger();
        when(numbers.nextNumber(DocNumberPrefix.FIN_RECEIPT))
                .thenAnswer(ignored -> "XS-TEST-" + sequence.incrementAndGet());
        when(currentUser.requireEmployeeId()).thenReturn(MAKER_ID);
        when(access.hasAuthority("customer_prepayment:view")).thenReturn(true);
        when(access.hasAuthority("finance:view:all")).thenReturn(true);
        service = new FinanceReceiptService(
                receiptRepo, lineRepo, ledgerRepo, arApService, tx,
                currentUser, names, em, numbers, access, glPosting,
                mock(com.uten.imp.features.finance.receivables.FinanceReceiptSourceAllocationService.class));
    }

    @Test
    void draftIgnoresClientDerivedLocalAmountAndExchangeDifference() {
        ArApLedger ledger = receivable("100.0000", "7.000000");

        FinanceReceiptDetail detail = service.create(request(
                ledger, "30.0000", "7.200000", "2.0000", "14.4000",
                "9999.0000", "-8888.0000"));

        FinanceReceiptLine saved = onlyLine(detail.getId());
        assertMoney(saved.getAmountOriginal(), "30.0000");
        assertMoney(saved.getAmountLocal(), "216.0000");
        assertMoney(saved.getWriteOffLocal(), "14.4000");
        assertMoney(saved.getAppliedAmountLocal(), "224.0000");
        assertMoney(saved.getExchangeDiff(), "6.4000");
        assertMoney(saved.getExchangeRate(), "7.200000");
        assertMoney(detail.getAmountOriginal(), "30.0000");
        assertMoney(detail.getAmountLocal(), "216.0000");
    }

    @Test
    void appliedReceiptRequiresExplicitPositiveArrivalRatePerLine() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        FinanceReceiptSaveRequest missing = request(
                ledger, "30.0000", "7.200000", "0.0000", "0.0000",
                "9999.0000", "9999.0000");
        missing.getItems().getFirst().setExchangeRate(null);
        // A valid header value must not rescue a missing line-level arrival rate.
        missing.setExchangeRate(new BigDecimal("6.900000"));

        FinanceReceiptSaveRequest zero = request(
                ledger, "30.0000", "7.200000", "0.0000", "0.0000",
                "9999.0000", "9999.0000");
        zero.getItems().getFirst().setExchangeRate(BigDecimal.ZERO);

        assertThatThrownBy(() -> service.create(missing))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("收款汇率必须大于 0");
        assertThatThrownBy(() -> service.create(zero))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("收款汇率必须大于 0");
    }

    @Test
    void updateAndDeleteAcquireTheSameHeaderWriteLockAsApproval() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        FinanceReceiptSaveRequest request = request(
                ledger, "30.0000", "7.200000", "0.0000", "0.0000",
                "9999.0000", "9999.0000");

        FinanceReceiptDetail updated = service.create(request);
        service.update(updated.getId(), request);
        FinanceReceiptDetail deleted = service.create(request);
        service.delete(deleted.getId());

        verify(em, times(2)).refresh(any(FinanceReceipt.class),
                org.mockito.ArgumentMatchers.eq(LockModeType.PESSIMISTIC_WRITE));
        assertThat(receipts.get(deleted.getId()).isDeleted()).isTrue();
    }

    @Test
    void otherFeeStyleWritesAndPostingLockHierarchyBeforeSaveAndValidation() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        FinanceReceiptSaveRequest request = request(
                ledger, "30.0000", "7.200000", "2.0000", "0.0000",
                "9999.0000", "9999.0000");
        request.setOtherFee(new BigDecimal("14.4000"));
        request.setOtherFeeStyleId(EXPENSE_STYLE_ID);

        FinanceReceiptDetail draft = service.create(request);

        InOrder createOrder = inOrder(hierarchyLock, receiptRepo);
        createOrder.verify(hierarchyLock).getSingleResult();
        createOrder.verify(receiptRepo, times(2)).save(any(FinanceReceipt.class));

        nativeSql.clear();
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.add(0L);
        service.approve(draft.getId());

        int lockIndex = indexOfSql("PAYMENT_STYLE_HIERARCHY");
        int validationIndex = indexOfSql("FROM payment_styles");
        assertThat(lockIndex).isZero();
        assertThat(validationIndex).isGreaterThan(lockIndex);
    }

    @Test
    void partialReceiptsAndFeeWriteOffAccumulateThenReverseFromPersistedSnapshots() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        FinanceReceiptDetail first = service.create(request(
                ledger, "30.0000", "7.200000", "2.0000", "14.4000",
                "9999.0000", "9999.0000"));
        FinanceReceiptDetail second = service.create(request(
                ledger, "68.0000", "6.900000", "0.0000", "0.0000",
                "9999.0000", "9999.0000"));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L, 0L, 1L));

        service.approve(first.getId());

        assertMoney(ledger.getAmountReceivedOriginal(), "30.0000");
        assertMoney(ledger.getAmountReceivedLocal(), "216.0000");
        assertMoney(ledger.getAmountWriteOffOriginal(), "2.0000");
        assertMoney(ledger.getAmountWriteOffLocal(), "14.4000");
        assertMoney(ledger.getAmountBalanceOriginal(), "68.0000");
        assertMoney(ledger.getAmountSettled(), "224.0000");
        assertMoney(ledger.getAmountBalance(), "476.0000");
        assertThat(ledger.isSettled()).isFalse();

        service.approve(second.getId());

        assertMoney(ledger.getAmountReceivedOriginal(), "98.0000");
        assertMoney(ledger.getAmountReceivedLocal(), "685.2000");
        assertMoney(ledger.getAmountWriteOffOriginal(), "2.0000");
        assertMoney(ledger.getAmountWriteOffLocal(), "14.4000");
        assertMoney(ledger.getAmountBalanceOriginal(), "0.0000");
        assertMoney(ledger.getAmountSettled(), "700.0000");
        assertMoney(ledger.getAmountBalance(), "0.0000");
        assertThat(ledger.isSettled()).isTrue();
        assertThat(ledger.getSettledDate()).isEqualTo(LocalDate.of(2026, 8, 8));

        FinanceReceiptLine secondLine = onlyLine(second.getId());
        assertMoney(secondLine.getAmountLocal(), "469.2000");
        assertMoney(secondLine.getAppliedAmountLocal(), "476.0000");
        assertMoney(secondLine.getExchangeDiff(), "-6.8000");
        assertMoney(secondLine.getBalanceBeforeOriginal(), "68.0000");
        assertMoney(secondLine.getBalanceAfterOriginal(), "0.0000");

        service.reverse(second.getId());

        assertMoney(ledger.getAmountReceivedOriginal(), "30.0000");
        assertMoney(ledger.getAmountReceivedLocal(), "216.0000");
        assertMoney(ledger.getAmountWriteOffOriginal(), "2.0000");
        assertMoney(ledger.getAmountWriteOffLocal(), "14.4000");
        assertMoney(ledger.getAmountBalanceOriginal(), "68.0000");
        assertMoney(ledger.getAmountSettled(), "224.0000");
        assertMoney(ledger.getAmountBalance(), "476.0000");
        assertThat(ledger.isSettled()).isFalse();
        assertThat(ledger.getSettledDate()).isNull();
        assertThat(receipts.get(second.getId()).getStatus()).isEqualTo((short) -1);
        verify(glPosting, times(2)).lockAutoProjectionPeriod(first.getBillDate());
        verify(glPosting).removeAutoProjection(
                "RECEIPT", second.getId(), second.getBillNo(), second.getBillDate());

        verify(ledgerRepo, times(3)).findAllByIdInForUpdate(any());
        verify(em, times(3)).refresh(any(FinanceReceipt.class),
                org.mockito.ArgumentMatchers.eq(LockModeType.PESSIMISTIC_WRITE));

        // USD account: balance and account statement both use the original-currency amount.
        verify(accountUpdate).setParameter("amount", new BigDecimal("30.0000"));
        verify(accountUpdate).setParameter("amount", new BigDecimal("68.0000"));
        verify(accountUpdate).setParameter("amount", new BigDecimal("-68.0000"));
        verify(reconciliationInsert).setParameter("inAmt", new BigDecimal("30.0000"));
        verify(reconciliationInsert).setParameter("inAmt", new BigDecimal("68.0000"));
        assertThat(nativeSql.stream().filter(sql -> sql.contains("FROM accounts account")).findFirst())
                .hasValueSatisfying(sql -> assertThat(sql)
                        .contains("FOR UPDATE OF account")
                        .contains("COALESCE(account.is_deleted,false)=false")
                        .contains("currency.status='使用'"));
    }

    @Test
    void cnyAccountUsesTheSameLocalAmountForBalanceAndReconciliation() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        FinanceReceiptDetail draft = service.create(request(
                ledger, "30.0000", "7.200000", "0.0000", "0.0000",
                "9999.0000", "9999.0000"));
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[] {UUID.randomUUID(), "CNY", "人民币"}));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.add(0L);

        service.approve(draft.getId());

        verify(accountUpdate).setParameter("amount", new BigDecimal("216.0000"));
        verify(reconciliationInsert).setParameter("inAmt", new BigDecimal("216.0000"));
    }

    @Test
    void approvalRejectsCashPlusWriteOffAboveOriginalCurrencyBalance() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        FinanceReceiptDetail draft = service.create(request(
                ledger, "99.0000", "7.000000", "2.0000", "14.0000",
                "1.0000", "1.0000"));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.add(0L);

        assertThatThrownBy(() -> service.approve(draft.getId()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("超过应收未收金额");

        assertMoney(ledger.getAmountReceivedOriginal(), "0.0000");
        assertMoney(ledger.getAmountReceivedLocal(), "0.0000");
        assertMoney(ledger.getAmountWriteOffOriginal(), "0.0000");
        assertMoney(ledger.getAmountWriteOffLocal(), "0.0000");
        assertMoney(ledger.getAmountBalanceOriginal(), "100.0000");
        assertMoney(ledger.getAmountSettled(), "0.0000");
        assertMoney(ledger.getAmountBalance(), "700.0000");
        verify(accountUpdate, never()).executeUpdate();
        verify(reconciliationInsert, never()).executeUpdate();
    }

    @Test
    void directPrepaymentRejectsMissingCurrencyRateOrAmountBeforeDraftPersistence() {
        FinanceReceiptSaveRequest missingOriginal = directRequest(CURRENCY_ID, "7.200000");
        missingOriginal.setAmountOriginal(null);
        missingOriginal.setAmountLocal(new BigDecimal("9999.0000"));

        assertThatThrownBy(() -> service.create(directRequest(null, "1.000000")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("客户和币别");
        assertThatThrownBy(() -> service.create(directRequest(CURRENCY_ID, null)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("汇率必须大于 0");
        assertThatThrownBy(() -> service.create(directRequest(CURRENCY_ID, "0.000000")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("汇率必须大于 0");
        assertThatThrownBy(() -> service.create(missingOriginal))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("原币金额必须大于 0");

        verify(arApService, never()).postArAp(any());
        verify(accountUpdate, never()).executeUpdate();
        verify(reconciliationInsert, never()).executeUpdate();
    }

    @Test
    void directPrepaymentDerivesLocalAmountAndIgnoresClientValue() {
        FinanceReceiptSaveRequest request = directRequest(CURRENCY_ID, "7.200000");
        request.setAmountOriginal(new BigDecimal("10.0000"));
        request.setAmountLocal(new BigDecimal("9999.0000"));

        FinanceReceiptDetail draft = service.create(request);

        assertMoney(draft.getAmountOriginal(), "10.0000");
        assertMoney(draft.getExchangeRate(), "7.200000");
        assertMoney(draft.getAmountLocal(), "72.0000");
    }

    private ArApLedger receivable(String original, String recognitionRate) {
        ArApLedger ledger = new ArApLedger();
        ledger.setDirection("AR");
        ledger.setSourceDocType("SALES_SHIPMENT");
        ledger.setBillNo("XC-TEST");
        ledger.setBillDate(LocalDate.of(2026, 8, 1));
        ledger.setClientId(CLIENT_ID);
        ledger.setCurrencyId(CURRENCY_ID);
        ledger.setExchangeRate(new BigDecimal(recognitionRate));
        ledger.setAmountOriginal(new BigDecimal(original));
        ledger.setAmountOriginalLocal(new BigDecimal(original).multiply(new BigDecimal(recognitionRate)));
        ledger.setAmountReceivedOriginal(new BigDecimal("0.0000"));
        ledger.setAmountReceivedLocal(new BigDecimal("0.0000"));
        ledger.setAmountWriteOffOriginal(new BigDecimal("0.0000"));
        ledger.setAmountWriteOffLocal(new BigDecimal("0.0000"));
        ledger.setAmountBalanceOriginal(new BigDecimal(original));
        ledger.setAmountSettled(new BigDecimal("0.0000"));
        ledger.setAmountBalance(ledger.getAmountOriginalLocal());
        ledger.setStatus((short) 1);
        ledgers.put(ledger.getId(), ledger);
        return ledger;
    }

    private static FinanceReceiptSaveRequest request(
            ArApLedger ledger,
            String cashOriginal,
            String receiptRate,
            String writeOffOriginal,
            String bankFeeLocal,
            String clientLocal,
            String clientExchangeDiff) {
        FinanceReceiptLineInput line = new FinanceReceiptLineInput();
        line.setLineNo(1);
        line.setAppliedLedgerId(ledger.getId());
        line.setAppliedBillNo(ledger.getBillNo());
        line.setClientId(CLIENT_ID);
        line.setCurrencyId(CURRENCY_ID);
        line.setExchangeRate(new BigDecimal(receiptRate));
        line.setAmountOriginal(new BigDecimal(cashOriginal));
        line.setAmountLocal(new BigDecimal(clientLocal));
        line.setExchangeDiff(new BigDecimal(clientExchangeDiff));
        line.setWriteOffAmount(new BigDecimal(writeOffOriginal));

        FinanceReceiptSaveRequest request = new FinanceReceiptSaveRequest();
        request.setReceiptKind("AR_SETTLEMENT");
        request.setBillDate(LocalDate.of(2026, 8, 8));
        request.setClientId(CLIENT_ID);
        request.setAccountId(ACCOUNT_ID);
        request.setCurrencyId(CURRENCY_ID);
        request.setExchangeRate(new BigDecimal(receiptRate));
        request.setAmountOriginal(new BigDecimal(cashOriginal));
        request.setAmountLocal(new BigDecimal(clientLocal));
        request.setBankFee(new BigDecimal(bankFeeLocal));
        request.setOtherFee(BigDecimal.ZERO);
        request.setItems(List.of(line));
        return request;
    }

    private static FinanceReceiptSaveRequest directRequest(UUID currencyId, String exchangeRate) {
        FinanceReceiptSaveRequest request = new FinanceReceiptSaveRequest();
        request.setReceiptKind("CUSTOMER_PREPAYMENT");
        request.setBillDate(LocalDate.of(2026, 8, 8));
        request.setClientId(CLIENT_ID);
        request.setAccountId(ACCOUNT_ID);
        request.setCurrencyId(currencyId);
        request.setExchangeRate(exchangeRate == null ? null : new BigDecimal(exchangeRate));
        request.setAmountOriginal(new BigDecimal("10.0000"));
        request.setItems(List.of());
        return request;
    }

    private FinanceReceiptLine onlyLine(UUID receiptId) {
        assertThat(linesByReceipt.get(receiptId)).hasSize(1);
        return linesByReceipt.get(receiptId).getFirst();
    }

    private static void assertMoney(BigDecimal actual, String expected) {
        assertThat(actual).isNotNull().isEqualByComparingTo(expected);
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }

    private int indexOfSql(String fragment) {
        for (int i = 0; i < nativeSql.size(); i++) {
            if (nativeSql.get(i).contains(fragment)) return i;
        }
        return -1;
    }
}
