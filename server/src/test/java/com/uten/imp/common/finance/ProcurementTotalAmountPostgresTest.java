package com.uten.imp.common.finance;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.sql.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Full forward migrations and real finance/snapshot/quantity mutation guards. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementTotalAmountPostgresTest {
    private static PostgreSQLContainer<?> postgres;
    @BeforeAll static void migrate() { postgres = MigratedSchemaBaseline.startMigratedContainer("total_amount"); }
    @AfterAll static void stop() { if (postgres != null) postgres.stop(); }

    @Test void exactTotalRoundTripsAndFinanceChecksItInsteadOfTruncatedPriceProduct() throws Exception {
        for (String prefix : List.of("purchase", "subcontract")) {
            try (Connection db = connect()) {
                Fixture f = seed(db, prefix);
                assertThat(decimal(db, "SELECT total_amount_input FROM " + prefix + "_order_items WHERE id='" + f.item() + "'"))
                        .isEqualByComparingTo("100");
                exec(db, "CREATE TEMP TABLE commercial_probe(order_type text,order_id uuid,status text,amount_snapshot numeric DEFAULT 105);"
                        + "CREATE TRIGGER guard BEFORE INSERT ON commercial_probe FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_finance_commercial_snapshot();"
                        + "CREATE TEMP TABLE display_probe(order_type text,order_id uuid,submission_snapshot jsonb,display_snapshot jsonb);"
                        + "CREATE TRIGGER display BEFORE INSERT ON display_probe FOR EACH ROW EXECUTE FUNCTION fn_procurement_approval_display_snapshot();");
                exec(db, "INSERT INTO commercial_probe(order_type,order_id,status) VALUES('" + prefix.toUpperCase() + "','" + f.header() + "','PENDING')");
                exec(db, "INSERT INTO display_probe VALUES('" + prefix.toUpperCase() + "','" + f.header()
                        + "',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('itemId','" + f.item() + "'))),NULL)");
                assertThat(scalar(db, "SELECT display_snapshot->'items'->0->>'totalAmountInput' FROM display_probe")).isEqualTo("100");
                exec(db, "UPDATE " + prefix + "_order_items SET amount_original=qty*price+5,amount_local=qty*price+5 WHERE id='" + f.item() + "'");
                assertThatThrownBy(() -> exec(db, "INSERT INTO commercial_probe(order_type,order_id,status) VALUES('" + prefix.toUpperCase() + "','" + f.header() + "','PENDING')"))
                        .isInstanceOf(SQLException.class).satisfies(e -> assertThat(((SQLException)e).getSQLState()).isEqualTo("23514"));
                exec(db, "SET session_replication_role=replica");
                exec(db, "UPDATE " + prefix + "_orders SET status=1 WHERE id='" + f.header() + "'");
                exec(db, "SET session_replication_role=origin");
                assertThatThrownBy(() -> exec(db, "UPDATE " + prefix + "_order_items SET total_amount_input=101 WHERE id='" + f.item() + "'"))
                        .isInstanceOf(SQLException.class).hasMessageContaining("immutable");
            }
        }
    }

    @Test void javaAndDatabaseAgreeOnReferencesAndExactRevisionRatios() throws Exception {
        try (Connection db = connect()) {
            for (String qty : List.of("3", "6", "3000", "99999999999999", "0.0001")) {
                BigDecimal q = new BigDecimal(qty);
                for (String total : List.of("0", "100", "1.000000000000000000000001")) {
                    try (PreparedStatement sql = db.prepareStatement("SELECT fn_procurement_reference_price(?,?)")) {
                        sql.setBigDecimal(1,new BigDecimal(total)); sql.setBigDecimal(2,q);
                        try (ResultSet r=sql.executeQuery()) { r.next(); assertThat(r.getBigDecimal(1))
                                .isEqualByComparingTo(MoneyPolicy.referenceUnitPrice(new BigDecimal(total),q)); }
                    }
                }
            }
            assertThat(decimal(db,"SELECT fn_procurement_revised_total_input(100,3000,6000)")).isEqualByComparingTo("200");
            assertThatThrownBy(() -> exec(db,"SELECT fn_procurement_revised_total_input(100,3000,1000)"))
                    .isInstanceOf(SQLException.class).hasMessageContaining("not an exact finite");
        }
    }

    @Test void pendingFinanceFreezesTheNewFactWhileOrderIsStillDraft() throws Exception {
        for (String prefix : List.of("purchase", "subcontract")) {
            try (Connection db = connect()) {
                Fixture f = seed(db, prefix);
                exec(db, "SET session_replication_role=replica");
                try {
                    exec(db, "INSERT INTO procurement_order_approval_cases(order_type,order_id,attempt,bill_no_snapshot,"
                            + "amount_snapshot,submission_snapshot,snapshot_hash,submitted_by_user_id,submitted_by_employee_id,"
                            + "assignee_user_id,assignee_employee_id,assignee_name_snapshot,status) VALUES('"
                            + prefix.toUpperCase() + "','" + f.header() + "',1,'TOTAL-PENDING',105,"
                            + "jsonb_build_object('items',jsonb_build_array(jsonb_build_object('itemId','" + f.item() + "'))),'fixture',"
                            + "gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),'fixture','PENDING')");
                } finally { exec(db, "SET session_replication_role=origin"); }
                assertThatThrownBy(() -> exec(db, "UPDATE " + prefix + "_order_items SET total_amount_input=101 WHERE id='" + f.item() + "'"))
                        .isInstanceOf(SQLException.class).hasMessageContaining("immutable");
            }
        }
    }

    @Test void provenRevisionUpdatesTotalBasisAndHeaderWithoutReapplyingOldApproximatePrice() throws Exception {
        for (String prefix : List.of("purchase", "subcontract")) {
            try (Connection db = connect()) {
                Fixture f = seed(db,prefix);
                db.setAutoCommit(false);
                try {
                    exec(db,"SET LOCAL session_replication_role=replica");
                    exec(db,"UPDATE " + prefix + "_orders SET status=1 WHERE id='" + f.header() + "'");
                    exec(db,"INSERT INTO procurement_order_source_revisions(id,order_type,order_id,order_item_id,old_qty,new_qty,unit_rate,before_item,approval_attempt_before,actor_user_id,actor_employee_id) "
                            + "SELECT gen_random_uuid(),'" + prefix.toUpperCase() + "',order_id,id,qty,6000,1,to_jsonb(i),0,gen_random_uuid(),gen_random_uuid() FROM " + prefix + "_order_items i WHERE id='" + f.item() + "'");
                    exec(db,"SET LOCAL session_replication_role=origin");
                    assertThat(scalar(db,"SELECT fn_is_proven_procurement_qty_revision('" + prefix + "_order_items',to_jsonb(i),to_jsonb(i)||'{\"qty\":6000,\"total_amount_input\":200,\"amount_original\":205,\"amount_local\":205}'::jsonb) FROM " + prefix + "_order_items i WHERE id='" + f.item() + "'"))
                            .isEqualTo("t");
                    assertThat(scalar(db,"SELECT fn_is_proven_procurement_header_revision('" + prefix.toUpperCase() + "',to_jsonb(h),to_jsonb(h)||'{\"total_original\":205,\"total_local\":205}'::jsonb) FROM " + prefix + "_orders h WHERE id='" + f.header() + "'"))
                            .isEqualTo("t");
                    // Real UPDATE triggers also accept this proven revision and retain the same reference price.
                    exec(db,"UPDATE " + prefix + "_order_items SET qty=6000,total_amount_input=200,amount_original=205,amount_local=205 WHERE id='" + f.item() + "'");
                    assertThat(decimal(db,"SELECT total_amount_input FROM " + prefix + "_order_items WHERE id='" + f.item() + "'"))
                            .isEqualByComparingTo("200");
                } finally { db.rollback(); }
            }
        }
    }

    private static Fixture seed(Connection db,String prefix) throws SQLException {
        UUID header=UUID.randomUUID(),item=UUID.randomUUID(); String bill="TOTAL-" + header;
        exec(db,"SET session_replication_role=replica");
        try {
            exec(db,"INSERT INTO " + prefix + "_orders(id,bill_no,bill_date,currency_id,settlement_method_id,exchange_rate,tax_rate,total_original,total_local) "
                    + "SELECT '" + header + "','" + bill + "',CURRENT_DATE,(SELECT id FROM currencies WHERE status='使用' AND NOT is_deleted LIMIT 1),"
                    + "(SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted LIMIT 1),1,0,105,105");
            exec(db,"INSERT INTO " + prefix + "_order_items(id,order_id,bill_no,bill_date,goods_id,line_no,qty,price,total_amount_input,amount_original,amount_local,goods_snapshot_source,goods_code_snapshot,goods_name_snapshot,extra_columns) VALUES('"
                    + item + "','" + header + "','" + bill + "',CURRENT_DATE,gen_random_uuid(),1,3000,0.0333333333,100,105,105,'MASTER_AT_SAVE','TOTAL','总金额货品','[{\"name\":\"包装费\",\"type\":\"AMOUNT\",\"operation\":\"ADD\",\"value\":\"5\"}]'::jsonb)");
        } finally { exec(db,"SET session_replication_role=origin"); }
        return new Fixture(header,item);
    }
    private record Fixture(UUID header,UUID item) {}
    private static Connection connect() throws SQLException { return DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()); }
    private static void exec(Connection db,String sql) throws SQLException { try (Statement s=db.createStatement()) { s.execute(sql); } }
    private static String scalar(Connection db,String sql) throws SQLException { try (Statement s=db.createStatement();ResultSet r=s.executeQuery(sql)) { r.next();return r.getString(1); } }
    private static BigDecimal decimal(Connection db,String sql) throws SQLException { return new BigDecimal(scalar(db,sql)); }
}
