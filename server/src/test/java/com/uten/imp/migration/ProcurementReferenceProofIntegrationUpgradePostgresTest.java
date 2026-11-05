package com.uten.imp.migration;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.FinancialJsonResults;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.*;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;

/** Actual SQL upgrade compatibility only; public Java save/finance review has its own E2E. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementReferenceProofIntegrationUpgradePostgresTest {
    private static final ObjectMapper JSON=new ObjectMapper();
    private static final java.util.concurrent.atomic.AtomicInteger BILLS=new java.util.concurrent.atomic.AtomicInteger(700000);
    private static final String DOWN="{\"version\":1,\"choices\":{\"money.reference-unit-price\":{\"scale\":2,\"rounding\":\"DOWN\"}}}";
    private static final String UP="{\"version\":1,\"choices\":{\"money.reference-unit-price\":{\"scale\":2,\"rounding\":\"HALF_UP\"}}}";
    private record Master(UUID actor,UUID supplier,UUID warehouse,UUID currency,UUID unit,UUID goods) { }
    private record Row(String kind,String table,UUID order,UUID item) { }

    @Test void realNullHistoryAndMainSavedMapRemainOriginalThroughCurrentTaggedProofUpgrade()throws Exception {
        try(var database=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("reference_proof_upgrade")
                .withUsername("reference_fixture").withPassword("anonymous-reference-only")) {
            database.start();migrate(database,"1032");
            Master master;List<Row> legacy=new ArrayList<>();Map<UUID,JsonNode> originalMoney=new LinkedHashMap<>();
            try(var connection=connect(database)) {
                master=master(connection);
                for(String kind:List.of("PURCHASE","SUBCONTRACT")) {
                    Row row=insert(connection,master,kind,"0.1666666666",null);legacy.add(row);
                    originalMoney.put(row.item(),money(connection,row));
                }
                assertThat(value(connection,"SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='purchase_order_items' AND column_name='reference_price_precision_policy'")).isEqualTo("0");
            }
            migrate(database,"1065");
            List<Row> mainMaps=new ArrayList<>();Map<UUID,JsonNode> beforeCurrent=new LinkedHashMap<>();
            try(var connection=connect(database)) {
                for(Row row:legacy) {
                    assertThat(money(connection,row)).isEqualTo(originalMoney.get(row.item()));
                    assertThat(value(connection,"SELECT reference_price_precision_policy IS NULL FROM "+row.table()+" WHERE id=?",row.item())).isEqualTo("t");
                    beforeCurrent.put(row.item(),json(connection,row));
                }
                for(String kind:List.of("PURCHASE","SUBCONTRACT")) {
                    Row row=insert(connection,master,kind,"0.16",DOWN);mainMaps.add(row);
                    JsonNode stored=FinancialJsonResults.tree(JSON,value(connection,"SELECT reference_price_precision_policy::text FROM "+row.table()+" WHERE id=?",row.item()));
                    assertThat(stored).isEqualTo(FinancialJsonResults.tree(JSON,DOWN));
                    assertThat(stored.has("kind")).isFalse();beforeCurrent.put(row.item(),json(connection,row));
                }
            }
            migrate(database,null);
            try(var connection=connect(database)) {
                List<Row> retained=new ArrayList<>(legacy);retained.addAll(mainMaps);
                for(Row row:retained) {
                    JsonNode actual=json(connection,row);JsonNode before=beforeCurrent.get(row.item());
                    // Only genuinely new technical source/copy columns may appear.
                    for(var field:before.properties())assertThat(actual.get(field.getKey())).as(row.kind()+" retained "+field.getKey()).isEqualTo(field.getValue());
                    assertThat(actual.path("reference_price_successor_source_id").isNull()).isTrue();
                    assertThat(actual.path("successor_copy_txid").isNull()).isTrue();
                    for(String choices:List.of("{\"version\":1,\"choices\":{}}",UP)) {
                        policy(connection,master.actor(),choices,false);
                        assertThat(value(connection,"SELECT fn_procurement_reference_price_matches(to_jsonb(i)) FROM "+row.table()+" i WHERE id=?",row.item())).isEqualTo("t");
                    }
                    JsonNode frozen=json(connection,row);
                    connection.setAutoCommit(false);
                    try {
                        policy(connection,master.actor(),UP,true);
                        execute(connection,"UPDATE "+row.table()+" SET qty=qty,price=price,total_amount_input=total_amount_input,unit_id=unit_id,unit_rate=unit_rate WHERE id=?",row.item());
                        assertThat(value(connection,"SELECT fn_adopt_procurement_reference_price_policy(?,?,?::jsonb)",row.kind(),row.order(),UP)).isEqualTo("0");
                        connection.commit();
                    }catch(Exception failure){connection.rollback();throw failure;}finally{connection.setAutoCommit(true);}
                    assertThat(json(connection,row)).isEqualTo(frozen);
                }
                for(String kind:List.of("PURCHASE","SUBCONTRACT")) {
                    Row modern=insert(connection,master,kind,"0.16",DOWN);
                    JsonNode proof=FinancialJsonResults.tree(JSON,value(connection,"SELECT reference_price_precision_policy::text FROM "+modern.table()+" WHERE id=?",modern.item()));
                    assertThat(proof.path("kind").asText()).isEqualTo("PROCUREMENT_REFERENCE_PRICE");
                    assertThat(proof.path("mode").asText()).isEqualTo("SELECTED");
                    assertThat(proof.path("precisionPolicy")).isEqualTo(FinancialJsonResults.tree(JSON,DOWN));
                    assertThat(proof.path("actorId").asText()).isEqualTo(master.actor().toString());
                    policy(connection,master.actor(),UP,false);
                    assertThat(value(connection,"SELECT fn_procurement_reference_price_matches(to_jsonb(i)) FROM "+modern.table()+" i WHERE id=?",modern.item())).isEqualTo("t");
                    assertThat(new BigDecimal(value(connection,"SELECT price FROM "+modern.table()+" WHERE id=?",modern.item()))).isEqualByComparingTo("0.16");
                }
            }
        }
    }

    private static Row insert(Connection connection,Master master,String kind,String price,String choices)throws Exception {
        String prefix=kind.equals("PURCHASE")?"purchase":"subcontract",number=kind.equals("PURCHASE")?"CD":"EO";
        UUID order=UUID.randomUUID(),item=UUID.randomUUID();String bill=number+"20260923"+String.format(Locale.ROOT,"%06d",BILLS.incrementAndGet());
        connection.setAutoCommit(false);
        try {
            policy(connection,master.actor(),choices==null?"{\"version\":1,\"choices\":{}}":choices,true);
            execute(connection,"INSERT INTO "+prefix+"_orders(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,exchange_rate,tax_rate,total_original,total_local,status,created_by,updated_by) VALUES(?,?,DATE '2026-09-23',?,?,?,1,0,1,1,0,?,?)",order,bill,master.supplier(),master.warehouse(),master.currency(),master.actor(),master.actor());
            execute(connection,"INSERT INTO "+prefix+"_order_items(id,bill_no,bill_date,order_id,line_no,goods_id,unit_id,unit_rate,qty,price,total_amount_input,amount_original,amount_local,goods_snapshot_source) VALUES(?,?,DATE '2026-09-23',?,1,?,?,1,6,?::numeric,1,1,1,'MASTER_AT_SAVE')",item,bill,order,master.goods(),master.unit(),price);
            connection.commit();return new Row(kind,prefix+"_order_items",order,item);
        }catch(Exception failure){connection.rollback();throw failure;}finally{connection.setAutoCommit(true);}
    }
    private static Master master(Connection c)throws SQLException {
        UUID actor=UUID.randomUUID(),employee=UUID.randomUUID(),supplier=UUID.randomUUID(),warehouse=UUID.randomUUID(),unit=UUID.randomUUID(),goods=UUID.randomUUID();
        execute(c,"INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',(SELECT id FROM departments WHERE code='DEPT_FIN'),DATE '2026-01-01','active','regular')",employee,"REF-UP-"+employee,"匿名参考价升级员工-"+employee);
        execute(c,"INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-not-used',false,'active')",actor,employee,"ref-up-"+actor);
        execute(c,"INSERT INTO suppliers(id,code,name,status,code_sequence) VALUES(?,?,'匿名参考价升级供应商','使用',(SELECT coalesce(max(code_sequence),0)+1 FROM suppliers))",supplier,"REF-UP-"+supplier);
        execute(c,"INSERT INTO warehouses(id,code,name)VALUES(?,?,'匿名参考价升级仓')",warehouse,"REF-UP-"+warehouse);
        execute(c,"INSERT INTO units(id,code,name)VALUES(?,?,'匿名参考价升级单位')",unit,"REF-UP-"+unit);
        execute(c,"INSERT INTO goods(id,code,name,unit_id,code_sequence)VALUES(?,?,'匿名参考价升级物料',?,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))",goods,"REF-UP-"+goods,unit);
        return new Master(actor,supplier,warehouse,UUID.fromString(value(c,"SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted LIMIT 1")),unit,goods);
    }
    private static void policy(Connection c,UUID actor,String json,boolean local)throws SQLException {
        execute(c,"SELECT set_config('app.actor_id',?,?),set_config('app.business_precision_choices',?,?)",actor.toString(),local,json,local);
    }
    private static JsonNode json(Connection c,Row row)throws Exception{return FinancialJsonResults.tree(JSON,value(c,"SELECT to_jsonb(i)::text FROM "+row.table()+" i WHERE id=?",row.item()));}
    private static JsonNode money(Connection c,Row row)throws Exception{return FinancialJsonResults.tree(JSON,value(c,"SELECT jsonb_build_object('qty',qty,'price',price,'total',total_amount_input,'original',amount_original,'local',amount_local,'unit',unit_id,'rate',unit_rate)::text FROM "+row.table()+" WHERE id=?",row.item()));}
    private static void migrate(PostgreSQLContainer database,String target){
        var config=TestFlyway.configure().dataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword())
                .locations(System.getProperty("uten.test.reference-integration.locations","classpath:db/migration")).cleanDisabled(true).outOfOrder(false);
        if(target!=null)config.target(target);assertThat(config.load().migrate().success).isTrue();
    }
    private static Connection connect(PostgreSQLContainer database)throws SQLException{return DriverManager.getConnection(database.getJdbcUrl(),database.getUsername(),database.getPassword());}
    private static void execute(Connection c,String sql,Object...args)throws SQLException{try(var s=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);s.execute();}}
    private static String value(Connection c,String sql,Object...args)throws SQLException{try(var s=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);try(var r=s.executeQuery()){assertThat(r.next()).isTrue();return r.getString(1);}}}
}
