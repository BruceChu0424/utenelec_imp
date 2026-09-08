package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.sql.*;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinancialBookAllocationPostgresTest {
    @Test void completeMigrationAndFiniteActualBookAllocation() throws Exception {
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine")) {
            pg.start();
            UUID supplier=UUID.randomUUID(),currency=UUID.randomUUID();
            UUID[] receipts={UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID()};
            Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())
                .locations("filesystem:src/main/resources/db/migration").target("508").load().migrate();
            try(var c=DriverManager.getConnection(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())) {
                execute(c,"INSERT INTO suppliers(id,code,name,status,code_sequence) VALUES(?,'BOOK-S','Book source','使用',100001)",supplier);
                execute(c,"INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,'BOOK-FX','Book currency',3.333333,'使用')",currency);
                UUID unit=UUID.randomUUID(),goods=UUID.randomUUID(),warehouse=UUID.randomUUID();
                execute(c,"INSERT INTO units(id,code,name) VALUES(?,'BOOK-UNIT','piece')",unit);
                execute(c,"INSERT INTO goods(id,code,name,min_qty,code_sequence) VALUES(?,'BOOK-GOODS','source goods',0,100001)",goods);
                execute(c,"INSERT INTO warehouses(id,code,name) VALUES(?,'BOOK-WH','source warehouse')",warehouse);
                c.setAutoCommit(false);
                for(int i=0;i<receipts.length;i++) {
                    String a=i==3?"0.0001":"3",b=i==3?"0":"10",rate=i==3?"0.0001":"3.333333";
                    String billNo = String.format(java.util.Locale.ROOT, "CJ20260907%06d", i + 1);
                    execute(c,"INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,currency_id,exchange_rate,total_original,total_local,warehouse_id,status) VALUES(?,?,CURRENT_DATE,?,?,?::numeric,?::numeric,?::numeric,?,1)",receipts[i],billNo,supplier,currency,rate,a,b,warehouse);
                    execute(c,"INSERT INTO purchase_receipt_items(id,bill_no,bill_date,receipt_id,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,goods_snapshot_source) VALUES(?,?,CURRENT_DATE,?,?,?,1,?::numeric,1,?::numeric,?::numeric,'MASTER_AT_SAVE')",UUID.randomUUID(),billNo,receipts[i],goods,unit,a,a,b);
                }
                c.commit();
            }
            Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())
                .locations("filesystem:src/main/resources/db/migration", "filesystem:../.codex-tmp/valuation-positions",
                    "filesystem:../.codex-tmp/iqc-consideration","filesystem:../.codex-tmp/financial-exact")
                .target("520").load().migrate();
            try(var c=DriverManager.getConnection(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())) {
                assertEquals("0.000000000000000000000007000001",value(c,"SELECT (1e-24::numeric*7.000001::numeric)::text"));
                assertEquals("3.333333333333333333333333333333",value(c,"SELECT fn_financial_book_part(1,3,10)::text"));
                assertEquals("3.333333333333333333333333333334",value(c,"SELECT fn_financial_book_part(1,1,10-2*fn_financial_book_part(1,3,10))::text"));
                assertEquals("true",value(c,"SELECT fn_financial_book_amount_is_exact(1e-24::numeric*7.000001)::text"));
                assertEquals("false",value(c,"SELECT fn_financial_amount_is_exact(1e-24::numeric*7.000001)::text"));
                UUID unpaid=source(c,receipts[0],supplier,currency,"3","10","3","10");
                var first=plan(c,unpaid,"1");
                assertAmount("3.333333333333333333333333333333",first.get("amountLocal").asText());
                assertAmount("1",first.get("offsetOriginal").asText());
                assertAmount("0",first.get("creditRemainingOriginal").asText());
                var full=plan(c,unpaid,"3");assertAmount("10",full.get("offsetLocal").asText());
                UUID partial=source(c,receipts[1],supplier,currency,"3","10","1","3.333333333333333333333333333334");
                var exhaust=plan(c,partial,"2");
                assertAmount("3.333333333333333333333333333334",exhaust.get("offsetLocal").asText());
                assertAmount("3.333333333333333333333333333333",exhaust.get("creditRemainingLocal").asText());
                UUID paid=source(c,receipts[2],supplier,currency,"3","10","0","0");
                var debit=plan(c,paid,"1");assertAmount("0",debit.get("offsetOriginal").asText());
                assertAmount("3.333333333333333333333333333333",debit.get("creditRemainingLocal").asText());
                UUID zeroBook=source(c,receipts[3],supplier,currency,"0.0001","0","0.0001","0");
                assertAmount("0",plan(c,zeroBook,"0.0001").get("amountLocal").asText());
                assertThrows(SQLException.class,()->plan(c,unpaid,"3.000000000000000000000001"));
                System.out.println("V515 actual/book migration + unpaid nonfinite, complete source, partial-paid exact tail, paid debit, zero-book credit, oversource rejection passed");
            }
        }
    }
    private static UUID source(Connection c,UUID receipt,UUID supplier,UUID currency,String a,String b,String balanceA,String balanceB)throws Exception {
        UUID id=UUID.randomUUID();
        execute(c,"""
            INSERT INTO ar_ap_ledger(id,direction,source_doc_type,source_doc_id,source_doc_no,bill_no,bill_date,
              supplier_id,currency_id,exchange_rate,amount_original,amount_original_local,amount_balance_original,amount_balance,
              amount_received_original,amount_received_local,amount_settled,amount_write_off_original,amount_write_off_local,status,is_settled,settled_date)
            VALUES(?,'AP','PURCHASE_RECEIPT',?,?,?,DATE '2026-09-07',?,?,3.333333,?::numeric,?::numeric,?::numeric,?::numeric,
              ?::numeric,?::numeric,?::numeric,0,0,1,?,CASE WHEN ? THEN DATE '2026-09-07' ELSE NULL END)
            """,id,receipt,"BOOK-"+id,"BOOK-"+id,supplier,currency,a,b,balanceA,balanceB,
            new BigDecimal(a).subtract(new BigDecimal(balanceA)),new BigDecimal(b).subtract(new BigDecimal(balanceB)),
            new BigDecimal(b).subtract(new BigDecimal(balanceB)),new BigDecimal(balanceA).signum()==0&&new BigDecimal(balanceB).signum()==0,
            new BigDecimal(balanceA).signum()==0&&new BigDecimal(balanceB).signum()==0);
        return id;
    }
    private static com.fasterxml.jackson.databind.JsonNode plan(Connection c,UUID source,String amount)throws Exception {
        return new ObjectMapper().enable(com.fasterxml.jackson.databind.DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)
                .readTree(value(c,"SELECT fn_plan_procurement_credit_book(?::uuid,?::numeric)::text",source,amount));
    }
    private static void assertAmount(String expected,String actual){assertEquals(0,new BigDecimal(expected).compareTo(new BigDecimal(actual)),
            ()->"expected exact amount "+expected+" but got "+actual);}
    private static void execute(Connection c,String sql,Object...args)throws SQLException{try(var s=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);s.execute();}}
    private static String value(Connection c,String sql,Object...args)throws SQLException{try(var s=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);try(var r=s.executeQuery()){return r.next()?r.getString(1):null;}}}
}
