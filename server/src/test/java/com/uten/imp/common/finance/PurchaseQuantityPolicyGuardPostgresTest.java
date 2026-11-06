package com.uten.imp.common.finance;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.UUID;
import com.uten.imp.testsupport.MigrationSqlResources;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Actual adoption SQL in a private schema; full source/finance authorization remains in revision E2E. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PurchaseQuantityPolicyGuardPostgresTest {
    private static final PostgreSQLContainer DATABASE = new PostgreSQLContainer("postgres:16-alpine");
    private static SingleConnectionDataSource source;
    private static JdbcTemplate jdbc;
    private static final String OLD = "{\"version\":1,\"choices\":{\"quantity.to-base\":{\"scale\":6,\"rounding\":\"DOWN\"}}}";
    private static final String NEXT = "{\"version\":1,\"choices\":{\"quantity.to-base\":{\"scale\":17,\"rounding\":\"HALF_UP\"}}}";

    @BeforeAll static void database() {
        DATABASE.start();
        source = new SingleConnectionDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword(), true);
        jdbc = new JdbcTemplate(source);
    }

    @AfterAll static void close() {
        if (source != null) {
            source.destroy();
        }
        DATABASE.stop();
    }

    @BeforeEach void originalAdoption() throws Exception {
        jdbc.execute("DROP SCHEMA IF EXISTS adoption CASCADE; CREATE SCHEMA adoption; SET search_path TO adoption");
        // Complete migrated columns/defaults; retain this oracle's original keys and constraints.
        MigratedProjectionSchema.createCurrentColumns(jdbc,
                "purchase_orders", "purchase_order_items", "purchase_receipt_items");
        jdbc.execute("""
                ALTER TABLE purchase_orders ADD PRIMARY KEY (id);
                ALTER TABLE purchase_order_items ADD PRIMARY KEY (id);
                """);
        String precision = sql("V990_1__explicit_business_precision_choices.sql");
        jdbc.execute(precision.substring(0, precision.indexOf("-- The same original/local book split")));
        jdbc.execute(function(sql("V518__procurement_iqc_replacement_consideration.sql"), "fn_financial_amount_is_exact"));
        String adoption = sql("V1033__frozen_document_quantity_adoption.sql");
        jdbc.execute(function(adoption, "fn_document_quantity_to_base"));
        jdbc.execute(function(adoption, "fn_document_return_quantity_slice"));
        jdbc.execute(function(adoption, "fn_guard_document_quantity_adoption"));
        jdbc.execute("CREATE TRIGGER trg_00_document_quantity_adoption BEFORE INSERT OR UPDATE ON purchase_order_items FOR EACH ROW EXECUTE FUNCTION fn_guard_document_quantity_adoption()");
        choose(OLD);
    }

    @Test void originalRoutineDemonstratesThePolicyRetagWithoutChangingAnyQuantity() {
        UUID item = seed(1); String before = row(item);
        choose(NEXT); jdbc.update("UPDATE purchase_order_items SET charged_base_qty=charged_base_qty+1 WHERE id=?", item);
        assertThat(row(item)).isNotEqualTo(before);
        assertThat(jdbc.queryForObject("SELECT quantity_precision_policy=CAST(? AS jsonb) FROM purchase_order_items WHERE id=?", Boolean.class, NEXT, item)).isTrue();
        assertThat(jdbc.queryForObject("SELECT charged_base_qty FROM purchase_order_items WHERE id=?", java.math.BigDecimal.class, item)).isEqualByComparingTo("3");
    }

    @ParameterizedTest @ValueSource(ints = {0, 1})
    void independentDerivedEditsCannotChangeValuesPoliciesOrOriginalInputs(int status) throws Exception {
        UUID item = seed(status); installGuard(); String before = row(item); choose(NEXT);
        assertThatThrownBy(() -> jdbc.update("UPDATE purchase_order_items SET charged_base_qty=charged_base_qty+1 WHERE id=?", item));
        assertThat(row(item)).isEqualTo(before);
        assertThatThrownBy(() -> jdbc.update("UPDATE purchase_order_items SET gift_base_qty=gift_base_qty+1 WHERE id=?", item));
        assertThat(row(item)).isEqualTo(before);
    }

    @ParameterizedTest @ValueSource(ints = {0, 1})
    void actualQuantityChangesStillFreezeTheirOwnOperationPolicy(int status) throws Exception {
        UUID item = seed(status); installGuard(); choose(NEXT);
        jdbc.update("UPDATE purchase_order_items SET qty=2 WHERE id=?", item);
        assertThat(jdbc.queryForObject("SELECT charged_base_qty FROM purchase_order_items WHERE id=?", java.math.BigDecimal.class, item)).isEqualByComparingTo("6");
        assertThat(jdbc.queryForObject("SELECT quantity_precision_policy=CAST(? AS jsonb) FROM purchase_order_items WHERE id=?", Boolean.class, NEXT, item)).isTrue();
    }

    @Test void stateOnlyChangesAndIndependentPolicyReplacementKeepTheFrozenProof() throws Exception {
        UUID item = seed(1); installGuard(); choose(NEXT);
        jdbc.update("UPDATE purchase_order_items SET remark='state-only' WHERE id=?", item);
        assertThat(jdbc.queryForObject("SELECT quantity_precision_policy=CAST(? AS jsonb) FROM purchase_order_items WHERE id=?", Boolean.class, OLD, item)).isTrue();
        String before = row(item);
        assertThatThrownBy(() -> jdbc.update("UPDATE purchase_order_items SET quantity_precision_policy=CAST(? AS jsonb) WHERE id=?", NEXT, item));
        assertThat(row(item)).isEqualTo(before);
    }

    @Test void subcontractAdoptionWithoutPurchaseOnlyColumnsKeepsItsOwnLifecycle() throws Exception {
        MigratedProjectionSchema.createCurrentColumns(jdbc,"subcontract_material_return_items");
        jdbc.execute("CREATE TRIGGER adoption BEFORE INSERT OR UPDATE ON subcontract_material_return_items FOR EACH ROW EXECUTE FUNCTION fn_guard_document_quantity_adoption()");
        UUID item = UUID.randomUUID();
        jdbc.update("INSERT INTO subcontract_material_return_items(id,qty,unit_id,unit_rate) VALUES(?,1,?,3)", item, UUID.randomUUID());
        installGuard(); choose(NEXT);
        jdbc.update("UPDATE subcontract_material_return_items SET qty=2 WHERE id=?", item);
        assertThat(jdbc.queryForObject("SELECT adopted_base_qty FROM subcontract_material_return_items WHERE id=?", java.math.BigDecimal.class, item)).isEqualByComparingTo("6");
    }

    @Test void purchaseReturnApprovalStillClosesTheActualFrozenSourceRemainder() throws Exception {
        MigratedProjectionSchema.createCurrentColumns(jdbc,"purchase_returns","purchase_return_items");
        jdbc.execute("CREATE TRIGGER adoption BEFORE INSERT OR UPDATE ON purchase_return_items FOR EACH ROW EXECUTE FUNCTION fn_guard_document_quantity_adoption()");
        UUID receipt = UUID.randomUUID(), first = UUID.randomUUID(), current = UUID.randomUUID(), unit = UUID.randomUUID();
        // The old v1 receipt retained four-place adoption of 3 * 0.333333 = 1.0000.
        jdbc.update("INSERT INTO purchase_receipt_items(id,qty,charged_base_qty,gift_qty,gift_base_qty,quantity_semantics,quantity_adoption_version) VALUES(?,3,1,0,0,'CHARGED_PLUS_GIFT_V1',1)", receipt);
        jdbc.update("INSERT INTO purchase_returns(id,status) VALUES(?,1),(?,0)", first, current);
        jdbc.update("INSERT INTO purchase_return_items(id,return_id,receipt_item_id,qty,unit_id,unit_rate,quantity_semantics,gift_qty,charged_base_qty,gift_base_qty) VALUES(?,?,?,?,?,0.333333,'CHARGED_PLUS_GIFT_V1',0,0.333333,0)", UUID.randomUUID(), first, receipt, 1, unit);
        UUID item = UUID.randomUUID();
        jdbc.update("INSERT INTO purchase_return_items(id,return_id,receipt_item_id,qty,unit_id,unit_rate,quantity_semantics,gift_qty,charged_base_qty,gift_base_qty) VALUES(?,?,?,?,?,0.333333,'CHARGED_PLUS_GIFT_V1',0,0.666666,0)", item, current, receipt, 2, unit);
        installGuard(); choose(NEXT);
        jdbc.update("UPDATE purchase_return_items SET charged_base_qty=0.666667 WHERE id=?", item);
        assertThat(jdbc.queryForObject("SELECT charged_base_qty FROM purchase_return_items WHERE id=?", java.math.BigDecimal.class, item)).isEqualByComparingTo("0.666667");
        assertThat(jdbc.queryForObject("SELECT quantity_source_proof->>'kind' FROM purchase_return_items WHERE id=?", String.class, item)).isEqualTo("SOURCE_RECEIPT");
    }

    private static UUID seed(int status) {
        UUID item = UUID.randomUUID(), order = UUID.randomUUID();
        jdbc.update("INSERT INTO purchase_orders(id,status) VALUES(?,?)",order,status);
        jdbc.update("INSERT INTO purchase_order_items(id,order_id,qty,unit_id,unit_rate,quantity_semantics,gift_qty) VALUES(?,?,1,?,3,'CHARGED_PLUS_GIFT_V1',1)", item, order, UUID.randomUUID());
        return item;
    }
    private static void choose(String policy) { jdbc.queryForObject("SELECT set_config('app.business_precision_choices',?,false)", String.class, policy); }
    private static String row(UUID item) { return jdbc.queryForObject("SELECT to_jsonb(i)::text FROM purchase_order_items i WHERE id=?", String.class, item); }
    private static void installGuard() throws Exception { jdbc.execute(sql("V1060__keep_frozen_purchase_quantity_policy_on_derived_only_updates.sql")); }
    private static String sql(String name) throws Exception { return MigrationSqlResources.read(name); }
    private static String function(String source, String name) { return MigrationSqlResources.function(source, name); }
}
