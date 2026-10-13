package com.uten.imp.businesschain;

import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Nonempty V854 upgrade: existing real paid/qualified root slices survive forward-only V855 unchanged. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","spring.flyway.target=854","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=RootSupplyActualWarehouseForwardMigrationEndToEndTest.Cleanup.class,
        mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class RootSupplyActualWarehouseForwardMigrationEndToEndTest {
    private static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine");
    private static final String SECRET=UUID.randomUUID()+"-"+UUID.randomUUID();
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        DATABASE.start();registry.add("spring.datasource.url",DATABASE::getJdbcUrl);
        registry.add("spring.datasource.username",DATABASE::getUsername);registry.add("spring.datasource.password",DATABASE::getPassword);
        registry.add("uten.jwt.secret",()->SECRET);registry.add("uten.crypto.pgp-master-key",()->SECRET);registry.add("uten.crypto.hmac-key",()->SECRET);
        registry.add("uten.bootstrap.admin-login",()->"root-forward-bootstrap");registry.add("uten.bootstrap.admin-password",()->SECRET+"Aa1!");
    }
    static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder()-1; }
        @Override public void afterTestClass(TestContext ignored) { DATABASE.stop(); }
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseReceiptService receipts;

    @Test void realExistingSourcesAndAppliedHistoryRemainByteForByteAndTheirReversalStillWorks() {
        var support=new RootSupplyActualWarehouseEndToEndTest();beans.autowireBean(support);support.prepare();
        try {
            var fixture=support.manualFixture(false);support.passManual(fixture);
            assertThat(db.queryForObject("SELECT max(version::integer) FROM flyway_schema_history WHERE success",Integer.class)).isEqualTo(854);
            assertThat(db.queryForObject("SELECT pg_get_functiondef('fn_guard_root_output_event()'::regprocedure)",String.class))
                    .contains("a.warehouse_id=NEW.warehouse_id");
            var before=businessFacts(fixture);
            var history=db.queryForList("SELECT row_to_json(history)::text FROM flyway_schema_history history WHERE version::integer<=854 ORDER BY installed_rank",String.class);
            var migration=Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                    .locations("classpath:db/migration").target("855").load();
            assertThat(migration.migrate().migrationsExecuted).isEqualTo(1);
            assertThat(businessFacts(fixture)).containsExactlyElementsOf(before);
            assertThat(db.queryForList("SELECT row_to_json(history)::text FROM flyway_schema_history history WHERE version::integer<=854 ORDER BY installed_rank",String.class))
                    .containsExactlyElementsOf(history);
            migration.validate();assertThat(migration.migrate().migrationsExecuted).isZero();
            assertThat(db.queryForObject("SELECT pg_get_functiondef('fn_guard_root_output_event()'::regprocedure)",String.class))
                    .doesNotContain("a.warehouse_id=NEW.warehouse_id").contains("original.warehouse_id<>NEW.warehouse_id");
            receipts.reverse(fixture.receipt());
            assertThat(db.queryForObject("SELECT COALESCE(SUM(root_fulfilled_qty),0) FROM production_material_analysis_items WHERE analysis_id=?",java.math.BigDecimal.class,fixture.analysis())).isZero();
            assertThat(db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id IN (?,?)",java.math.BigDecimal.class,fixture.goods().get(0),fixture.goods().get(1))).isZero();
        } finally { support.clear(); }
    }

    private List<String> businessFacts(RootSupplyActualWarehouseEndToEndTest.Fixture fixture) {
        java.util.ArrayList<String> facts=new java.util.ArrayList<>();
        facts.addAll(db.queryForList("SELECT row_to_json(output)::text FROM preplan_root_output_events output WHERE analysis_id=? ORDER BY id",String.class,fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(item)::text FROM production_material_analysis_items item WHERE analysis_id=? ORDER BY id",String.class,fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(reservation)::text FROM stock_reservations reservation WHERE source_doc_id=? ORDER BY id",String.class,fixture.receipt()));
        facts.addAll(db.queryForList("SELECT row_to_json(balance)::text FROM stock_balances balance WHERE goods_id IN (?,?) ORDER BY id",String.class,fixture.goods().get(0),fixture.goods().get(1)));
        facts.addAll(db.queryForList("SELECT row_to_json(entitlement)::text FROM preplan_stock_entitlement_events entitlement WHERE source_receipt_id=? OR beneficiary_analysis_id=? ORDER BY id",String.class,fixture.receipt(),fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(movement)::text FROM stock_movements movement WHERE source_doc_id=? ORDER BY id",String.class,fixture.receipt()));
        return List.copyOf(facts);
    }
}
