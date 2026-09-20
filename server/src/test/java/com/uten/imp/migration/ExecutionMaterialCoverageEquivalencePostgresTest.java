package com.uten.imp.migration;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Independent old-SQL oracle, including unusual intermediate states seen by deferred guards. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ExecutionMaterialCoverageEquivalencePostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate jdbc;
    private static String coverageSql;
    private final UUID segment = UUID.randomUUID();
    private final UUID otherSegment = UUID.randomUUID();
    private final UUID packageId = UUID.randomUUID();

    @BeforeAll static void start() throws Exception {
        POSTGRES.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        com.uten.imp.support.MigratedProjectionSchema.createTables(jdbc,"621",
                "production_material_demands","stock_reservations","production_planning_package_document_items",
                "production_planning_package_documents","stock_documents","stock_document_items",
                "production_material_stock_postings","production_execution_segment_events");
        String v616 = migration("V616__execution_workshop_material_custody.sql");
        String scalar = function(v616, "fn_execution_demand_draw_commitment_qty");
        String oldExpression = "COALESCE(item.base_qty,item.qty*COALESCE(item.unit_rate,1))";
        assertTrue(scalar.contains(oldExpression));
        jdbc.execute(function(migration("V618__production_material_return_receiving_warehouse.sql"),
                "fn_production_draw_item_effective_qty"));
        // Apply the actual V618 compatibility change to the frozen V616 scalar oracle.
        jdbc.execute(scalar.replace(oldExpression,
                "(fn_production_draw_item_effective_qty(item.id)*COALESCE(item.unit_rate,1))"));
        coverageSql = function(migration("V622__execution_segment_material_coverage_batch.sql"),
                "fn_execution_segment_material_coverage").replace("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION");
        jdbc.execute(coverageSql);
    }

    @AfterAll static void stop() { POSTGRES.stop(); }

    @BeforeEach void clear() {
        jdbc.execute("TRUNCATE production_execution_segment_events,production_material_stock_postings,"
                + "production_planning_package_document_items,production_planning_package_documents,"
                + "stock_document_items,stock_documents,stock_reservations,production_material_demands");
    }

    @Test void sharedInstructionUsesWholeItemIssuesOnceButKeepsEachDemandMapping() {
        UUID first = demand(segment, "20.1234"), second = demand(segment, "30.0001");
        UUID outside = demand(otherSegment, "100");
        UUID item = draw(first, segment, "10", "25", "2");
        jdbc.update("INSERT INTO production_planning_package_document_items(package_id,document_type,document_id,document_item_id,demand_id) SELECT package_id,document_type,"
                + "document_id,document_item_id,? FROM production_planning_package_document_items WHERE demand_id=?", second, first);
        posting(item, first, "ISSUE", "4.1234");
        posting(item, second, "ISSUE", "3.0001");
        posting(item, outside, "ISSUE", "2.0002");
        posting(item, first, "ISSUE_REVERSE", "1.0001");
        posting(item, first, "GOOD_RETURN", "0.3333");
        posting(item, first, "GOOD_RETURN_REVERSE", "0.1001");
        jdbc.update("INSERT INTO stock_reservations(demand_id,qty,released_qty) VALUES (?,30,5),(?,40,2)", first, second);
        assertEquivalent();
        var actual = coverage();
        assertQty("25", actual.get(0).get("draw_backed"));
        assertQty("25", actual.get(1).get("draw_backed"));
        reduce(item, "MATERIAL_RETURN_DRAW_REDUCE", "2.25");
        assertEquivalent();
        reduce(item, "MATERIAL_RETURN_DRAW_RESTORE", "1.125");
        assertEquivalent();
        assertMutationRejected("WHEN 'GOOD_RETURN' THEN -posting.qty_base", "WHEN 'GOOD_RETURN' THEN 0");
    }

    @Test void cancelledDeletedAndWrongSegmentHeadersMatchEveryOldBoundary() {
        UUID first = demand(segment, "100");
        UUID removed = demand(segment, "99");
        jdbc.update("UPDATE production_material_demands SET is_deleted=TRUE WHERE id=?", removed);
        UUID deletedItem = draw(first, segment, "2", null, null);
        jdbc.update("UPDATE stock_document_items SET is_deleted=TRUE WHERE id=?", deletedItem);
        UUID cancelled = draw(first, segment, "3", null, "1.5");
        jdbc.update("UPDATE stock_documents SET status=-1 WHERE id=(SELECT doc_id FROM stock_document_items WHERE id=?)", cancelled);
        UUID deletedDocument = draw(first, segment, "4", null, "2");
        jdbc.update("UPDATE stock_documents SET is_deleted=TRUE WHERE id=(SELECT doc_id FROM stock_document_items WHERE id=?)", deletedDocument);
        UUID foreignHeader = draw(first, otherSegment, "5", null, "0.5");
        posting(cancelled, first, "ISSUE", "1.1");
        posting(deletedItem, first, "GOOD_RETURN", "0.1");
        posting(foreignHeader, first, "ISSUE", "0.3333");
        draw(removed, segment, "99", null, "1");
        jdbc.update("INSERT INTO stock_reservations(demand_id,qty,released_qty,is_deleted) VALUES (?,8,3,FALSE),(?,50,0,TRUE)", first, first);
        assertEquivalent();
        assertEquals(1, coverage().size());
        assertQty("2", coverage().getFirst().get("draw_backed"),
                "Historical DRAW keeps the old item-deletion predicate; foreign headers never count");
        assertQty("5", coverage().getFirst().get("stock_backed"));
        jdbc.update("UPDATE stock_documents SET status=0,is_deleted=FALSE");
        jdbc.update("UPDATE stock_document_items SET is_deleted=FALSE");
        assertEquivalent();
    }

    @Test void fortyMappingsAndRepeatedPostingsDoNotMultiplyTheIssuedBudget() {
        UUID first = demand(segment, "120");
        UUID item = draw(first, segment, "120", null, "1");
        for (int index = 0; index < 39; index++) {
            UUID next = demand(segment, "120");
            jdbc.update("INSERT INTO production_planning_package_document_items(package_id,document_type,document_id,document_item_id,demand_id) SELECT package_id,document_type,"
                    + "document_id,document_item_id,? FROM production_planning_package_document_items WHERE demand_id=?", next, first);
            posting(item, next, "ISSUE", "0.2501");
            posting(item, next, "ISSUE_REVERSE", "0.0001");
        }
        assertEquivalent();
        assertEquals(40, coverage().size());
        assertMutationRejected("SELECT DISTINCT id FROM instructions", "SELECT id FROM instructions");
        posting(item, first, "GOOD_RETURN", "1.0001");
        assertEquivalent();
    }

    private void assertEquivalent() {
        var actual = coverage();
        var expected = jdbc.queryForList("""
                SELECT d.id AS demand_id,d.required_qty,
                  COALESCE((SELECT SUM(r.qty-r.released_qty) FROM stock_reservations r
                    WHERE r.demand_id=d.id AND NOT r.is_deleted),0) AS stock_backed,
                  COALESCE((SELECT SUM(COALESCE(i.base_qty,i.qty*COALESCE(i.unit_rate,1)))
                    FROM production_planning_package_document_items m
                    JOIN production_planning_package_documents h ON h.package_id=m.package_id
                      AND h.document_type=m.document_type AND h.document_id=m.document_id
                    JOIN stock_documents sd ON sd.id=m.document_id AND sd.doc_type='DRAW'
                      AND NOT sd.is_deleted AND sd.status<>-1
                    JOIN stock_document_items i ON i.id=m.document_item_id AND i.doc_id=m.document_id
                    WHERE m.demand_id=d.id AND m.document_type='DRAW' AND h.execution_segment_id=?),0) AS draw_backed,
                  fn_execution_demand_draw_commitment_qty(d.id) AS draw_committed
                FROM production_material_demands d WHERE d.execution_segment_id=? AND NOT d.is_deleted ORDER BY d.id
                """, segment, segment);
        assertEquals(expected.size(), actual.size());
        for (int index = 0; index < expected.size(); index++) {
            assertEquals(expected.get(index).get("demand_id"), actual.get(index).get("demand_id"));
            for (String field : List.of("required_qty", "stock_backed", "draw_backed", "draw_committed")) {
                assertQty(expected.get(index).get(field).toString(), actual.get(index).get(field), field);
            }
        }
    }

    private void assertMutationRejected(String original, String mutation) {
        assertTrue(coverageSql.contains(original), "Mutation must change the real candidate SQL");
        try {
            jdbc.execute(coverageSql.replace(original, mutation));
            assertThrows(AssertionError.class, this::assertEquivalent,
                    "The populated oracle fixture must detect the intentionally broken coverage");
        } finally {
            jdbc.execute(coverageSql);
        }
        assertEquivalent();
    }

    private List<Map<String,Object>> coverage() {
        return jdbc.queryForList("SELECT * FROM fn_execution_segment_material_coverage(?) ORDER BY demand_id", segment);
    }
    private UUID demand(UUID owner, String required) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO production_material_demands(id,execution_segment_id,required_qty) VALUES (?,?,?)", id, owner, new BigDecimal(required));
        return id;
    }
    private UUID draw(UUID demand, UUID headerSegment, String qty, String base, String rate) {
        UUID document = UUID.randomUUID(), item = UUID.randomUUID();
        jdbc.update("INSERT INTO stock_documents(id,doc_type,status) VALUES (?,'DRAW',0)", document);
        jdbc.update("INSERT INTO stock_document_items(id,doc_id,qty,base_qty,unit_rate) VALUES (?,?,?,?,?)",
                item, document, new BigDecimal(qty), base == null ? null : new BigDecimal(base), rate == null ? null : new BigDecimal(rate));
        jdbc.update("INSERT INTO production_planning_package_documents(package_id,document_type,document_id,execution_segment_id) VALUES (?,'DRAW',?,?)", packageId, document, headerSegment);
        jdbc.update("INSERT INTO production_planning_package_document_items(package_id,document_type,document_id,document_item_id,demand_id) VALUES (?,'DRAW',?,?,?)", packageId, document, item, demand);
        return item;
    }
    private void posting(UUID item, UUID demand, String type, String qty) {
        jdbc.update("INSERT INTO production_material_stock_postings(stock_document_item_id,demand_id,posting_type,qty_base) VALUES (?,?,?,?)", item, demand, type, new BigDecimal(qty));
    }
    private void reduce(UUID item, String action, String qty) {
        jdbc.update("INSERT INTO production_execution_segment_events(action,receiving_confirmation_id,draw_document_ids,draw_item_quantities) SELECT ?,?,ARRAY[doc_id],jsonb_build_object(id::text,CAST(? AS numeric)) FROM stock_document_items WHERE id=?",
                action, UUID.randomUUID(), new BigDecimal(qty), item);
    }
    private static void assertQty(String expected, Object actual, String... message) {
        assertEquals(0, new BigDecimal(expected).compareTo((BigDecimal) actual), String.join(" ", message));
    }
    private static String migration(String name) throws Exception {
        return Files.readString(Path.of("src/main/resources/db/migration", name));
    }
    private static String function(String sql, String name) {
        int begin = sql.indexOf("CREATE FUNCTION " + name + "(");
        assertTrue(begin >= 0, name);
        int bodyStart = sql.indexOf("AS $", begin) + 3;
        int delimiterEnd = sql.indexOf('$', bodyStart + 1) + 1;
        String delimiter = sql.substring(bodyStart, delimiterEnd);
        int end = sql.indexOf(delimiter + ";", delimiterEnd);
        assertTrue(end >= 0, name);
        return sql.substring(begin, end + delimiter.length() + 1);
    }
}
