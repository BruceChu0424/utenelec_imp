package com.uten.imp.common.saleschain;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.sql.Types;
import java.util.Objects;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 在真实 PostgreSQL 上验证 {@link SalesOrderChainSql} 与 {@link SalesChainStatus} 对同一张用例表
 * （{@link SalesChainStatusTest#CASES}）给出相同结果，并验证 V545 回填 SQL 只改"仍有未排量的 3/4/5/6 行"。
 * 只建两张与 sales_order_items / plan_order_item_links 同列型的影子表，不跑 Flyway（规则与表结构无关）。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SalesOrderChainSqlPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_chain")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void start() throws Exception {
        POSTGRES.start();
        try (Connection c = connection(); Statement st = c.createStatement()) {
            st.execute("""
                    CREATE TABLE sales_order_items (
                        id uuid PRIMARY KEY,
                        case_no int NOT NULL,
                        is_deleted boolean NOT NULL DEFAULT false,
                        chain_status smallint,
                        qty numeric(18,4), shipped_qty numeric(18,4), returned_qty numeric(18,4),
                        flag_qty numeric(18,4), reserved_qty numeric(18,4),
                        planned_qty numeric(18,4), produced_qty numeric(18,4),
                        updated_at timestamptz NOT NULL DEFAULT now())
                    """);
            st.execute("""
                    CREATE TABLE plan_order_item_links (
                        id uuid PRIMARY KEY, order_item_id uuid NOT NULL,
                        is_deleted boolean NOT NULL DEFAULT false, produced_qty numeric(18,4))
                    """);
        }
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void sqlCaseAndJavaMirrorAgreeOnTheWholeCaseTable() throws Exception {
        try (Connection c = connection()) {
            for (int n = 0; n < SalesChainStatusTest.CASES.size(); n++) {
                insertCase(c, n, SalesChainStatusTest.CASES.get(n));
            }
            // 用例表行 case_no < 100；其他测试用 900+ 且与本测试共享同一张影子表。
            String sql = "SELECT case_no, "
                    + SalesOrderChainSql.chainStatusCaseSql(SalesOrderChainSql.ChainStatusInputs.of("i"))
                    + ", " + SalesOrderChainSql.unplannedQtySql("i")
                    + " FROM sales_order_items i WHERE case_no < 100 ORDER BY case_no";
            try (Statement st = c.createStatement(); ResultSet rs = st.executeQuery(sql)) {
                int seen = 0;
                while (rs.next()) {
                    SalesChainStatusTest.Case k = SalesChainStatusTest.CASES.get(rs.getInt(1));
                    assertEquals(k.expected(), rs.getShort(2), "SQL 派生: " + k.why());
                    BigDecimal unplanned = SalesChainStatus.unplannedQty(
                            bd(k.qty()), bd(k.shipped()), bd(k.returned()), bd(k.flag()),
                            bd(k.reserved()), bd(k.planned()), bd(k.produced()));
                    assertEquals(0, unplanned.compareTo(rs.getBigDecimal(3)), "未排量: " + k.why());
                    seen++;
                }
                assertEquals(SalesChainStatusTest.CASES.size(), seen);
            }
        }
    }

    @Test
    void deltaInputsReadTheOldRowValueLikeAnUpdateSetClause() throws Exception {
        try (Connection c = connection()) {
            // 订 10、预留 10（7 可发货），让单 6 → 预留 4，未排 6 → 1 部分预留。
            UUID id = insertRow(c, 900, 7, "10", "0", "0", "0", "10", "0", "0");
            String sql = "UPDATE sales_order_items SET reserved_qty = COALESCE(reserved_qty,0) - ?, chain_status = "
                    + SalesOrderChainSql.chainStatusCaseSql(
                            SalesOrderChainSql.ChainStatusInputs.of("").reservedDelta(" - ?"))
                    + " WHERE id = ?";
            int placeholders = (int) sql.chars().filter(ch -> ch == '?').count();
            try (PreparedStatement ps = c.prepareStatement(sql)) {
                for (int i = 1; i < placeholders; i++) ps.setBigDecimal(i, new BigDecimal("6"));
                ps.setObject(placeholders, id);
                assertEquals(1, ps.executeUpdate());
            }
            assertEquals(1, chainOf(c, id));
            assertEquals(1, SalesChainStatus.derive((short) 7, bd("10"), bd("0"), bd("0"), bd("0"),
                    bd("4"), bd("0"), bd("0")));
        }
    }

    @Test
    void reportedQtyExpressionKeepsProducingOnlyWhileAnActiveLinkHasReports() throws Exception {
        try (Connection c = connection()) {
            UUID stillReported = insertRow(c, 901, 5, "10", "0", "0", "0", "0", "10", "0");
            UUID fullyReversed = insertRow(c, 902, 5, "10", "0", "0", "0", "0", "10", "0");
            try (PreparedStatement ps = c.prepareStatement(
                    "INSERT INTO plan_order_item_links(id, order_item_id, is_deleted, produced_qty) VALUES (?,?,?,?)")) {
                ps.setObject(1, UUID.randomUUID()); ps.setObject(2, stillReported);
                ps.setBoolean(3, false); ps.setBigDecimal(4, new BigDecimal("3"));
                ps.executeUpdate();
                ps.setObject(1, UUID.randomUUID()); ps.setObject(2, fullyReversed);
                ps.setBoolean(3, false); ps.setBigDecimal(4, BigDecimal.ZERO);
                ps.executeUpdate();
            }
            String sql = "UPDATE sales_order_items order_item SET chain_status = "
                    + SalesOrderChainSql.chainStatusCaseSql(
                            SalesOrderChainSql.ChainStatusInputs.of("order_item")
                                    .producing(SalesOrderChainSql.hasReportedQtySql("order_item")))
                    + " WHERE order_item.case_no IN (901, 902)";
            try (Statement st = c.createStatement()) {
                assertEquals(2, st.executeUpdate(sql));
            }
            assertEquals(5, chainOf(c, stillReported), "仍有有效报工量 → 留在 5");
            assertEquals(4, chainOf(c, fullyReversed), "报工全部冲回 → 已排产 4");
        }
    }

    @Test
    void v545BackfillOnlyMovesPlannedRowsThatStillHaveUnplannedQty() throws Exception {
        try (Connection c = connection()) {
            // 影子表被本类各测试共享：先清空，回填命中行数才可精确断言。
            try (Statement st = c.createStatement()) {
                st.executeUpdate("DELETE FROM sales_order_items");
                st.executeUpdate("DELETE FROM plan_order_item_links");
            }
            UUID partial = insertRow(c, 910, 4, "10", "0", "0", "0", "0", "4", "0");
            UUID partialReserved = insertRow(c, 911, 5, "10", "0", "0", "0", "2", "4", "0");
            UUID partialShipped = insertRow(c, 912, 6, "10", "3", "0", "0", "0", "4", "3");
            UUID full = insertRow(c, 913, 4, "10", "0", "0", "0", "0", "10", "0");
            UUID pendingAlready = insertRow(c, 914, 2, "10", "0", "0", "0", "0", "4", "0");
            UUID deleted = insertRow(c, 915, 4, "10", "0", "0", "0", "0", "4", "0");
            try (Statement st = c.createStatement()) {
                st.executeUpdate("UPDATE sales_order_items SET is_deleted = true WHERE id = '" + deleted + "'");
            }
            String migration = new String(Objects.requireNonNull(
                    SalesOrderChainSqlPostgresTest.class.getResourceAsStream(
                            "/db/migration/V545__sales_order_item_chain_status_unplanned_backfill.sql"))
                    .readAllBytes(), StandardCharsets.UTF_8);
            try (Statement st = c.createStatement()) {
                assertEquals(3, st.executeUpdate(migration), "只命中 3 条仍有未排量的 3-6 行");
                assertEquals(0, st.executeUpdate(migration), "幂等：重跑无命中");
            }
            assertEquals(2, chainOf(c, partial));
            assertEquals(1, chainOf(c, partialReserved));
            assertEquals(8, chainOf(c, partialShipped));
            assertEquals(4, chainOf(c, full));
            assertEquals(2, chainOf(c, pendingAlready));
            assertEquals(4, chainOf(c, deleted));
            assertTrue(migration.contains("IN (3,4,5,6)"));
            assertFalse(migration.contains("planned_qty ="), "回填不得改数量列");
        }
    }

    private static void insertCase(Connection c, int caseNo, SalesChainStatusTest.Case k) throws Exception {
        insertRow(c, caseNo, k.current(), k.qty(), k.shipped(), k.returned(), k.flag(),
                k.reserved(), k.planned(), k.produced());
    }

    private static UUID insertRow(Connection c, int caseNo, int chain, String qty, String shipped,
                                  String returned, String flag, String reserved, String planned,
                                  String produced) throws Exception {
        UUID id = UUID.randomUUID();
        try (PreparedStatement ps = c.prepareStatement("""
                INSERT INTO sales_order_items(id, case_no, chain_status, qty, shipped_qty, returned_qty,
                    flag_qty, reserved_qty, planned_qty, produced_qty)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """)) {
            ps.setObject(1, id);
            ps.setInt(2, caseNo);
            ps.setShort(3, (short) chain);
            String[] values = {qty, shipped, returned, flag, reserved, planned, produced};
            for (int i = 0; i < values.length; i++) {
                if (values[i] == null) ps.setNull(4 + i, Types.NUMERIC);
                else ps.setBigDecimal(4 + i, new BigDecimal(values[i]));
            }
            ps.executeUpdate();
        }
        return id;
    }

    private static int chainOf(Connection c, UUID id) throws Exception {
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT chain_status FROM sales_order_items WHERE id = ?")) {
            ps.setObject(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                assertTrue(rs.next());
                return rs.getInt(1);
            }
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static BigDecimal bd(String value) {
        return value == null ? null : new BigDecimal(value);
    }
}
