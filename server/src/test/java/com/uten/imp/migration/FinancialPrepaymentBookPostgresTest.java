package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.sql.*;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static com.uten.imp.migration.FinancialActualBankReceiptPostgresTest.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinancialPrepaymentBookPostgresTest {
    @Test void actualBankPrepaymentKeepsEverySourceBookRemainderAcrossThreeApplicationsAndReversal() throws Exception {
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine")) {
            pg.start();migrate(pg,"508");
            Fixture f;
            try(var c=connect(pg)){f=historicalShippedOrder(c);}
            migrate(pg,"520");
            try(var c=connect(pg)) {
                UUID bank=account(c,f.base(),"PREPAY");
                UUID receipt=receipt(c,f.client(),f.maker(),bank,f.base(),f.currency(),"3","3.333333","10","0");
                approve(c,receipt,f.approver());
                UUID source=UUID.fromString(value(c,"SELECT id FROM ar_ap_ledger WHERE source_doc_id=? AND source_doc_type='DIRECT_RECEIPT'",receipt));
                List<UUID> batches=new ArrayList<>();
                for(int i=0;i<3;i++) {
                    String beforeA=value(c,"SELECT abs(amount_balance_original) FROM ar_ap_ledger WHERE id=?",source);
                    String beforeB=value(c,"SELECT abs(amount_balance) FROM ar_ap_ledger WHERE id=?",source);
                    BigDecimal local=new BigDecimal(value(c,"SELECT fn_financial_book_part(1,?::numeric,?::numeric)",beforeA,beforeB));
                    assertAmount(i==2?"3.333333333333333333333333333334":"3.333333333333333333333333333333",local.toPlainString());
                    batches.add(apply(c,f,source,local));
                }
                assertAmount("3",value(c,"SELECT sum(amount_original) FROM customer_open_item_offsets WHERE source_ledger_id=? AND status='APPLIED'",source));
                assertAmount("10",value(c,"SELECT sum(source_amount_local) FROM customer_open_item_offsets WHERE source_ledger_id=? AND status='APPLIED'",source));
                assertAmount("0",value(c,"SELECT sum(exchange_difference) FROM customer_open_item_offsets WHERE source_ledger_id=? AND status='APPLIED'",source));
                assertEquals("true",value(c,"SELECT is_settled::text FROM ar_ap_ledger WHERE id=?",source));
                assertEquals("true",value(c,"SELECT is_settled::text FROM ar_ap_ledger WHERE id=?",f.target()));
                assertRejected(c,"UPDATE customer_open_item_offsets SET book_allocation_version=0 WHERE offset_batch_id=?",batches.getFirst());
                for(int i=batches.size()-1;i>=0;i--)reverseApplication(c,batches.get(i),f.actor());
                assertAmount("-3",value(c,"SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",source));
                assertAmount("-10",value(c,"SELECT amount_balance FROM ar_ap_ledger WHERE id=?",source));
                assertAmount("3",value(c,"SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",f.target()));
                assertAmount("10",value(c,"SELECT amount_balance FROM ar_ap_ledger WHERE id=?",f.target()));
                reverse(c,receipt);assertAmount("0",value(c,"SELECT balance_current FROM accounts WHERE id=?",bank));
                assertEquals("true",value(c,"SELECT is_consistent::text FROM v_receipt_gl_integrity WHERE receipt_id=?",receipt));
                System.out.println("V520 actual-bank customer prepayment book1: 3A/10B three exact source applications, no artificial FX, immutable basis and full LIFO restoration passed");
            }
        }
    }
    private static UUID apply(Connection c,Fixture f,UUID source,BigDecimal local)throws Exception {
        UUID batch=UUID.randomUUID();c.setAutoCommit(false);
        try {
            execute(c,"INSERT INTO customer_open_item_offset_batches(id,client_id,currency_id,effective_date,status,row_version,idempotency_key,request_hash,reason,applied_by) VALUES(?,?,?,CURRENT_DATE,'APPLIED',0,?,?,'actual bank book allocation',?)",batch,f.client(),f.currency(),"book-"+batch,"hash-"+batch,f.actor());
            execute(c,"""
                INSERT INTO customer_open_item_offsets(offset_batch_id,line_sequence,client_id,currency_id,source_ledger_id,target_ledger_id,
                  target_source_ref_id,sales_order_id,amount_original,source_amount_local,target_amount_local,exchange_difference,
                  source_rate,target_rate,source_balance_before_original,source_balance_after_original,target_balance_before_original,target_balance_after_original,
                  source_balance_before_local,source_balance_after_local,target_balance_before_local,target_balance_after_local,
                  target_ref_balance_before_original,target_ref_balance_after_original,target_ref_balance_before_local,target_ref_balance_after_local,
                  effective_date,status,row_version,book_allocation_version)
                SELECT ?,1,?,?,s.id,t.id,?,?,1,?::numeric,?::numeric,0,s.exchange_rate,t.exchange_rate,
                  s.amount_balance_original,s.amount_balance_original+1,t.amount_balance_original,t.amount_balance_original-1,
                  s.amount_balance,s.amount_balance+?::numeric,t.amount_balance,t.amount_balance-?::numeric,
                  t.amount_balance_original,t.amount_balance_original-1,t.amount_balance,t.amount_balance-?::numeric,CURRENT_DATE,'APPLIED',0,1
                FROM ar_ap_ledger s CROSS JOIN ar_ap_ledger t WHERE s.id=? AND t.id=?
                """,batch,f.client(),f.currency(),f.ref(),f.order(),local,local,local,local,local,source,f.target());
            execute(c,"UPDATE ar_ap_ledger SET amount_offset_original=amount_offset_original-1,amount_offset_local=amount_offset_local-?::numeric,amount_balance_original=amount_balance_original+1,amount_balance=amount_balance+?::numeric,is_settled=(amount_balance_original=-1 AND amount_balance=-?::numeric),settled_date=CASE WHEN amount_balance_original=-1 AND amount_balance=-?::numeric THEN CURRENT_DATE END WHERE id=?",local,local,local,local,source);
            execute(c,"UPDATE ar_ap_ledger SET amount_offset_original=amount_offset_original+1,amount_offset_local=amount_offset_local+?::numeric,amount_balance_original=amount_balance_original-1,amount_balance=amount_balance-?::numeric,is_settled=(amount_balance_original=1 AND amount_balance=?::numeric),settled_date=CASE WHEN amount_balance_original=1 AND amount_balance=?::numeric THEN CURRENT_DATE END WHERE id=?",local,local,local,local,f.target());
            c.commit();return batch;
        } catch(Exception e){c.rollback();throw e;}finally{c.setAutoCommit(true);}
    }
    private static void reverseApplication(Connection c,UUID batch,UUID actor)throws Exception {
        c.setAutoCommit(false);
        try {
            execute(c,"UPDATE ar_ap_ledger ledger SET amount_offset_original=ledger.amount_offset_original+o.amount_original,amount_offset_local=ledger.amount_offset_local+o.source_amount_local,amount_balance_original=o.source_balance_before_original,amount_balance=o.source_balance_before_local,is_settled=FALSE,settled_date=NULL FROM customer_open_item_offsets o WHERE o.offset_batch_id=? AND ledger.id=o.source_ledger_id",batch);
            execute(c,"UPDATE ar_ap_ledger ledger SET amount_offset_original=ledger.amount_offset_original-o.amount_original,amount_offset_local=ledger.amount_offset_local-o.target_amount_local,amount_balance_original=o.target_balance_before_original,amount_balance=o.target_balance_before_local,is_settled=FALSE,settled_date=NULL FROM customer_open_item_offsets o WHERE o.offset_batch_id=? AND ledger.id=o.target_ledger_id",batch);
            execute(c,"UPDATE customer_open_item_offsets SET status='REVERSED',row_version=row_version+1,reversed_by=?,reversed_at=now() WHERE offset_batch_id=?",actor,batch);
            execute(c,"UPDATE customer_open_item_offset_batches SET status='REVERSED',row_version=row_version+1,reverse_reason='exact source restoration',reversed_by=?,reversed_at=now() WHERE id=?",actor,batch);c.commit();
        }catch(Exception e){c.rollback();throw e;}finally{c.setAutoCommit(true);}
    }
    private static Fixture historicalShippedOrder(Connection c)throws Exception {
        UUID client=UUID.randomUUID(),currency=UUID.randomUUID(),approver=UUID.randomUUID(),actor=UUID.randomUUID();
        UUID maker=UUID.fromString(value(c,"SELECT id FROM employees WHERE code='ADMIN'"));
        UUID base=UUID.fromString(value(c,"SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted"));
        UUID order=UUID.randomUUID(),orderItem=UUID.randomUUID(),shipment=UUID.randomUUID(),target=UUID.randomUUID(),ref=UUID.randomUUID();
        UUID unit=UUID.randomUUID(),goods=UUID.randomUUID(),warehouse=UUID.randomUUID();
        c.setAutoCommit(false);
        try {
            execute(c,"INSERT INTO clients(id,code,name,status,code_sequence,sales_payment_type) VALUES(?,'PREPAY-BOOK-CLIENT','prepayment book client','使用',100400,'CASH')",client);
            execute(c,"INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,'PREPAY-BOOK-CURRENCY','prepayment book currency',3.333333,'使用')",currency);
            execute(c,"INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,'PREPAY-BOOK-APPROVER','prepayment book approver',id_type,department_id,CURRENT_DATE,'active','regular' FROM employees WHERE id=?",approver,maker);
            execute(c,"INSERT INTO users(id,employee_id,login_account,password_hash,status) VALUES(?,?,'prepay-book-actor','test-only','active')",actor,approver);
            execute(c,"INSERT INTO units(id,code,name) VALUES(?,'PREPAY-BOOK-UNIT','piece')",unit);
            execute(c,"INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES(?,'PREPAY-BOOK-GOODS','prepayment goods',?,100400)",goods,unit);
            execute(c,"INSERT INTO warehouses(id,code,name) VALUES(?,'PREPAY-BOOK-WAREHOUSE','prepayment warehouse')",warehouse);
            execute(c,"INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,exchange_rate,total_original,total_local,status,is_closed,is_stopped,deposit,shipment_policy) VALUES(?,'XD20260907000401',DATE '2026-09-07',?,?,3.333333,3,10,1,FALSE,FALSE,0,'ALLOW_PARTIAL')",order,client,currency);
            execute(c,"INSERT INTO sales_order_items(id,order_id,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,price,discount,amount_original,amount_local,goods_snapshot_source) VALUES(?,?,'XD20260907000401',DATE '2026-09-07',1,?,?,1,3,1,1,3,10,'MASTER_AT_SAVE')",orderItem,order,goods,unit);
            execute(c,"INSERT INTO sales_shipments(id,bill_no,bill_date,source_order_id,client_id,currency_id,exchange_rate,owner_employee_id,maker_id,warehouse_id,status,warehouse_work_status,finance_gate_version,finance_audit,finance_auditor_id,finance_audited_at,handed_over_at,ar_posted,total_original,total_local) VALUES(?,'XC20260907000401',DATE '2026-09-07',?,?,?,3.333333,?,?,?,1,'SHIPPED',1,1,?,now(),now(),TRUE,3,10)",shipment,order,client,currency,maker,maker,warehouse,approver);
            execute(c,"INSERT INTO sales_shipment_items(id,shipment_id,bill_no,bill_date,line_no,order_item_id,goods_id,unit_id,unit_rate,qty,price,discount,amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at) VALUES(?,?,'XC20260907000401',DATE '2026-09-07',1,?,?,?,1,3,1,1,3,10,'PREPAY-BOOK-GOODS','prepayment goods','MASTER_AT_APPROVAL',now())",UUID.randomUUID(),shipment,orderItem,goods,unit);
            execute(c,"INSERT INTO ar_ap_ledger(id,direction,source_doc_type,source_doc_id,source_doc_no,bill_no,bill_date,client_id,currency_id,exchange_rate,amount_original,amount_original_local,amount_received_original,amount_received_local,amount_write_off_original,amount_write_off_local,amount_balance_original,amount_balance,status,is_settled) VALUES(?,'AR','SALES_SHIPMENT',?,'XC20260907000401','XC20260907000401',DATE '2026-09-07',?,?,3.333333,3,10,0,0,0,0,3,10,1,FALSE)",target,shipment,client,currency);
            execute(c,"INSERT INTO ar_ap_source_refs(id,ledger_id,source_type,source_id,source_no,source_sequence,amount_original,amount_local) VALUES(?,?,'SALES_ORDER',?,'XD20260907000401',1,3,10)",ref,target,order);c.commit();
        }catch(Exception e){c.rollback();throw e;}finally{c.setAutoCommit(true);}
        return new Fixture(client,currency,base,maker,approver,actor,order,target,ref);
    }
    private record Fixture(UUID client,UUID currency,UUID base,UUID maker,UUID approver,UUID actor,UUID order,UUID target,UUID ref){}
    private static Connection connect(PostgreSQLContainer<?> pg)throws SQLException{return DriverManager.getConnection(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword());}
    private static void migrate(PostgreSQLContainer<?> pg,String target){Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("filesystem:src/main/resources/db/migration","filesystem:../.codex-tmp/valuation-positions","filesystem:../.codex-tmp/iqc-consideration","filesystem:../.codex-tmp/financial-exact").target(target).load().migrate();}
}
