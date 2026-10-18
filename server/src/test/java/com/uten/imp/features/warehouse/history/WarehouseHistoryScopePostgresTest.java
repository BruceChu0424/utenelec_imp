package com.uten.imp.features.warehouse.history;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** List/count/facet/detail scope executes against actual migrated tables and types. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseHistoryScopePostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;
    private NamedParameterJdbcTemplate jdbc;
    private final UUID warehouse = UUID.randomUUID(), outside = UUID.randomUUID();

    @BeforeAll static void baseline() throws Exception { database = MigratedSchemaBaseline.openDatabase("warehouse_history_scope"); }
    @AfterAll static void closeBaseline() throws Exception { if (database != null) database.close(); }
    @BeforeEach void projection() throws Exception {
        connection = database.openConnection();
        connection.setAutoCommit(false);
        try (var statement = connection.createStatement()) {
            statement.execute("CREATE SCHEMA history_scope_oracle");
            statement.execute("SET LOCAL search_path=history_scope_oracle,public");
        }
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,
                "purchase_receipts", "purchase_receipt_items", "subcontract_receipts", "subcontract_receipt_items",
                "subcontract_material_issues", "subcontract_material_issue_items", "subcontract_returns", "subcontract_return_items",
                "subcontract_material_returns", "subcontract_material_return_items", "subcontract_wastes", "subcontract_waste_items",
                "procurement_inspection_items", "suppliers", "warehouses", "goods", "colors", "units");
        jdbc = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
    }
    @AfterEach void rollback() throws Exception { if (connection != null) { connection.rollback(); connection.close(); } }

    @Test void everyHistorySourceUsesTheSameScopedBaseForTotalsFacetsAndBothDetailQueries() {
        var scope = new WarehouseTaskScope(true, List.of(warehouse), false);
        for (WarehouseHistoryType type : WarehouseHistoryType.values()) {
            UUID visible = header(type, warehouse, "VISIBLE"), hidden = header(type, outside, "HIDDEN");
            line(type, visible, false); line(type, hidden, false);
            assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(type, scope), parameters(scope), Long.class)).isEqualTo(1);
            assertThat(jdbc.queryForList(WarehouseHistoryQueries.listSql(type, WarehouseHistoryQueries.DEFAULT_ORDER_BY, scope), parameters(scope)))
                    .extracting(row -> row.get("id")).containsExactly(visible);
            assertThat(jdbc.queryForList(WarehouseHistoryQueries.facetsSql(type, "h.bill_no", scope), parameters(scope)))
                    .extracting(row -> row.get("bill_no")).containsExactly("VISIBLE");
            for (UUID id : List.of(visible, hidden)) {
                var values = parameters(scope).addValue("id", id);
                int expected = id.equals(visible) ? 1 : 0;
                assertThat(jdbc.queryForList(WarehouseHistoryQueries.detailHeaderSql(type, scope), values)).hasSize(expected);
                assertThat(jdbc.queryForList(WarehouseHistoryQueries.detailLinesSql(type, scope), values)).hasSize(expected);
            }
            UUID unassigned = header(type, null, "UNASSIGNED");
            line(type, unassigned, false);
            var defaultOther = new WarehouseTaskScope(true, List.of(), true);
            assertThat(jdbc.queryForList(WarehouseHistoryQueries.listSql(type, WarehouseHistoryQueries.DEFAULT_ORDER_BY, defaultOther),
                    parameters(defaultOther))).extracting(row -> row.get("id")).containsExactly(unassigned);
            assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(type, WarehouseTaskScope.NONE), parameters(WarehouseTaskScope.NONE), Long.class))
                    .isZero();
        }
    }

    @Test void literalMultiWordSearchAndExactIdentityRankingAreSharedByHistoryRowsCountAndFacets() {
        var type=WarehouseHistoryType.SUBCONTRACT_MATERIAL_RETURN;
        var scope=new WarehouseTaskScope(true,List.of(warehouse),false);
        UUID near=header(type,warehouse,"A-NEAR"), exact=header(type,warehouse,"Z-EXACT");
        UUID nearLine=line(type,near,false),exactLine=line(type,exact,false);
        execute("UPDATE subcontract_material_return_items SET goods_name_snapshot='Metric Screw extra' WHERE id=:id","id",nearLine);
        execute("UPDATE subcontract_material_return_items SET goods_name_snapshot='Metric Screw' WHERE id=:id","id",exactLine);
        UUID hidden=header(type,outside,"Metric Screw"); line(type,hidden,false);
        var params=parameters(scope).addValue("keyword","Metric Screw").addValue("limit",1);
        assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(type,scope),params,Long.class)).isEqualTo(2);
        assertThat(jdbc.queryForList(WarehouseHistoryQueries.listSql(type,WarehouseHistoryQueries.DEFAULT_ORDER_BY,scope),params))
                .extracting(row->row.get("id")).containsExactly(exact);
        assertThat(jdbc.queryForList(WarehouseHistoryQueries.listSql(type,WarehouseHistoryQueries.DEFAULT_ORDER_BY,scope),params.addValue("offset",1)))
                .extracting(row->row.get("id")).containsExactly(near);
        assertThat(jdbc.queryForList(WarehouseHistoryQueries.facetsSql(type,"h.bill_no",scope),params)).hasSize(2);
        execute("UPDATE subcontract_material_return_items SET goods_code_snapshot='A%_B' WHERE id=:id","id",exactLine);
        execute("UPDATE subcontract_material_return_items SET goods_code_snapshot='AxYB' WHERE id=:id","id",nearLine);
        params.addValue("keyword","Z-EXACT A%_B").addValue("offset",0);
        assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(type,scope),params,Long.class)).isEqualTo(1);
        assertThat(jdbc.queryForList(WarehouseHistoryQueries.listSql(type,WarehouseHistoryQueries.DEFAULT_ORDER_BY,scope),params))
                .extracting(row->row.get("id")).containsExactly(exact);
    }

    @Test void receiptWarehouseFollowsActiveInspectionFactsWithoutTreatingAssignedInspectionAsUnassigned() {
        for (WarehouseHistoryType type : List.of(WarehouseHistoryType.PURCHASE_RECEIPT, WarehouseHistoryType.SUBCONTRACT_RECEIPT)) {
            UUID receipt = header(type, null, "INSPECTED");
            UUID item = line(type, receipt, false);
            String domain = type == WarehouseHistoryType.PURCHASE_RECEIPT ? "PURCHASE" : "SUBCONTRACT";
            execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,status)"
                    + " VALUES(:id,:type,:receipt,:item,:warehouse,'PASSED')", "id", UUID.randomUUID(), "type", domain,
                    "receipt", receipt, "item", item, "warehouse", warehouse);
            var scope = new WarehouseTaskScope(true, List.of(warehouse), false);
            assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(type, scope), parameters(scope), Long.class)).isEqualTo(1);
            var unassigned = new WarehouseTaskScope(true, List.of(), true);
            assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(type, unassigned), parameters(unassigned), Long.class)).isZero();
            execute("UPDATE procurement_inspection_items SET status='REVERSED' WHERE receipt_id=:id", "id", receipt);
            assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(type, scope), parameters(scope), Long.class)).isZero();
            assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(type, unassigned), parameters(unassigned), Long.class)).isEqualTo(1);
        }
    }

    @Test void lossResolvesEveryLiveSourceIssueWarehouseEvenWhenTheHeaderCapturesAnotherWarehouse() {
        UUID loss = header(WarehouseHistoryType.SUBCONTRACT_WASTE, outside, "MULTI-WAREHOUSE");
        UUID issue = header(WarehouseHistoryType.SUBCONTRACT_MATERIAL_ISSUE, warehouse, "ISSUE");
        UUID issueItem = line(WarehouseHistoryType.SUBCONTRACT_MATERIAL_ISSUE, issue, false);
        UUID lossItem = line(WarehouseHistoryType.SUBCONTRACT_WASTE, loss, false);
        execute("UPDATE subcontract_waste_items SET material_issue_item_id=:issue WHERE id=:id", "issue", issueItem, "id", lossItem);
        var scope = new WarehouseTaskScope(true, List.of(warehouse), false);
        assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(WarehouseHistoryType.SUBCONTRACT_WASTE, scope), parameters(scope), Long.class))
                .isEqualTo(1);
        assertThat(jdbc.queryForList(WarehouseHistoryQueries.detailHeaderSql(WarehouseHistoryType.SUBCONTRACT_WASTE, scope),
                parameters(scope).addValue("id", loss))).hasSize(1);
        assertThat(jdbc.queryForList(WarehouseHistoryQueries.detailLinesSql(WarehouseHistoryType.SUBCONTRACT_WASTE, scope),
                parameters(scope).addValue("id", loss))).hasSize(1);
        execute("UPDATE subcontract_waste_items SET is_deleted=TRUE WHERE id=:id", "id", lossItem);
        assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(WarehouseHistoryType.SUBCONTRACT_WASTE, scope), parameters(scope), Long.class))
                .isZero();
    }

    @Test void sameDocumentItemsStaySeparateBeforePagingSearchAndBillNumberFacets() {
        var scope = new WarehouseTaskScope(true, List.of(warehouse), false);
        for (WarehouseHistoryType type : WarehouseHistoryType.values()) {
            UUID document = header(type, warehouse, "TWO-ITEMS");
            UUID first = line(type, document, false), second = line(type, document, false);
            execute("UPDATE " + type.itemTable() + " SET line_no=2,goods_name_snapshot='Second physical item',qty=7 WHERE id=:id",
                    "id", second);
            var values = parameters(scope).addValue("bill_no", "TWO-ITEMS").addValue("limit", 1);
            assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(type,scope),values,Long.class)).isEqualTo(2);
            String sql = WarehouseHistoryQueries.listSql(type,WarehouseHistoryQueries.DEFAULT_ORDER_BY,scope);
            assertThat(jdbc.queryForList(sql,values)).extracting(row -> row.get("item_id")).containsExactly(first);
            assertThat(jdbc.queryForList(sql,values.addValue("offset",1))).extracting(row -> row.get("item_id")).containsExactly(second);
            assertThat(jdbc.queryForList(WarehouseHistoryQueries.facetsSql(type,"h.bill_no",scope),values))
                    .extracting(row -> ((Number)row.get("count")).longValue()).containsExactly(2L);
            values.addValue("keyword","Second physical item").addValue("offset",0);
            assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(type,scope),values,Long.class)).isEqualTo(1);
            assertThat(jdbc.queryForList(sql,values)).extracting(row -> row.get("item_id")).containsExactly(second);
        }
    }

    @Test void receiptItemsInOtherWarehousesCannotLeakThroughTheirSharedHeader() {
        var type = WarehouseHistoryType.PURCHASE_RECEIPT;
        UUID document = header(type,warehouse,"SPLIT-RECEIPT");
        UUID first = line(type,document,false), second = line(type,document,false);
        for (UUID item : List.of(first,second)) {
            execute("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,status)"
                    + " VALUES(:id,'PURCHASE',:receipt,:item,:warehouse,'PASSED')",
                    "id",UUID.randomUUID(),"receipt",document,"item",item,"warehouse",item.equals(first)?warehouse:outside);
        }
        execute("UPDATE procurement_inspection_items SET warehouse_id=NULL WHERE receipt_item_id=:item", "item",first);
        var scope = new WarehouseTaskScope(true,List.of(warehouse),false);
        assertThat(jdbc.queryForObject(WarehouseHistoryQueries.countSql(type,scope),parameters(scope),Long.class)).isEqualTo(1);
        assertThat(jdbc.queryForList(WarehouseHistoryQueries.listSql(type,WarehouseHistoryQueries.DEFAULT_ORDER_BY,scope),parameters(scope)))
                .extracting(row -> row.get("item_id")).containsExactly(first);
        assertThat(jdbc.queryForList(WarehouseHistoryQueries.detailLinesSql(type,scope),parameters(scope).addValue("id",document)))
                .extracting(row -> row.get("id")).containsExactly(first);
    }

    private UUID header(WarehouseHistoryType type, UUID warehouseId, String billNo) {
        UUID id = UUID.randomUUID();
        execute("INSERT INTO " + type.headerTable()
                + "(id,bill_no,bill_date,warehouse_id,status,is_closed,is_deleted) VALUES(:id,:bill,'2026-10-12',:warehouse,1,FALSE,FALSE)",
                "id", id, "bill", billNo, "warehouse", warehouseId);
        return id;
    }
    private UUID line(WarehouseHistoryType type, UUID headerId, boolean deleted) {
        UUID id = UUID.randomUUID();
        execute("INSERT INTO " + type.itemTable() + "(id," + type.itemForeignKey()
                + ",line_no,goods_code_snapshot,goods_name_snapshot,qty,is_deleted) VALUES(:id,:header,1,'PHYSICAL','实物',2,:deleted)",
                "id", id, "header", headerId, "deleted", deleted);
        return id;
    }
    private static MapSqlParameterSource parameters(WarehouseTaskScope scope) {
        return new MapSqlParameterSource().addValue("warehouse_scope", scope.idsCsv())
                .addValue("keyword", "").addValue("keyword_pattern", "%%").addValue("status", null)
                .addValue("date_from", null).addValue("date_to", null).addValue("bill_no", null).addValue("source_doc_no", null)
                .addValue("limit", 20).addValue("offset", 0L);
    }
    @Test void malformedFixtureBindingsFailBeforeAnyDatabaseWrite() {
        assertThatThrownBy(() -> execute("SELECT 1", "missingValue"))
                .isInstanceOf(IllegalArgumentException.class).hasMessage("SQL fixture parameters must be key/value pairs");
    }

    private void execute(String sql, Object... parameters) {
        if (parameters.length % 2 != 0) throw new IllegalArgumentException("SQL fixture parameters must be key/value pairs");
        var values = new MapSqlParameterSource();
        for (int index = 0; index + 1 < parameters.length; index += 2) values.addValue((String) parameters[index], parameters[index + 1]);
        jdbc.update(sql, values);
    }
}
