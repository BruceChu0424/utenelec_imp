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
import org.springframework.core.io.FileSystemResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;
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
    private JdbcTemplate db;
    private TransactionTemplate transaction;
    private FinanceBatchEntryService service;
    private FinanceExpenseService expenses;
    private final ObjectMapper json = new ObjectMapper().findAndRegisterModules();

    @BeforeAll static void start() throws Exception {
        POSTGRES.start();
        source = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        var db = new JdbcTemplate(source);
        db.execute("CREATE TABLE users(id uuid PRIMARY KEY)");
        db.execute("CREATE TABLE synthetic_documents(id uuid PRIMARY KEY, account_id uuid)");
        db.execute("CREATE TABLE finance_receipts(bank_reference varchar(128), amount numeric, CONSTRAINT finance_receipts_v1_external_evidence_chk CHECK (NULLIF(btrim(bank_reference),'') IS NOT NULL AND amount>0))");
        db.execute("CREATE TABLE finance_payments(bank_reference varchar(128), amount numeric, CONSTRAINT finance_payments_v2_shape_chk CHECK (NULLIF(btrim(bank_reference),'') IS NOT NULL AND amount>0))");
        for (String migration : List.of("V991__finance_batch_entry_commands.sql", "V992__finance_bank_reference_optional.sql")) {
            db.execute(java.nio.file.Files.readString(java.nio.file.Path.of("src/main/resources/db/migration/" + migration)));
        }
    }
    @AfterAll static void stop() { POSTGRES.stop(); }
    @BeforeEach void setup() {
        db = new JdbcTemplate(source);
        db.execute("TRUNCATE finance_batch_entry_commands,synthetic_documents,users");
        UUID actor = UUID.randomUUID(); db.update("INSERT INTO users VALUES (?)", actor);
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
    @Test void optionalReferencePreservesOtherDatabaseGuards() {
        for (String table : List.of("finance_receipts", "finance_payments")) {
            db.update("INSERT INTO " + table + " VALUES (NULL,1)");
            db.update("INSERT INTO " + table + " VALUES ('',1)");
            assertThatThrownBy(() -> db.update("INSERT INTO " + table + " VALUES (NULL,-1)"))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        }
    }

    @Test void fullFreshFlywayChainAcceptsTheForwardMigrations() {
        db.execute("CREATE DATABASE finance_batch_flyway");
        String url = POSTGRES.getJdbcUrl().replace("/" + POSTGRES.getDatabaseName(), "/finance_batch_flyway");
        var flyway = com.uten.imp.testsupport.TestFlyway.configure()
                .dataSource(url, POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load();
        flyway.migrate();
        assertThat(flyway.info().current().getVersion().toString()).isEqualTo("992");
    }
}
