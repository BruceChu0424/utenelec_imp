package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class CustomerPrepaymentHistoricalReversalPostgresTest {
    @Test
    void nonemptyUpgradePreservesHistoricalMoneyAndAllowsOnlyHistoricalClosedOrderUpdates() throws Exception {
        try(var postgres=new PostgreSQLContainer<>("postgres:16.15-alpine")
                .withDatabaseName("uten_advance_reversal").withUsername("uten").withPassword("uten")) {
            postgres.start();
            // Genuine V0 history predates immutable receipt GL ownership in V407.
            migrate(postgres,"406");
            UUID client=UUID.randomUUID(),currency=UUID.randomUUID(),order=UUID.randomUUID();
            UUID approved=UUID.randomUUID(),draft=UUID.randomUUID(),unbound=UUID.randomUUID();
            UUID originalVoucher=UUID.randomUUID(),bankStyle=UUID.randomUUID();
            try(Connection c=connection(postgres)) {
                execute(c,"INSERT INTO clients(id,code,name,status,code_sequence) VALUES(?,'ADV-REV','Advance reversal','使用',2)",client);
                execute(c,"INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,'ADV-REV-CNY','Advance reversal',1,'使用')",currency);
                execute(c,"""
                        INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,total_original,status,
                            is_closed,is_stopped,shipment_policy)
                        VALUES(?,'XD20260907009701',DATE '2026-09-07',?,?,100,1,FALSE,FALSE,'ALLOW_PARTIAL')
                        """,order,client,currency);
                receipt(c,approved,"XS20260907009701",client,currency,order,1);
                receipt(c,draft,"XS20260907009702",client,currency,order,0);
                receipt(c,unbound,"XS20260907009703",client,currency,null,0);
                execute(c,"INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,'ADV-REV-BANK','Historical bank','ACCOUNT',0,'使用')",bankStyle);
                voucher(c,originalVoucher,approved,"RECEIPT",null,1);
                entries(c,originalVoucher,approved,"RECEIPT",bankStyle,1);
                execute(c,"UPDATE sales_orders SET is_closed=TRUE WHERE id=?",order);
                rejected(c,"23514","UPDATE finance_receipts SET sales_order_id=sales_order_id,status=-1,reversed_at=now() WHERE id=?",approved);
            }
            migrate(postgres,"498");
            String before;
            try(Connection c=connection(postgres)){before=snapshot(c,approved);}
            migrate(postgres,"499");
            try(Connection c=connection(postgres)) {
                assertThat(snapshot(c,approved)).isEqualTo(before);
                rejected(c,"23514","UPDATE finance_receipts SET status=1 WHERE id=?",draft);
                rejected(c,"23514","UPDATE finance_receipts SET sales_order_id=? WHERE id=?",order,unbound);
                assertThatThrownBy(()->receipt(c,UUID.randomUUID(),"XS20260907009704",client,currency,order,0))
                        .isInstanceOf(SQLException.class).extracting(e->((SQLException)e).getSQLState()).isEqualTo("23514");
                // Keep the complete original/reversal GL pair. The forward
                // migration must not weaken this independent money constraint.
                c.setAutoCommit(false);
                UUID reversalVoucher=UUID.randomUUID();
                voucher(c,reversalVoucher,approved,"RECEIPT_REV",originalVoucher,0);
                entries(c,reversalVoucher,approved,"RECEIPT_REV",bankStyle,-1);
                execute(c,"UPDATE gl_vouchers SET status=1 WHERE id=?",reversalVoucher);
                execute(c,"UPDATE gl_vouchers SET reversed_by_voucher_id=? WHERE id=?",reversalVoucher,originalVoucher);
                // Hibernate includes unchanged identity columns in its update.
                execute(c,"UPDATE finance_receipts SET sales_order_id=sales_order_id,status=-1,reversed_at=now() WHERE id=?",approved);
                c.commit(); c.setAutoCommit(true);
                assertThat(value(c,"SELECT status FROM finance_receipts WHERE id=?",approved)).isEqualTo("-1");
                assertThat(value(c,"SELECT COUNT(*) FROM gl_entries WHERE voucher_id IN(?,?)",originalVoucher,reversalVoucher)).isEqualTo("4");
                assertThat(value(c,"SELECT amount_original FROM finance_receipts WHERE id=?",approved)).isEqualTo("40.0000");
                rejected(c,"55000","UPDATE finance_receipts SET amount_original=41 WHERE id=?",approved);
                // Valid new approval still works when the order is active.
                execute(c,"UPDATE sales_orders SET is_closed=FALSE WHERE id=?",order);
                execute(c,"UPDATE finance_receipts SET status=1 WHERE id=?",draft);
                assertThat(value(c,"SELECT status FROM finance_receipts WHERE id=?",draft)).isEqualTo("1");
            }
        }
    }

    private static void voucher(Connection c,UUID id,UUID receipt,String type,UUID original,int status)throws SQLException {
        execute(c,"""
                INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,source_doc_id,status,reversal_of_voucher_id)
                VALUES(?,'XS20260907009701','2026-09',DATE '2026-09-07','AUTO',?,?,?,?)
                """,id,type,receipt,status,original);
    }
    private static void entries(Connection c,UUID voucher,UUID receipt,String type,UUID bankStyle,int direction)throws SQLException {
        execute(c,"""
                INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,source_doc_type,source_doc_id,source_bill_no)
                VALUES(?,1,?,?,40,DATE '2026-09-07','2026-09',?,?,'XS20260907009701'),
                      (?,2,'37900000-0000-4000-8100-000000000001',?,40,DATE '2026-09-07','2026-09',?,?,'XS20260907009701')
                """,voucher,bankStyle,direction,type,receipt,voucher,-direction,type,receipt);
    }

    private static void receipt(Connection c,UUID id,String bill,UUID client,UUID currency,UUID order,int status)throws SQLException {
        execute(c,"""
                INSERT INTO finance_receipts(id,bill_no,bill_date,client_id,currency_id,exchange_rate,
                    amount_original,amount_local,bank_fee,other_fee,status,receipt_kind,sales_order_id,is_deleted)
                VALUES(?,?,DATE '2026-09-07',?,?,1,40,40,0,0,?,'CUSTOMER_PREPAYMENT',?,FALSE)
                """,id,bill,client,currency,status,order);
    }
    private static String snapshot(Connection c,UUID id)throws SQLException {
        return value(c,"SELECT to_jsonb(r)::text FROM finance_receipts r WHERE id=?",id);
    }
    private static void rejected(Connection c,String state,String sql,Object...args)throws SQLException {
        c.setAutoCommit(false);
        try {assertThatThrownBy(()->execute(c,sql,args)).isInstanceOf(SQLException.class)
                .extracting(e->((SQLException)e).getSQLState()).isEqualTo(state);}
        finally {c.rollback();c.setAutoCommit(true);}
    }
    private static void execute(Connection c,String sql,Object...args)throws SQLException {
        try(PreparedStatement s=c.prepareStatement(sql)) {
            for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);
            s.executeUpdate();
        }
    }
    private static String value(Connection c,String sql,Object...args)throws SQLException {
        try(PreparedStatement s=c.prepareStatement(sql)) {
            for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);
            try(var result=s.executeQuery()){assertThat(result.next()).isTrue();return result.getString(1);}
        }
    }
    private static Connection connection(PostgreSQLContainer<?> postgres)throws SQLException {
        return DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());
    }
    private static void migrate(PostgreSQLContainer<?> postgres,String target) {
        Flyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                .locations("classpath:db/migration").target(target).load().migrate();
    }
}
