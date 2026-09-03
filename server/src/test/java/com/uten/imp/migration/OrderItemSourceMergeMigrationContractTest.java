package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * V463「订货行多来源锚定（同货品合并生成订货单）」静态契约：
 * <ol>
 *   <li>purchase/subcontract_order_item_sources 两表 + 行级审计触发器；</li>
 *   <li>历史行回填（alloc_qty = 行数量，单来源）；</li>
 *   <li>FIFO 分摊函数（末位吸收超额 ⇒ 单来源行为与历史逐位一致）；</li>
 *   <li>v_procurement_decomposition_tasks 的待财务占用改按 sources 汇总；</li>
 *   <li>v_preplan_buy_action_slice_progress 的订货行经 sources 关联；</li>
 *   <li>V464 重发 business_data_reset() 双胞胎（320 表含两张 sources 表）。</li>
 * </ol>
 */
class OrderItemSourceMergeMigrationContractTest {

    private static final Path MIGRATION_ROOT = Path.of(
            "src", "main", "resources", "db", "migration");

    private static String migrationSql(String file) throws IOException {
        Path direct = MIGRATION_ROOT.resolve(file);
        Path fallback = Path.of("server").resolve(direct);
        return Files.readString(
                Files.exists(direct) ? direct : fallback,
                StandardCharsets.UTF_8);
    }

    @Test
    void sourcesTablesExistWithAuditTriggersAndUniqueAnchors() throws IOException {
        String sql = migrationSql("V463__order_item_source_merge.sql");
        for (String table : new String[]{
                "purchase_order_item_sources", "subcontract_order_item_sources"}) {
            assertTrue(sql.contains("CREATE TABLE " + table),
                    table + " must be created by V463");
            assertTrue(sql.contains(
                    "CREATE TRIGGER trg_audit_" + table),
                    table + " must own a row-level audit trigger");
            assertTrue(sql.contains("UNIQUE (order_item_id"),
                    table + " must keep one anchor row per source item");
            assertTrue(sql.contains("CHECK (alloc_qty > 0)"),
                    table + " alloc shares must be strictly positive");
        }
    }

    @Test
    void legacyAnchoredRowsAreBackfilledAsSingleSource() throws IOException {
        String sql = migrationSql("V463__order_item_source_merge.sql");
        // 回填不区分 is_deleted（读取侧视图自带过滤）且幂等（ON CONFLICT DO NOTHING）。
        assertTrue(sql.contains(
                "INSERT INTO purchase_order_item_sources"));
        assertTrue(sql.contains(
                "INSERT INTO subcontract_order_item_sources"));
        Matcher purchaseBackfill = Pattern.compile(
                "SELECT oi\\.id, oi\\.request_item_id, COALESCE\\(oi\\.qty, 0\\), 1").matcher(sql);
        assertTrue(purchaseBackfill.find(),
                "purchase backfill must copy alloc_qty = 行数量, line_no = 1");
    }

    @Test
    void fifoShareFunctionsGiveOverflowToLastSource() throws IOException {
        String sql = migrationSql("V463__order_item_source_merge.sql");
        // 末位来源吸收超额：单来源行（回填 alloc=qty）份额 = 全量，
        // 与 V463 前的单锚行为逐位一致；非末位 clamp 在 alloc 内。
        assertTrue(sql.contains("CREATE OR REPLACE FUNCTION fn_purchase_order_source_share"));
        assertTrue(sql.contains("CREATE OR REPLACE FUNCTION fn_subcontract_order_source_share"));
        int lastBranch = sql.indexOf("WHEN b.rn = b.source_count");
        assertTrue(lastBranch > 0, "share function must special-case the last source");
    }

    @Test
    void decompositionTaskViewCountsPendingViaSources() throws IOException {
        String sql = migrationSql("V463__order_item_source_merge.sql");
        Matcher pending = Pattern.compile(
                "JOIN purchase_order_item_sources src ON src\\.order_item_id = oi\\.id").matcher(sql);
        assertTrue(pending.find(),
                "purchase_pending must aggregate alloc_qty via sources");
        assertTrue(sql.contains("SUM(COALESCE(src.alloc_qty, 0)) AS pending_qty"),
                "pending occupation must use source shares, not whole-line qty");
        assertTrue(sql.contains(
                "JOIN subcontract_order_item_sources src ON src.order_item_id = oi.id"),
                "subcontract_pending must aggregate via sources too");
    }

    @Test
    void buySliceProgressViewJoinsOrderItemsThroughSources() throws IOException {
        String sql = migrationSql("V463__order_item_source_merge.sql");
        assertTrue(sql.contains(
                "FROM purchase_order_item_sources src"),
                "slice progress must expand merged lines by source");
        // FIFO 分摊在视图内以窗口函数实现（prefix/末位吸收），列契约与 V446 一致。
        assertTrue(sql.contains("WINDOW w AS ("));
        assertTrue(sql.contains("AS source_count"),
                "last-source overflow branch must exist in the view");
    }

    @Test
    void resetTwinCoversNewSourceTables() throws IOException {
        String ops = Files.readString(
                Files.exists(Path.of("ops", "reset_business_data.sql"))
                        ? Path.of("ops", "reset_business_data.sql")
                        : Path.of("server", "ops", "reset_business_data.sql"),
                StandardCharsets.UTF_8);
        String twin = migrationSql("V464__reset_twin_order_item_sources.sql");
        for (String table : new String[]{
                "purchase_order_item_sources", "subcontract_order_item_sources"}) {
            assertTrue(ops.contains("('" + table + "', 'CLEAR')"),
                    "ops reset script must classify " + table);
            assertTrue(twin.contains("('" + table + "', 'CLEAR')"),
                    "V464 twin function must classify " + table);
        }
        assertTrue(twin.contains("CREATE OR REPLACE FUNCTION business_data_reset()"),
                "V464 must re-emit the runtime reset twin");
    }
}
