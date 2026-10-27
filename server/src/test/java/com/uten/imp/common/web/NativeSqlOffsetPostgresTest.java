package com.uten.imp.common.web;

import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.quote.SalesQuoteFinanceService;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.draw.SubcontractDrawQueryService;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Actual service SQL on a migrated private database: large OFFSET must not wrap negative. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class NativeSqlOffsetPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static EntityManagerFactory factory;

    @BeforeAll static void baseline() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("native_offset_boundary");
        var source = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        var bean = new LocalContainerEntityManagerFactoryBean(); bean.setDataSource(source);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter()); bean.setPackagesToScan("com.uten.imp.security");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none")); bean.afterPropertiesSet(); factory = bean.getObject();
    }
    @AfterAll static void close() throws Exception {
        if (factory != null) {
            factory.close();
        }
        if (database != null) {
            database.close();
        }
    }

    @ParameterizedTest @ValueSource(strings = {"schedule", "quote-finance", "order-finance", "subcontract-draw"})
    void emptyDatabaseDeepPagesExecuteRealSqlAndKeepTheirActualIndex(String reader) {
        try (EntityManager em = factory.createEntityManager()) {
            // A unique fixture keyword makes the result empty without clearing
            // any table. PostgreSQL still executes the actual SQL and rejects
            // the old negative int offset.
            String keyword = "B1-OFFSET-" + java.util.UUID.randomUUID();
            PageResponse<?> result = switch (reader) {
                case "schedule" -> new ProductionScheduleService(em, null, null).pending(
                        Integer.MAX_VALUE, Integer.MAX_VALUE, keyword, null, null, null, null, null, null);
                case "quote-finance" -> {
                    var service = mock(SalesQuoteFinanceService.class, CALLS_REAL_METHODS);
                    ReflectionTestUtils.setField(service, "em", em);
                    ReflectionTestUtils.setField(service, "claimViews", mock(TaskClaimService.class));
                    yield service.list("pending", keyword, Integer.MAX_VALUE, Integer.MAX_VALUE);
                }
                case "order-finance" -> {
                    var service = mock(SalesOrderFinanceConfirmService.class, CALLS_REAL_METHODS);
                    ReflectionTestUtils.setField(service, "em", em);
                    yield service.pending(Integer.MAX_VALUE, Integer.MAX_VALUE, null, keyword, null);
                }
                case "subcontract-draw" -> {
                    var access = mock(SubcontractDocumentAccessPolicy.class);
                    when(access.nativeReadScope("o.maker_id", "readOwners"))
                            .thenReturn(new NativeReadScope("1=1", null, Set.of()));
                    yield new SubcontractDrawQueryService(em, access).tasks(Integer.MAX_VALUE, Integer.MAX_VALUE,
                            keyword, "ALL", null, List.of()).page();
                }
                default -> throw new IllegalArgumentException(reader);
            };
            assertThat(result.getPage()).isEqualTo(Integer.MAX_VALUE);
            assertThat(result.getSize()).isEqualTo(reader.equals("subcontract-draw") ? 200 : 100);
            assertThat(result.getItems()).isEmpty();
        }
    }
}
