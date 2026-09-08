package com.uten.imp.features.finance.receipt;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.accountflow.AccountFlowLedgerService;
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
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.clearInvocations;
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
    private static final UUID AGENT_ID = UUID.fromString("70000000-0000-0000-0000-000000000007");
    private static final UUID FEE_ACCOUNT_ID = UUID.fromString("80000000-0000-0000-0000-000000000008");
    private static final UUID ACCOUNT_STYLE_ID = UUID.fromString("90000000-0000-0000-0000-000000000009");
    private static final UUID FEE_ACCOUNT_STYLE_ID = UUID.fromString("a0000000-0000-0000-0000-00000000000a");

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
    private Query hierarchyLock;
    private Query idempotencyLock;
    private Query createReplay;
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
            if(receipt.getVersion()==null)receipt.setVersion(0L);
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
        Query clientLookup = query();
        Query supplierLookup = query();
        Query expenseStyleCount = query();
        hierarchyLock = query();
        idempotencyLock = query();
        createReplay = query();
        Query flowIntegrity = query();
        Query projectionIntegrity = query();
        Query postingRole = query();
        when(postingCount.getSingleResult()).thenAnswer(ignored ->
                postingCounts.isEmpty() ? 0L : postingCounts.removeFirst());
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[] {ACCOUNT_ID, CURRENCY_ID, false, "USD", "美元",ACCOUNT_STYLE_ID}));
        when(accountUpdate.executeUpdate()).thenReturn(1);
        when(reconciliationInsert.executeUpdate()).thenReturn(1);
        when(createReplay.getResultList()).thenReturn(List.of());
        when(flowIntegrity.getSingleResult()).thenReturn(1L);
        when(projectionIntegrity.getResultList()).thenReturn(
                List.<Object[]>of(new Object[]{1L,1L}));
        when(postingRole.getSingleResult()).thenReturn(EXPENSE_STYLE_ID);
        when(idempotencyLock.getSingleResult()).thenReturn(1L);
        when(clientLookup.getSingleResult()).thenReturn("测试客户");
        when(supplierLookup.getResultList()).thenReturn(List.of("测试外贸公司"));
        when(expenseStyleCount.getSingleResult()).thenReturn(1L);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            nativeSql.add(sql);
            if (sql.contains("PAYMENT_STYLE_HIERARCHY")) {
                return hierarchyLock;
            }
            if (sql.contains("FIN_RECEIPT_CREATE|")
                    || sql.contains("pg_advisory_xact_lock(hashtextextended")) {
                return idempotencyLock;
            }
            if (sql.contains("SELECT id FROM finance_receipts")
                    && sql.contains("create_idempotency_key")) {
                return createReplay;
            }
            if (sql.contains("v_receipt_flow_integrity")
                    && sql.contains("v_receipt_gl_integrity")) {
                return projectionIntegrity;
            }
            if (sql.contains("FROM v_receipt_flow_integrity")) {
                return flowIntegrity;
            }
            if (sql.contains("FROM finance_reconciliations") && sql.contains("COUNT(*)")) {
                return postingCount;
            }
            if (sql.contains("SELECT account.id,account.currency_id")
                    && sql.contains("FROM accounts account")) {
                return accountLock;
            }
            if (sql.contains("UPDATE accounts")) {
                return accountUpdate;
            }
            if (sql.contains("INSERT INTO finance_reconciliations")) {
                return reconciliationInsert;
            }
            if (sql.contains("SELECT name FROM clients")) {
                return clientLookup;
            }
            if (sql.contains("SELECT name FROM suppliers")) {
                return supplierLookup;
            }
            if (sql.contains("FROM payment_styles") && sql.contains("COUNT(*)")) {
                return expenseStyleCount;
            }
            if (sql.contains("system_posting_style_id(:roleKey)")) {
                return postingRole;
            }
            throw new AssertionError("unexpected SQL: " + sql);
        });

        AtomicInteger sequence = new AtomicInteger();
        when(numbers.nextNumber(DocNumberPrefix.FIN_RECEIPT))
                .thenAnswer(ignored -> "XS-TEST-" + sequence.incrementAndGet());
        when(currentUser.requireEmployeeId()).thenReturn(MAKER_ID);
        when(access.hasAuthority("customer_prepayment:view")).thenReturn(true);
        when(access.hasAuthority("finance:view:all")).thenReturn(true);
        var sourceAllocation=mock(com.uten.imp.features.finance.receivables.FinanceReceiptSourceAllocationService.class);
        when(sourceAllocation.plannedBookAmount(any(),any())).thenAnswer(invocation->{
            ArApLedger ledger=invocation.getArgument(0);BigDecimal original=invocation.getArgument(1);
            return com.uten.imp.common.finance.FinancialBookAllocation.part(original,ledger.getAmountBalanceOriginal(),ledger.getAmountBalance());
        });
        service = new FinanceReceiptService(
                receiptRepo, lineRepo, ledgerRepo, arApService, tx,
                currentUser, names, em, numbers, access, glPosting,
                sourceAllocation,
                mock(AccountFlowLedgerService.class));
    }

    @Test
    void draftSeparatesGrossSettlementNetAccountAndDeductedFee() {
        ArApLedger ledger = receivable("100.0000", "7.000000");

        FinanceReceiptDetail detail = service.create(request(
                ledger, "30.0000", "7.200000", "2.0000", "14.4000",
                "9999.0000", "-8888.0000"));

        FinanceReceiptLine saved = onlyLine(detail.getId());
        assertMoney(saved.getAmountOriginal(), "30.0000");
        assertMoney(saved.getAmountLocal(), "216.0000");
        assertMoney(saved.getWriteOffLocal(), "0.0000");
        assertMoney(saved.getAppliedAmountLocal(), "210.0000");
        assertMoney(saved.getExchangeDiff(), "6.0000");
        assertMoney(saved.getExchangeRate(), "7.200000");
        assertMoney(detail.getAmountOriginal(), "30.0000");
        assertMoney(detail.getAmountLocal(), "216.0000");
        assertMoney(detail.getBankFeeAccountAmount(), "2.0000");
        assertMoney(detail.getBankFee(), "14.4000");
        assertMoney(detail.getAccountAmount(), "28.0000");
        assertMoney(detail.getAccountAmountLocal(), "201.6000");
    }

    @Test
    void tradeAgentUsdSettlementPostsGrossArAndNetCnyAccount() {
        ArApLedger ledger=receivable("100000.0000","7.000000");
        UUID cnyCurrency=UUID.randomUUID();
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{ACCOUNT_ID,cnyCurrency,true,"CNY","人民币",ACCOUNT_STYLE_ID}));
        FinanceReceiptSaveRequest request=request(
                ledger,"1000.0000","7.200000","0.0000","0.0000",
                "0.0000","0.0000");
        request.setAccountCurrencyId(cnyCurrency);
        request.setAccountAmount(request.getAmountOriginal().multiply(request.getExchangeRate()));
        request.setSettlementChannel("TRADE_AGENT_CONVERSION");
        request.setSettlementAgentSupplierId(AGENT_ID);
        request.setExchangeRateSource("TRADE_AGENT_STATEMENT");
        request.setAgentStatementNo("AGENT-SETTLE-20260808");
        request.setOtherFeeAccountAmount(new BigDecimal("72.0000"));
        request.setAccountAmount(new BigDecimal("7128.0000"));
        request.setOtherFeeStyleId(EXPENSE_STYLE_ID);
        request.setFeeSettlementMode("DEDUCTED_FROM_PROCEEDS");
        request.setFeeBearer("COMPANY");

        FinanceReceiptDetail draft=service.create(request);
        assertMoney(draft.getAmountOriginal(),"1000.0000");
        assertMoney(draft.getSettlementGrossLocal(),"7200.0000");
        assertMoney(draft.getOtherFee(),"72.0000");
        assertMoney(draft.getAccountAmount(),"7128.0000");
        assertMoney(draft.getAccountAmountLocal(),"7128.0000");
        assertThat(draft.getSettlementAgentNameSnapshot()).isEqualTo("测试外贸公司");

        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L,0L));
        service.approve(draft.getId());

        assertMoney(ledger.getAmountReceivedOriginal(),"1000.0000");
        assertMoney(ledger.getAmountReceivedLocal(),"7200.0000");
        assertMoney(ledger.getAmountWriteOffOriginal(),"0.0000");
        assertMoney(ledger.getAmountBalanceOriginal(),"99000.0000");
        assertMoney(ledger.getAmountSettled(),"7000.0000");
        assertMoney(ledger.getAmountBalance(),"693000.0000");
        FinanceReceiptLine line=onlyLine(draft.getId());
        assertMoney(line.getExchangeDiff(),"200.0000");
        verify(accountUpdate).setParameter("amount",new BigDecimal("7128.0000"));
        verify(reconciliationInsert).setParameter("amount",new BigDecimal("7128.0000"));
    }

    @Test
    void v1RejectsMissingBankReferenceBeforeAccountMutation() {
        ArApLedger ledger=receivable("100.0000","7.000000");
        FinanceReceiptSaveRequest request=request(
                ledger,"10.0000","7.200000","0.0000","0.0000",
                "0.0000","0.0000");
        request.setBankReference("   ");

        assertThatThrownBy(() -> service.create(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("真实银行入账流水号");
        verify(accountUpdate,never()).executeUpdate();
        verify(reconciliationInsert,never()).executeUpdate();
    }

    @Test
    void tradeAgentRejectsMissingAgentStatementNumber() {
        ArApLedger ledger=receivable("100.0000","7.000000");
        UUID cnyCurrency=UUID.randomUUID();
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{ACCOUNT_ID,cnyCurrency,true,"CNY","人民币",ACCOUNT_STYLE_ID}));
        FinanceReceiptSaveRequest request=request(
                ledger,"10.0000","7.200000","0.0000","0.0000",
                "0.0000","0.0000");
        request.setAccountCurrencyId(cnyCurrency);
        request.setAccountAmount(request.getAmountOriginal().multiply(request.getExchangeRate()));
        request.setSettlementChannel("TRADE_AGENT_CONVERSION");
        request.setSettlementAgentSupplierId(AGENT_ID);
        request.setExchangeRateSource("TRADE_AGENT_STATEMENT");
        request.setAgentStatementNo(" ");

        assertThatThrownBy(() -> service.create(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("代理结算单号");
        verify(accountUpdate,never()).executeUpdate();
        verify(reconciliationInsert,never()).executeUpdate();
    }

    @Test
    void separatelyPaidFeePostsGrossReceiptAndRealFeePaymentAccount() {
        ArApLedger ledger=receivable("100000.0000","7.000000");
        UUID cnyCurrency=UUID.randomUUID();
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{ACCOUNT_ID,cnyCurrency,true,"CNY","人民币",ACCOUNT_STYLE_ID},
                new Object[]{FEE_ACCOUNT_ID,cnyCurrency,true,"CNY","人民币",FEE_ACCOUNT_STYLE_ID}));
        FinanceReceiptSaveRequest request=request(
                ledger,"1000.0000","7.200000","0.0000","0.0000",
                "0.0000","0.0000");
        request.setAccountCurrencyId(cnyCurrency);
        request.setAccountAmount(request.getAmountOriginal().multiply(request.getExchangeRate()));
        request.setBankFeeAccountAmount(new BigDecimal("50.0000"));
        request.setFeeSettlementMode("PAID_SEPARATELY");
        request.setFeeBearer("COMPANY");
        request.setFeePaymentAccountId(FEE_ACCOUNT_ID);

        FinanceReceiptDetail draft=service.create(request);
        assertMoney(draft.getSettlementGrossLocal(),"7200.0000");
        assertMoney(draft.getAccountAmount(),"7200.0000");
        assertMoney(draft.getAccountAmountLocal(),"7200.0000");
        assertMoney(draft.getBankFee(),"50.0000");
        assertThat(draft.getFeePaymentAccountId()).isEqualTo(FEE_ACCOUNT_ID);
        assertThat(draft.getFeeAccountCurrencyId()).isEqualTo(cnyCurrency);

        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L,0L));
        service.approve(draft.getId());

        verify(accountUpdate).setParameter("amount",new BigDecimal("7200.0000"));
        verify(accountUpdate).setParameter("amount",new BigDecimal("50.0000"));
        verify(reconciliationInsert).setParameter("amount",new BigDecimal("7200.0000"));
        verify(reconciliationInsert).setParameter("amount",new BigDecimal("50.0000"));
    }

    @Test
    void customerOrAgentBorneDeductionCannotBeMisbookedAsCompanyExpense() {
        ArApLedger ledger=receivable("100.0000","7.000000");
        FinanceReceiptSaveRequest request=request(
                ledger,"10.0000","7.200000","0.0000","0.0000",
                "0.0000","0.0000");
        request.setBankFeeAccountAmount(new BigDecimal("1.0000"));
        request.setFeeSettlementMode("DEDUCTED_FROM_PROCEEDS");
        request.setFeeBearer("CUSTOMER");

        assertThatThrownBy(() -> service.create(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("形成新的应收/索赔")
                .hasMessageContaining("不能直接记为本公司费用");
    }

    @Test
    void createIdempotencyHashDistinguishesFeeBearer() {
        ArApLedger ledger=receivable("100.0000","7.000000");
        FinanceReceiptSaveRequest request=request(
                ledger,"10.0000","7.200000","0.0000","7.2000",
                "0.0000","0.0000");
        FinanceReceiptDetail first=service.create(request);
        when(createReplay.getResultList()).thenReturn(List.of(first.getId()));
        request.setFeeBearer("CUSTOMER");

        assertThatThrownBy(() -> service.create(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("收款创建幂等键已用于不同内容");
    }

    @Test
    void createIdempotencyHashUsesEffectiveLegacyFeeFallback() {
        ArApLedger ledger=receivable("100.0000","7.000000");
        FinanceReceiptSaveRequest request=request(
                ledger,"10.0000","7.200000","0.0000","0.0000",
                "0.0000","0.0000");
        request.setBankFeeAccountAmount(null);
        request.setBankFee(new BigDecimal("1.0000"));
        request.setAccountAmount(new BigDecimal("9.0000"));
        request.setFeeSettlementMode("DEDUCTED_FROM_PROCEEDS");
        request.setFeeBearer("COMPANY");
        FinanceReceiptDetail first=service.create(request);
        when(createReplay.getResultList()).thenReturn(List.of(first.getId()));
        request.setBankFee(new BigDecimal("2.0000"));

        assertThatThrownBy(() -> service.create(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("收款创建幂等键已用于不同内容");
    }

    @Test
    void createIdempotencyHashCanonicalizesEnumsAndTrimmedEvidence() {
        ArApLedger ledger=receivable("100.0000","7.000000");
        FinanceReceiptSaveRequest request=request(
                ledger,"10.0000","7.200000","0.0000","0.0000",
                "0.0000","0.0000");
        request.setSettlementChannel(" direct_account ");
        request.setExchangeRateSource(" bank_statement ");
        request.setFeeSettlementMode(" none ");
        request.setFeeBearer(" none ");
        request.setBankReference(" BANK-TEST ");
        FinanceReceiptDetail first=service.create(request);
        when(createReplay.getResultList()).thenReturn(List.of(first.getId()));
        request.setSettlementChannel("DIRECT_ACCOUNT");
        request.setExchangeRateSource("BANK_STATEMENT");
        request.setFeeSettlementMode("NONE");
        request.setFeeBearer("NONE");
        request.setBankReference("BANK-TEST");

        assertThat(service.create(request).getId()).isEqualTo(first.getId());
    }

    @Test
    void approvalLocksGlPeriodBeforeAnyAccountRow() {
        ArApLedger ledger=receivable("100.0000","7.000000");
        FinanceReceiptDetail draft=service.create(request(
                ledger,"10.0000","7.200000","0.0000","0.0000",
                "0.0000","0.0000"));
        clearInvocations(glPosting,accountLock);
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L,0L));

        service.approve(draft.getId());

        InOrder order=inOrder(glPosting,accountLock);
        order.verify(glPosting).lockAutoProjectionPeriod(draft.getBillDate());
        order.verify(accountLock).getResultList();
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
        request.setExpectedVersion(updated.getVersion());
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
        request.setOtherFeeAccountAmount(new BigDecimal("2.0000"));
        request.setAccountAmount(new BigDecimal("28.0000"));
        request.setFeeSettlementMode("DEDUCTED_FROM_PROCEEDS");
        request.setFeeBearer("COMPANY");
        request.setOtherFeeStyleId(EXPENSE_STYLE_ID);

        FinanceReceiptDetail draft = service.create(request);

        InOrder createOrder = inOrder(hierarchyLock, receiptRepo);
        createOrder.verify(hierarchyLock).getSingleResult();
        createOrder.verify(receiptRepo, times(3)).save(any(FinanceReceipt.class));

        nativeSql.clear();
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L, 0L));
        service.approve(draft.getId());

        int lockIndex = indexOfSql("PAYMENT_STYLE_HIERARCHY");
        int validationIndex = indexOfSql("FROM payment_styles");
        assertThat(lockIndex).isZero();
        assertThat(validationIndex).isGreaterThan(lockIndex);
    }

    @Test
    void partialReceiptsKeepGrossArAndReverseOnlyTheActualNetAccountPosting() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        FinanceReceiptDetail first = service.create(request(
                ledger, "30.0000", "7.200000", "2.0000", "14.4000",
                "9999.0000", "9999.0000"));
        FinanceReceiptSaveRequest secondRequest = request(
                ledger, "70.0000", "6.900000", "0.0000", "0.0000",
                "9999.0000", "9999.0000");
        secondRequest.setBillDate(LocalDate.of(2026, 8, 9));
        FinanceReceiptDetail second = service.create(secondRequest);
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L, 0L, 0L, 0L, 1L, 0L));

        service.approve(first.getId());

        assertMoney(ledger.getAmountReceivedOriginal(), "30.0000");
        assertMoney(ledger.getAmountReceivedLocal(), "216.0000");
        assertMoney(ledger.getAmountWriteOffOriginal(), "0.0000");
        assertMoney(ledger.getAmountWriteOffLocal(), "0.0000");
        assertMoney(ledger.getAmountBalanceOriginal(), "70.0000");
        assertMoney(ledger.getAmountSettled(), "210.0000");
        assertMoney(ledger.getAmountBalance(), "490.0000");
        assertThat(ledger.isSettled()).isFalse();

        service.approve(second.getId());

        assertMoney(ledger.getAmountReceivedOriginal(), "100.0000");
        assertMoney(ledger.getAmountReceivedLocal(), "699.0000");
        assertMoney(ledger.getAmountWriteOffOriginal(), "0.0000");
        assertMoney(ledger.getAmountWriteOffLocal(), "0.0000");
        assertMoney(ledger.getAmountBalanceOriginal(), "0.0000");
        assertMoney(ledger.getAmountSettled(), "700.0000");
        assertMoney(ledger.getAmountBalance(), "0.0000");
        assertThat(ledger.isSettled()).isTrue();
        assertThat(ledger.getSettledDate()).isEqualTo(LocalDate.of(2026, 8, 9));

        FinanceReceiptLine firstLine = onlyLine(first.getId());
        FinanceReceiptLine secondLine = onlyLine(second.getId());
        assertMoney(firstLine.getExchangeRate(), "7.200000");
        assertMoney(firstLine.getAmountLocal(), "216.0000");
        assertMoney(firstLine.getWriteOffLocal(), "0.0000");
        assertMoney(firstLine.getBalanceBeforeOriginal(), "100.0000");
        assertMoney(firstLine.getBalanceAfterOriginal(), "70.0000");
        assertMoney(secondLine.getExchangeRate(), "6.900000");
        assertMoney(secondLine.getAmountLocal(), "483.0000");
        assertMoney(secondLine.getAppliedAmountLocal(), "490.0000");
        assertMoney(secondLine.getExchangeDiff(), "-7.0000");
        assertMoney(secondLine.getBalanceBeforeOriginal(), "70.0000");
        assertMoney(secondLine.getBalanceAfterOriginal(), "0.0000");

        service.reverse(second.getId());

        assertMoney(ledger.getAmountReceivedOriginal(), "30.0000");
        assertMoney(ledger.getAmountReceivedLocal(), "216.0000");
        assertMoney(ledger.getAmountWriteOffOriginal(), "0.0000");
        assertMoney(ledger.getAmountWriteOffLocal(), "0.0000");
        assertMoney(ledger.getAmountBalanceOriginal(), "70.0000");
        assertMoney(ledger.getAmountSettled(), "210.0000");
        assertMoney(ledger.getAmountBalance(), "490.0000");
        assertThat(ledger.isSettled()).isFalse();
        assertThat(ledger.getSettledDate()).isNull();
        assertThat(receipts.get(second.getId()).getStatus()).isEqualTo((short) -1);
        verify(glPosting).lockAutoProjectionPeriod(first.getBillDate());
        verify(glPosting).lockAutoProjectionPeriod(second.getBillDate());
        verify(glPosting).reverseReceiptDoc(
                org.mockito.ArgumentMatchers.eq(second.getId()), any(OffsetDateTime.class));

        verify(ledgerRepo, times(3)).findAllByIdInForUpdate(any());
        verify(em, times(3)).refresh(any(FinanceReceipt.class),
                org.mockito.ArgumentMatchers.eq(LockModeType.PESSIMISTIC_WRITE));

        // USD account: balance and account statement both use the original-currency amount.
        verify(accountUpdate).setParameter("amount", new BigDecimal("28.0000"));
        verify(accountUpdate).setParameter("amount", new BigDecimal("70.0000"));
        verify(accountUpdate).setParameter("amount", new BigDecimal("-70.0000"));
        verify(reconciliationInsert).setParameter("amount", new BigDecimal("28.0000"));
        verify(reconciliationInsert).setParameter("amount", new BigDecimal("70.0000"));
        assertThat(nativeSql.stream().filter(sql -> sql.contains("FROM accounts account")
                        && sql.contains("FOR UPDATE OF account")).findFirst())
                .hasValueSatisfying(sql -> assertThat(sql)
                        .contains("FOR UPDATE OF account")
                        .contains("COALESCE(account.is_deleted,FALSE)=FALSE")
                        .contains("currency.status='使用'"));
    }

    @Test
    void cnyAccountUsesTheSameLocalAmountForBalanceAndReconciliation() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        UUID cnyCurrency=UUID.randomUUID();
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[] {ACCOUNT_ID,cnyCurrency,true,"CNY","人民币",ACCOUNT_STYLE_ID}));
        FinanceReceiptSaveRequest request=request(
                ledger, "30.0000", "7.200000", "0.0000", "0.0000",
                "9999.0000", "9999.0000");
        request.setAccountCurrencyId(cnyCurrency);
        request.setAccountAmount(request.getAmountOriginal().multiply(request.getExchangeRate()));
        FinanceReceiptDetail draft = service.create(request);
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L,0L));

        service.approve(draft.getId());

        verify(accountUpdate).setParameter("amount", new BigDecimal("216.0000"));
        verify(reconciliationInsert).setParameter("amount", new BigDecimal("216.0000"));
    }

    @Test
    void baseCurrencyUuidAuthorityWinsOverEditableCurrencyLabels() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        UUID baseCurrency=UUID.randomUUID();
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[] {ACCOUNT_ID,baseCurrency,true,"USD","美金",ACCOUNT_STYLE_ID}));
        FinanceReceiptSaveRequest request=request(
                ledger, "30.0000", "7.200000", "0.0000", "0.0000",
                "9999.0000", "9999.0000");
        request.setAccountCurrencyId(baseCurrency);
        request.setAccountAmount(new BigDecimal("216.0000"));
        FinanceReceiptDetail draft = service.create(request);
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L,0L));

        service.approve(draft.getId());

        verify(accountUpdate).setParameter("amount", new BigDecimal("216.0000"));
    }

    @Test
    void foreignCurrencyUuidCannotMasqueradeAsRmbByEditableLabels() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        FinanceReceiptDetail draft = service.create(request(
                ledger, "30.0000", "7.200000", "0.0000", "0.0000",
                "9999.0000", "9999.0000"));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L,0L));

        service.approve(draft.getId());

        verify(accountUpdate).setParameter("amount", new BigDecimal("30.0000"));
    }

    @Test
    void settlementLineCannotChangeTheReceivableOriginalCurrency() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        FinanceReceiptSaveRequest request = request(
                ledger, "30.0000", "7.200000", "0.0000", "0.0000",
                "9999.0000", "9999.0000");
        request.getItems().getFirst().setCurrencyId(UUID.randomUUID());

        assertThatThrownBy(() -> service.create(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("核销原币必须与应收币种一致")
                .hasMessageContaining("人民币账户");
    }

    @Test
    void usdReceivableCannotPostDirectlyIntoAThirdCurrencyAccount() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        UUID hkdCurrency=UUID.randomUUID();
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[] {ACCOUNT_ID,hkdCurrency,false,"HKD","港币",ACCOUNT_STYLE_ID}));
        FinanceReceiptSaveRequest request=request(
                ledger, "30.0000", "7.200000", "0.0000", "0.0000",
                "9999.0000", "9999.0000");
        request.setAccountCurrencyId(hkdCurrency);

        assertThatThrownBy(() -> service.create(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("第三币种暂不支持");
    }

    @Test
    void v1RejectsMixingCommercialWriteOffIntoSettlementFees() {
        ArApLedger ledger = receivable("100.0000", "7.000000");
        FinanceReceiptSaveRequest request=request(
                ledger, "99.0000", "7.000000", "2.0000", "14.0000",
                "1.0000", "1.0000");
        request.getItems().getFirst().setWriteOffAmount(new BigDecimal("2.0000"));

        assertThatThrownBy(() -> service.create(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不能把手续费")
                .hasMessageContaining("专用调整流程");
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
                .hasMessageContaining("结算原币");
        assertThatThrownBy(() -> service.create(directRequest(CURRENCY_ID, null)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("实际结算汇率必须完整");
        assertThatThrownBy(() -> service.create(directRequest(CURRENCY_ID, "0.000000")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("收款汇率必须大于 0");
        assertThatThrownBy(() -> service.create(missingOriginal))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("原币毛额");

        verify(arApService, never()).postArAp(any());
        verify(accountUpdate, never()).executeUpdate();
        verify(reconciliationInsert, never()).executeUpdate();
    }

    @Test
    void directPrepaymentDerivesLocalAmountAndIgnoresClientValue() {
        FinanceReceiptSaveRequest request = directRequest(CURRENCY_ID, "7.200000");
        request.setAmountOriginal(new BigDecimal("10.0000"));
        request.setAccountAmount(new BigDecimal("10.0000"));
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

    @Test
    void receiptsAfterAdvanceApplicationPreserveBothOffsetBalancesAndReverseAtTheOriginalBookRate() {
        ArApLedger ledger=receivable("100.0000","7.000000");
        ledger.setAmountOffsetOriginal(new BigDecimal("20.0000"));
        ledger.setAmountOffsetLocal(new BigDecimal("140.0000"));
        ledger.setAmountBalanceOriginal(new BigDecimal("80.0000"));
        ledger.setAmountBalance(new BigDecimal("560.0000"));
        FinanceReceiptDetail first=service.create(request(ledger,"30.0000","7.100000","0","0","0","0"));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L,0L));
        service.approve(first.getId());
        assertMoney(ledger.getAmountBalanceOriginal(),"50.0000");
        assertMoney(ledger.getAmountBalance(),"350.0000");
        assertMoney(ledger.getAmountSettled(),"210.0000");
        assertMoney(onlyLine(first.getId()).getAmountLocal(),"213.0000");
        assertMoney(onlyLine(first.getId()).getExchangeDiff(),"3.0000");

        when(currentUser.requireEmployeeId()).thenReturn(MAKER_ID);
        FinanceReceiptDetail finalReceipt=service.create(request(ledger,"50.0000","7.200000","0","0","0","0"));
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L,0L));
        service.approve(finalReceipt.getId());
        assertMoney(ledger.getAmountBalanceOriginal(),"0.0000");
        assertMoney(ledger.getAmountBalance(),"0.0000");
        assertMoney(ledger.getAmountSettled(),"560.0000");
        assertMoney(onlyLine(finalReceipt.getId()).getAppliedAmountLocal(),"350.0000");
        assertMoney(onlyLine(finalReceipt.getId()).getAmountLocal(),"360.0000");
        assertMoney(onlyLine(finalReceipt.getId()).getExchangeDiff(),"10.0000");

        postingCounts.addAll(List.of(1L,0L));
        service.reverse(finalReceipt.getId());
        assertMoney(ledger.getAmountBalanceOriginal(),"50.0000");
        assertMoney(ledger.getAmountBalance(),"350.0000");
        postingCounts.addAll(List.of(1L,0L));
        service.reverse(first.getId());
        assertMoney(ledger.getAmountBalanceOriginal(),"80.0000");
        assertMoney(ledger.getAmountBalance(),"560.0000");
        assertMoney(ledger.getAmountOffsetOriginal(),"20.0000");
        assertMoney(ledger.getAmountOffsetLocal(),"140.0000");
    }

    @Test
    void v2UsesActualBankAmountEvenWhenTheReferenceQuoteHasMoreDigits() {
        ArApLedger ledger=receivable("100.0000","7.000000");
        UUID base=UUID.randomUUID();
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{ACCOUNT_ID,base,true,"CNY","人民币",ACCOUNT_STYLE_ID}));
        FinanceReceiptSaveRequest req=request(ledger,"88.1234","7.123456","0","0","999","999");
        req.setAccountCurrencyId(base);req.setAccountAmount(new BigDecimal("624.7432"));
        req.setBankFeeAccountAmount(new BigDecimal("3.0001"));
        req.setFeeSettlementMode("DEDUCTED_FROM_PROCEEDS");req.setFeeBearer("COMPANY");
        FinanceReceiptDetail draft=service.create(req);
        assertThat(draft.getSettlementAuthorityVersion()).isEqualTo((short)2);
        assertMoney(draft.getAccountAmount(),"624.7432");assertMoney(draft.getAmountLocal(),"627.7433");
        assertMoney(draft.getItems().getFirst().getAmountLocal(),"627.7433");
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L,0L));service.approve(draft.getId());
        assertMoney(onlyLine(draft.getId()).getAppliedAmountLocal(),"616.8638");
        assertMoney(onlyLine(draft.getId()).getExchangeDiff(),"10.8795");
        verify(accountUpdate).setParameter("amount",new BigDecimal("624.7432"));
        postingCounts.addAll(List.of(1L,0L));service.reverse(draft.getId());
        assertMoney(ledger.getAmountBalanceOriginal(),"100");assertMoney(ledger.getAmountBalance(),"700");
    }

    @Test
    void v2SameCurrencyRejectsEvenOneActualFractionalUnitAndKeepsThirtyDigitBookProduct() {
        ArApLedger ledger=receivable("100","7.000001");
        FinanceReceiptSaveRequest req=request(ledger,"0.000000000000000000000001","7.000001","0","0","0","0");
        req.setAccountAmount(new BigDecimal("0.000000000000000000000002"));
        assertThatThrownBy(()->service.create(req)).isInstanceOf(ApiException.class).hasMessageContaining("同币种银行实收");
        req.setCreateIdempotencyKey(UUID.randomUUID().toString());
        req.setAccountAmount(new BigDecimal("0.000000000000000000000001"));
        FinanceReceiptDetail exact=service.create(req);
        assertMoney(exact.getAccountAmountLocal(),"0.000000000000000000000007000001");
        assertMoney(exact.getAmountLocal(),"0.000000000000000000000007000001");
    }

    @Test
    void v2MultipleArLinesKeepTheWholeBankFactAndItsFinalRemainder() {
        ArApLedger one=receivable("1","3.333333");
        ArApLedger two=receivable("2","3.333333");
        UUID base=UUID.randomUUID();
        when(accountLock.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{ACCOUNT_ID,base,true,"CNY","人民币",ACCOUNT_STYLE_ID}));
        FinanceReceiptSaveRequest req=request(one,"1","3.333333","0","0","0","0");
        FinanceReceiptLineInput second=request(two,"2","3.333333","0","0","0","0").getItems().getFirst();second.setLineNo(2);
        req.setItems(List.of(req.getItems().getFirst(),second));req.setAccountCurrencyId(base);req.setAccountAmount(BigDecimal.TEN);
        FinanceReceiptDetail result=service.create(req);
        var lines=linesByReceipt.get(result.getId()).stream().sorted(Comparator.comparing(FinanceReceiptLine::getLineNo)).toList();
        assertMoney(lines.get(0).getAmountLocal(),"3.333333333333333333333333333333");
        assertMoney(lines.get(1).getAmountLocal(),"6.666666666666666666666666666667");
        assertMoney(lines.get(1).getBankBasisAfterOriginal(),"0");assertMoney(lines.get(1).getBankBasisAfterLocal(),"0");
        assertMoney(lines.stream().map(FinanceReceiptLine::getAmountLocal).reduce(BigDecimal.ZERO,BigDecimal::add),"10");
    }

    @Test
    void v2ActualNativeFeeKeepsItsThirtyDigitBookValueThroughApproval() {
        ArApLedger ledger=receivable("1","7.000001");
        FinanceReceiptSaveRequest req=request(ledger,"0.000000000000000000000003","7.000001","0","0","0","0");
        req.setAccountAmount(new BigDecimal("0.000000000000000000000002"));
        req.setBankFeeAccountAmount(new BigDecimal("0.000000000000000000000001"));
        req.setFeeSettlementMode("DEDUCTED_FROM_PROCEEDS");req.setFeeBearer("COMPANY");
        FinanceReceiptDetail draft=service.create(req);
        when(currentUser.requireEmployeeId()).thenReturn(APPROVER_ID);
        postingCounts.addAll(List.of(0L,0L));FinanceReceiptDetail approved=service.approve(draft.getId());
        assertMoney(approved.getBankFee(),"0.000000000000000000000007000001");
        assertMoney(approved.getAmountLocal(),"0.000000000000000000000021000003");
        assertMoney(approved.getAccountAmountLocal(),"0.000000000000000000000014000002");
        assertMoney(onlyLine(draft.getId()).getExchangeDiff(),"0");
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
        line.setWriteOffAmount(BigDecimal.ZERO);

        FinanceReceiptSaveRequest request = new FinanceReceiptSaveRequest();
        request.setReceiptKind("AR_SETTLEMENT");
        request.setBillDate(LocalDate.of(2026, 8, 8));
        request.setClientId(CLIENT_ID);
        request.setAccountId(ACCOUNT_ID);
        request.setCurrencyId(CURRENCY_ID);
        request.setExchangeRate(new BigDecimal(receiptRate));
        request.setAmountOriginal(new BigDecimal(cashOriginal));
        request.setAmountLocal(new BigDecimal(clientLocal));
        BigDecimal feeLocal = new BigDecimal(bankFeeLocal);
        BigDecimal feeAccount = feeLocal.signum() == 0
                ? BigDecimal.ZERO
                : feeLocal.divide(new BigDecimal(receiptRate), 4, java.math.RoundingMode.HALF_UP);
        request.setBankFeeAccountAmount(feeAccount);
        request.setAccountAmount(new BigDecimal(cashOriginal).subtract(feeAccount));
        request.setOtherFeeAccountAmount(BigDecimal.ZERO);
        request.setFeeSettlementMode(
                feeAccount.signum() == 0 ? "NONE" : "DEDUCTED_FROM_PROCEEDS");
        request.setFeeBearer(feeAccount.signum() == 0 ? "NONE" : "COMPANY");
        request.setSettlementChannel("DIRECT_ACCOUNT");
        request.setExchangeRateSource("BANK_STATEMENT");
        request.setExchangeRateEffectiveAt(java.time.OffsetDateTime.parse(
                "2026-08-08T09:00:00+08:00"));
        request.setBankBookedAt(java.time.OffsetDateTime.parse(
                "2026-08-08T10:00:00+08:00"));
        request.setBankReference("BANK-TEST");
        request.setAccountCurrencyId(CURRENCY_ID);
        request.setCreateIdempotencyKey(UUID.randomUUID().toString());
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
        request.setAccountAmount(new BigDecimal("10.0000"));
        request.setBankFeeAccountAmount(BigDecimal.ZERO);
        request.setOtherFeeAccountAmount(BigDecimal.ZERO);
        request.setFeeSettlementMode("NONE");
        request.setFeeBearer("NONE");
        request.setSettlementChannel("DIRECT_ACCOUNT");
        request.setExchangeRateSource("BANK_STATEMENT");
        request.setExchangeRateEffectiveAt(java.time.OffsetDateTime.parse(
                "2026-08-08T09:00:00+08:00"));
        request.setBankBookedAt(java.time.OffsetDateTime.parse(
                "2026-08-08T10:00:00+08:00"));
        request.setBankReference("BANK-PREPAY-TEST");
        request.setAccountCurrencyId(CURRENCY_ID);
        request.setCreateIdempotencyKey(UUID.randomUUID().toString());
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
