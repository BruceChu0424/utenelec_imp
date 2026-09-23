package com.uten.imp.migration;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 热表触发器卫生契约(ADR-106 / V674)：在真实 Flyway 迁移到头的库上验证触发器的起跳条件。
 *
 * <ul>
 *   <li>热表上的延迟约束触发器凡是对 UPDATE 起跳的，必须带 WHEN(只在相关列真变了时排队)；</li>
 *   <li>V674 重建的 38 条 ENABLE ALWAYS 守卫(含 _upd 变体)仍是 ALWAYS；</li>
 *   <li>单号取号函数只挂 INSERT；UPDATE 由列级 WHEN 守卫接管，且每张表都有；</li>
 *   <li>被同表覆盖校验完全包含的三条采购来源溯源触发器不能再装回来；</li>
 *   <li>收付款类别引用方取共享锁、层级/状态变更方取排他锁。</li>
 * </ul>
 * 负向行为(改了相关列仍被拒、无关列更新零调用)见 WorkshopDirectTransferBatchEndToEndTest。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class HotTableTriggerHygieneContractTest {

    private static final String HOT_TABLES = """
            'stock_reservations', 'stock_documents', 'stock_document_items', 'production_plan_items',
            'stock_value_nodes', 'stock_value_events', 'preplan_stock_entitlement_events',
            'production_execution_segments', 'production_material_analysis_materials',
            'production_material_analysis_items', 'production_material_analyses'
            """;

    /**
     * V674 重建的触发器里必须是 ENABLE ALWAYS 的全部 38 条(表.触发器)：V645 时为 ALWAYS 的 27 条原名，
     * 加上从它们拆出的 11 条 _upd 变体。写死清单而不是拿变体和原名互比——两条一起丢了 ALWAYS 时互比照样相等。
     */
    private static final List<String> ALWAYS_GUARDS_REBUILT_BY_V674 = List.of(
            "production_execution_segments.trg_00_material_snapshot_product_qty",
            "production_execution_segments.trg_00_material_snapshot_product_qty_upd",
            "production_execution_segments.trg_final_report_target_change",
            "production_execution_segments.trg_guard_execution_split_segment_identity",
            "production_execution_segments.trg_guard_execution_split_segment_identity_upd",
            "production_execution_segments.trg_guard_execution_start_material_custody",
            "production_execution_segments.trg_guard_execution_workshop_material_custody",
            "production_material_analyses.trg_direct_subcontract_analysis_preparation",
            "production_material_analyses.trg_future_transfer_analysis",
            "production_material_analysis_items.trg_bind_direct_subcontract_preparation",
            "production_material_analysis_items.trg_bind_direct_subcontract_preparation_upd",
            "production_material_analysis_items.trg_subcontract_preparation_analysis_source_guard",
            "production_material_analysis_items.trg_subcontract_preparation_analysis_source_guard_upd",
            "production_plan_items.trg_guard_production_plan_item_supply_update",
            "stock_document_items.trg_guard_production_draw_issue_requested_qty",
            "stock_reservations.trg_00_capture_material_reservation_projection",
            "stock_reservations.trg_00_workshop_source_reservation_release",
            "stock_reservations.trg_check_material_reservation_consumed_projection",
            "stock_reservations.trg_check_material_reservation_consumed_projection_upd",
            "stock_reservations.trg_check_workshop_source_reservation_balance",
            "stock_reservations.trg_check_workshop_source_reservation_balance_upd",
            "stock_reservations.trg_guard_workshop_custody_reservation",
            "stock_reservations.trg_guard_workshop_custody_reservation_upd",
            "stock_value_events.trg_consumption_return_event",
            "stock_value_events.trg_stock_value_position_event_complete",
            "stock_value_events.trg_stock_value_reverse_store",
            "stock_value_events.trg_subcontract_loss_position_fact",
            "stock_value_events.trg_subcontract_material_unconsume",
            "stock_value_nodes.trg_consumption_return_quantity",
            "stock_value_nodes.trg_consumption_return_quantity_upd",
            "stock_value_nodes.trg_stock_value_cost_distribution",
            "stock_value_nodes.trg_stock_value_cost_distribution_upd",
            "stock_value_nodes.trg_stock_value_exact_bounds",
            "stock_value_nodes.trg_stock_value_exact_bounds_upd",
            "stock_value_nodes.trg_stock_value_exact_identity",
            "stock_value_nodes.trg_stock_value_node_lifecycle",
            "stock_value_nodes.trg_stock_value_node_lifecycle_upd",
            "stock_value_nodes.trg_stock_value_revision_fact");

    private static PostgreSQLContainer<?> database;

    @BeforeAll
    static void migrate() {
        database = MigratedSchemaBaseline.startMigratedContainer("trigger_hygiene");
    }

    @AfterAll
    static void stop() {
        if (database != null) database.stop();
    }

    @Test
    void deferredConstraintTriggersOnHotTablesOnlyFireForRelevantUpdates() throws SQLException {
        // tgtype bit 16 = UPDATE. A WHEN is required even with UPDATE OF: JPA/whole-row updates put
        // every column in the SET list, and column lists ignore BEFORE-trigger rewrites.
        assertThat(strings("""
                SELECT c.relname || '.' || t.tgname
                FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                WHERE NOT t.tgisinternal AND t.tginitdeferred AND (t.tgtype & 16) <> 0
                  AND t.tgqual IS NULL AND c.relname IN (%s)
                ORDER BY 1
                """.formatted(HOT_TABLES)))
                .as("热表上的延迟约束触发器对 UPDATE 起跳时必须带 WHEN(相关列真变了才排队)")
                .isEmpty();
    }

    @Test
    void rebuiltGuardsKeepEnableAlways() throws SQLException {
        // DROP + CREATE resets ENABLE ALWAYS to ORIGIN; guards that must fire even under
        // session_replication_role=replica have to keep that mode on the original and every _upd variant.
        String names = String.join(",", ALWAYS_GUARDS_REBUILT_BY_V674.stream().map(name -> "'" + name + "'").toList());
        assertThat(strings("""
                SELECT c.relname || '.' || t.tgname
                FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                WHERE NOT t.tgisinternal AND t.tgenabled = 'A' AND c.relname || '.' || t.tgname IN (%s)
                ORDER BY 1
                """.formatted(names)))
                .as("V674 重建的 ALWAYS 守卫(含 _upd 变体)必须全部仍是 ALWAYS，复制角色下的维护写入才仍被拦住")
                .containsExactlyInAnyOrderElementsOf(ALWAYS_GUARDS_REBUILT_BY_V674);
        assertThat(strings("""
                SELECT c.relname || '.' || variant.tgname || ' ' || variant.tgenabled::text || '<>' || original.tgenabled::text
                FROM pg_trigger variant
                JOIN pg_class c ON c.oid = variant.tgrelid
                JOIN pg_trigger original ON original.tgrelid = variant.tgrelid AND NOT original.tgisinternal
                     AND original.tgname = regexp_replace(variant.tgname, '_(upd|del)$', '')
                WHERE NOT variant.tgisinternal AND variant.tgname ~ '_(upd|del)$'
                  AND variant.tgenabled <> original.tgenabled
                ORDER BY 1
                """)).as("以后再拆出的 _upd / _del 也要与原名触发器同样的启用模式").isEmpty();
    }

    @Test
    void businessDocumentIdentifierIsReservedOnInsertAndGuardedPerColumnOnUpdate() throws SQLException {
        assertThat(strings("""
                SELECT c.relname || '.' || t.tgname
                FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_proc p ON p.oid = t.tgfoid
                WHERE NOT t.tgisinternal AND p.proname = 'fn_reserve_business_document_identifier'
                  AND (t.tgtype & 16) <> 0
                """)).as("取号函数只在 INSERT 起跳").isEmpty();
        assertThat(strings("""
                SELECT c.relname
                FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_proc p ON p.oid = t.tgfoid
                WHERE NOT t.tgisinternal AND p.proname = 'fn_reserve_business_document_identifier'
                  AND NOT EXISTS (
                      SELECT 1 FROM pg_trigger guard JOIN pg_proc gp ON gp.oid = guard.tgfoid
                      WHERE guard.tgrelid = t.tgrelid AND NOT guard.tgisinternal
                        AND gp.proname = 'fn_guard_business_document_identifier_immutable'
                        AND (guard.tgtype & 16) <> 0 AND guard.tgqual IS NOT NULL
                        AND cardinality(guard.tgattr::int2[]) > 0)
                """)).as("每张取号表都要有 UPDATE OF 单号列 + WHEN 的不可变守卫").isEmpty();
        assertThat(strings("""
                SELECT proname FROM pg_proc
                WHERE proname = 'fn_reserve_business_document_identifier' AND prosrc LIKE '%TG_OP = ''UPDATE''%'
                """)).as("取号函数里走不到的 UPDATE 分支已删除").isEmpty();
    }

    @Test
    void subsumedPurchaseProvenanceTriggersStayMerged() throws SQLException {
        assertThat(strings("""
                SELECT tgname FROM pg_trigger
                WHERE tgname IN ('trg_purchase_reservation_receipt_provenance',
                                 'trg_purchase_draw_receipt_provenance',
                                 'trg_purchase_draw_item_receipt_provenance')
                """)).isEmpty();
        assertThat(strings("""
                SELECT tgname FROM pg_trigger
                WHERE tgname IN ('trg_receipt_reservation_conservation', 'trg_receipt_reservation_conservation_upd',
                                 'trg_receipt_stock_document_provenance', 'trg_receipt_stock_document_provenance_upd',
                                 'trg_receipt_stock_document_item_provenance',
                                 'trg_receipt_stock_document_item_provenance_upd')
                ORDER BY 1
                """)).as("包含它们的覆盖校验仍在").hasSize(6);
    }

    @Test
    void paymentStyleReferencesShareTheHierarchyLockAndHierarchyChangesStayExclusive() throws SQLException {
        for (String reference : List.of("fn_guard_payment_style_reference", "fn_enforce_account_style_uuid_authority",
                "fn_enforce_system_posting_style_role")) {
            assertThat(strings("SELECT prosrc FROM pg_proc WHERE proname = '" + reference + "'"))
                    .singleElement().satisfies(source -> assertThat(source)
                            .contains("pg_advisory_xact_lock_shared(")
                            .doesNotContain("pg_advisory_xact_lock("));
        }
        assertThat(strings("SELECT prosrc FROM pg_proc WHERE proname = 'fn_guard_active_account_style_status'"))
                .singleElement().satisfies(source -> assertThat(source)
                        .contains("pg_advisory_xact_lock(")
                        .doesNotContain("pg_advisory_xact_lock_shared("));
    }

    private static List<String> strings(String sql) throws SQLException {
        List<String> values = new ArrayList<>();
        try (Connection connection = DriverManager.getConnection(
                database.getJdbcUrl(), database.getUsername(), database.getPassword());
             Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            while (result.next()) values.add(result.getString(1));
        }
        return values;
    }
}
