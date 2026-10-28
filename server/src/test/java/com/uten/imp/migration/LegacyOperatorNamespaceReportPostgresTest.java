package com.uten.imp.migration;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.report.FinanceReportService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.features.production.report.ProductionReportService;
import com.uten.imp.features.purchase.report.PurchaseReportService;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Executes the real report actor projections/joins against distinct operator and worker namespaces. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class LegacyOperatorNamespaceReportPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private static final UUID MODERN = UUID.fromString("00000000-0000-0000-0000-000000000100");
    private static JdbcTemplate db;

    @BeforeAll static void start() {
        PG.start();
        db = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        com.uten.imp.support.MigratedProjectionSchema.createCurrentColumns(db,"employees");
        db.execute("ALTER TABLE employees ADD PRIMARY KEY(id)");
        db.update("INSERT INTO employees(id,legacy_id,full_name) VALUES (?::uuid,25,'Employee with operator number'),"
                + "(?::uuid,26,'Employee with approver number'),(?::uuid,999,'Modern employee')",
                UUID.randomUUID(), UUID.randomUUID(), MODERN);
        db.execute("""
                CREATE TABLE legacy_actor_fixture(
                    fixture_no integer PRIMARY KEY, maker_id uuid, approver_id uuid,
                    maker_legacy_id integer, approver_legacy_id integer, maker_name text, approver_name text,
                    operator_id uuid, operator_legacy_id integer, applicant_id uuid, applicant_legacy_id integer)
                """);
        for (int number = 1; number <= 4; number++) {
            UUID current = number == 2 ? MODERN : number == 4 ? UUID.randomUUID() : null;
            db.update("INSERT INTO legacy_actor_fixture VALUES (?,?,?,25,26,?,?,NULL,25,NULL,25)",
                    number, current, current, number == 3 ? null : "Frozen operator",
                    number == 3 ? null : "Frozen approver");
        }
    }

    @AfterAll static void stop() { PG.stop(); }

    @ParameterizedTest
    @ValueSource(strings = {"financePayment", "financeExpense", "financeIncome", "purchaseRequest",
            "purchaseOrder", "purchaseReceipt", "purchaseReturn", "productionPlan"})
    void reportUsesModernUuidOrFrozenOperatorNameNeverWorkerNumber(String report) {
        String sql = reportSql(report);
        String maker = projection(sql, "makerName");
        boolean hasApprover = sql.contains("AS \"approverName\"");
        String approver = hasApprover ? projection(sql, "approverName") : "NULL::text";
        String alias = documentAlias(sql);
        String actorJoins = employeeJoin(sql, "em_mk")
                + (hasApprover ? "\n" + employeeJoin(sql, "em_ap") : "");
        var rows = db.queryForList("SELECT " + alias + ".fixture_no, " + maker + " AS maker, "
                + approver + " AS approver FROM legacy_actor_fixture " + alias + " " + actorJoins
                + " ORDER BY " + alias + ".fixture_no");
        assertThat(rows).hasSize(4);
        assertThat(rows.get(0).get("maker")).isEqualTo("Frozen operator");
        assertThat(rows.get(1).get("maker")).isEqualTo("Modern employee");
        assertThat((String) rows.get(2).get("maker")).isNullOrEmpty();
        assertThat(rows.get(3).get("maker")).isEqualTo("Frozen operator");
        if (hasApprover) {
            assertThat(rows.get(0).get("approver")).isEqualTo("Frozen approver");
            assertThat(rows.get(1).get("approver")).isEqualTo("Modern employee");
            assertThat((String) rows.get(2).get("approver")).isNullOrEmpty();
            assertThat(rows.get(3).get("approver")).isEqualTo("Frozen approver");
        }
    }

    @ParameterizedTest
    @ValueSource(strings = {"financePayment", "purchaseRequest"})
    void genuineWorkerRoleStillResolvesWorkerLegacyNumber(String report) {
        String sql = reportSql(report);
        String employeeAlias = report.equals("financePayment") ? "em_op" : "em_app";
        String actual = db.queryForObject("SELECT " + employeeAlias + ".full_name FROM legacy_actor_fixture "
                + documentAlias(sql) + " " + employeeJoin(sql, employeeAlias)
                + " WHERE fixture_no=1", String.class);
        assertThat(actual).isEqualTo("Employee with operator number");
    }

    private static String projection(String sql, String column) {
        var match = Pattern.compile("(COALESCE\\(em_(?:mk|ap)\\.full_name,\\s*[top]\\.(?:maker|approver)_name(?:,\\s*'')?\\))\\s+AS \\\""
                + column + "\\\"").matcher(sql);
        assertThat(match.find()).as("actual report projection %s", column).isTrue();
        return match.group(1);
    }

    private static String documentAlias(String sql) {
        var match = Pattern.compile("em_mk\\.id\\s*=\\s*([top])\\.maker_id").matcher(sql);
        assertThat(match.find()).as("actual document maker UUID join").isTrue();
        return match.group(1);
    }

    private static String employeeJoin(String sql, String employeeAlias) {
        var match = Pattern.compile("LEFT JOIN employees " + employeeAlias
                + " ON .*?(?=\\s+(?:LEFT\\s+JOIN|JOIN|WHERE|GROUP\\s+BY|ORDER\\s+BY|LIMIT)|$)",
                Pattern.DOTALL).matcher(sql);
        assertThat(match.find()).as("actual report join %s", employeeAlias).isTrue();
        return match.group();
    }

    private static String reportSql(String report) {
        List<String> generated = new ArrayList<>();
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            String sql = call.getArgument(0);
            if (sql.contains("AS \"makerName\"")) generated.add(sql);
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenReturn(query);
            when(query.getResultList()).thenReturn(List.of());
            when(query.getSingleResult()).thenReturn(0L);
            return query;
        });
        var access = mock(FinanceDocumentAccessPolicy.class);
        when(access.scope()).thenReturn(new OwnerScope(true, Set.of()));
        when(access.hasAuthority(anyString())).thenReturn(true);
        when(access.nativeReadScope(anyString(), anyString(), any(OwnerScope.class)))
                .thenReturn(new NativeReadScope("1=1", null, Set.of()));
        var finance = new FinanceReportService(em, access, mock(SystemSettingsService.class),
                mock(FinanceStatementService.class), mock(FinanceCostService.class),
                mock(GlReportService.class), mock(FixedAssetService.class),
                new com.uten.imp.features.finance.report.PartyMonthlySummaryService(em));
        var purchase = new PurchaseReportService(em, mock(SystemSettingsService.class));
        var production = new ProductionReportService(em, mock(SystemSettingsService.class));
        switch (report) {
            case "financePayment" -> finance.paymentSummary(null,null,null,null,null,null,Map.of(),1,50,null,null);
            case "financeExpense" -> finance.expenseSummary(null,null,null,null,null,null,Map.of(),1,50,null,null);
            case "financeIncome" -> finance.incomeSummary(null,null,null,null,null,null,Map.of(),1,50,null,null);
            case "purchaseRequest" -> purchase.requestSummary(null,null,null,null,null,Map.of(),1,50,null,null);
            case "purchaseOrder" -> purchase.orderSummary(null,null,null,null,null,null,Map.of(),1,50,null,null);
            case "purchaseReceipt" -> purchase.receiptSummary(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
            case "purchaseReturn" -> purchase.returnSummary(null,null,null,null,null,null,null,Map.of(),1,50,null,null);
            case "productionPlan" -> production.planSummary(null,null,null,null,null,Map.of(),1,50,null,null);
            default -> throw new IllegalArgumentException(report);
        }
        assertThat(generated).as("generated data SQL for %s", report).isNotEmpty();
        return generated.getFirst();
    }
}
