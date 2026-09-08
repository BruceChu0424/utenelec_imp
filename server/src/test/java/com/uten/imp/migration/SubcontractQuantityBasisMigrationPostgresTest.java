package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import java.sql.*;
import java.util.UUID;
import java.math.BigDecimal;
import static org.junit.jupiter.api.Assertions.*;

/** Migration compatibility only: declarative unexecuted/reversed history, never business-chain evidence. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SubcontractQuantityBasisMigrationPostgresTest {
    private static final java.util.concurrent.atomic.AtomicInteger SEQUENCE=new java.util.concurrent.atomic.AtomicInteger();
    @Test
    void unexecutedExactPatternIsCorrectedWhileReversedAndLegacyHistoryStayUntouched() throws Exception {
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine").withDatabaseName("sc_unit_basis")
                .withUsername("uten").withPassword("uten-test-only")) {
            pg.start();
            migrate(pg,"501");
            Fixture fresh,history,legacy;
            try(Connection c=DriverManager.getConnection(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())) {
                fresh=seed(c,false,false); history=seed(c,true,false); legacy=seed(c,false,true);
            }
            migrate(pg,"502");
            try(Connection c=DriverManager.getConnection(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())) {
                assertDecimal(c,"select unit_rate from subcontract_material_plan_items where id=?",fresh.planItem(),"1");
                assertDecimal(c,"select bom_unit_qty from subcontract_material_plan_items where id=?",fresh.planItem(),"2");
                assertDecimal(c,"select qty from subcontract_material_issue_items where id=?",fresh.issueItem(),"20");
                assertDecimal(c,"select unit_rate from subcontract_material_issue_items where id=?",fresh.issueItem(),"1");
                assertDecimal(c,"select unit_rate from subcontract_material_plan_items where id=?",history.planItem(),"2");
                assertDecimal(c,"select unit_rate from subcontract_material_issue_items where id=?",history.issueItem(),"2");
                assertDecimal(c,"select bom_unit_qty from subcontract_material_plan_items where id=?",legacy.planItem(),"1");
                assertDecimal(c,"select unit_rate from subcontract_material_plan_items where id=?",legacy.planItem(),"2");
                assertEquals(0,count(c,"select count(*) from v_subcontract_quantity_basis_issues where plan_item_id=?",fresh.planItem()));
                assertEquals(1,count(c,"select count(*) from v_subcontract_quantity_basis_issues where plan_item_id=?",history.planItem()));
                assertEquals(0,count(c,"select count(*) from v_subcontract_quantity_basis_issues where plan_item_id=?",legacy.planItem()));
                SQLException invalid=assertThrows(SQLException.class,()->execute(c,"""
                        INSERT INTO subcontract_material_plan_items(id,plan_id,order_item_id,line_no,parent_goods_id,goods_id,
                            unit_id,unit_rate,bom_unit_qty,planned_qty,issued_qty,flow_mode,preparation_status,prepared_qty,
                            bom_has_children_snapshot,preparation_bom_fingerprint)
                        SELECT ?,plan_id,order_item_id,2,parent_goods_id,goods_id,unit_id,2,1,20,0,
                            'DIRECT_OUTBOUND','READY_OUTBOUND',20,FALSE,repeat('a',64)
                        FROM subcontract_material_plan_items WHERE id=?
                        """,UUID.randomUUID(),fresh.planItem()));
                assertEquals("23514",invalid.getSQLState());
                assertTrue(invalid.getMessage().contains("target outbound requires basic unit quantities"));
                // Reversal/cancellation fields remain writable on a historical inconsistent row;
                // the INSERT guard does not force a dishonest rewrite of its frozen quantity basis.
                execute(c,"update subcontract_material_plan_items set preparation_status='CANCELLED' where id=?",history.planItem());
                assertDecimal(c,"select unit_rate from subcontract_material_plan_items where id=?",history.planItem(),"2");
                assertEquals(0,count(c,"select count(*) from stock_movements where goods_id=?",history.goods()));
            }
        }
    }

    private static void migrate(PostgreSQLContainer<?> pg,String version) {
        Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())
                .locations("classpath:db/migration").target(version).load().migrate();
    }
    private record Fixture(UUID planItem,UUID issueItem,UUID goods) {}
    private static Fixture seed(Connection c,boolean reversed,boolean legacy) throws Exception {
        UUID unit=UUID.randomUUID(),box=UUID.randomUUID(),goods=UUID.randomUUID(),order=UUID.randomUUID(),
                item=UUID.randomUUID(),plan=UUID.randomUUID(),line=UUID.randomUUID(),issue=UUID.randomUUID(),issueItem=UUID.randomUUID();
        String suffix=String.format(java.util.Locale.ROOT,"20260907%06d",SEQUENCE.incrementAndGet());
        String orderNo="EO"+suffix;
        String issueNo="EC"+suffix;
        c.setAutoCommit(false);
        execute(c,"insert into units(id,code,name,status) values (?,?,'piece','使用'),(?,?,'box','使用')",unit,"UNIT-"+unit,box,"BOX-"+box);
        execute(c,"insert into goods(id,code,name,unit_id,code_sequence) values (?,?,'migration quantity fixture',?,(select coalesce(max(code_sequence),0)+1 from goods))",goods,"GOODS-"+goods,unit);
        execute(c,"insert into subcontract_orders(id,bill_no,bill_date,status) values (?,?,DATE '2026-01-01',0)",order,orderNo);
        execute(c,"""
                insert into subcontract_order_items(id,order_id,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,
                    goods_code_snapshot,goods_name_snapshot,goods_snapshot_source)
                values (?,?,?,DATE '2026-01-01',1,?,?,2,10,?,'migration quantity fixture','MASTER_AT_SAVE')
                """,item,order,orderNo,goods,box,"GOODS-"+goods);
        execute(c,"insert into subcontract_material_plans(id,order_id,order_bill_no,status) values (?,?,?,'OPEN')",plan,order,orderNo);
        execute(c,"""
                insert into subcontract_material_plan_items(id,plan_id,order_item_id,line_no,parent_goods_id,goods_id,
                    unit_id,unit_rate,bom_unit_qty,planned_qty,issued_qty,flow_mode,preparation_status,prepared_qty,
                    bom_has_children_snapshot,preparation_bom_fingerprint)
                values (?,?,?,1,?,?,?,2,1,20,0,?,?,20,?,?)
                """,line,plan,item,goods,goods,unit,legacy?"LEGACY_BOM_COMPONENT":"DIRECT_OUTBOUND",
                legacy?"LEGACY_READY":"READY_OUTBOUND",legacy?null:false,legacy?null:"a".repeat(64));
        execute(c,"insert into subcontract_material_issues(id,bill_no,bill_date,status) values (?,?,DATE '2026-01-01',?)",issue,issueNo,reversed?-1:0);
        execute(c,"""
                insert into subcontract_material_issue_items(id,issue_id,order_item_id,plan_item_id,bill_no,bill_date,line_no,
                    parent_goods_id,goods_id,unit_id,unit_rate,qty,
                    goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,
                    parent_goods_code_snapshot,parent_goods_name_snapshot,parent_goods_snapshot_source)
                values (?,?,?,?,?,DATE '2026-01-01',1,?,?,?,2,20,?,'migration quantity fixture','MASTER_AT_SAVE',
                    ?,'migration quantity fixture','MASTER_AT_SAVE')
                """,issueItem,issue,item,line,issueNo,goods,goods,unit,"GOODS-"+goods,"GOODS-"+goods);
        c.commit(); c.setAutoCommit(true);
        return new Fixture(line,issueItem,goods);
    }
    private static void execute(Connection c,String sql,Object...args) throws SQLException {
        try(var s=c.prepareStatement(sql)) { for(int n=0;n<args.length;n++)s.setObject(n+1,args[n]);s.executeUpdate(); }
    }
    private static int count(Connection c,String sql,UUID id) throws SQLException {
        try(var s=c.prepareStatement(sql)) {s.setObject(1,id);try(var r=s.executeQuery()){r.next();return r.getInt(1);}}
    }
    private static void assertDecimal(Connection c,String sql,UUID id,String expected) throws SQLException {
        try(var s=c.prepareStatement(sql)) {s.setObject(1,id);try(var r=s.executeQuery()){assertTrue(r.next());assertEquals(0,r.getBigDecimal(1).compareTo(new BigDecimal(expected)));}}
    }
}
