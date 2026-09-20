package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.payment.dto.FinancePaymentLineInput;
import com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest;
import com.uten.imp.features.finance.payables.SupplierOffsetCommandService;
import com.uten.imp.features.finance.payables.SupplierOffsetContracts;
import com.uten.imp.features.finance.payables.ProcurementPayablesService;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest;
import com.uten.imp.features.finance.receivables.CustomerPrepaymentContracts;
import com.uten.imp.features.finance.receivables.CustomerPrepaymentOffsetService;
import com.uten.imp.features.finance.report.FinanceReportService;
import com.uten.imp.support.LegacyFinanceImportFixture;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.YearMonth;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.*;

/** Actual approved bootstrap opening -> native payment -> native credit application, without old cash reconstruction. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","spring.flyway.enabled=false","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=LegacyOpeningOffsetEndToEndTest.Cleanup.class,mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class LegacyOpeningOffsetEndToEndTest {
    private static final AtomicInteger SEQUENCE=new AtomicInteger(920000);
    private static final String SECRET=UUID.randomUUID()+"-"+UUID.randomUUID();
    private static PostgreSQLContainer<?> template;
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) throws Exception {
        template=MigratedSchemaBaseline.startMigratedContainer("opening_offset_template");
        try(var ignored=MigratedSchemaBaseline.cloneConnection(template,"opening_offset_runtime")) { }
        properties.add("spring.datasource.url",()->MigratedSchemaBaseline.jdbcUrlFor(template,"opening_offset_runtime"));
        properties.add("spring.datasource.username",template::getUsername);
        properties.add("spring.datasource.password",template::getPassword);
        properties.add("uten.jwt.secret",()->SECRET);properties.add("uten.crypto.pgp-master-key",()->SECRET);
        properties.add("uten.crypto.hmac-key",()->SECRET);properties.add("uten.bootstrap.admin-login",()->"opening-offset-admin");
        properties.add("uten.bootstrap.admin-password",()->SECRET+"Aa1!");
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored){if(template!=null)template.stop();}
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired PlatformTransactionManager transactions;
    @Autowired PermissionResolver permissions;
    @Autowired FinancePaymentService payments;
    @Autowired FinanceReceiptService receipts;
    @Autowired ArApLedgerService ledgers;
    @Autowired SupplierOffsetCommandService offsets;
    @Autowired ProcurementPayablesService payables;
    @Autowired CustomerPrepaymentOffsetService customerOffsets;
    @Autowired FinanceReportService reports;
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private UUID maker,reviewer,account,currency,supplier,client;
    private int supplierLegacy,clientLegacy;
    private String supplierCode;

    @BeforeEach void prepare() {
        int sequence=SEQUENCE.incrementAndGet();supplierLegacy=sequence;clientLegacy=sequence;
        supplierCode="SYN-OFF-S-"+sequence;
        supplier=jdbc.queryForObject("INSERT INTO suppliers(legacy_id,code,name,status,code_sequence) VALUES(?,?,?,'使用',?) RETURNING id",UUID.class,supplierLegacy,supplierCode,supplierCode,sequence);
        client=jdbc.queryForObject("INSERT INTO clients(legacy_id,code,name,status,code_sequence,sales_payment_type) VALUES(?,?,?,'使用',?,'MONTHLY') RETURNING id",UUID.class,clientLegacy,"SYN-OFF-C-"+sequence,"SYN-OFF-C-"+sequence,sequence);
        currency=jdbc.queryForObject("SELECT id FROM currencies WHERE legacy_id=1",UUID.class);
        UUID style=jdbc.queryForObject("INSERT INTO payment_styles(code,name,category,level,status) VALUES(?,?,'ACCOUNT',0,'使用') RETURNING id",UUID.class,"SYN-OFF-B-"+sequence,"Synthetic offset account");
        account=jdbc.queryForObject("INSERT INTO accounts(code,name,account_type,status,currency_id,style_id,init_balance,balance_current) VALUES(?,?,'CASH','使用',?,?,100,100) RETURNING id",UUID.class,"SYN-OFF-A-"+sequence,"Synthetic offset account",currency,style);
        UUID department=jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
        world=new FullChainEndToEndTest.World(department,null,null,null,null,null,null,null,client,supplier,null,null,currency,null,0);
        fixture=new FullChainEndToEndTest();ReflectionTestUtils.setField(fixture,"jdbc",jdbc);ReflectionTestUtils.setField(fixture,"permissionResolver",permissions);
        fixture.seedChartOfAccounts();
        jdbc.update("INSERT INTO payment_styles(code,name,category,level,status) SELECT 'SYN-ADVANCE','Synthetic customer advance','LIABILITY',0,'使用' WHERE NOT EXISTS(SELECT 1 FROM payment_styles WHERE code='SYN-ADVANCE')");
        jdbc.update("UPDATE system_posting_style_roles role SET style_id=style.id FROM payment_styles style WHERE role.role_key='CUSTOMER_ADVANCE' AND style.code='SYN-ADVANCE'");
        maker=fixture.createUserWithPerms(world,"offset-maker-"+sequence,"finance_payment:create","finance_payment:edit","finance_payment:view","finance_receipt:create","finance_receipt:edit","finance_receipt:view","finance:view:all","finance_post:execute","customer_prepayment:view");
        reviewer=fixture.createUserWithPerms(world,"offset-reviewer-"+sequence,"finance_payment:view","finance_payment:approve","finance_payment:reverse","finance_receipt:view","finance_receipt:approve","finance_receipt:reverse","finance:view:all","customer_prepayment:view");
        fixture.loginAs(maker);
    }
    @AfterEach void clearUser(){SecurityContextHolder.clearContext();}

    @Test void seventeenThenRealPaymentThreeThenCreditFourIsTenAndReverseRestoresFourOnly() throws Exception {
        UUID target=opening("AP","25","8","17",true,"2025-01-31T15:59:59Z");
        String proof=proof(target);
        payment(target,"3");
        assertBalance(target,"14");
        UUID source=credit("4");
        assertThat(payables.detail(target).item().legacyImported()).isTrue();
        assertThat(payables.detail(source).item().legacyImported()).isFalse();
        var request=new SupplierOffsetContracts.ApplyRequest(source,null,"Apply current approved credit",
                List.of(new SupplierOffsetContracts.Target(target,new BigDecimal("4"))));
        var result=offsets.apply(request);
        assertBalance(target,"10");assertBalance(source,"0");
        assertThat(amount("SELECT amount_received_original FROM ar_ap_ledger WHERE id=?",target)).isEqualByComparingTo("11");
        assertThat(amount("SELECT amount_offset_original FROM ar_ap_ledger WHERE id=?",target)).isEqualByComparingTo("4");
        assertThat(proof(target)).isEqualTo(proof);
        assertThatThrownBy(()->offsets.apply(request)).isInstanceOf(ApiException.class);
        assertBalance(target,"10");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM supplier_open_item_offsets WHERE target_ledger_id=?",Integer.class,target)).isEqualTo(1);
        assertReportBalance("10",YearMonth.from(BusinessTime.today()).atDay(1));
        assertReportBalance("10",YearMonth.from(BusinessTime.today()).plusMonths(1).atDay(1));
        offsets.reverse(result.offsetBatchId(),new SupplierOffsetContracts.ReverseRequest("Reverse this current allocation"));
        assertBalance(target,"14");assertBalance(source,"-4");
        assertThat(amount("SELECT amount_offset_original FROM ar_ap_ledger WHERE id=?",target)).isEqualByComparingTo("0");
        assertThat(amount("SELECT amount_received_original FROM ar_ap_ledger WHERE id=?",target)).isEqualByComparingTo("11");
        offsets.reverse(result.offsetBatchId(),new SupplierOffsetContracts.ReverseRequest("Same already reversed allocation"));
        assertBalance(target,"14");assertThat(proof(target)).isEqualTo(proof);
    }

    @Test void negativeUnknownOriginalWrongPartyAndCutoffCannotBecomeAnOffsetTargetOrFundingSource() throws Exception {
        UUID source=credit("8");
        UUID negative=opening("AP","-7","0","-7",true,"2025-01-31T15:59:59Z");
        UUID unknown=opening("AP","25","8","17",false,"2025-01-31T15:59:59Z");
        UUID future=opening("AP","25","8","17",true,BusinessTime.today()+"T15:59:59Z");
        for(UUID target:List.of(negative,unknown,future)) {
            assertThatThrownBy(()->offsets.apply(new SupplierOffsetContracts.ApplyRequest(source,null,"Must not guess historical eligibility",
                    List.of(new SupplierOffsetContracts.Target(target,BigDecimal.ONE))))).isInstanceOf(ApiException.class);
        }
        UUID positive=opening("AP","25","8","17",true,"2025-01-31T15:59:59Z");
        int originalSupplier=supplierLegacy;
        supplierLegacy=SEQUENCE.incrementAndGet();
        jdbc.update("INSERT INTO suppliers(legacy_id,code,name,status,code_sequence) VALUES(?,?,?,'使用',?)",supplierLegacy,"SYN-OFF-OTHER-"+supplierLegacy,"Other synthetic supplier",supplierLegacy);
        UUID otherParty=opening("AP","25","8","17",true,"2025-01-31T15:59:59Z");
        supplierLegacy=originalSupplier;
        assertThatThrownBy(()->offsets.apply(new SupplierOffsetContracts.ApplyRequest(source,null,"Cannot cross suppliers",
                List.of(new SupplierOffsetContracts.Target(otherParty,BigDecimal.ONE))))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->offsets.apply(new SupplierOffsetContracts.ApplyRequest(negative,null,"Historical credit is not new funds",
                List.of(new SupplierOffsetContracts.Target(positive,BigDecimal.ONE))))).isInstanceOf(ApiException.class);
        assertBalance(source,"-8");assertBalance(positive,"17");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM supplier_open_item_offsets WHERE source_ledger_id=?",Integer.class,source)).isZero();
    }

    @ParameterizedTest @CsvSource({"25,8,17","0,-8,8"})
    void completePaymentToZeroRetainsInitialEligibilityThroughDeferredTerminalChecks(String original,String settled,String balance) throws Exception {
        UUID target=opening("AP",original,settled,balance,true,"2025-01-31T15:59:59Z");
        String originalProof=proof(target);
        UUID payment=payment(target,balance);
        assertBalance(target,"0");
        assertThat(jdbc.queryForObject("SELECT is_settled FROM ar_ap_ledger WHERE id=?",Boolean.class,target)).isTrue();
        assertThat(jdbc.queryForObject("SELECT fn_is_verified_legacy_opening_target(?,'AP')",Boolean.class,target)).isTrue();
        assertThatThrownBy(()->payment(target,"1")).isInstanceOf(ApiException.class);
        assertBalance(target,"0");
        fixture.loginAs(reviewer);payments.reverse(payment);fixture.loginAs(maker);
        assertBalance(target,balance);
        assertThat(amount("SELECT amount_received_original FROM ar_ap_ledger WHERE id=?",target)).isEqualByComparingTo(settled);
        assertThat(proof(target)).isEqualTo(originalProof);
        fixture.loginAs(reviewer);assertThatThrownBy(()->payments.reverse(payment)).isInstanceOf(ApiException.class);fixture.loginAs(maker);
        assertBalance(target,balance);
    }

    @ParameterizedTest @CsvSource({"25,8,17","0,-8,8"})
    void completeReceiptToZeroRetainsInitialEligibilityAndDoesNotCreateOldOrderAllocations(String original,String settled,String balance) throws Exception {
        UUID target=opening("AR",original,settled,balance,true,"2025-01-31T15:59:59Z");
        String originalProof=proof(target);
        FinanceReceiptSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"receiptRequest",world,target,account,null,balance,balance,"0","0",BigDecimal.ONE,BusinessTime.today());
        UUID receipt=receipts.create(request).getId();fixture.loginAs(reviewer);receipts.approve(receipt);fixture.loginAs(maker);
        assertBalance(target,"0");
        assertThat(jdbc.queryForObject("SELECT is_settled FROM ar_ap_ledger WHERE id=?",Boolean.class,target)).isTrue();
        assertThat(jdbc.queryForObject("SELECT fn_is_verified_legacy_opening_ar(?)",Boolean.class,target)).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM finance_receipt_source_allocations WHERE ledger_id=?",Integer.class,target)).isZero();
        fixture.loginAs(reviewer);receipts.reverse(receipt);fixture.loginAs(maker);
        assertBalance(target,balance);
        assertThat(amount("SELECT amount_received_original FROM ar_ap_ledger WHERE id=?",target)).isEqualByComparingTo(settled);
        assertThat(proof(target)).isEqualTo(originalProof);
        fixture.loginAs(reviewer);assertThatThrownBy(()->receipts.reverse(receipt)).isInstanceOf(ApiException.class);fixture.loginAs(maker);
        assertBalance(target,balance);
    }

    @Test void completeOffsetToZeroThenReverseUsesTheOriginalProofWithoutConsumingItAgain() throws Exception {
        UUID target=opening("AP","25","8","17",true,"2025-01-31T15:59:59Z");
        payment(target,"3");UUID source=credit("14");
        var result=offsets.apply(new SupplierOffsetContracts.ApplyRequest(source,null,"Apply exact remaining credit",
                List.of(new SupplierOffsetContracts.Target(target,new BigDecimal("14")))));
        assertBalance(target,"0");assertBalance(source,"0");
        assertThat(jdbc.queryForObject("SELECT fn_is_verified_legacy_opening_target(?,'AP')",Boolean.class,target)).isTrue();
        offsets.reverse(result.offsetBatchId(),new SupplierOffsetContracts.ReverseRequest("Restore this exact offset"));
        assertBalance(target,"14");assertBalance(source,"-14");
    }

    @Test void knownCustomerOpeningStillRequiresItsRealOrderSourceAndCannotUseAnInventedOrderUuid() throws Exception {
        UUID target=opening("AR","25","8","17",true,"2025-01-31T15:59:59Z");
        FinanceReceiptSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"receiptRequest",world,null,account,null,"4","4","0","0",BigDecimal.ONE,BusinessTime.today());
        request.setReceiptKind("CUSTOMER_PREPAYMENT");request.setItems(List.of());request.setCurrencyId(currency);
        request.setExchangeRate(BigDecimal.ONE);request.setAmountOriginal(new BigDecimal("4"));
        UUID receipt=receipts.create(request).getId();fixture.loginAs(reviewer);receipts.approve(receipt);fixture.loginAs(maker);
        UUID source=jdbc.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='DIRECT_RECEIPT' AND source_doc_id=?",UUID.class,receipt);
        assertThatThrownBy(()->customerOffsets.apply(new CustomerPrepaymentContracts.ApplyRequest("opening-no-order-"+UUID.randomUUID(),source,
                List.of(new CustomerPrepaymentContracts.Target(target,UUID.randomUUID(),new BigDecimal("4"))),"Order evidence must exist")))
                .isInstanceOf(ApiException.class).hasMessageContaining("销售单 UUID 来源");
        assertBalance(target,"17");assertBalance(source,"-4");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM customer_open_item_offsets WHERE target_ledger_id=?",Integer.class,target)).isZero();
    }

    private UUID opening(String direction,String total,String settled,String balance,boolean known,String cutoff) throws Exception {
        ObjectNode source=(ObjectNode)new ObjectMapper().readTree(LegacyFinanceImportFixture.source("AR".equals(direction)?"m_in.csv":"m_out.csv"));
        int id=SEQUENCE.incrementAndGet();source.put("legacy_id",id);source.put("bill_no","SYN-OPEN-"+id);
        source.put("AR".equals(direction)?"client_legacy_id":"supplier_legacy_id","AR".equals(direction)?clientLegacy:supplierLegacy);
        source.put("total",new BigDecimal(total));source.put("settled",new BigDecimal(settled));source.put("balance",new BigDecimal(balance));
        source.put("currency_legacy_id",known?1:0);source.put("exchange_rate",known?1:0);
        return new TransactionTemplate(transactions).execute(status->{
            UUID run=LegacyFinanceImportFixture.context(jdbc);
            jdbc.update("UPDATE legacy_migration_runs SET reconciliation_summary=reconciliation_summary||jsonb_build_object('sourceSnapshotAsOfUtc',CAST(? AS text)) WHERE run_id=?",cutoff,run);
            UUID ledger=jdbc.queryForObject("SELECT fn_import_legacy_finance_source(?,?,?::jsonb)",UUID.class,run,"AR".equals(direction)?"AR_OPENING":"AP_OPENING",source.toString());
            jdbc.update("UPDATE legacy_migration_runs SET status='SUCCESS',finished_at=now() WHERE run_id=?",run);
            return ledger;
        });
    }
    private UUID payment(UUID target,String value) {
        FinancePaymentLineInput line=new FinancePaymentLineInput();line.setAppliedLedgerId(target);line.setSupplierId(supplier);line.setAmountOriginal(new BigDecimal(value));
        FinancePaymentSaveRequest request=new FinancePaymentSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(supplier);request.setAccountId(account);
        request.setCurrencyId(currency);request.setExchangeRate(BigDecimal.ONE);request.setAccountCurrencyId(currency);request.setAccountAmount(new BigDecimal(value));
        request.setBankFeeAccountAmount(BigDecimal.ZERO);request.setBankReference("OPENING-AP-"+UUID.randomUUID());request.setBankBookedAt(OffsetDateTime.now());
        request.setCreateIdempotencyKey(UUID.randomUUID().toString());request.setItems(List.of(line));
        fixture.loginAs(maker);UUID id=payments.create(request).getId();fixture.loginAs(reviewer);payments.approve(id);fixture.loginAs(maker);
        return id;
    }
    private UUID credit(String amount) {
        UUID source=UUID.randomUUID();String no="CT"+BusinessTime.today().toString().replace("-","")+String.format("%06d",SEQUENCE.incrementAndGet());
        new TransactionTemplate(transactions).executeWithoutResult(status->ledgers.postArAp(new ArApLedgerService.ArApPostingRequest("AP","PURCHASE_RETURN",source,no,BusinessTime.today(),null,supplier,currency,BigDecimal.ONE,new BigDecimal(amount).negate(),null,"Current synthetic approved credit")));
        return jdbc.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_id=? AND source_doc_type='PURCHASE_RETURN'",UUID.class,source);
    }
    private String proof(UUID id){return jdbc.queryForObject("SELECT to_jsonb(proof)::text FROM legacy_finance_import_sources proof WHERE target_id=?",String.class,id);}
    private BigDecimal amount(String sql,UUID id){return jdbc.queryForObject(sql,BigDecimal.class,id);}
    private void assertBalance(UUID id,String expected){assertThat(amount("SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",id)).isEqualByComparingTo(expected);assertThat(amount("SELECT amount_balance FROM ar_ap_ledger WHERE id=?",id)).isEqualByComparingTo(expected);}
    private void assertReportBalance(String expected,LocalDate from) {
        var report=reports.payableSummary(supplierCode,from,from.withDayOfMonth(from.lengthOfMonth()),Map.of(),1,50,null,null);
        assertThat(report.rows()).hasSize(1);assertThat((BigDecimal)report.rows().getFirst().get("balance")).isEqualByComparingTo(expected);
    }
}
