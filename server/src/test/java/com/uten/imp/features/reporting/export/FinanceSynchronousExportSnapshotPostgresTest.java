package com.uten.imp.features.reporting.export;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.report.FinanceReportService;
import com.uten.imp.features.finance.report.PartyMonthlySummaryService;
import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportTableResponse;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.support.FinanceReportTestAccess;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** A legacy download must not combine a pre-correction count with post-correction amounts. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FinanceSynchronousExportSnapshotPostgresTest {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("finance_export_snapshot").withReuse(false)
            .withCreateContainerCmdModifier(command -> command.getHostConfig()
                    .withMemory(256L * 1024 * 1024).withNanoCPUs(1_000_000_000L));

    @BeforeAll static void start() { POSTGRES.start(); }
    @AfterAll static void stop() { POSTGRES.stop(); }

    @Test void synchronousAuthorityKeepsOneSnapshotWhenAnotherConnectionCorrectsTheSource() {
        var source = dataSource();
        var jdbc = new JdbcTemplate(source);
        // A distinct DataSource deliberately avoids the export transaction's thread-bound connection.
        var outside = new JdbcTemplate(dataSource());
        jdbc.execute("CREATE TABLE export_facts(id integer PRIMARY KEY, amount numeric NOT NULL)");
        jdbc.update("INSERT INTO export_facts VALUES(1,123.45)");
        var statements = mock(FinanceStatementService.class);
        when(statements.supplierStatement(isNull(), isNull(), isNull(), anyInt(), anyInt(), any()))
                .thenAnswer(call -> {
                    long count = jdbc.queryForObject("SELECT count(*) FROM export_facts", Long.class);
                    outside.update("UPDATE export_facts SET amount=999.99 WHERE id=1");
                    outside.update("INSERT INTO export_facts VALUES(2,50)");
                    var rows = jdbc.queryForList("SELECT amount FROM export_facts ORDER BY id");
                    return new ReportTableResponse(List.of(ReportColumn.money("amount", "金额")),
                            rows, Map.of(), call.getArgument(3), call.getArgument(4), count, 1);
                });
        var settings = mock(SystemSettingsService.class);
        when(settings.readInt(any())).thenReturn(1000);
        var target = new FinanceReportService(mock(EntityManager.class), FinanceReportTestAccess.company(),
                settings, statements, mock(FinanceCostService.class), mock(GlReportService.class),
                mock(FixedAssetService.class), mock(PartyMonthlySummaryService.class));
        var transactions = new TransactionInterceptor();
        transactions.setTransactionManager(new DataSourceTransactionManager(source));
        transactions.setTransactionAttributeSource(new AnnotationTransactionAttributeSource());
        var proxy = new ProxyFactory(target);
        proxy.addAdvice(transactions);
        var reports = (FinanceReportService) proxy.getProxy();

        var downloaded = reports.export("statements/supplier", Map.of(), null, null);

        assertThat(downloaded.total()).isEqualTo(1);
        assertThat(downloaded.rows()).singleElement().satisfies(row ->
                assertThat((BigDecimal) row.get("amount")).isEqualByComparingTo("123.45"));
        assertThat(outside.queryForObject("SELECT sum(amount) FROM export_facts", BigDecimal.class))
                .isEqualByComparingTo("1049.99");
    }

    private static DriverManagerDataSource dataSource() {
        return new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
}
