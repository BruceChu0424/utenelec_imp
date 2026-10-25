package com.uten.imp.migration;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;

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
    void v498ToV499PreservesApprovedMoneyAndAllowsACompleteHistoricalOrderReversal() throws Exception {
        try(var postgres=new PostgreSQLContainer("postgres:16.15-alpine")
                .withDatabaseName("uten_advance_reversal").withUsername("fixture_admin").withPassword("uten")) {
            postgres.start();
            // V425 is reached only as part of this genuinely fresh initialization.
            migrate(postgres,"498");
            UUID client=UUID.randomUUID(),order=UUID.randomUUID();
            UUID approved=UUID.randomUUID(),draft=UUID.randomUUID(),unbound=UUID.randomUUID();
            UUID bankStyle=UUID.randomUUID(),account=UUID.randomUUID(),approver=UUID.randomUUID();
            UUID currency,maker,originalVoucher;
            try(Connection c=connection(postgres)) {
                currency=UUID.fromString(value(c,"SELECT id::text FROM currencies WHERE is_base_currency"));
                maker=UUID.fromString(value(c,"SELECT id::text FROM employees WHERE code='ADMIN'"));
                execute(c,"INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,'ADV-REV-APPROVER','Advance reversal approver',id_type,department_id,CURRENT_DATE,'active','regular' FROM employees WHERE id=?",approver,maker);
                execute(c,"INSERT INTO clients(id,code,name,status,code_sequence,sales_payment_type) VALUES(?,'ADV-REV','Advance reversal','使用',2,'CASH')",client);
                execute(c,"INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,'ADV-REV-BANK','Actual bank','ACCOUNT',0,'使用')",bankStyle);
                execute(c,"INSERT INTO accounts(id,code,name,currency_id,style_id,status,init_balance,balance_current,receipts_total,payments_total) VALUES(?,'ADV-REV-ACCOUNT','Actual account',?,?,'使用',0,0,0,0)",account,currency,bankStyle);
                execute(c,"""
                        INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,total_original,status,
                            is_closed,is_stopped,shipment_policy)
                        VALUES(?,'XD20260907009701',DATE '2026-09-07',?,?,100,1,FALSE,FALSE,'ALLOW_PARTIAL')
                        """,order,client,currency);
                nativeReceipt(c,approved,"XS20260907009701",client,currency,order,maker,account);
                nativeReceipt(c,draft,"XS20260907009702",client,currency,order,maker,account);
                nativeReceipt(c,unbound,"XS20260907009703",client,currency,null,maker,account);
                // Use the real account/AR/GL posting fixture, not a fabricated V0 voucher.
                FinancialActualBankReceiptPostgresTest.approve(c,approved,approver);
                originalVoucher=UUID.fromString(value(c,"SELECT id::text FROM gl_vouchers WHERE source_type='RECEIPT' AND source_doc_id=?",approved));
                execute(c,"UPDATE sales_orders SET is_closed=TRUE WHERE id=?",order);
                rejected(c,"23514","UPDATE finance_receipts SET sales_order_id=sales_order_id,status=-1,reversed_at=now() WHERE id=?",approved);
            }
            String before;
            try(Connection c=connection(postgres)){before=snapshot(c,approved);}
            migrate(postgres,"499");
            try(Connection c=connection(postgres)) {
                assertThat(snapshot(c,approved)).isEqualTo(before);
                rejected(c,"23514","UPDATE finance_receipts SET status=1 WHERE id=?",draft);
                rejected(c,"23514","UPDATE finance_receipts SET sales_order_id=? WHERE id=?",order,unbound);
                UUID finalCurrency=currency,finalMaker=maker;
                assertThatThrownBy(()->nativeReceipt(c,UUID.randomUUID(),"XS20260907009704",client,finalCurrency,order,finalMaker,account))
                        .isInstanceOf(SQLException.class).extracting(e->((SQLException)e).getSQLState()).isEqualTo("23514");
                FinancialActualBankReceiptPostgresTest.reverse(c,approved);
                assertThat(value(c,"SELECT status FROM finance_receipts WHERE id=?",approved)).isEqualTo("-1");
                assertThat(value(c,"SELECT COUNT(*) FROM gl_entries WHERE voucher_id=? OR voucher_id IN(SELECT id FROM gl_vouchers WHERE reversal_of_voucher_id=?)",originalVoucher,originalVoucher)).isEqualTo("4");
                assertThat(value(c,"SELECT amount_original FROM finance_receipts WHERE id=?",approved)).isEqualTo("40.0000");
                assertThat(value(c,"SELECT is_consistent::text FROM v_receipt_gl_integrity WHERE receipt_id=?",approved)).isEqualTo("true");
                assertThat(value(c,"SELECT is_consistent::text FROM v_receipt_flow_integrity WHERE receipt_id=?",approved)).isEqualTo("true");
                rejected(c,"55000","UPDATE finance_receipts SET amount_original=41 WHERE id=?",approved);
                execute(c,"UPDATE sales_orders SET is_closed=FALSE WHERE id=?",order);
                FinancialActualBankReceiptPostgresTest.approve(c,draft,approver);
                assertThat(value(c,"SELECT status FROM finance_receipts WHERE id=?",draft)).isEqualTo("1");
            }
        }
    }

    @Test
    void preV407MoneyAndGlArePreservedWhenTheHistoricalChainRefusesV425() throws Exception {
        try(var postgres=new PostgreSQLContainer("postgres:16.15-alpine")
                .withDatabaseName("uten_advance_old_money").withUsername("fixture_admin").withPassword("uten")) {
            postgres.start();migrate(postgres,"406");
            UUID client=UUID.randomUUID(),currency=UUID.randomUUID(),order=UUID.randomUUID();
            UUID approved=UUID.randomUUID(),voucher=UUID.randomUUID(),bankStyle=UUID.randomUUID();
            try(Connection c=connection(postgres)) {
                execute(c,"INSERT INTO clients(id,code,name,status,code_sequence) VALUES(?,'ADV-OLD','Old advance','使用',2)",client);
                execute(c,"INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,'ADV-OLD-CNY','Old advance',1,'使用')",currency);
                execute(c,"INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,total_original,status,is_closed,is_stopped,shipment_policy) VALUES(?,'XD20260907009701',DATE '2026-09-07',?,?,100,1,FALSE,FALSE,'ALLOW_PARTIAL')",order,client,currency);
                legacyReceipt(c,approved,"XS20260907009701",client,currency,order,1);
                execute(c,"INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,'ADV-OLD-BANK','Historical bank','ACCOUNT',0,'使用')",bankStyle);
                voucher(c,voucher,approved,"RECEIPT",null,1);entries(c,voucher,approved,"RECEIPT",bankStyle,1);
            }
            migrate(postgres,"424");
            try(Connection c=connection(postgres)) {
                String before=preservedHistory(c);
                assertThatThrownBy(()->migrate(postgres,"425"))
                        .isInstanceOf(org.flywaydb.core.api.FlywayException.class)
                        .hasStackTraceContaining("V425 audit fresh-start is allowed only");
                assertThat(preservedHistory(c)).isEqualTo(before);
                assertThat(value(c,"SELECT amount_original FROM finance_receipts WHERE id=?",approved)).isEqualTo("40.0000");
                assertThat(value(c,"SELECT max(version::integer) FROM flyway_schema_history WHERE success")).isEqualTo("424");
            }
        }
    }

    private static String preservedHistory(Connection c)throws SQLException {
        return value(c,"""
                SELECT jsonb_build_object(
                    'receipts',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM finance_receipts r),
                    'vouchers',(SELECT jsonb_agg(to_jsonb(v) ORDER BY id) FROM gl_vouchers v),
                    'entries',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM gl_entries e),
                    'audit',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM audit_log a))::text
                """);
    }

    private static void nativeReceipt(Connection c,UUID id,String bill,UUID client,UUID currency,
            UUID order,UUID maker,UUID account)throws SQLException {
        execute(c,"""
                INSERT INTO finance_receipts(id,bill_no,bill_date,receipt_kind,sales_order_id,client_id,currency_id,account_id,
                    exchange_rate,amount_original,amount_local,bank_fee,other_fee,status,is_deleted,settlement_authority_version,maker_id,bank_reference,
                    create_idempotency_key,create_request_hash,settlement_channel,settlement_rate_quote_direction,exchange_rate_source,
                    exchange_rate_effective_at,bank_booked_at,account_currency_id,account_exchange_rate,account_exchange_rate_source,
                    account_amount,account_amount_local,bank_fee_account_amount,other_fee_account_amount,fee_settlement_mode,fee_bearer,
                    fee_account_currency_id,fee_account_exchange_rate,gl_account_style_id,gl_counter_style_id)
                SELECT ?,?,DATE '2026-09-07','CUSTOMER_PREPAYMENT',?,?,?,a.id,
                    1,40,40,0,0,0,FALSE,1,?,'ADV-REV-EXACT-BANK',?,repeat('a',64),
                    'DIRECT_ACCOUNT','BASE_PER_SETTLEMENT','BANK_STATEMENT',now(),now(),a.currency_id,1,'BASE_CURRENCY_IDENTITY',
                    40,40,0,0,'NONE','NONE',a.currency_id,1,a.style_id,system_posting_style_id('CUSTOMER_ADVANCE')
                FROM accounts a WHERE a.id=?
                """,id,bill,order,client,currency,maker,"advance-reversal-"+id,account);
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

    private static void legacyReceipt(Connection c,UUID id,String bill,UUID client,UUID currency,UUID order,int status)throws SQLException {
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
    private static Connection connection(PostgreSQLContainer postgres)throws SQLException {
        return DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());
    }
    private static void migrate(PostgreSQLContainer postgres,String target) {
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                .locations("classpath:db/migration").target(target).load().migrate();
    }
}
