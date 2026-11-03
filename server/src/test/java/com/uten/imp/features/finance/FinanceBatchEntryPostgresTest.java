package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Validation;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class FinanceBatchEntryPostgresTest {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine");
    private static DriverManagerDataSource source;
    private static org.flywaydb.core.Flyway flyway;
    private static UUID actor;
    private JdbcTemplate db;
    private TransactionTemplate transaction;
    private FinanceBatchEntryService service;
    private FinanceExpenseService expenses;
    private final ObjectMapper json = new ObjectMapper().findAndRegisterModules();

    @BeforeAll static void start() throws Exception {
        POSTGRES.start();
        source = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        flyway = com.uten.imp.testsupport.TestFlyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load();
        flyway.migrate();
        var db = new JdbcTemplate(source);
        db.execute("CREATE TABLE synthetic_documents(id uuid PRIMARY KEY, account_id uuid)");
        UUID employee = UUID.randomUUID();
        UUID department = db.queryForObject("SELECT id FROM departments WHERE NOT is_deleted ORDER BY code LIMIT 1", UUID.class);
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')
                """, employee, "FB-" + employee,
                com.uten.imp.support.SyntheticEmployeeIdentity.name("财务批量录入测试员工", employee), department);
        actor = UUID.randomUUID();
        db.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password,is_super_admin)
                VALUES(?,?,?,'test-only','active',false,false)
                """, actor, employee, "finance-batch-" + actor);
    }
    @AfterAll static void stop() { POSTGRES.stop(); }
    @BeforeEach void setup() {
        db = new JdbcTemplate(source);
        db.execute("TRUNCATE finance_batch_entry_commands,synthetic_documents");
        var user = mock(SecurityContextCurrentUser.class);
        when(user.requireId()).thenReturn(actor);
        var principal = mock(AuthUser.class); when(principal.getLoginAccount()).thenReturn("fixture");
        when(user.get()).thenReturn(Optional.of(principal));
        expenses = mock(FinanceExpenseService.class);
        when(expenses.create(any())).thenAnswer(call -> {
            var request = (com.uten.imp.features.finance.expense.dto.FinanceExpenseSaveRequest)call.getArgument(0);
            db.update("INSERT INTO synthetic_documents VALUES (?,?)", UUID.randomUUID(), request.getAccountId());
            if ("reject".equals(request.getRemark())) throw new ApiException(ErrorCode.VALIDATION_FAILED, "fixture rejection");
            return null;
        });
        service = new FinanceBatchEntryService(new NamedParameterJdbcTemplate(source), json,
            Validation.buildDefaultValidatorFactory().getValidator(), user, mock(AuditService.class),
            mock(FinanceReceiptService.class), mock(FinancePaymentService.class), expenses,
            mock(FinanceOtherIncomeService.class), mock(FinanceBankTransferService.class));
        transaction = new TransactionTemplate(new DataSourceTransactionManager(source));
    }
    private JsonNode entry(String account, String remark) throws Exception {
        return json.readTree("{\"billDate\":\"2026-11-02\",\"accountId\":\""+account+"\",\"remark\":\""+remark+"\",\"items\":[]}");
    }
    private JsonNode run(List<JsonNode> entries) {
        return transaction.execute(status -> service.create("expenses", new FinanceBatchEntryController.Request("fixture-batch-key", entries)));
    }
    @Test void laterFailureRollsBackAllDocumentsAndReceipt() throws Exception {
        var first = entry(UUID.randomUUID().toString(), "ok");
        var second = entry(UUID.randomUUID().toString(), "reject");
        assertThatThrownBy(() -> run(List.of(first, second))).isInstanceOf(ApiException.class).hasMessageContaining("第 2 组");
        assertThat(db.queryForObject("SELECT count(*) FROM synthetic_documents", Integer.class)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM finance_batch_entry_commands", Integer.class)).isZero();
    }
    @Test void lostResponseReplayReturnsOriginalWithoutCreatingAgain() throws Exception {
        var entries = List.of(entry(UUID.randomUUID().toString(), "ok"));
        assertThat(run(entries)).isEqualTo(run(entries));
        assertThat(db.queryForObject("SELECT count(*) FROM synthetic_documents", Integer.class)).isOne();
        assertThatThrownBy(() -> run(List.of(entry(UUID.randomUUID().toString(), "changed")))).isInstanceOf(ApiException.class);
        verify(expenses, times(1)).create(any());
    }
    @Test void concurrentRepeatSerializesOnTheWholeBatch() throws Exception {
        var entries = List.of(entry(UUID.randomUUID().toString(), "ok"));
        try (var workers = Executors.newFixedThreadPool(2)) {
            var a = workers.submit(() -> run(entries)); var b = workers.submit(() -> run(entries));
            assertThat(a.get(20, TimeUnit.SECONDS)).isEqualTo(b.get(20, TimeUnit.SECONDS));
        }
        assertThat(db.queryForObject("SELECT count(*) FROM synthetic_documents", Integer.class)).isOne();
    }
    @Test void optionalReferencePreservesOtherDatabaseGuards() throws Exception {
        var constraints = constraintSnapshot();
        var columns = columnSnapshot();
        String migration = java.nio.file.Files.readString(java.nio.file.Path.of(
                "src/main/resources/db/migration/V992__finance_bank_reference_optional.sql"));
        transaction.executeWithoutResult(status -> {
            try {
                for (String table : List.of("finance_receipts", "finance_payments")) {
                    String name = table.equals("finance_receipts")
                            ? "finance_receipts_v1_external_evidence_chk" : "finance_payments_v2_shape_chk";
                    String optional = checkDefinition(table, name);
                    // Restore only the old bank-reference predicate in the actual full check.
                    // All other production CHECK/FK/type contracts remain installed.
                    String required = optional.replace(
                            "((bank_reference IS NULL) OR (length((bank_reference)::text) <= 128))",
                            "(NULLIF(btrim((bank_reference)::text), ''::text) IS NOT NULL)");
                    assertThat(required).as("The reviewed optional bank-reference clause must exist").isNotEqualTo(optional);
                    db.execute("ALTER TABLE " + table + " DROP CONSTRAINT " + name);
                    db.execute("ALTER TABLE " + table + " ADD CONSTRAINT " + name + " " + required);
                    assertThat(evaluateCheck(table, checkDefinition(table, name), null, 1)).isFalse();
                }
                db.execute(migration);
                assertThat(constraintSnapshot()).isEqualTo(constraints);
                assertThat(columnSnapshot()).isEqualTo(columns);
                for (String table : List.of("finance_receipts", "finance_payments")) {
                    String name = table.equals("finance_receipts")
                            ? "finance_receipts_v1_external_evidence_chk" : "finance_payments_v2_shape_chk";
                    String actual = checkDefinition(table, name);
                    assertThat(evaluateCheck(table, actual, null, 1)).isTrue();
                    assertThat(evaluateCheck(table, actual, "", 1)).isTrue();
                    assertThat(evaluateCheck(table, actual, null, -1)).isFalse();
                }
            } finally {
                status.setRollbackOnly();
            }
        });
        assertThat(constraintSnapshot()).isEqualTo(constraints);
        assertThat(columnSnapshot()).isEqualTo(columns);
    }

    private String checkDefinition(String table, String name) {
        return db.queryForObject("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid=to_regclass(?) AND conname=?",
                String.class, table, name);
    }

    private List<java.util.Map<String, Object>> constraintSnapshot() {
        return db.queryForList("""
                SELECT c.relname, p.conname, p.contype, pg_get_constraintdef(p.oid) AS definition,
                       p.convalidated, p.condeferrable, p.condeferred
                FROM pg_constraint p JOIN pg_class c ON c.oid=p.conrelid
                WHERE c.oid IN ('finance_receipts'::regclass,'finance_payments'::regclass)
                ORDER BY c.relname,p.conname
                """);
    }

    private List<java.util.Map<String, Object>> columnSnapshot() {
        return db.queryForList("""
                SELECT c.relname,a.attname,format_type(a.atttypid,a.atttypmod) AS type,a.attnotnull,
                       pg_get_expr(d.adbin,d.adrelid) AS default_value
                FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
                LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
                WHERE c.oid IN ('finance_receipts'::regclass,'finance_payments'::regclass)
                  AND a.attnum>0 AND NOT a.attisdropped
                ORDER BY c.relname,a.attnum
                """);
    }

    private Boolean evaluateCheck(String table, String definition, String reference, int amount) {
        var row = json.createObjectNode();
        String id = UUID.randomUUID().toString();
        for (String key : List.of("maker_id", "supplier_id", "account_id", "currency_id", "account_currency_id",
                "gl_account_style_id", "gl_ap_style_id")) row.put(key, id);
        for (String key : List.of("exchange_rate", "amount_local", "account_exchange_rate", "account_amount", "account_amount_local")) row.put(key, 1);
        row.put("status", 0).put("settlement_authority_version", 1).put("amount_authority_version", 2)
                .put("settlement_channel", "DIRECT_ACCOUNT").put("amount_original", amount)
                .put("bank_fee_account_amount", 0).put("bank_fee_local", 0).put("bank_booked_at", "2026-11-03T00:00:00Z");
        if (reference == null) row.putNull("bank_reference"); else row.put("bank_reference", reference);
        assertThat(definition).startsWith("CHECK (").doesNotContain("NOT VALID");
        // Evaluate the actual catalog CHECK on typed rows; no business document is inserted.
        return db.queryForObject("SELECT " + definition.substring("CHECK ".length())
                + " FROM jsonb_populate_record(NULL::" + table + ", CAST(? AS jsonb)) AS probe", Boolean.class, row.toString());
    }

    @Test void fullFreshFlywayChainAcceptsTheForwardMigrations() {
        assertThat(flyway.info().applied())
                .extracting(info -> info.getScript())
                .contains("V991__finance_batch_entry_commands.sql",
                        "V992__finance_bank_reference_optional.sql");
        assertThat(flyway.info().pending()).isEmpty();
    }
}
