package com.uten.imp.businesschain;

import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.visitor.sms.SmsGatewaySecretRewrap;
import com.uten.imp.security.SecretCipher;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.jpa.EntityManagerFactoryBuilder;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.verify;
import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_HEAD_VERSION;
import static com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT;
import static com.uten.imp.migration.MigrationRehearsalSupport.migrationFileCountUpTo;

/** Nonempty V854 -> V855 proof, then current-schema application reversal of those same historical slices. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","spring.flyway.target=854","spring.jpa.hibernate.ddl-auto=none","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=RootSupplyActualWarehouseForwardMigrationEndToEndTest.Cleanup.class,
        mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class RootSupplyActualWarehouseForwardMigrationEndToEndTest {
    private static final PostgreSQLContainer DATABASE=new PostgreSQLContainer("postgres:16-alpine");
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
    @Autowired EntityManagerFactoryBuilder entityManagerFactoryBuilder;
    @Autowired javax.sql.DataSource dataSource;
    @Autowired SecretCipher cipher;
    // The SMS settings table starts at V867. Its current-schema startup task is
    // unrelated to this real V854 fixture; keep encryption and migration beans real.
    @MockitoBean(enforceOverride = true) SmsGatewaySecretRewrap smsGatewaySecretRewrap;

    @Test void realExistingSourcesAndAppliedHistoryRemainByteForByteAndTheirReversalStillWorks() {
        assertThat(cipher.available()).isTrue();
        verify(smsGatewaySecretRewrap).onStartup();
        assertThat(db.queryForObject("SELECT to_regclass('public.sms_gateway_settings') IS NULL", Boolean.class)).isTrue();
        var support=new RootSupplyActualWarehouseEndToEndTest();beans.autowireBean(support);support.prepare();
        try {
            // Prepare versioned V854 analysis/request/procurement facts, then run real
            // receipt/IQC/stock commands. Historical authorities restore before Flyway;
            // current-schema receipt reversal below always uses the production bean.
            var historical=new LegacyV854RootSupplyFixture(support);
            var fixture=historical.createAndPass();
            historical.assertCurrentComponentsRestored();
            assertThat(db.queryForObject("SELECT max(version::integer) FROM flyway_schema_history WHERE success",Integer.class)).isEqualTo(854);
            assertThat(db.queryForObject("SELECT pg_get_functiondef('fn_guard_root_output_event()'::regprocedure)",String.class))
                    .contains("a.warehouse_id=NEW.warehouse_id");
            var before=businessFacts(fixture);
            assertThat(db.queryForObject("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='purchase_receipt_items' AND column_name='order_item_legacy_id'",Integer.class)).isZero();
            var beforeCurrent=businessFacts(fixture,true);
            var history=db.queryForList("SELECT row_to_json(history)::text FROM flyway_schema_history history WHERE version::integer<=854 ORDER BY installed_rank",String.class);
            var migration=com.uten.imp.testsupport.TestFlyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                    .locations("classpath:db/migration").target("855").load();
            assertThat(migration.migrate().migrationsExecuted).isEqualTo(1);
            assertThat(businessFacts(fixture)).containsExactlyElementsOf(before);
            assertThat(db.queryForList("SELECT row_to_json(history)::text FROM flyway_schema_history history WHERE version::integer<=854 ORDER BY installed_rank",String.class))
                    .containsExactlyElementsOf(history);
            migration.validate();assertThat(migration.migrate().migrationsExecuted).isZero();
            assertThat(db.queryForObject("SELECT pg_get_functiondef('fn_guard_root_output_event()'::regprocedure)",String.class))
                    .doesNotContain("a.warehouse_id=NEW.warehouse_id").contains("original.warehouse_id<>NEW.warehouse_id");

            // This phase proves V855 in isolation. The current application also
            // requires V861's scoped public-source signature; it cannot reverse
            // against a historical V855-only schema.
            assertThat(db.queryForObject("SELECT to_regprocedure('public.fn_preplan_make_public_supply_sources(uuid,uuid,uuid[])') IS NULL",Boolean.class))
                    .isTrue();
            var historyThrough855=db.queryForList("SELECT row_to_json(history)::text FROM flyway_schema_history history WHERE version::integer<=855 ORDER BY installed_rank",String.class);
            var currentMigration=com.uten.imp.testsupport.TestFlyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                    .locations("classpath:db/migration").target(CURRENT_HEAD_VERSION).load();
            assertThat(currentMigration.migrate().migrationsExecuted)
                    .isEqualTo(CURRENT_MIGRATION_COUNT-migrationFileCountUpTo(855));
            currentMigration.validate();assertThat(currentMigration.migrate().migrationsExecuted).isZero();
            assertThat(db.queryForObject("SELECT max(version::integer) FROM flyway_schema_history WHERE success",Integer.class))
                    .isEqualTo(com.uten.imp.testsupport.FixtureNumbers.integer(CURRENT_HEAD_VERSION));
            assertThat(db.queryForObject("SELECT to_regclass('public.sms_gateway_settings') IS NOT NULL", Boolean.class)).isTrue();
            assertThat(db.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE version IS NOT NULL AND success",Integer.class))
                    .isEqualTo(CURRENT_MIGRATION_COUNT);
            assertThat(db.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE NOT success",Integer.class)).isZero();
            // Historical preparation intentionally uses V854, before columns in
            // today's entity mappings exist. Once all forward migrations are
            // applied, validate every current mapping before using current beans.
            validateCurrentApplicationSchema();
            historical.assertCurrentComponentsRestored();
            assertThat(db.queryForObject("SELECT to_regprocedure('public.fn_preplan_make_public_supply_sources(uuid,uuid,uuid[])') IS NOT NULL",Boolean.class))
                    .isTrue();
            // V909 adds one nullable legacy-reference field without backfilling
            // native historical receipts. Compare every original field and
            // independently require the precise new column to remain NULL.
            assertThat(db.queryForObject("SELECT data_type='integer' AND is_nullable='YES' AND column_default IS NULL FROM information_schema.columns WHERE table_schema='public' AND table_name='purchase_receipt_items' AND column_name='order_item_legacy_id'",Boolean.class)).isTrue();
            assertThat(db.queryForObject("SELECT count(*) FROM purchase_receipt_items WHERE receipt_id=? AND order_item_legacy_id IS NOT NULL",Integer.class,fixture.receipt())).isZero();
            assertThat(businessFacts(fixture,true)).containsExactlyElementsOf(beforeCurrent);
            assertThat(db.queryForList("SELECT row_to_json(history)::text FROM flyway_schema_history history WHERE version::integer<=855 ORDER BY installed_rank",String.class))
                    .containsExactlyElementsOf(historyThrough855);
            var originalFulfillments=db.queryForList("SELECT row_to_json(output)::text FROM preplan_root_output_events output WHERE analysis_id=? AND event_kind='FULFILL' ORDER BY id",String.class,fixture.analysis());
            assertThat(originalFulfillments).hasSize(2);
            assertThat(db.queryForObject("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=? AND warehouse_id<>?",Integer.class,fixture.analysis(),fixture.leaf())).isZero();
            assertThat(db.queryForObject("SELECT status FROM purchase_receipts WHERE id=?",Integer.class,fixture.receipt())).isEqualTo(1);
            receipts.reverse(fixture.receipt());
            assertThat(db.queryForObject("SELECT COALESCE(SUM(root_fulfilled_qty),0) FROM production_material_analysis_items WHERE analysis_id=?",java.math.BigDecimal.class,fixture.analysis())).isZero();
            assertThat(db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id IN (?,?)",java.math.BigDecimal.class,fixture.goods().get(0),fixture.goods().get(1))).isZero();
            assertThat(db.queryForObject("SELECT status FROM purchase_receipts WHERE id=?",Integer.class,fixture.receipt())).isEqualTo(-1);
            assertThat(db.queryForList("SELECT row_to_json(output)::text FROM preplan_root_output_events output WHERE analysis_id=? AND event_kind='FULFILL' ORDER BY id",String.class,fixture.analysis()))
                    .containsExactlyElementsOf(originalFulfillments);
            assertThat(db.queryForObject("SELECT count(*) FROM preplan_root_output_events WHERE analysis_id=? AND event_kind='REVERSE'",Integer.class,fixture.analysis()))
                    .isEqualTo(originalFulfillments.size());
            assertThat(db.queryForObject("""
                    SELECT count(*) FROM preplan_root_output_events reversal
                    LEFT JOIN preplan_root_output_events original ON original.id=reversal.reversed_event_id AND original.event_kind='FULFILL'
                    WHERE reversal.analysis_id=? AND reversal.event_kind='REVERSE' AND (
                        original.id IS NULL OR
                        (reversal.analysis_item_id,reversal.root_material_id,reversal.warehouse_id,reversal.goods_id,reversal.color_id,
                         reversal.qty_base,reversal.route,reversal.source_reservation_id,reversal.release_entitlement_event_id,
                         reversal.sales_order_item_id,reversal.sales_reservation_id,reversal.source_receipt_type,reversal.source_receipt_id)
                        IS DISTINCT FROM
                        (original.analysis_item_id,original.root_material_id,original.warehouse_id,original.goods_id,original.color_id,
                         original.qty_base,original.route,original.source_reservation_id,original.release_entitlement_event_id,
                         original.sales_order_item_id,original.sales_reservation_id,original.source_receipt_type,original.source_receipt_id))
                    """,Integer.class,fixture.analysis())).isZero();
        } finally { support.clear(); }
    }

    private void validateCurrentApplicationSchema() {
        var validation = entityManagerFactoryBuilder.dataSource(dataSource)
                .packages("com.uten.imp")
                .persistenceUnit("root-supply-forward-current-schema")
                .properties(java.util.Map.of("hibernate.hbm2ddl.auto", "validate"))
                .build();
        try {
            validation.afterPropertiesSet();
            assertThat(validation.getObject()).isNotNull();
        } finally {
            validation.destroy();
        }
    }

    private List<String> businessFacts(RootSupplyActualWarehouseEndToEndTest.Fixture fixture) {
        return businessFacts(fixture,false);
    }

    private List<String> businessFacts(RootSupplyActualWarehouseEndToEndTest.Fixture fixture,boolean projectV909NullableColumn) {
        java.util.ArrayList<String> facts=new java.util.ArrayList<>();
        facts.addAll(db.queryForList("SELECT row_to_json(analysis)::text FROM production_material_analyses analysis WHERE id=?",String.class,fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(material)::text FROM production_material_analysis_materials material WHERE analysis_id=? ORDER BY id",String.class,fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(action)::text FROM preplan_supply_actions action WHERE analysis_id=? ORDER BY id",String.class,fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(allocation)::text FROM preplan_supply_action_allocations allocation WHERE analysis_id=? ORDER BY id",String.class,fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(request)::text FROM purchase_requests request WHERE id IN(SELECT external_document_id FROM preplan_supply_actions WHERE analysis_id=? AND external_document_type='PURCHASE_REQUEST') ORDER BY id",String.class,fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(item)::text FROM purchase_request_items item WHERE id IN(SELECT external_item_id FROM preplan_supply_action_allocations WHERE analysis_id=?) ORDER BY id",String.class,fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(receipt)::text FROM purchase_receipts receipt WHERE id=?",String.class,fixture.receipt()));
        facts.addAll(db.queryForList(projectV909NullableColumn
                ? "SELECT (to_jsonb(item)-'order_item_legacy_id')::text FROM purchase_receipt_items item WHERE receipt_id=? ORDER BY id"
                : "SELECT row_to_json(item)::text FROM purchase_receipt_items item WHERE receipt_id=? ORDER BY id",String.class,fixture.receipt()));
        facts.addAll(db.queryForList("SELECT row_to_json(output)::text FROM preplan_root_output_events output WHERE analysis_id=? ORDER BY id",String.class,fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(item)::text FROM production_material_analysis_items item WHERE analysis_id=? ORDER BY id",String.class,fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(reservation)::text FROM stock_reservations reservation WHERE source_doc_id=? ORDER BY id",String.class,fixture.receipt()));
        facts.addAll(db.queryForList("SELECT row_to_json(balance)::text FROM stock_balances balance WHERE goods_id IN (?,?) ORDER BY id",String.class,fixture.goods().get(0),fixture.goods().get(1)));
        facts.addAll(db.queryForList("SELECT row_to_json(entitlement)::text FROM preplan_stock_entitlement_events entitlement WHERE source_receipt_id=? OR beneficiary_analysis_id=? ORDER BY id",String.class,fixture.receipt(),fixture.analysis()));
        facts.addAll(db.queryForList("SELECT row_to_json(movement)::text FROM stock_movements movement WHERE source_doc_id=? ORDER BY id",String.class,fixture.receipt()));
        return List.copyOf(facts);
    }
}
