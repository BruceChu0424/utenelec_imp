package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ArApDualCurrencySettlementPostgresTest {
    @Test void nonemptyUpgradeCorrectsOnlyDerivedStateAndKeepsBothCurrencyGuardsInReplicaMode() throws Exception {
        try(var database=new PostgreSQLContainer<>("postgres:16-alpine")) {
            database.start();
            // V512 was an unpublished prototype; V511 is the preceding formal schema.
            migrate(database,System.getProperty("uten.test.dualCurrencyBefore","511"));
            UUID client=UUID.randomUUID(),supplier=UUID.randomUUID(),currency=UUID.randomUUID();
            var rows=new LinkedHashMap<String,UUID>();
            for(String kind:List.of("AR","AP","CREDIT","ZERO","LEGACY","LOCAL")) rows.put(kind,UUID.randomUUID());
            Map<UUID,String> before=new LinkedHashMap<>();
            try(var connection=connect(database)) {
                execute(connection,"INSERT INTO clients(id,code,name,status,code_sequence,sales_payment_type) VALUES(?,'SETTLE-C','结清测试客户','使用',100000,'MONTHLY')",client);
                execute(connection,"INSERT INTO suppliers(id,code,name,status,code_sequence) VALUES(?,'SETTLE-S','结清测试供应商','使用',100000)",supplier);
                execute(connection,"INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,'SETTLE-FX','结清测试币种',0.0001,'使用')",currency);
                for(var row:rows.entrySet()) {
                    String kind=row.getKey();
                    if(kind.equals("CREDIT")) {
                        var rejected=assertThrows(SQLException.class,()->insertLedger(connection,kind,row.getValue(),client,supplier,currency,true));
                        assertEquals("23514",rejected.getSQLState());
                        assertTrue(rejected.getMessage().contains("ar_ap_ledger_ap_original_open_item_shape_chk"),
                                "旧派生把合法负原币/零本币归PAYABLE，原币形状守卫会拒绝；不能伪造已存在的错误历史行");
                        continue;
                    }
                    insertLedger(connection,kind,row.getValue(),client,supplier,currency,true);
                    before.put(row.getValue(),moneySnapshot(connection,row.getValue()));
                }
            }
            migrate(database,"513");
            try(var connection=connect(database)) {
                for(var row:before.entrySet()) assertEquals(row.getValue(),moneySnapshot(connection,row.getKey()),"迁移不能修改任何原账金额或来源");
                insertLedger(connection,"CREDIT",rows.get("CREDIT"),client,supplier,currency,false);
                for(String kind:List.of("AR","AP","CREDIT","LOCAL")) {
                    assertEquals("false",value(connection,"SELECT is_settled::text FROM ar_ap_ledger WHERE id=?",rows.get(kind)));
                    assertNull(value(connection,"SELECT settled_date FROM ar_ap_ledger WHERE id=?",rows.get(kind)));
                }
                for(String kind:List.of("ZERO","LEGACY")) assertEquals("true",value(connection,"SELECT is_settled::text FROM ar_ap_ledger WHERE id=?",rows.get(kind)));
                assertEquals("CREDIT",value(connection,"SELECT open_item_kind FROM ar_ap_ledger WHERE id=?",rows.get("CREDIT")));
                execute(connection,"SET session_replication_role=replica");
                execute(connection,"UPDATE ar_ap_ledger SET open_item_kind='PAYABLE' WHERE id=?",rows.get("CREDIT"));
                assertEquals("CREDIT",value(connection,"SELECT open_item_kind FROM ar_ap_ledger WHERE id=?",rows.get("CREDIT")));
                var rejected=assertThrows(SQLException.class,()->execute(connection,
                        "UPDATE ar_ap_ledger SET is_settled=TRUE,settled_date=DATE '2026-09-07' WHERE id=?",rows.get("AR")));
                assertEquals("23514",rejected.getSQLState());
                assertTrue(rejected.getMessage().contains("ar_ap_ledger_settled_consistency_chk"));
            }
        }
    }

    private static void insertLedger(Connection connection,String kind,UUID id,UUID client,UUID supplier,UUID currency,boolean oldRule)throws SQLException {
        boolean ap=kind.equals("AP")||kind.equals("CREDIT");
        String original=kind.equals("CREDIT")?"-0.0001":kind.equals("AR")||kind.equals("AP")?"0.0001":"0";
        String local=kind.equals("LOCAL")?"0.0001":"0";
        String type=ap?(kind.equals("CREDIT")?"PURCHASE_RETURN":"PURCHASE_RECEIPT"):"SALES_SHIPMENT";
        boolean settled=!kind.equals("LOCAL") && (oldRule || kind.equals("ZERO") || kind.equals("LEGACY"));
        execute(connection,"""
                INSERT INTO ar_ap_ledger(id,direction,source_doc_type,source_doc_id,source_doc_no,bill_no,bill_date,
                    client_id,supplier_id,currency_id,exchange_rate,amount_original,amount_original_local,
                    amount_balance_original,amount_balance,amount_received_original,amount_received_local,
                    amount_write_off_original,amount_write_off_local,status,is_settled,settled_date)
                VALUES(?,?,?,?,?,?,DATE '2026-09-07',?,?,?,0.0001,CAST(? AS numeric),CAST(? AS numeric),CAST(? AS numeric),CAST(? AS numeric),
                    CAST(? AS numeric),0,CAST(? AS numeric),0,1,?,CASE WHEN ? THEN DATE '2026-09-07' ELSE NULL END)
                """,id,ap?"AP":"AR",type,UUID.randomUUID(),"SETTLE-"+id,"SETTLE-"+id,
                ap?null:client,ap?supplier:null,currency,original,local,kind.equals("LEGACY")?null:original,local,
                kind.equals("LEGACY")?null:"0",kind.equals("LEGACY")?null:"0",settled,settled);
    }

    private static String moneySnapshot(Connection connection,UUID id)throws SQLException {
        return value(connection,"SELECT (to_jsonb(ledger)-ARRAY['is_settled','settled_date','open_item_kind','updated_at','updated_by'])::text FROM ar_ap_ledger ledger WHERE id=?",id);
    }
    private static void migrate(PostgreSQLContainer<?> database,String target) {
        String extra=System.getProperty("uten.test.extraMigrationLocation","");
        String[] locations=extra.isBlank()?new String[]{"classpath:db/migration"}:new String[]{"classpath:db/migration",extra};
        Flyway.configure().dataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword())
                .locations(locations).target(target).load().migrate();
    }
    private static Connection connect(PostgreSQLContainer<?> database)throws SQLException { return DriverManager.getConnection(database.getJdbcUrl(),database.getUsername(),database.getPassword()); }
    private static void execute(Connection connection,String sql,Object...args)throws SQLException {
        try(var statement=connection.prepareStatement(sql)){for(int i=0;i<args.length;i++) statement.setObject(i+1,args[i]);statement.execute();}
    }
    private static String value(Connection connection,String sql,Object...args)throws SQLException {
        try(var statement=connection.prepareStatement(sql)){for(int i=0;i<args.length;i++) statement.setObject(i+1,args[i]);try(var result=statement.executeQuery()){return result.next()?result.getString(1):null;}}
    }
}
