package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CustomerPrepaymentNonEmptyUpgradePostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16.15-alpine")
                    .withDatabaseName("uten_customer_prepayment_upgrade")
                    .withUsername("uten").withPassword("uten");

    @BeforeAll static void start(){POSTGRES.start();}
    @AfterAll static void stop(){POSTGRES.stop();}

    @Test
    void v378HistoryUpgradesWithoutGuessingMultiOrderCashOrRewritingLegacyDeposit() throws Exception {
        flyway("378").migrate();
        Fixture f;
        try(Connection connection=connection()){f=seedV378(connection);}
        flyway(null).migrate();
        try(Connection connection=connection()){
            assertThat(text(connection,"SELECT receipt_kind FROM finance_receipts WHERE id=?",f.singleReceipt()))
                    .isEqualTo("AR_SETTLEMENT");
            assertThat(text(connection,"SELECT receipt_kind FROM finance_receipts WHERE id=?",f.multiReceipt()))
                    .isEqualTo("AR_SETTLEMENT");
            assertThat(text(connection,"SELECT receipt_kind FROM finance_receipts WHERE id=?",f.directReceipt()))
                    .isEqualTo("CUSTOMER_PREPAYMENT");
            assertThat(number(connection,"SELECT bank_fee FROM finance_receipts WHERE id=?",f.directReceipt()))
                    .isEqualTo(2);
            assertThat(number(connection,"SELECT settlement_authority_version FROM finance_receipts WHERE id=?",f.directReceipt()))
                    .isZero();
            assertThat(text(connection,"""
                    SELECT reconciliation_state FROM v_receipt_v0_gl_reconciliation
                    WHERE receipt_id=?
                    """,f.directReceipt())).isEqualTo("MISSING");
            assertThat(text(connection,"SELECT open_item_kind FROM ar_ap_ledger WHERE id=?",f.directLedger()))
                    .isEqualTo("CUSTOMER_PREPAYMENT");
            assertThat(number(connection,"""
                    SELECT COUNT(*) FROM finance_receipt_source_allocations
                    WHERE receipt_line_id=? AND sales_order_id=? AND cash_original=3.0000
                    """,f.singleLine(),f.orderOne())).isEqualTo(1);
            assertThat(number(connection,"""
                    SELECT COUNT(*) FROM finance_receipt_source_allocations
                    WHERE receipt_line_id=?
                    """,f.multiLine())).isZero();
            assertThat(number(connection,"""
                    SELECT COALESCE(ledger.amount_received_original,0)
                         + COALESCE(ledger.amount_write_off_original,0)
                         - COALESCE((SELECT SUM(a.cash_original+a.write_off_original)
                                     FROM finance_receipt_source_allocations a
                                     WHERE a.ledger_id=ledger.id AND a.status='APPLIED'),0)
                    FROM ar_ap_ledger ledger WHERE ledger.id=?
                    """,f.multiLedger())).isEqualTo(4);
            assertThat(number(connection,"""
                    SELECT COUNT(*) FROM ar_ap_source_refs
                    WHERE ledger_id=? AND source_type='SALES_ORDER'
                    """,f.multiLedger())).isEqualTo(2);
            assertThat(number(connection,"SELECT deposit FROM sales_orders WHERE id=?",f.orderOne()))
                    .isEqualTo(99);
            assertSqlState(connection,"23514","UPDATE sales_orders SET deposit=0 WHERE id=?",f.orderOne());
            assertThat(number(connection,"""
                    SELECT COUNT(*) FROM flyway_schema_history WHERE version='389' AND success=TRUE
                    """)).isEqualTo(1);
            assertThat(number(connection,"""
                    SELECT COUNT(*) FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                    WHERE t.tgname LIKE 'trg_audit%'
                      AND t.tgrelid IN('customer_open_item_offset_batches'::regclass,
                                       'customer_open_item_offsets'::regclass,
                                       'finance_receipt_source_allocations'::regclass)
                      AND p.proname IN('fn_audit','fn_audit_redacted')
                    """)).isEqualTo(3);
        }
        String querySource=java.nio.file.Files.readString(java.nio.file.Path.of(
                "src/main/java/com/uten/imp/features/finance/receivables/CustomerPrepaymentQueryService.java"));
        assertThat(querySource)
                .contains("部分客户付款或历史结算缺少准确的订单来源明细")
                .contains("invoicePosition.unresolvedCashCount()>0")
                .contains("hasUnallocated ? null : money(cashReceivedOriginal)")
                .contains("hasUnallocated ? null : money(cashReceivedLocal)");
    }

    private static Fixture seedV378(Connection c)throws SQLException{
        UUID client=UUID.randomUUID(),currency=UUID.randomUUID(),order1=UUID.randomUUID(),order2=UUID.randomUUID();
        UUID singleLedger=UUID.randomUUID(),multiLedger=UUID.randomUUID(),directLedger=UUID.randomUUID();
        UUID singleReceipt=UUID.randomUUID(),multiReceipt=UUID.randomUUID(),directReceipt=UUID.randomUUID();
        UUID singleLine=UUID.randomUUID(),multiLine=UUID.randomUUID();
        execute(c,"INSERT INTO clients(id,code,name,status,code_sequence) VALUES(?,?,?,'使用',2)",
                client,"CP-UPGRADE-"+client,"Customer prepayment upgrade");
        execute(c,"INSERT INTO currencies(id,legacy_id,code,name,exchange_rate,status) "
                        + "VALUES(?,1,?,?,1,'使用')",
                currency,"UPG-"+currency,"Upgrade currency");
        insertOrder(c,order1,"XD20260823000011",client,currency,"99.0000");
        insertOrder(c,order2,"XD20260823000012",client,currency,"0");
        insertLedger(c,singleLedger,"SALES_SHIPMENT",UUID.randomUUID(),"AR-UPG-SINGLE",client,currency,
                "10","10","3","3","7","3","7");
        insertLedger(c,multiLedger,"SALES_SHIPMENT",UUID.randomUUID(),"AR-UPG-MULTI",client,currency,
                "20","20","4","4","16","4","16");
        insertReceipt(c,singleReceipt,"XS20260823000011",client,currency,"3");
        insertReceipt(c,multiReceipt,"XS20260823000012",client,currency,"4");
        insertLine(c,singleLine,singleReceipt,singleLedger,client,currency,"3","10","7");
        insertLine(c,multiLine,multiReceipt,multiLedger,client,currency,"4","20","16");
        execute(c,"""
                INSERT INTO finance_receipts(id,bill_no,bill_date,client_id,currency_id,exchange_rate,
                    amount_original,amount_local,bank_fee,other_fee,status,is_deleted)
                VALUES(?,'XS20260823000013',DATE '2026-08-23',?,?,1,5,5,2,0,1,FALSE)
                """,directReceipt,client,currency);
        insertLedger(c,directLedger,"DIRECT_RECEIPT",directReceipt,"XS20260823000013",client,currency,
                "0","0","5","5","-5","5","-5");
        execute(c,"""
                INSERT INTO ar_ap_source_refs(ledger_id,source_type,source_id,source_no,amount_original,amount_local)
                VALUES(?,'SALES_ORDER',?,'XD20260823000011',10,10)
                """,singleLedger,order1);
        execute(c,"""
                INSERT INTO ar_ap_source_refs(ledger_id,source_type,source_id,source_no,amount_original,amount_local)
                VALUES(?,'SALES_ORDER',?,'XD20260823000011',8,8),
                      (?,'SALES_ORDER',?,'XD20260823000012',12,12)
                """,multiLedger,order1,multiLedger,order2);
        return new Fixture(order1,singleLedger,multiLedger,directLedger,singleReceipt,multiReceipt,
                directReceipt,singleLine,multiLine);
    }

    private static void insertOrder(Connection c,UUID id,String no,UUID client,UUID currency,String deposit)throws SQLException{
        execute(c,"""
                INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,exchange_rate,
                    total_original,total_local,status,is_closed,is_stopped,deposit,shipment_policy)
                VALUES(?,?,DATE '2026-08-23',?,?,1,20,20,1,FALSE,FALSE,?::numeric,'ALLOW_PARTIAL')
                """,id,no,client,currency,deposit);
    }

    private static void insertReceipt(Connection c,UUID id,String no,UUID client,UUID currency,String amount)throws SQLException{
        execute(c,"""
                INSERT INTO finance_receipts(id,bill_no,bill_date,client_id,currency_id,exchange_rate,
                    amount_original,amount_local,bank_fee,other_fee,status,is_deleted)
                VALUES(?,?,DATE '2026-08-23',?,?,1,?::numeric,?::numeric,0,0,1,FALSE)
                """,id,no,client,currency,amount,amount);
    }

    private static void insertLine(Connection c,UUID id,UUID receipt,UUID ledger,UUID client,UUID currency,
                                   String amount,String before,String after)throws SQLException{
        execute(c,"""
                INSERT INTO finance_receipt_lines(id,receipt_id,bill_no,bill_date,applied_ledger_id,
                    client_id,line_no,amount_original,amount_local,exchange_diff,currency_id,
                    exchange_rate,write_off_amount,write_off_local,applied_amount_local,
                    balance_before_original,balance_after_original,is_deleted)
                VALUES(?,?,'HIST',DATE '2026-08-23',?,?,1,?::numeric,?::numeric,0,?,1,0,0,
                       ?::numeric,?::numeric,?::numeric,FALSE)
                """,id,receipt,ledger,client,amount,amount,currency,amount,before,after);
    }

    private static void insertLedger(Connection c,UUID id,String type,UUID sourceId,String no,UUID client,UUID currency,
                                     String original,String local,String receivedOriginal,String receivedLocal,
                                     String balanceOriginal,String settled,String balance)throws SQLException{
        execute(c,"""
                INSERT INTO ar_ap_ledger(id,direction,source_doc_type,source_doc_id,source_doc_no,bill_no,bill_date,
                    client_id,currency_id,exchange_rate,amount_original,amount_original_local,
                    amount_received_original,amount_received_local,amount_write_off_original,amount_write_off_local,
                    amount_offset_original,amount_offset_local,amount_balance_original,amount_settled,amount_balance,
                    is_settled,status,is_deleted)
                VALUES(?,'AR',?,?,?,?,DATE '2026-08-23',?,?,1,?::numeric,?::numeric,?::numeric,?::numeric,
                       0,0,0,0,?::numeric,?::numeric,?::numeric,FALSE,1,FALSE)
                """,id,type,sourceId,no,no,client,currency,original,local,receivedOriginal,receivedLocal,
                balanceOriginal,settled,balance);
    }

    private static void assertSqlState(Connection c,String state,String sql,Object...args)throws SQLException{
        c.setAutoCommit(false);try{assertThatThrownBy(()->execute(c,sql,args)).isInstanceOf(SQLException.class)
                .extracting(error->((SQLException)error).getSQLState()).isEqualTo(state);c.rollback();}
        finally{c.setAutoCommit(true);}
    }
    private static void execute(Connection c,String sql,Object...args)throws SQLException{try(PreparedStatement s=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);s.executeUpdate();}}
    private static String text(Connection c,String sql,Object...args)throws SQLException{return String.valueOf(value(c,sql,args));}
    private static long number(Connection c,String sql,Object...args)throws SQLException{return ((Number)value(c,sql,args)).longValue();}
    private static Object value(Connection c,String sql,Object...args)throws SQLException{try(PreparedStatement s=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);try(ResultSet r=s.executeQuery()){assertThat(r.next()).isTrue();return r.getObject(1);}}}
    private static Connection connection()throws SQLException{return DriverManager.getConnection(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());}
    private static Flyway flyway(String target){var config=Flyway.configure().dataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword()).locations("classpath:db/migration");if(target!=null)config.target(target);return config.load();}
    private record Fixture(UUID orderOne,UUID singleLedger,UUID multiLedger,UUID directLedger,
                           UUID singleReceipt,UUID multiReceipt,UUID directReceipt,UUID singleLine,UUID multiLine){}
}
