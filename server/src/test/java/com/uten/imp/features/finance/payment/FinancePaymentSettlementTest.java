package com.uten.imp.features.finance.payment;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.accountflow.AccountFlowLedgerService;
import com.uten.imp.features.finance.arap.ArApLedger;
import com.uten.imp.features.finance.arap.ArApLedgerRepository;
import com.uten.imp.features.finance.payment.dto.FinancePaymentDetail;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class FinancePaymentSettlementTest {

    private static final UUID SUPPLIER_ID = UUID.fromString("10000000-0000-0000-0000-000000000001");
    private static final UUID ACCOUNT_ID = UUID.fromString("20000000-0000-0000-0000-000000000002");
    private static final UUID CURRENCY_ID = UUID.fromString("30000000-0000-0000-0000-000000000003");
    private static final UUID MAKER_ID = UUID.fromString("40000000-0000-0000-0000-000000000004");
    private static final UUID APPROVER_ID = UUID.fromString("50000000-0000-0000-0000-000000000005");
    private static final UUID ACCOUNT_STYLE_ID = UUID.fromString("60000000-0000-0000-0000-000000000006");

    private FinancePaymentRepository paymentRepo;
    private FinancePaymentLineRepository lineRepo;
    private ArApLedgerRepository ledgerRepo;
    private SecurityContextCurrentUser currentUser;
    private EntityManager em;
    private Query postingCount;
    private Query accountLock;
    private Query accountUpdate;
    private Query reconciliationInsert;
    private Query createReplay;
    private GlPostingService glPostingService;
    private AccountFlowLedgerService accountFlowLedger;
    private final ArrayDeque<Long> postingCounts = new ArrayDeque<>();
    private final Map<UUID, FinancePayment> payments = new HashMap<>();
    private final Map<UUID, List<FinancePaymentLine>> linesByPayment = new HashMap<>();
    private final Map<UUID, ArApLedger> ledgers = new HashMap<>();
    private FinancePaymentService service;

    @BeforeEach
    void setUp() {
        paymentRepo = mock(FinancePaymentRepository.class);
        lineRepo = mock(FinancePaymentLineRepository.class);
        ledgerRepo = mock(ArApLedgerRepository.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        EmployeeNameResolver names = mock(EmployeeNameResolver.class);
        DocNumberService numbers = mock(DocNumberService.class);
        FinanceDocumentAccessPolicy access = mock(FinanceDocumentAccessPolicy.class);
        glPostingService = mock(GlPostingService.class);
        accountFlowLedger = mock(AccountFlowLedgerService.class);
        em = mock(EntityManager.class);

        when(paymentRepo.save(any(FinancePayment.class))).thenAnswer(invocation -> {
            FinancePayment payment = invocation.getArgument(0);
            payments.put(payment.getId(), payment);
            return payment;
        });
        when(paymentRepo.findById(any(UUID.class))).thenAnswer(invocation ->
                Optional.ofNullable(payments.get(invocation.getArgument(0))));
        when(paymentRepo.findByBillNo(anyString())).thenReturn(Optional.empty());

        when(lineRepo.save(any(FinancePaymentLine.class))).thenAnswer(invocation -> {
            FinancePaymentLine line = invocation.getArgument(0);
            List<FinancePaymentLine> stored = linesByPayment.computeIfAbsent(
                    line.getPaymentId(), ignored -> new ArrayList<>());
            stored.removeIf(existing -> existing.getId().equals(line.getId()));
            stored.add(line);
            return line;
        });
        when(lineRepo.findByPaymentIdOrderByLineNoAsc(any(UUID.class))).thenAnswer(invocation ->
                linesByPayment.getOrDefault(invocation.getArgument(0), List.of()).stream()
                        .sorted(Comparator.comparing(FinancePaymentLine::getLineNo))
                        .toList());

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
        Query idempotencyLock = query();
        createReplay = query();
        Query supplierLookup = query();
        Query hierarchy=query();Query postingStyle=query();
        when(hierarchy.getSingleResult()).thenReturn(1L);
        when(postingStyle.getSingleResult()).thenReturn(ACCOUNT_STYLE_ID);
        when(postingCount.getSingleResult()).thenAnswer(ignored ->
                postingCounts.isEmpty() ? 0L : postingCounts.removeFirst());
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[] {CURRENCY_ID, "USD", "美元", false,ACCOUNT_STYLE_ID}));
        when(accountUpdate.executeUpdate()).thenReturn(1);
        when(reconciliationInsert.executeUpdate()).thenReturn(1);
        when(idempotencyLock.getSingleResult()).thenReturn(1L);
        when(createReplay.getResultList()).thenReturn(List.of());
        when(supplierLookup.getSingleResult()).thenReturn("测试供应商");
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if(sql.contains("PAYMENT_STYLE_HIERARCHY"))return hierarchy;
            if(sql.contains("system_posting_style_id(:roleKey)"))return postingStyle;
            if (sql.contains("pg_advisory_xact_lock(hashtextextended")) {
                return idempotencyLock;
            }
            if (sql.contains("SELECT id FROM finance_payments")
                    && sql.contains("create_idempotency_key")) {
                return createReplay;
            }
            if (sql.contains("FROM finance_reconciliations") && sql.contains("COUNT(*)")) {
                return postingCount;
            }
            if (sql.contains("FROM accounts account")) {
                return accountLock;
            }
            if (sql.contains("UPDATE accounts")) {
                return accountUpdate;
            }
            if (sql.contains("INSERT INTO finance_reconciliations")) {
                return reconciliationInsert;
            }
            if (sql.contains("SELECT name FROM suppliers")) {
                return supplierLookup;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });

        when(numbers.nextNumber(DocNumberPrefix.FIN_PAYMENT)).thenReturn("CF-TEST-1");
        when(currentUser.requireEmployeeId()).thenReturn(MAKER_ID);
        service = new FinancePaymentService(
                mock(com.uten.imp.features.finance.payables.SupplierClosedPeriodGuard.class),
                paymentRepo, lineRepo, ledgerRepo, tx,
                currentUser, names, em, numbers, access, glPostingService,
                accountFlowLedger,
                mock(com.uten.imp.features.finance.payables.SupplierPayableHoldGuard.class));
    }

    @Test
    void draftIgnoresClientDerivedAmountsAndUsesThePayableBookRate() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");

        FinancePaymentDetail detail = service.create(request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "9999.0000", "-8888.0000"));

        assertMoney(detail.getAmountOriginal(), "30.0000");
        assertMoney(detail.getAmountLocal(), "216.0000");
        assertThat(detail.getItems()).hasSize(1);
        assertMoney(detail.getItems().getFirst().getAmountLocal(), "216.0000");
        assertMoney(detail.getItems().getFirst().getAppliedAmountLocal(), "210.0000");
        assertMoney(detail.getItems().getFirst().getExchangeDiff(), "6.0000");
        assertThat(payments.get(detail.getId()).getAmountAuthorityVersion()).isEqualTo((short) 2);
    }

    @Test
    void createRejectsAMissingExchangeRateInsteadOfUsingTheEntityDefault() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        FinancePaymentSaveRequest request = request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "216.0000", "6.0000");
        request.setExchangeRate(null);

        assertThatThrownBy(() -> service.create(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("付款汇率不能为空");

        verify(paymentRepo, never()).save(any());
    }

    @Test
    void createRejectsAMissingIdempotencyKeyBeforeSaving() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        FinancePaymentSaveRequest request = request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "216.0000", "6.0000");
        request.setCreateIdempotencyKey(null);

        assertThatThrownBy(() -> service.create(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("付款创建幂等键格式不正确");
        verify(paymentRepo, never()).save(any());
    }

    @Test
    void createIdempotencyReplaysTheSameCanonicalRequest() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        FinancePaymentSaveRequest firstRequest = request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "216.0000", "6.0000");
        firstRequest.setCreateIdempotencyKey("payment-retry-001");
        FinancePaymentDetail first = service.create(firstRequest);
        when(createReplay.getResultList()).thenReturn(List.of(first.getId()));

        FinancePaymentSaveRequest retry = request(
                payable, CURRENCY_ID, "7.2", "30.0", "9999.0000", "-8888.0000");
        retry.setCreateIdempotencyKey("payment-retry-001");
        FinancePaymentDetail replay = service.create(retry);

        assertThat(replay.getId()).isEqualTo(first.getId());
        assertThat(payments).hasSize(1);
        assertThat(replay.getCreateIdempotencyKey()).isEqualTo("payment-retry-001");
    }

    @Test
    void createIdempotencyRejectsDifferentEffectiveContent() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        FinancePaymentSaveRequest firstRequest = request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "216.0000", "6.0000");
        firstRequest.setCreateIdempotencyKey("payment-retry-002");
        FinancePaymentDetail first = service.create(firstRequest);
        when(createReplay.getResultList()).thenReturn(List.of(first.getId()));
        FinancePaymentSaveRequest changed = request(
                payable, CURRENCY_ID, "7.200000", "31.0000", "223.2000", "6.2000");
        changed.setCreateIdempotencyKey("payment-retry-002");

        assertThatThrownBy(() -> service.create(changed))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("幂等键已用于不同内容");
        assertThat(payments).hasSize(1);
    }

    @Test
    void draftUpdateRequiresTheCurrentOptimisticVersion() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        FinancePaymentDetail draft = service.create(request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "216.0000", "6.0000"));
        payments.get(draft.getId()).setVersion(4L);
        FinancePaymentSaveRequest stale = request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "216.0000", "6.0000");
        stale.setExpectedVersion(3L);

        assertThatThrownBy(() -> service.update(draft.getId(), stale))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("付款草稿已被其他操作更新");
        verify(lineRepo, never()).deleteByPaymentId(any(UUID.class));
    }

    @Test
    void approvalRejectsDirectPaymentUntilSupplierPrepaymentAssetChainExists() {
        FinancePaymentSaveRequest request = new FinancePaymentSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 9));
        request.setSupplierId(SUPPLIER_ID);
        request.setAccountId(ACCOUNT_ID);
        request.setCurrencyId(CURRENCY_ID);
        request.setExchangeRate(new BigDecimal("7.200000"));
        request.setAmountOriginal(new BigDecimal("30.0000"));
        bankFacts(request,new BigDecimal("30.0000"));
        request.setCreateIdempotencyKey(UUID.randomUUID().toString());
        request.setItems(List.of());
        FinancePaymentDetail draft = service.create(request);
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.add(0L);

        assertThatThrownBy(() -> service.approve(draft.getId()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("供应商预付资产科目")
                .hasMessageContaining("当前禁止审核");

        assertThat(payments.get(draft.getId()).getStatus()).isZero();
        verify(accountUpdate, never()).executeUpdate();
        verify(reconciliationInsert, never()).executeUpdate();
    }

    @Test
    void rejectsCrossCurrencyReferencesBeforeSavingLines() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        UUID otherCurrency = UUID.randomUUID();
        payable.setCurrencyId(otherCurrency);

        assertThatThrownBy(() -> service.create(request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "216.0000", "6.0000")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("跨币种核销");

        verify(lineRepo, never()).save(any());
    }

    @Test
    void approvalRechecksTheLockedBalanceAndRejectsConcurrentOverpayment() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        FinancePaymentDetail draft = service.create(request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "216.0000", "6.0000"));
        payable.setAmountReceivedOriginal(new BigDecimal("80.0000"));
        payable.setAmountReceivedLocal(new BigDecimal("576.0000"));
        payable.setAmountBalanceOriginal(new BigDecimal("20.0000"));
        payable.setAmountSettled(new BigDecimal("560.0000"));
        payable.setAmountBalance(new BigDecimal("140.0000"));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);

        assertThatThrownBy(() -> service.approve(draft.getId()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("超过应付未付金额");

        verify(accountUpdate, never()).executeUpdate();
        verify(reconciliationInsert, never()).executeUpdate();
    }

    @Test
    void partialPaymentUsesTheConfirmedRemainingBookPoolRatherThanRecalculatingItsHistoricalQuote() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        FinancePaymentDetail draft = service.create(request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "216.0000", "6.0000"));
        payable.setAmountBalanceOriginal(new BigDecimal("50.0000"));
        payable.setAmountReceivedOriginal(new BigDecimal("50.0000"));
        payable.setAmountReceivedLocal(new BigDecimal("600.0000"));
        payable.setAmountSettled(new BigDecimal("600.0000"));
        payable.setAmountBalance(new BigDecimal("100.0000"));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.add(0L);

        FinancePaymentDetail approved=service.approve(draft.getId());
        assertMoney(approved.getItems().getFirst().getAppliedAmountLocal(),"60.0000");
        assertMoney(payable.getAmountBalanceOriginal(),"20.0000");
        assertMoney(payable.getAmountBalance(),"40.0000");
    }

    @Test
    void approvalAndReverseUseServerCashAndBookAmountsSymmetrically() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        FinancePaymentDetail draft = service.create(request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "9999.0000", "-8888.0000"));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.add(0L);

        FinancePaymentDetail approved = service.approve(draft.getId());

        assertThat(approved.getStatus()).isEqualTo((short) 1);
        assertMoney(payable.getAmountReceivedOriginal(), "30.0000");
        assertMoney(payable.getAmountReceivedLocal(), "216.0000");
        assertMoney(payable.getAmountSettled(), "210.0000");
        assertMoney(payable.getAmountBalanceOriginal(), "70.0000");
        assertMoney(payable.getAmountBalance(), "490.0000");
        verify(accountUpdate).setParameter("amount", new BigDecimal("30.0000"));
        verify(reconciliationInsert).setParameter("outAmt", new BigDecimal("30.0000"));

        postingCounts.add(1L);
        FinancePaymentDetail reversed = service.reverse(draft.getId());

        assertThat(reversed.getStatus()).isEqualTo((short) -1);
        assertMoney(payable.getAmountReceivedOriginal(), "0.0000");
        assertMoney(payable.getAmountReceivedLocal(), "0.0000");
        assertMoney(payable.getAmountSettled(), "0.0000");
        assertMoney(payable.getAmountBalanceOriginal(), "100.0000");
        assertMoney(payable.getAmountBalance(), "700.0000");
        verify(glPostingService).reverseActualBankPayment(org.mockito.ArgumentMatchers.eq(draft.getId()),any(OffsetDateTime.class));
        verify(accountUpdate).setParameter("amount", new BigDecimal("-30.0000"));
        verify(accountFlowLedger).reverse(
                org.mockito.ArgumentMatchers.eq(FinancePaymentService.RECON_SOURCE),
                org.mockito.ArgumentMatchers.eq(draft.getId()),
                any(OffsetDateTime.class),
                org.mockito.ArgumentMatchers.eq("采购付款红冲"));
    }

    @Test
    void baseCurrencyUuidUsesLocalAmountEvenWhenLabelsPretendUsd() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        UUID base=UUID.randomUUID();
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[] {base, "USD", "美元", true,ACCOUNT_STYLE_ID}));
        var req=request(payable,CURRENCY_ID,"7.200000","30.0000","9999.0000","-8888.0000");
        req.setAccountCurrencyId(base);req.setAccountAmount(new BigDecimal("216.0000"));
        FinancePaymentDetail draft=service.create(req);
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.add(0L);

        service.approve(draft.getId());

        verify(accountUpdate).setParameter("amount", new BigDecimal("216.0000"));
        verify(reconciliationInsert).setParameter("outAmt", new BigDecimal("216.0000"));
    }

    @Test
    void foreignCurrencyUuidCannotMasqueradeAsRmbByEditableLabels() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        FinancePaymentDetail draft = service.create(request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "9999.0000", "-8888.0000"));
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[] {CURRENCY_ID, "CNY", "人民币", false,ACCOUNT_STYLE_ID}));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.add(0L);

        service.approve(draft.getId());

        verify(accountUpdate).setParameter("amount", new BigDecimal("30.0000"));
        verify(reconciliationInsert).setParameter("outAmt", new BigDecimal("30.0000"));
    }

    @ParameterizedTest
    @ValueSource(strings = {"missing-local", "insufficient-original", "insufficient-local"})
    void reverseFailsClosedWhenTheAuthoritativePaymentBreakdownIsIncomplete(String corruption) {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        FinancePaymentDetail draft = service.create(request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "216.0000", "6.0000"));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.add(0L);
        service.approve(draft.getId());
        switch (corruption) {
            case "missing-local" -> payable.setAmountReceivedLocal(null);
            case "insufficient-original" -> payable.setAmountReceivedOriginal(new BigDecimal("29.9999"));
            case "insufficient-local" -> payable.setAmountReceivedLocal(new BigDecimal("215.9999"));
            default -> throw new AssertionError("unexpected corruption: " + corruption);
        }
        postingCounts.add(1L);
        clearInvocations(accountUpdate, accountFlowLedger);

        assertThatThrownBy(() -> service.reverse(draft.getId()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("应付双币累计");

        assertMoney(payable.getAmountSettled(), "210.0000");
        verify(accountUpdate, never()).executeUpdate();
        verify(accountFlowLedger, never()).reverse(
                anyString(), any(UUID.class), any(OffsetDateTime.class), anyString());
    }

    @Test
    void reverseRejectsAnApprovedClientEraPaymentWithoutAnAuthorityMarker() {
        ArApLedger payable = payable("100.0000", "700.0000", "7.000000");
        FinancePaymentDetail draft = service.create(request(
                payable, CURRENCY_ID, "7.200000", "30.0000", "216.0000", "6.0000"));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.add(0L);
        service.approve(draft.getId());
        payments.get(draft.getId()).setAmountAuthorityVersion((short) 0);
        clearInvocations(accountUpdate, accountFlowLedger);

        assertThatThrownBy(() -> service.reverse(draft.getId()))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("历史付款金额尚未经过服务端核验");

        assertMoney(payable.getAmountSettled(), "210.0000");
        verify(accountUpdate, never()).executeUpdate();
        verify(accountFlowLedger, never()).reverse(
                anyString(), any(UUID.class), any(OffsetDateTime.class), anyString());
    }

    @Test
    void finalPaymentUsesTheExactRemainingBookValue() {
        ArApLedger payable = payable("100.0000", "700.0001", "7.000000");
        payable.setAmountReceivedOriginal(new BigDecimal("32.0000"));
        payable.setAmountReceivedLocal(new BigDecimal("230.4000"));
        payable.setAmountBalanceOriginal(new BigDecimal("68.0000"));
        payable.setAmountSettled(new BigDecimal("224.0000"));
        payable.setAmountBalance(new BigDecimal("476.0001"));

        FinancePaymentDetail detail = service.create(request(
                payable, CURRENCY_ID, "7.200000", "68.0000", "1.0000", "1.0000"));

        assertMoney(detail.getItems().getFirst().getAmountLocal(), "489.6000");
        assertMoney(detail.getItems().getFirst().getAppliedAmountLocal(), "476.0001");
        assertMoney(detail.getItems().getFirst().getExchangeDiff(), "13.5999");
    }

    private ArApLedger payable(String original, String originalLocal, String rate) {
        ArApLedger ledger = new ArApLedger();
        ledger.setDirection("AP");
        ledger.setSourceDocType("PURCHASE_RECEIPT");
        ledger.setBillNo("CJ-TEST-1");
        ledger.setBillDate(LocalDate.of(2026, 8, 1));
        ledger.setSupplierId(SUPPLIER_ID);
        ledger.setCurrencyId(CURRENCY_ID);
        ledger.setExchangeRate(new BigDecimal(rate));
        ledger.setAmountOriginal(new BigDecimal(original));
        ledger.setAmountOriginalLocal(new BigDecimal(originalLocal));
        ledger.setAmountReceivedOriginal(BigDecimal.ZERO.setScale(4));
        ledger.setAmountReceivedLocal(BigDecimal.ZERO.setScale(4));
        ledger.setAmountWriteOffOriginal(BigDecimal.ZERO.setScale(4));
        ledger.setAmountWriteOffLocal(BigDecimal.ZERO.setScale(4));
        ledger.setAmountBalanceOriginal(new BigDecimal(original));
        ledger.setAmountSettled(BigDecimal.ZERO.setScale(4));
        ledger.setAmountBalance(new BigDecimal(originalLocal));
        ledgers.put(ledger.getId(), ledger);
        return ledger;
    }

    private FinancePaymentSaveRequest request(
            ArApLedger ledger,
            UUID currencyId,
            String paymentRate,
            String amountOriginal,
            String clientAmountLocal,
            String clientExchangeDiff) {
        FinancePaymentLineInput line = new FinancePaymentLineInput();
        line.setAppliedLedgerId(ledger.getId());
        line.setAppliedBillNo("CLIENT-CONTROLLED");
        line.setSupplierId(SUPPLIER_ID);
        line.setAmountOriginal(new BigDecimal(amountOriginal));
        line.setAmountLocal(new BigDecimal(clientAmountLocal));
        line.setExchangeDiff(new BigDecimal(clientExchangeDiff));

        FinancePaymentSaveRequest request = new FinancePaymentSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 9));
        request.setSupplierId(SUPPLIER_ID);
        request.setAccountId(ACCOUNT_ID);
        bankFacts(request,new BigDecimal(amountOriginal));
        request.setCurrencyId(currencyId);
        request.setExchangeRate(new BigDecimal(paymentRate));
        request.setAmountOriginal(new BigDecimal("999.0000"));
        request.setAmountLocal(new BigDecimal("9999.0000"));
        request.setCreateIdempotencyKey(UUID.randomUUID().toString());
        request.setItems(List.of(line));
        return request;
    }

    private static void bankFacts(FinancePaymentSaveRequest request,BigDecimal actual) {
        request.setAccountCurrencyId(CURRENCY_ID);request.setAccountAmount(actual);
        request.setBankFeeAccountAmount(BigDecimal.ZERO);request.setBankReference("BANK-PAYMENT-TEST");
        request.setBankBookedAt(OffsetDateTime.parse("2026-08-09T10:00:00+08:00"));
    }

    private Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }

    @Test
    void actualBankDebitAndExplicitFeeOverrideTheReferenceQuoteAndReverseTheirOriginalSnapshots() {
        ArApLedger payable=payable("100","700","7");UUID base=UUID.randomUUID();
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(new Object[]{base,"CNY","人民币",true,ACCOUNT_STYLE_ID}));
        var req=request(payable,CURRENCY_ID,"7.2","50.1234","999","999");
        req.setAccountCurrencyId(base);req.setAccountAmount(new BigDecimal("327.8885"));req.setBankFeeAccountAmount(new BigDecimal("3"));
        var draft=service.create(req);
        assertMoney(draft.getAmountLocal(),"324.8885");assertMoney(draft.getAccountAmount(),"327.8885");assertMoney(draft.getBankFee(),"3");
        assertMoney(draft.getItems().getFirst().getAppliedAmountLocal(),"350.8638");
        assertMoney(draft.getItems().getFirst().getExchangeDiff(),"-25.9753");
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);postingCounts.add(0L);service.approve(draft.getId());
        verify(glPostingService).postActualBankPayment(draft.getId());
        verify(accountUpdate).setParameter("amount",new BigDecimal("327.8885"));
        assertMoney(payable.getAmountReceivedLocal(),"324.8885");
        postingCounts.add(1L);service.reverse(draft.getId());
        verify(accountUpdate).setParameter("amount",new BigDecimal("-327.8885"));
        assertMoney(payable.getAmountBalanceOriginal(),"100");assertMoney(payable.getAmountBalance(),"700");
    }

    @Test
    void sameCurrencyRequiresExactBankReconciliationAndRetainsThirtyDigitCashFeeAndFxSnapshots() {
        ArApLedger payable=payable("1","7","7");
        var req=request(payable,CURRENCY_ID,"7.000001","0.000000000000000000000001","0","0");
        req.setAccountAmount(new BigDecimal("0.000000000000000000000002"));
        assertThatThrownBy(()->service.create(req)).isInstanceOf(ApiException.class).hasMessageContaining("同币种实际银行扣款");
        req.setCreateIdempotencyKey(UUID.randomUUID().toString());req.setBankFeeAccountAmount(new BigDecimal("0.000000000000000000000001"));
        var draft=service.create(req);
        assertMoney(draft.getAccountAmountLocal(),"0.000000000000000000000014000002");
        assertMoney(draft.getBankFee(),"0.000000000000000000000007000001");
        assertMoney(draft.getItems().getFirst().getExchangeDiff(),"0.000000000000000000000000000001");
        var json=new com.fasterxml.jackson.databind.ObjectMapper().findAndRegisterModules().valueToTree(draft);
        assertThat(json.get("accountAmountExact").asText()).isEqualTo("0.000000000000000000000002");
        assertThat(json.get("accountAmountLocalExact").asText()).isEqualTo("0.000000000000000000000014000002");
        assertThat(json.get("bankFeeExact").asText()).isEqualTo("0.000000000000000000000007000001");
        assertThat(json.get("settlementAuthorityVersion").asInt()).isEqualTo(2);
        assertThat(json.get("bankAuthority")).isNull();
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);postingCounts.add(0L);service.approve(draft.getId());
        postingCounts.add(1L);service.reverse(draft.getId());assertMoney(payable.getAmountBalance(),"7");
    }

    @Test
    void approvedV1PaymentStillReversesItsStoredCashAndBookSnapshots() {
        ArApLedger payable=payable("100","700","7");
        var draft=service.create(request(payable,CURRENCY_ID,"7.2","30","0","0"));
        FinancePayment payment=payments.get(draft.getId());payment.setAmountAuthorityVersion((short)1);payment.setStatus((short)1);
        payable.setAmountReceivedOriginal(new BigDecimal("30"));payable.setAmountReceivedLocal(new BigDecimal("216"));
        payable.setAmountSettled(new BigDecimal("210"));payable.setAmountBalanceOriginal(new BigDecimal("70"));payable.setAmountBalance(new BigDecimal("490"));
        postingCounts.add(1L);service.reverse(payment.getId());
        verify(glPostingService).removePaymentDoc(payment.getId(),payment.getBillNo(),payment.getBillDate());
        verify(glPostingService,never()).reverseActualBankPayment(any(),any());
        assertMoney(payable.getAmountBalanceOriginal(),"100");assertMoney(payable.getAmountBalance(),"700");
    }

    @Test
    void theSameBankInstantAndRepresentationalZerosReplayOneActualPayment() {
        ArApLedger payable=payable("100","700","7");
        var first=request(payable,CURRENCY_ID,"7.2","30","0","0");
        var created=service.create(first);when(createReplay.getResultList()).thenReturn(List.of(created.getId()));
        var retry=request(payable,CURRENCY_ID,"7.200000","30.0000","0","0");
        retry.setCreateIdempotencyKey(first.getCreateIdempotencyKey());
        retry.setBankBookedAt(first.getBankBookedAt().withOffsetSameInstant(java.time.ZoneOffset.UTC));
        retry.setBankReference("  BANK-PAYMENT-TEST  ");
        assertThat(service.create(retry).getId()).isEqualTo(created.getId());
    }

    @Test
    void aFrozenV417RequestHashReplaysItsApprovedV1WithoutInventingBankAuthority() {
        var source=new ArApLedger();source.setId(UUID.fromString("70000000-0000-0000-0000-000000000007"));
        var request=request(source,CURRENCY_ID,"7.2","30","0","0");
        request.setAccountAmount(null);request.setAccountCurrencyId(null);request.setBankFeeAccountAmount(null);
        request.setBankReference(null);request.setBankBookedAt(null);
        var original=new FinancePayment();original.setMakerId(MAKER_ID);original.setBillNo("CF-V1-HISTORY");
        original.setBillDate(LocalDate.of(2026,8,9));original.setStatus((short)1);original.setAmountAuthorityVersion((short)1);
        original.setCreateIdempotencyKey(request.getCreateIdempotencyKey());
        // Fixed legacy field sequence, before bank metadata existed; independently generated SHA-256 fixture.
        original.setCreateRequestHash("b5f25143c79abf81269656695b65c09426d6eaa78bb86c14cf359f6d53b7d50b");
        payments.put(original.getId(),original);when(createReplay.getResultList()).thenReturn(List.of(original.getId()));
        var replay=service.create(request);
        assertThat(replay.getId()).isEqualTo(original.getId());assertThat(replay.getAmountAuthorityVersion()).isEqualTo((short)1);
        assertThat(replay.getAccountAmount()).isNull();verify(paymentRepo,never()).save(any());
        request.setAccountAmount(new BigDecimal("30"));
        assertThatThrownBy(()->service.create(request)).isInstanceOf(ApiException.class).hasMessageContaining("幂等键已用于不同内容");
    }

    private static void assertMoney(BigDecimal actual, String expected) {
        assertThat(actual).isNotNull();
        assertThat(actual.compareTo(new BigDecimal(expected))).isZero();
    }
}
