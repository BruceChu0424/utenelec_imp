package com.uten.imp.features.ai.usage;

import com.uten.imp.audit.AuditService;
import com.uten.imp.features.admin.systemtest.BusinessDataResetDrainGate;
import com.uten.imp.features.ai.gateway.AiCallLogService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class AiProviderBillingPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static JdbcTemplate jdbc;
    static DriverManagerDataSource dataSource;
    UUID provider, actorId, employeeId;
    AiProviderBillingService billing;
    AiCallLogService logs;
    TransactionTemplate transaction;
    SecurityContextCurrentUser current;
    @BeforeAll static void open() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("ai_billing_snapshots");
        dataSource = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        jdbc = new JdbcTemplate(dataSource);
    }
    @AfterAll static void close() throws Exception { if (database != null) database.close(); }
    @BeforeEach void setup() {
        provider = UUID.randomUUID(); actorId = UUID.randomUUID(); employeeId = UUID.randomUUID();
        jdbc.update("INSERT INTO ai_providers(id,name,preset,region,protocol,base_url,model) VALUES(?,?,'CUSTOM','LOCAL','OPENAI_CHAT','http://127.0.0.1:1','model-a')",
                provider, "price-" + provider);
        current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(actorId, employeeId, "admin", Set.of("authorization:manage"), false, true, true)));
        var named = new NamedParameterJdbcTemplate(jdbc);
        var manager = new DataSourceTransactionManager(dataSource);
        transaction = new TransactionTemplate(manager);
        billing = new AiProviderBillingService(named, new AiUsageAdminAccess(current), mock(AuditService.class));
        logs = new AiCallLogService(named, manager, new BusinessDataResetDrainGate());
    }
    private AiUsageDtos.Billing save(long version, String input, String output) {
        return transaction.execute(status -> billing.save(provider,
                new AiUsageDtos.BillingRequest(version, "METERED", "USD", input, output, null, null)));
    }
    @Test void capturedPricesSurviveEditsAndNewModelsNeverReuseAnOldModelRate() {
        var first = save(0, "1.5", "3");
        Long generation = logs.captureResetGeneration();
        var snapshot = logs.capturePricing(provider, "model-a", generation);
        var second = save(first.version(), "9", "20");
        logs.record(new AiCallLogService.CallRecord("COST_QUERY", provider, "test-provider", "model-a", "OPENAI_CHAT", true,
                null, 200, 1000, 500, 10, null, actorId, generation, employeeId, snapshot));
        var record = jdbc.queryForMap("SELECT estimated_cost,actual_cost,billing_input_per_million,billing_provider_version,employee_id FROM ai_call_logs WHERE provider_id=?", provider);
        assertThat(record.get("estimated_cost").toString()).isEqualTo("0.003000000000000000");
        assertThat(record.get("actual_cost")).isNull();
        assertThat(record.get("billing_provider_version")).isEqualTo(first.version());
        assertThat(record.get("employee_id")).isEqualTo(employeeId);
        assertThatThrownBy(() -> save(0, "1", "1")).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        jdbc.update("UPDATE ai_providers SET model='model-b',version=version+1 WHERE id=?", provider);
        assertThat(logs.capturePricing(provider, "model-b", generation)).isNull();
        var displayed = billing.get(provider);
        assertThat(displayed.billingMode()).isEqualTo("UNKNOWN");
        assertThat(displayed.inputPerMillion()).isNull(); assertThat(displayed.outputPerMillion()).isNull();
        assertThat(displayed.quota().status()).isEqualTo("NOT_CONFIGURED"); assertThat(displayed.quota().windows()).hasSize(2);
        assertThat(second.version()).isGreaterThan(first.version());
    }
    @Test void missingTokensStayNullAndCannotProduceAZeroEstimate() {
        save(0, "1", "2");
        Long generation = logs.captureResetGeneration();
        logs.record(new AiCallLogService.CallRecord("MISSING_USAGE", provider, "test-provider", "model-a", "OPENAI_CHAT", true,
                null, 200, null, 500, 10, null, actorId, generation, employeeId, logs.capturePricing(provider, "model-a", generation)));
        var record = jdbc.queryForMap("SELECT input_tokens,output_tokens,estimated_cost,actual_cost,usage_capture_version FROM ai_call_logs WHERE provider_id=?", provider);
        assertThat(record.get("input_tokens")).isNull(); assertThat(record.get("output_tokens")).isEqualTo(500);
        assertThat(record.get("estimated_cost")).isNull(); assertThat(record.get("actual_cost")).isNull();
        assertThat(((Number)record.get("usage_capture_version")).intValue()).isEqualTo(1);
    }
    @Test void subscriptionQuotasOnlySurviveInSubscriptionModeAndCountSuccessfulCalls() {
        var saved = transaction.execute(status -> billing.save(provider,
                new AiUsageDtos.BillingRequest(0L, "SUBSCRIPTION", "CNY", null, null, 5, 120)));
        assertThat(saved.billingMode()).isEqualTo("SUBSCRIPTION");
        assertThat(saved.quota5h()).isEqualTo(5L);
        assertThat(saved.quotaWeekly()).isEqualTo(120L);
        assertThatThrownBy(() -> transaction.execute(status -> billing.save(provider,
                new AiUsageDtos.BillingRequest(saved.version(), "SUBSCRIPTION", null, null, null, 0, 120))))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        Long generation = logs.captureResetGeneration();
        for (int calls = 0; calls < 3; calls++) logs.record(new AiCallLogService.CallRecord("QUOTA_WINDOW", provider,
                "test-provider", "model-a", "OPENAI_CHAT", true, null, 200, 10, 10, 5, null, actorId, generation, employeeId, null));
        logs.record(new AiCallLogService.CallRecord("QUOTA_WINDOW", provider, "test-provider", "model-a",
                "OPENAI_CHAT", false, "UPSTREAM", 500, null, null, 5, null, actorId, generation, employeeId, null));
        var quota = billing.get(provider).quota();
        assertThat(quota.status()).isEqualTo("LOGGED");
        assertThat(quota.windows()).extracting(AiUsageDtos.QuotaWindow::key, AiUsageDtos.QuotaWindow::used, AiUsageDtos.QuotaWindow::quota)
                .containsExactly(tuple("FIVE_HOURS", 3L, 5L), tuple("WEEKLY", 3L, 120L));
        var metered = transaction.execute(status -> billing.save(provider,
                new AiUsageDtos.BillingRequest(saved.version(), "METERED", "USD", "1", "2", 5, 120)));
        assertThat(metered.quota5h()).isNull();
        assertThat(metered.quotaWeekly()).isNull();
        assertThat(metered.quota().status()).isEqualTo("NOT_CONFIGURED");
        assertThat(metered.quota().windows()).extracting(AiUsageDtos.QuotaWindow::used, AiUsageDtos.QuotaWindow::quota)
                .containsExactly(tuple(3L, null), tuple(3L, null));
    }
    @Test void ordinaryOrImpersonatedAccountsCannotReadOrChangeRates() {
        when(current.get()).thenReturn(Optional.of(new AuthUser(actorId, employeeId, "staff", Set.of("authorization:manage"), false, true, false)));
        assertThatThrownBy(() -> billing.get(provider)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThatThrownBy(() -> save(0, "1", "2")).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(actorId, employeeId, "admin", Set.of("authorization:manage"), false, true, true, false, UUID.randomUUID())));
        assertThatThrownBy(() -> billing.get(provider)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(jdbc.queryForObject("SELECT version FROM ai_providers WHERE id=?", Long.class, provider)).isZero();
    }
}
