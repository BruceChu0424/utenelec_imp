package com.uten.imp.common.columns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.sql.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Real migrated schema; fixture seeding alone bypasses unrelated document lifecycle triggers. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessColumnPostgresTest {
    private static PostgreSQLContainer<?> postgres;
    private static final ObjectMapper JSON = new ObjectMapper();
    @BeforeAll static void migrate() { postgres = MigratedSchemaBaseline.startMigratedContainer("business_columns"); }
    @AfterAll static void stop() { if (postgres != null) postgres.stop(); }

    @Test void javaAndPostgresHaveIdenticalOrderedExactAmounts() throws Exception {
        try (Connection db = connect()) {
            for (int i = 0; i < 30; i++) {
                BigDecimal base = new BigDecimal("123.456789012345").add(BigDecimal.valueOf(i));
                var columns = List.of(column("ADD", "0.000000000001"), column("MULTIPLY", "1.25"),
                        column("SUBTRACT", "0.5"), column("DIVIDE", "8"));
                try (PreparedStatement q = db.prepareStatement("SELECT fn_business_columns_amount(?,?::jsonb)")) {
                    q.setBigDecimal(1, base); q.setString(2, JSON.writeValueAsString(columns));
                    try (ResultSet result = q.executeQuery()) {
                        result.next(); assertThat(result.getBigDecimal(1)).isEqualByComparingTo(ExtraColumnCalculator.apply(base, columns));
                    }
                }
            }
            for (String divisor : List.of("0", "3")) {
                try (PreparedStatement q = db.prepareStatement("SELECT fn_business_columns_amount(1,?::jsonb)")) {
                    q.setString(1, JSON.writeValueAsString(List.of(column("DIVIDE", divisor))));
                    assertThatThrownBy(q::executeQuery).isInstanceOf(SQLException.class)
                            .satisfies(e -> assertThat(((SQLException)e).getSQLState()).isEqualTo("23514"));
                }
            }
        }
    }

    @Test void fourDocumentTypesPersistColumnsAndFreezeApprovedSnapshots() throws Exception {
        for (String prefix : List.of("sales_quote", "sales_order", "purchase_order", "subcontract_order")) {
            try (Connection db = connect()) {
                Fixture f = seed(db, prefix);
                String columnJson = JSON.writeValueAsString(List.of(column("NONE", "特殊包装")));
                try (PreparedStatement update = db.prepareStatement("UPDATE " + prefix + "_items SET extra_columns=?::jsonb WHERE id=?")) {
                    update.setString(1, columnJson); update.setObject(2, f.item()); update.executeUpdate();
                }
                assertThat(scalar(db, "SELECT extra_columns->0->>'value' FROM " + prefix + "_items WHERE id='" + f.item() + "'"))
                        .isEqualTo("特殊包装");
                if (prefix.startsWith("sales"))
                    exec(db, "UPDATE " + prefix + "_items SET goods_name_en_snapshot='Packing clip' WHERE id='" + f.item() + "'");
                exec(db, "SET session_replication_role=replica");
                exec(db, "UPDATE " + prefix + "s SET status=1 WHERE id='" + f.header() + "'");
                exec(db, "SET session_replication_role=origin");
                assertThatThrownBy(() -> exec(db, "UPDATE " + prefix + "_items SET extra_columns='[]'::jsonb WHERE id='" + f.item() + "'"))
                        .isInstanceOf(SQLException.class).hasMessageContaining("snapshots are immutable");
                if (prefix.startsWith("sales")) {
                    assertThatThrownBy(() -> exec(db, "UPDATE " + prefix + "_items SET goods_name_en_snapshot='New name' WHERE id='" + f.item() + "'"))
                            .isInstanceOf(SQLException.class).hasMessageContaining("snapshots are immutable");
                    assertThat(scalar(db, "SELECT goods_name_en_snapshot FROM " + prefix + "_items WHERE id='" + f.item() + "'"))
                            .isEqualTo("Packing clip");
                }
            }
        }
    }

    @Test void procurementFinanceGuardAndReviewSnapshotIncludeExtraConsideration() throws Exception {
        for (String prefix : List.of("purchase_order", "subcontract_order")) {
            try (Connection db = connect()) {
                Fixture f = seed(db, prefix);
                String kind = prefix.startsWith("purchase") ? "PURCHASE" : "SUBCONTRACT";
                exec(db, """
                        CREATE TEMP TABLE commercial_probe(order_type text, order_id uuid, status text, amount_snapshot numeric DEFAULT 35);
                        CREATE TRIGGER commercial_guard BEFORE INSERT ON commercial_probe
                        FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_finance_commercial_snapshot();
                        CREATE TEMP TABLE display_probe(order_type text, order_id uuid, submission_snapshot jsonb, display_snapshot jsonb);
                        CREATE TRIGGER display_guard BEFORE INSERT ON display_probe
                        FOR EACH ROW EXECUTE FUNCTION fn_procurement_approval_display_snapshot();
                        """);
                exec(db, "INSERT INTO commercial_probe(order_type,order_id,status) VALUES('" + kind + "','" + f.header() + "','PENDING')");
                exec(db, "INSERT INTO display_probe VALUES('" + kind + "','" + f.header()
                        + "',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('itemId','" + f.item() + "'))),NULL)");
                assertThat(scalar(db, "SELECT display_snapshot->'items'->0->'extraColumns'->0->>'value' FROM display_probe"))
                        .isEqualTo("5");
                exec(db, "UPDATE " + prefix + "_items SET amount_original=30,amount_local=30 WHERE id='" + f.item() + "'");
                exec(db, "UPDATE " + prefix + "s SET total_original=30,total_local=30 WHERE id='" + f.header() + "'");
                assertThatThrownBy(() -> exec(db, "INSERT INTO commercial_probe(order_type,order_id,status) VALUES('" + kind + "','" + f.header() + "','PENDING')"))
                        .isInstanceOf(SQLException.class).satisfies(e -> assertThat(((SQLException)e).getSQLState()).isEqualTo("23514"));
            }
        }
    }

    @Test void procurementPendingFinanceFreezesTextEvenWhileTheHeaderRemainsDraft() throws Exception {
        for (String prefix : List.of("purchase_order", "subcontract_order")) {
            try (Connection db = connect()) {
                Fixture f = seed(db, prefix);
                String kind = prefix.startsWith("purchase") ? "PURCHASE" : "SUBCONTRACT";
                exec(db, "SET session_replication_role=replica");
                try {
                    exec(db, """
                            INSERT INTO procurement_order_approval_cases(order_type,order_id,attempt,
                                bill_no_snapshot,amount_snapshot,submission_snapshot,snapshot_hash,
                                submitted_by_user_id,submitted_by_employee_id,assignee_user_id,assignee_employee_id,
                                assignee_name_snapshot,status)
                            VALUES('%s','%s',1,'COL-PENDING',35,
                                jsonb_build_object('items',jsonb_build_array(jsonb_build_object('itemId','%s'))),'fixture-only',
                                gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),'fixture','PENDING')
                            """.formatted(kind,f.header(),f.item()));
                } finally { exec(db, "SET session_replication_role=origin"); }
                assertThat(scalar(db, "SELECT status FROM " + prefix + "s WHERE id='" + f.header() + "'")).isEqualTo("0");
                assertThatThrownBy(() -> exec(db, "UPDATE " + prefix + "_items SET extra_columns=extra_columns || "
                        + "'[{\"name\":\"包装要求\",\"type\":\"TEXT\",\"operation\":\"NONE\",\"value\":\"changed\"}]'::jsonb WHERE id='" + f.item() + "'"))
                        .isInstanceOf(SQLException.class).hasMessageContaining("snapshots are immutable");
            }
        }
    }

    private static Fixture seed(Connection db, String prefix) throws Exception {
        UUID header = UUID.randomUUID(), item = UUID.randomUUID();
        String bill = "COL-" + header;
        boolean sales = prefix.startsWith("sales");
        String parent = prefix.equals("sales_quote") ? "quote_id" : "order_id";
        String extra = JSON.writeValueAsString(List.of(column("ADD", "5")));
        exec(db, "SET session_replication_role=replica");
        try {
            exec(db, "INSERT INTO " + prefix + "s(id,bill_no,bill_date" + (prefix.equals("sales_order") ? ",client_id" : "")
                    + ") VALUES('" + header + "','" + bill + "',CURRENT_DATE" + (prefix.equals("sales_order") ? ",'" + UUID.randomUUID() + "'" : "") + ")");
            if (!sales) exec(db, "UPDATE " + prefix + "s SET currency_id=(SELECT id FROM currencies WHERE status='使用' AND NOT is_deleted LIMIT 1),"
                    + "settlement_method_id=(SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted LIMIT 1),"
                    + "exchange_rate=1,tax_rate=0,total_original=35,total_local=35 WHERE id='" + header + "'");
            try (PreparedStatement insert = db.prepareStatement("INSERT INTO " + prefix + "_items(id,bill_no,bill_date," + parent
                    + ",goods_id,line_no,qty,price,amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,extra_columns) "
                    + "VALUES(?,?,CURRENT_DATE,?,?,1,3,10,35,35,'COL','测试货品','MASTER_AT_SAVE',?::jsonb)")) {
                insert.setObject(1,item); insert.setString(2,bill); insert.setObject(3,header); insert.setObject(4,UUID.randomUUID());
                insert.setString(5,extra); insert.executeUpdate();
            }
        } finally { exec(db,"SET session_replication_role=origin"); }
        return new Fixture(header,item);
    }
    private record Fixture(UUID header, UUID item) {}
    private static ExtraColumnSnapshot column(String operation, String value) {
        return new ExtraColumnSnapshot(UUID.randomUUID(), "包装费", operation.equals("NONE") ? "TEXT" : "AMOUNT", operation, value);
    }
    private static Connection connect() throws SQLException { return DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()); }
    private static void exec(Connection db,String sql) throws SQLException { try (Statement s=db.createStatement()) { s.execute(sql); } }
    private static String scalar(Connection db,String sql) throws SQLException {
        try (Statement s=db.createStatement(); ResultSet r=s.executeQuery(sql)) { r.next(); return r.getString(1); }
    }
}
