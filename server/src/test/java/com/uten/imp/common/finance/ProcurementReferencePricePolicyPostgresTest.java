package com.uten.imp.common.finance;

import com.uten.imp.testsupport.MigrationSqlResources;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Real retained SQL and current forward guards; service authorization is covered by procurement E2E. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementReferencePricePolicyPostgresTest {
    private static final PostgreSQLContainer DATABASE = new PostgreSQLContainer("postgres:16-alpine");
    private static SingleConnectionDataSource source;
    private static JdbcTemplate jdbc;
    private static final UUID CURRENCY = UUID.randomUUID(), SETTLEMENT = UUID.randomUUID();
    private static final String PURPOSE = "money.reference-unit-price";
    private record OwnerSql(String orderInsert, String itemInsert, String row, String header, String proof,
            String replacePolicy, String deleteItem, String missingPolicy) { }
    private static OwnerSql owner(String prefix) {
        return switch (prefix) {
            case "purchase" -> new OwnerSql(
                    "INSERT INTO purchase_orders(id,status,currency_id,exchange_rate,tax_rate,settlement_method_id,total_original,total_local) VALUES(?,?,?,1,0,?,?,?)",
                    "INSERT INTO purchase_order_items(id,order_id,legacy_id,qty,unit_id,price,total_amount_input,amount_original,amount_local) VALUES(?,?,?,?,?,?,?,?,?)",
                    "SELECT to_jsonb(i)::text FROM purchase_order_items i WHERE id=?", "SELECT to_jsonb(i)::text FROM purchase_orders i WHERE id=?",
                    "SELECT fn_procurement_reference_price_proof(1,6,reference_price_precision_policy) FROM purchase_order_items WHERE id=?",
                    "UPDATE purchase_order_items SET reference_price_precision_policy=fn_business_precision_snapshot() WHERE id=?",
                    "DELETE FROM purchase_order_items WHERE id=?", "SELECT reference_price_precision_policy IS NULL FROM purchase_order_items WHERE id=?");
            case "subcontract" -> new OwnerSql(
                    "INSERT INTO subcontract_orders(id,status,currency_id,exchange_rate,tax_rate,settlement_method_id,total_original,total_local) VALUES(?,?,?,1,0,?,?,?)",
                    "INSERT INTO subcontract_order_items(id,order_id,legacy_id,qty,unit_id,price,total_amount_input,amount_original,amount_local) VALUES(?,?,?,?,?,?,?,?,?)",
                    "SELECT to_jsonb(i)::text FROM subcontract_order_items i WHERE id=?", "SELECT to_jsonb(i)::text FROM subcontract_orders i WHERE id=?",
                    "SELECT fn_procurement_reference_price_proof(1,6,reference_price_precision_policy) FROM subcontract_order_items WHERE id=?",
                    "UPDATE subcontract_order_items SET reference_price_precision_policy=fn_business_precision_snapshot() WHERE id=?",
                    "DELETE FROM subcontract_order_items WHERE id=?", "SELECT reference_price_precision_policy IS NULL FROM subcontract_order_items WHERE id=?");
            default -> throw new IllegalArgumentException("Unsupported fixture owner");
        };
    }

    @BeforeAll static void database() {
        DATABASE.start(); source = new SingleConnectionDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword(), true);
        jdbc = new JdbcTemplate(source);
    }
    @AfterAll static void close() { if (source != null) source.destroy(); DATABASE.stop(); }

    @BeforeEach void originalSchemaAndProofs() throws Exception {
        jdbc.execute("DROP SCHEMA IF EXISTS reference_price CASCADE; CREATE SCHEMA reference_price; SET search_path TO reference_price");
        jdbc.execute("CREATE TABLE currencies(id uuid,status text,is_deleted boolean DEFAULT false); CREATE TABLE settlement_methods(id uuid,status text,is_deleted boolean DEFAULT false)");
        jdbc.update("INSERT INTO currencies(id,status) VALUES(?,'使用')", CURRENCY);
        jdbc.update("INSERT INTO settlement_methods(id,status) VALUES(?,'使用')", SETTLEMENT);
        jdbc.execute("""
                DO $fixture$ DECLARE prefix text; BEGIN
                FOREACH prefix IN ARRAY ARRAY['purchase','subcontract'] LOOP
                 EXECUTE format('CREATE TABLE %I(id uuid PRIMARY KEY,status smallint DEFAULT 0,currency_id uuid,exchange_rate numeric,tax_rate numeric,settlement_method_id uuid,total_original numeric,total_local numeric,is_deleted boolean DEFAULT false)',prefix||'_orders');
                 EXECUTE format('CREATE TABLE %I(id uuid PRIMARY KEY,order_id uuid,legacy_id bigint,qty numeric,price numeric,amount_original numeric,amount_local numeric,unit_id uuid,unit_rate numeric DEFAULT 1,quantity_semantics text DEFAULT ''CHARGED_PLUS_GIFT_V1'',gift_qty numeric DEFAULT 0,charged_base_qty numeric,gift_base_qty numeric,quantity_adoption_version smallint DEFAULT 2,quantity_precision_policy jsonb,extra_columns jsonb DEFAULT ''[]'',is_deleted boolean DEFAULT false)',prefix||'_order_items');
                END LOOP; END $fixture$;
                """);
        jdbc.execute("CREATE TABLE purchase_receipt_items(id uuid,qty numeric,charged_base_qty numeric,gift_qty numeric,gift_base_qty numeric)");
        jdbc.execute("CREATE TABLE procurement_order_approval_cases(id uuid PRIMARY KEY,order_type text,order_id uuid,request_type text DEFAULT 'ORDER',status text,version bigint DEFAULT 1,attempt integer DEFAULT 1,amount_snapshot numeric,submission_snapshot jsonb,snapshot_hash text,display_snapshot jsonb)");
        jdbc.execute("CREATE TABLE procurement_order_source_revisions(id uuid,order_type text,order_id uuid,order_item_id uuid,old_qty numeric,new_qty numeric,before_item jsonb,created_txid bigint DEFAULT txid_current(),pending_case_id uuid,pending_case_version bigint)");
        jdbc.execute("CREATE TABLE procurement_order_approval_events(case_id uuid,event_type text,actor_user_id uuid,actor_employee_id uuid,event_snapshot jsonb)");
        String exact = read("V990_1__explicit_business_precision_choices.sql");
        jdbc.execute(exact.substring(0, exact.indexOf("-- The same original/local book split")));
        String old = read("V518__procurement_iqc_replacement_consideration.sql");
        routine(old, "fn_financial_amount_is_exact");
        routine(read("V744__business_document_extra_columns.sql"), "fn_business_columns_amount");
        routine(old, "fn_guard_procurement_finance_commercial_snapshot");
        routine(old, "fn_is_proven_procurement_qty_revision");
        routine(old, "fn_is_proven_procurement_header_revision");
        String columns = read("V746__business_column_commercial_snapshot_guards.sql");
        jdbc.execute(columns.substring(columns.indexOf("DO $migration$"), columns.indexOf("    source := pg_get_functiondef('fn_procurement_approval_display_snapshot")) + "\nEND\n$migration$;");
        String total = read("V760__procurement_total_amount_input.sql");
        jdbc.execute(total.substring(0, total.indexOf("    source := pg_get_functiondef('fn_procurement_approval_display_snapshot")) + "\nEND\n$migration$;");
        routine(read("V844__purchase_free_tranche_fulfillment_and_replacements.sql"), "fn_guard_procurement_finance_commercial_snapshot");
        String pending = read("V963__purchase_pending_review_quantity_revision.sql");
        String proofPatch = pending.substring(pending.indexOf("    definition:=pg_get_functiondef('fn_is_proven_procurement_qty_revision"), pending.indexOf("    definition:=pg_get_functiondef('fn_prepare_procurement_source_allocation"));
        jdbc.execute("DO $patch$ DECLARE definition text;anchor text; BEGIN\n" + proofPatch + "\nEND $patch$;");
        routine(pending, "fn_is_pending_purchase_case_qty_revision");
        jdbc.execute(read("V1047__proven_qty_revision_quantity_adoption_columns.sql"));
        String adoption = read("V1033__frozen_document_quantity_adoption.sql");
        routine(adoption, "fn_document_quantity_to_base"); routine(adoption, "fn_guard_document_quantity_adoption");
        jdbc.execute("CREATE TRIGGER adoption BEFORE INSERT OR UPDATE ON purchase_order_items FOR EACH ROW EXECUTE FUNCTION fn_guard_document_quantity_adoption()");
        choose(Map.of());
    }

    @ParameterizedTest @ValueSource(strings = {"purchase", "subcontract"})
    void newChoicesAndAnotherReviewersSessionUseTheSameStoredProof(String prefix) throws Exception {
        install(); UUID order = order(prefix, 0, BigDecimal.ONE);
        for (var choice : List.of(new BusinessPrecisionContext.Choice(4, "HALF_UP"), new BusinessPrecisionContext.Choice(4, "DOWN"),
                new BusinessPrecisionContext.Choice(10, "HALF_UP"), new BusinessPrecisionContext.Choice(24, "DOWN"))) {
            UUID item = UUID.randomUUID();
            var selected = Map.of(PURPOSE, choice); choose(selected);
            ProcurementReferencePrice.Adoption reference;
            try (var ignored = BusinessPrecisionContext.use(selected)) { reference = ProcurementReferencePrice.adopt(BigDecimal.ONE, new BigDecimal("6")); }
            insert(prefix, item, order, new BigDecimal("6"), BigDecimal.ONE, reference.price(), null);
            String before = row(prefix, item); choose(Map.of(PURPOSE, new BusinessPrecisionContext.Choice(0, "DOWN")));
            assertThat(jdbc.queryForObject(owner(prefix).proof(), BigDecimal.class, item)).isEqualByComparingTo(reference.price());
            UUID review = UUID.randomUUID();
            jdbc.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,status,amount_snapshot) VALUES(?,?,?,'PENDING',1)", review, kind(prefix), order);
            assertThat(row(prefix, item)).isEqualTo(before);
            assertThatThrownBy(() -> jdbc.update(owner(prefix).replacePolicy(), item));
            assertThat(row(prefix, item)).isEqualTo(before);
            jdbc.update("DELETE FROM procurement_order_approval_cases WHERE id=?", review);
            jdbc.update(owner(prefix).deleteItem(), item);
        }
    }

    @ParameterizedTest @ValueSource(strings = {"purchase", "subcontract"})
    void oldNullPoliciesRemainTheActualHistoricalContractWithoutBackfill(String prefix) throws Exception {
        UUID order = order(prefix, 1, BigDecimal.ONE), item = UUID.randomUUID();
        insert(prefix, item, order, new BigDecimal("6"), BigDecimal.ONE, new BigDecimal("0.1666666666"), null);
        String before = row(prefix, item); install(); choose(Map.of(PURPOSE, new BusinessPrecisionContext.Choice(4, "HALF_UP")));
        assertThat(jdbc.queryForObject(owner(prefix).missingPolicy(), Boolean.class, item)).isTrue();
        jdbc.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,status,amount_snapshot) VALUES(?,?,?,'PENDING',1)", UUID.randomUUID(), kind(prefix), order);
        assertThat(row(prefix, item)).contains("\"reference_price_precision_policy\": null");
        assertThat(row(prefix, item).replace(", \"reference_price_precision_policy\": null", "")).isEqualTo(before);
    }

    @Test void approvedQuantityRevisionUsesItsFrozenNewPolicyBeforeAndAfterTheHeaderFlush() throws Exception {
        install(); var originalChoice = Map.of(PURPOSE, new BusinessPrecisionContext.Choice(4, "DOWN")); choose(originalChoice);
        UUID order = order("purchase", 1, BigDecimal.ONE), item = UUID.randomUUID();
        insert("purchase", item, order, new BigDecimal("6"), BigDecimal.ONE, new BigDecimal("0.1666"), null);
        source.getConnection().setAutoCommit(false);
        try {
            String oldItem = row("purchase", item), oldHeader = header("purchase", order);
            var selected = Map.of(PURPOSE, new BusinessPrecisionContext.Choice(10, "DOWN"), "money.revised-total", new BusinessPrecisionContext.Choice(4, "HALF_UP")); choose(selected);
            BigDecimal total; ProcurementReferencePrice.Adoption reference;
            try (var ignored = BusinessPrecisionContext.use(selected)) {
                total = MoneyPolicy.revisedTotalAmountInput(BigDecimal.ONE, new BigDecimal("6"), new BigDecimal("7"));
                reference = ProcurementReferencePrice.adopt(total, new BigDecimal("7"));
            }
            jdbc.update("INSERT INTO procurement_order_source_revisions(id,order_type,order_id,order_item_id,old_qty,new_qty,before_item) VALUES(?,'PURCHASE',?,?,6,7,CAST(? AS jsonb))", UUID.randomUUID(), order, item, oldItem);
            String nextHeader = jdbc.queryForObject("SELECT CAST(? AS jsonb)||jsonb_build_object('total_original',CAST(? AS numeric),'total_local',CAST(? AS numeric))", String.class, oldHeader, total, total);
            assertThat(jdbc.queryForObject("SELECT fn_is_proven_procurement_header_revision('PURCHASE',CAST(? AS jsonb),CAST(? AS jsonb))", Boolean.class, oldHeader, nextHeader)).isTrue();
            jdbc.update("UPDATE purchase_order_items SET qty=7,total_amount_input=?,price=?,amount_original=?,amount_local=? WHERE id=?", total, reference.price(), total, total, item);
            choose(Map.of(PURPOSE, new BusinessPrecisionContext.Choice(0, "DOWN"), "money.revised-total", new BusinessPrecisionContext.Choice(0, "DOWN")));
            assertThat(jdbc.queryForObject("SELECT fn_is_proven_procurement_qty_revision('purchase_order_items',CAST(? AS jsonb),to_jsonb(i)) FROM purchase_order_items i WHERE id=?", Boolean.class, oldItem, item)).isTrue();
            assertThat(jdbc.queryForObject("SELECT fn_is_proven_procurement_header_revision('PURCHASE',CAST(? AS jsonb),CAST(? AS jsonb))", Boolean.class, oldHeader, nextHeader)).isTrue();
        } finally { source.getConnection().rollback(); source.getConnection().setAutoCommit(true); }
    }

    @Test void independentPostedPolicyReplacementIsRejectedEvenInReplicaMode() throws Exception {
        install(); choose(Map.of(PURPOSE, new BusinessPrecisionContext.Choice(4, "DOWN")));
        UUID order = order("subcontract", 1, BigDecimal.ONE), item = UUID.randomUUID();
        insert("subcontract", item, order, new BigDecimal("6"), BigDecimal.ONE, new BigDecimal("0.1666"), null);
        String before = row("subcontract", item); source.getConnection().setAutoCommit(false);
        try {
            jdbc.execute("SET LOCAL session_replication_role='replica'"); choose(Map.of(PURPOSE, new BusinessPrecisionContext.Choice(0, "DOWN")));
            assertThatThrownBy(() -> jdbc.update("UPDATE subcontract_order_items SET reference_price_precision_policy=fn_business_precision_snapshot() WHERE id=?", item));
        } finally { source.getConnection().rollback(); source.getConnection().setAutoCommit(true); }
        assertThat(row("subcontract", item)).isEqualTo(before);
    }

    @Test void pendingPurchaseQuantityRevisionKeepsItsCaseAndBindsTheDerivedPriceToTheActualRow() throws Exception {
        install(); choose(Map.of(PURPOSE, new BusinessPrecisionContext.Choice(4, "DOWN")));
        UUID order = order("purchase", 0, BigDecimal.ONE), item = UUID.randomUUID(), review = UUID.randomUUID();
        insert("purchase", item, order, new BigDecimal("6"), BigDecimal.ONE, new BigDecimal("0.1666"), null);
        String originalSnapshot = pendingSnapshot(order);
        jdbc.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,status,amount_snapshot,submission_snapshot,snapshot_hash) VALUES(?,'PURCHASE',?,'PENDING',1,CAST(? AS jsonb),'before')", review, order, originalSnapshot);
        String oldCase = jdbc.queryForObject("SELECT to_jsonb(c)::text FROM procurement_order_approval_cases c WHERE id=?", String.class, review);
        source.getConnection().setAutoCommit(false);
        try {
            String oldItem = row("purchase", item);
            jdbc.update("INSERT INTO procurement_order_source_revisions(id,order_type,order_id,order_item_id,old_qty,new_qty,before_item,pending_case_id,pending_case_version) VALUES(?,'PURCHASE',?,?,6,7,CAST(? AS jsonb),?,1)", UUID.randomUUID(), order, item, oldItem, review);
            var selected = Map.of(PURPOSE, new BusinessPrecisionContext.Choice(10, "DOWN"), "money.revised-total", new BusinessPrecisionContext.Choice(4, "HALF_UP")); choose(selected);
            BigDecimal total; ProcurementReferencePrice.Adoption reference;
            try (var ignored = BusinessPrecisionContext.use(selected)) {
                total = MoneyPolicy.revisedTotalAmountInput(BigDecimal.ONE, new BigDecimal("6"), new BigDecimal("7"));
                reference = ProcurementReferencePrice.adopt(total, new BigDecimal("7"));
            }
            jdbc.update("UPDATE purchase_order_items SET qty=7,total_amount_input=?,price=?,amount_original=?,amount_local=? WHERE id=?", total, reference.price(), total, total, item);
            jdbc.update("UPDATE purchase_orders SET total_original=?,total_local=? WHERE id=?", total, total, order);
            String nextSnapshot = pendingSnapshot(order);
            String nextCase = jdbc.queryForObject("SELECT CAST(? AS jsonb)||jsonb_build_object('version',2,'amount_snapshot',CAST(? AS numeric),'submission_snapshot',CAST(? AS jsonb),'snapshot_hash','after','display_snapshot',NULL)", String.class, oldCase, total, nextSnapshot);
            jdbc.update("INSERT INTO procurement_order_approval_events(case_id,event_type,event_snapshot) VALUES(?,'QUANTITY_CHANGED',jsonb_build_object('previousVersion',1,'previousSnapshotHash','before','previousSubmissionSnapshot',CAST(? AS jsonb),'previousDisplaySnapshot',NULL,'snapshotHash','after'))", review, originalSnapshot);
            assertThat(jdbc.queryForObject("SELECT fn_is_pending_purchase_case_qty_revision(CAST(? AS jsonb),CAST(? AS jsonb))", Boolean.class, oldCase, nextCase)).isTrue();
            assertThat(jdbc.queryForObject("SELECT fn_is_pending_purchase_case_qty_revision(CAST(? AS jsonb),jsonb_set(CAST(? AS jsonb),'{submission_snapshot,items,0,price}','0.1'))", Boolean.class, oldCase, nextCase)).isFalse();
        } finally { source.getConnection().rollback(); source.getConnection().setAutoCommit(true); }
    }

    private static void install() throws Exception {
        jdbc.execute(read("V1062__freeze_procurement_total_reference_price_policy.sql"));
        jdbc.execute("CREATE TRIGGER finance_proof BEFORE INSERT OR UPDATE ON procurement_order_approval_cases FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_finance_commercial_snapshot()");
    }
    private static UUID order(String prefix, int status, BigDecimal total) {
        UUID id = UUID.randomUUID();
        jdbc.update(owner(prefix).orderInsert(), id, status, CURRENCY, SETTLEMENT, total, total); return id;
    }
    private static void insert(String prefix, UUID id, UUID order, BigDecimal qty, BigDecimal total, BigDecimal price, Long legacy) {
        jdbc.update(owner(prefix).itemInsert(), id, order, legacy, qty, UUID.randomUUID(), price, total, total, total);
    }
    private static String kind(String prefix) { return prefix.equals("purchase") ? "PURCHASE" : "SUBCONTRACT"; }
    private static String row(String prefix, UUID item) { return jdbc.queryForObject(owner(prefix).row(), String.class, item); }
    private static String header(String prefix, UUID id) { return jdbc.queryForObject(owner(prefix).header(), String.class, id); }
    private static String pendingSnapshot(UUID order) {
        return jdbc.queryForObject("""
                SELECT jsonb_build_object('orderType','PURCHASE','orderId',id,'totalOriginal',total_original,'totalLocal',total_local,
                  'items',(SELECT jsonb_agg(jsonb_build_object('itemId',i.id,'qty',i.qty,'price',i.price,
                    'amountOriginal',i.amount_original,'amountLocal',i.amount_local,'totalAmountInput',i.total_amount_input) ORDER BY i.id)
                    FROM purchase_order_items i WHERE i.order_id=h.id))::text FROM purchase_orders h WHERE id=?
                """, String.class, order);
    }
    private static void choose(Map<String, BusinessPrecisionContext.Choice> choices) throws Exception {
        try (var ignored = BusinessPrecisionContext.use(choices)) { jdbc.queryForObject("SELECT set_config('app.business_precision_choices',?,false)", String.class, BusinessPrecisionContext.json()); }
    }
    private static String read(String name) throws Exception { return MigrationSqlResources.read(name); }
    private static void routine(String sql, String name) { jdbc.execute(MigrationSqlResources.function(sql, name).replaceFirst("FUNCTION public\\.", "FUNCTION ")); }
}
