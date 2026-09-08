package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.math.BigDecimal;
import java.sql.DriverManager;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.CALLS_REAL_METHODS;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SubcontractLossClaimIntegrityContractTest {

    private static final Path MAIN = Path.of("src/main/java/com/uten/imp");
    private static final Path MIGRATIONS = Path.of("src/main/resources/db/migration");

    @Test
    void reversedOffsetHistoryAndClaimLedgerReversalUseACompatibleRetentionStrategy() throws IOException {
        String offsetMigration = read(MIGRATIONS.resolve("V332__supplier_open_item_offsets.sql"));
        String claimService = read(MAIN.resolve(
                "features/finance/payables/SubcontractLossClaimService.java"));
        String arApService = read(MAIN.resolve(
                "features/finance/arap/ArApLedgerServiceImpl.java"));

        boolean offsetRowsRestrictLedgerDeletion = Pattern.compile(
                        "(?s)(source_ledger_id|target_ledger_id).*?REFERENCES\\s+ar_ap_ledger\\(id\\)\\s+ON\\s+DELETE\\s+RESTRICT")
                .matcher(offsetMigration).find();
        boolean claimCallsPhysicalLedgerReversal = claimService.contains(
                "arApService.reverseArAp(resolutionId, AP_SOURCE_TYPE)");
        boolean arApReversalPhysicallyDeletes = arApService.contains("repo.deleteAll(rows)")
                || arApService.contains("repo.delete(ledger)");

        assertThat(offsetRowsRestrictLedgerDeletion
                && claimCallsPhysicalLedgerReversal
                && arApReversalPhysicallyDeletes)
                .as("REVERSED offset rows cannot retain RESTRICT FKs while claim reversal physically deletes their ledger")
                .isFalse();
    }

    @Test
    void physicalCompensationEvidenceIsLineBoundQuantityCheckedAndSingleUse() throws IOException {
        String service = read(MAIN.resolve(
                "features/finance/payables/SubcontractLossClaimService.java"));
        String method = between(service,
                "private void recordFulfillmentDocument",
                "private UUID baseCurrencyId");

        assertThat(method)
                .as("a same-supplier document alone is not evidence for a specific material-loss line")
                .containsAnyOf("order_item_id", "goods_id", "case_line_id");
        assertThat(method)
                .as("the approved document quantity must cover the resolution quantity")
                .containsAnyOf("resolution.quantity()", "fulfilled_qty", "available_qty");
        assertThat(method)
                .as("one receipt/return must not be reused to settle multiple claim resolutions")
                .containsAnyOf("fulfillment_doc_id", "claim_fulfillment_allocations", "subcontract_loss_fulfillment_allocations", "document_item_id");
    }

    @Test
    void cashCompensationHasARealSettlementPathInsteadOfAPermanentPendingState() throws IOException {
        String service = read(MAIN.resolve(
                "features/finance/payables/SubcontractLossClaimService.java"));
        boolean hardBlocked = service.contains(
                "现金赔偿必须先进入专用资金收款与银行对账，当前不能用手工证据冒充到账");
        boolean hasDedicatedPath = service.contains("fulfillCashCompensation")
                || service.contains("CASH_RECEIPT")
                || service.contains("cashCompensationSettlement");

        assertThat(hardBlocked && !hasDedicatedPath)
                .as("CASH_COMPENSATION must be resolvable through a bank-backed path")
                .isFalse();
    }

    @Test
    void claimAmountTotalsOnlyMonetaryRecoveryResolutions() throws IOException {
        String service = read(MAIN.resolve(
                "features/finance/payables/SubcontractLossClaimService.java"));
        String decision = between(service,
                "public CaseDetail decide",
                "public CaseDetail fulfill");

        assertThat(decision)
                .as("company-bear, waiver and quantity-only replacement rows must not inflate claim_amount_local")
                .containsPattern("(?s)if\\s*\\(MONEY_TYPES\\.contains\\(type\\)\\)\\s*(?:\\{\\s*)?claimTotal\\s*=\\s*claimTotal\\.add\\(amount\\)");
    }

    @Test
    @EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
    void outputCompensationRequiresExplicitZeroInBothCurrenciesAndTheExactApprovedSource() throws Exception {
        // Focused PostgreSQL regression for the service's actual fulfillment SQL;
        // these isolated tables exercise its predicate and write ordering, not migration guards.
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("loss_fulfillment_amount_predicate")
                .withUsername("uten").withPassword("uten-test-only")) {
            postgres.start();
            try (var connection = DriverManager.getConnection(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
                var dataSource = new SingleConnectionDataSource(connection, true);
                var jdbc = new JdbcTemplate(dataSource);
                var named = new NamedParameterJdbcTemplate(dataSource);
                jdbc.execute("CREATE TEMP TABLE subcontract_receipts(id uuid PRIMARY KEY,supplier_id uuid,status smallint,is_deleted boolean)");
                jdbc.execute("CREATE TEMP TABLE subcontract_receipt_items(id uuid PRIMARY KEY,receipt_id uuid,order_item_id uuid,qty numeric,amount_original numeric,amount_local numeric,is_deleted boolean)");
                jdbc.execute("CREATE TEMP TABLE subcontract_loss_case_lines(id uuid PRIMARY KEY,order_item_id uuid)");
                jdbc.execute("CREATE TEMP TABLE subcontract_loss_fulfillment_allocations(id uuid,resolution_id uuid,case_line_id uuid,document_type text,document_id uuid,document_item_id uuid,quantity numeric,created_by uuid)");
                UUID caseId=UUID.randomUUID(), lineId=UUID.randomUUID(), orderItemId=UUID.randomUUID();
                UUID supplierId=UUID.randomUUID(), receiptId=UUID.randomUUID(), itemId=UUID.randomUUID();
                jdbc.update("INSERT INTO subcontract_receipts VALUES (?,?,1,FALSE)",receiptId,supplierId);
                jdbc.update("INSERT INTO subcontract_receipt_items VALUES (?,?,?,2,0,0,FALSE)",itemId,receiptId,orderItemId);
                jdbc.update("INSERT INTO subcontract_loss_case_lines VALUES (?,?)",lineId,orderItemId);

                EntityManager em=mock(EntityManager.class);
                when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
                    String sql=invocation.getArgument(0);
                    Map<String,Object> parameters=new LinkedHashMap<>();
                    Query query=mock(Query.class);
                    when(query.setParameter(anyString(),any())).thenAnswer(binding -> {
                        parameters.put(binding.getArgument(0),binding.getArgument(1));
                        return query;
                    });
                    when(query.getSingleResult()).thenAnswer(ignored -> named.queryForObject(sql,parameters,Long.class));
                    when(query.executeUpdate()).thenAnswer(ignored -> named.update(sql,parameters));
                    return query;
                });
                SecurityContextCurrentUser currentUser=mock(SecurityContextCurrentUser.class);
                when(currentUser.requireId()).thenReturn(UUID.randomUUID());
                var service=mock(SubcontractLossClaimService.class,CALLS_REAL_METHODS);
                ReflectionTestUtils.setField(service,"em",em);
                ReflectionTestUtils.setField(service,"currentUser",currentUser);
                Object loss=privateRecord("CaseRow",caseId,UUID.randomUUID(),"SW-SOURCE",supplierId,
                        "AWAITING_FULFILLMENT",new BigDecimal("2"),UUID.randomUUID(),1L);
                Object resolution=privateRecord("ResolutionRow",UUID.randomUUID(),lineId,"OUTPUT_REPLACEMENT",
                        "AWAITING_FULFILLMENT",new BigDecimal("2"),BigDecimal.ZERO,null);
                var request=new SubcontractLossClaimContracts.FulfillmentRequest(1L,new BigDecimal("2"),
                        BigDecimal.ZERO,"verified source","SUBCONTRACT_RECEIPT",receiptId,itemId,"SR-SOURCE",null,null,null);

                for (BigDecimal[] amounts : new BigDecimal[][] {
                        {null,null}, {null,BigDecimal.ZERO}, {BigDecimal.ZERO,null},
                        {new BigDecimal("0.000000000000000000000001"),BigDecimal.ZERO},
                        {BigDecimal.ZERO,new BigDecimal("0.000000000000000000000000000001")}}) {
                    jdbc.update("UPDATE subcontract_receipt_items SET amount_original=?,amount_local=?",(Object[])amounts);
                    assertFulfillmentRejected(service,loss,resolution,request,jdbc);
                }
                jdbc.update("UPDATE subcontract_receipt_items SET amount_original=0,amount_local=0");
                jdbc.update("UPDATE subcontract_receipts SET supplier_id=?",UUID.randomUUID());
                assertFulfillmentRejected(service,loss,resolution,request,jdbc);
                jdbc.update("UPDATE subcontract_receipts SET supplier_id=?,status=0",supplierId);
                assertFulfillmentRejected(service,loss,resolution,request,jdbc);
                jdbc.update("UPDATE subcontract_receipts SET status=1,is_deleted=TRUE");
                assertFulfillmentRejected(service,loss,resolution,request,jdbc);
                jdbc.update("UPDATE subcontract_receipts SET is_deleted=FALSE");
                jdbc.update("UPDATE subcontract_receipt_items SET order_item_id=?",UUID.randomUUID());
                assertFulfillmentRejected(service,loss,resolution,request,jdbc);
                jdbc.update("UPDATE subcontract_receipt_items SET order_item_id=?,qty=1",orderItemId);
                assertFulfillmentRejected(service,loss,resolution,request,jdbc);
                jdbc.update("UPDATE subcontract_receipt_items SET qty=2,is_deleted=TRUE");
                assertFulfillmentRejected(service,loss,resolution,request,jdbc);
                jdbc.update("UPDATE subcontract_receipt_items SET is_deleted=FALSE");

                ReflectionTestUtils.invokeMethod(service,"recordFulfillmentDocument",loss,resolution,request);
                assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM subcontract_loss_fulfillment_allocations",Long.class)).isEqualTo(1L);
                assertThat(jdbc.queryForObject("SELECT quantity FROM subcontract_loss_fulfillment_allocations",BigDecimal.class)).isEqualByComparingTo("2");
                assertThat(jdbc.queryForObject("SELECT document_item_id FROM subcontract_loss_fulfillment_allocations",UUID.class)).isEqualTo(itemId);
                assertThat(jdbc.queryForObject("SELECT case_line_id FROM subcontract_loss_fulfillment_allocations",UUID.class)).isEqualTo(lineId);
            }
        }
    }

    private static Object privateRecord(String name,Object... fields) throws Exception {
        var constructor=Class.forName(SubcontractLossClaimService.class.getName()+"$"+name).getDeclaredConstructors()[0];
        constructor.setAccessible(true);
        return constructor.newInstance(fields);
    }

    private static void assertFulfillmentRejected(SubcontractLossClaimService service,Object loss,Object resolution,
            SubcontractLossClaimContracts.FulfillmentRequest request,JdbcTemplate jdbc) {
        assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(service,"recordFulfillmentDocument",loss,resolution,request))
                .isInstanceOf(ApiException.class).hasMessageContaining("履约明细与索赔订单、材料、数量或委外商不一致");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM subcontract_loss_fulfillment_allocations",Long.class)).isZero();
    }

    private static String between(String source, String start, String end) {
        int from = source.indexOf(start);
        int to = source.indexOf(end, from + start.length());
        assertThat(from).as("start marker %s", start).isGreaterThanOrEqualTo(0);
        assertThat(to).as("end marker %s", end).isGreaterThan(from);
        return source.substring(from, to);
    }

    private static String read(Path path) throws IOException {
        return Files.readString(path);
    }
}
