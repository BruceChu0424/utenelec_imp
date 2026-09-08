package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.sql.*;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinancialActualBankReceiptPostgresTest {
    @Test void actualBankAndThirtyDigitForeignReceiptCommitAndReverseWithoutChangingEitherSnapshot() throws Exception {
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine")) {
            pg.start();
            Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())
                .locations("filesystem:src/main/resources/db/migration","filesystem:../.codex-tmp/valuation-positions",
                    "filesystem:../.codex-tmp/iqc-consideration","filesystem:../.codex-tmp/financial-exact")
                .target("520").load().migrate();
            try(var c=DriverManager.getConnection(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())) {
                UUID client=UUID.randomUUID(),foreign=UUID.randomUUID(),approver=UUID.randomUUID();
                UUID base=UUID.fromString(value(c,"SELECT id::text FROM currencies WHERE is_base_currency AND NOT is_deleted"));
                UUID maker=UUID.fromString(value(c,"SELECT id::text FROM employees WHERE code='ADMIN'"));
                execute(c,"INSERT INTO clients(id,code,name,status,code_sequence,sales_payment_type) VALUES(?,'BANK-ACTUAL-C','实际银行测试','使用',100100,'CASH')",client);
                execute(c,"INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,'BANK-ACTUAL-FX','实际银行外币',7.123456,'使用')",foreign);
                execute(c,"INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,'BANK-ACTUAL-APPROVER','实际银行审核',id_type,department_id,CURRENT_DATE,'active','regular' FROM employees WHERE id=?",approver,maker);
                UUID bank=account(c,base,"CNY"),foreignBank=account(c,foreign,"FX");
                UUID converted=receipt(c,client,maker,bank,base,foreign,"88.1234","7.123456","624.7432","3.0001");
                assertAmount("627.7433",value(c,"SELECT amount_local FROM finance_receipts WHERE id=?",converted));
                assertRejected(c,"UPDATE finance_receipts SET amount_local=round(amount_original*exchange_rate,4) WHERE id=?",converted);
                approve(c,converted,approver);
                assertAmount("624.7432",value(c,"SELECT balance_current FROM accounts WHERE id=?",bank));
                assertEquals("true",value(c,"SELECT is_consistent::text FROM v_receipt_flow_integrity WHERE receipt_id=?",converted));
                assertEquals("true",value(c,"SELECT is_consistent::text FROM v_receipt_gl_integrity WHERE receipt_id=?",converted));
                assertAmount("0",value(c,"SELECT sum(e.amount*e.direction) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_doc_id=?",converted));
                assertRejected(c,"UPDATE finance_receipts SET account_amount=account_amount+0.000000000000000000000001 WHERE id=?",converted);
                reverse(c,converted);
                assertAmount("0",value(c,"SELECT balance_current FROM accounts WHERE id=?",bank));
                assertEquals("true",value(c,"SELECT is_consistent::text FROM v_receipt_flow_integrity WHERE receipt_id=?",converted));
                assertEquals("true",value(c,"SELECT is_consistent::text FROM v_receipt_gl_integrity WHERE receipt_id=?",converted));
                assertAmount("624.7432",value(c,"SELECT account_amount FROM finance_receipts WHERE id=?",converted));

                UUID tiny=receipt(c,client,maker,foreignBank,foreign,foreign,"0.000000000000000000000001","7.000001","0.000000000000000000000001","0");
                assertAmount("0.000000000000000000000007000001",value(c,"SELECT account_amount_local FROM finance_receipts WHERE id=?",tiny));
                assertRejected(c,"UPDATE finance_receipts SET account_amount=0.000000000000000000000002,account_amount_local=0.000000000000000000000014000002,amount_local=0.000000000000000000000014000002 WHERE id=?",tiny);
                approve(c,tiny,approver);
                assertAmount("0.000000000000000000000001",value(c,"SELECT balance_current FROM accounts WHERE id=?",foreignBank));
                assertAmount("0.000000000000000000000007000001",value(c,"SELECT amount_local FROM finance_reconciliations WHERE source_doc_id=? AND entry_kind='POSTING'",tiny));
                reverse(c,tiny);
                assertAmount("0",value(c,"SELECT balance_current FROM accounts WHERE id=?",foreignBank));
                assertEquals("true",value(c,"SELECT is_consistent::text FROM v_receipt_gl_integrity WHERE receipt_id=?",tiny));
                UUID tinyFee=receipt(c,client,maker,foreignBank,foreign,foreign,"0.000000000000000000000003","7.000001","0.000000000000000000000002","0.000000000000000000000001");
                approve(c,tinyFee,approver);
                assertAmount("0.000000000000000000000007000001",value(c,"SELECT bank_fee FROM finance_receipts WHERE id=?",tinyFee));
                assertAmount("0.000000000000000000000002",value(c,"SELECT balance_current FROM accounts WHERE id=?",foreignBank));
                reverse(c,tinyFee);
                assertAmount("0",value(c,"SELECT balance_current FROM accounts WHERE id=?",foreignBank));
                assertEquals("true",value(c,"SELECT is_consistent::text FROM v_receipt_gl_integrity WHERE receipt_id=?",tinyFee));
                System.out.println("V520 actual bank net + deducted fees and 24*6=30-digit foreign account: persisted AR/account/flow/GL, immutable original snapshots and complete reversals passed");
            }
        }
    }
    static UUID account(Connection c,UUID currency,String suffix)throws Exception {
        UUID id=UUID.randomUUID(),style=UUID.randomUUID();
        execute(c,"INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,'ACCOUNT',0,'使用')",style,"BANK-ACTUAL-STYLE-"+suffix,"实际银行科目"+suffix);
        execute(c,"INSERT INTO accounts(id,code,name,currency_id,style_id,status,init_balance,balance_current,receipts_total,payments_total) VALUES(?,?,?,?,?,'使用',0,0,0,0)",id,"BANK-ACTUAL-ACCOUNT-"+suffix,"实际银行"+suffix,currency,style);return id;
    }
    static UUID receipt(Connection c,UUID client,UUID maker,UUID account,UUID accountCurrency,UUID settlementCurrency,String original,String rate,String net,String fee)throws Exception {
        UUID id=UUID.randomUUID();BigDecimal actual=new BigDecimal(net),bankFee=new BigDecimal(fee);
        boolean same=accountCurrency.equals(settlementCurrency);BigDecimal accountRate=same?new BigDecimal(rate):BigDecimal.ONE;
        BigDecimal netLocal=actual.multiply(accountRate),feeLocal=bankFee.multiply(accountRate);
        execute(c,"""
            INSERT INTO finance_receipts(id,bill_no,bill_date,receipt_kind,client_id,account_id,currency_id,
              exchange_rate,amount_original,amount_local,bank_fee,other_fee,status,is_deleted,settlement_authority_version,maker_id,bank_reference,
              create_idempotency_key,create_request_hash,settlement_channel,settlement_rate_quote_direction,exchange_rate_source,
              exchange_rate_effective_at,bank_booked_at,account_currency_id,account_exchange_rate,account_exchange_rate_source,
              account_amount,account_amount_local,bank_fee_account_amount,other_fee_account_amount,fee_settlement_mode,fee_bearer,
              fee_account_currency_id,fee_account_exchange_rate,gl_account_style_id,gl_counter_style_id,gl_bank_fee_style_id)
            SELECT ?, 'XS'||to_char(CURRENT_DATE,'YYYYMMDD')||lpad((SELECT count(*)+1 FROM finance_receipts)::text,6,'0'),CURRENT_DATE,
              'CUSTOMER_PREPAYMENT',?,a.id,?,?::numeric,?::numeric,?::numeric,?::numeric,0,0,FALSE,2,?,'BANK-ACTUAL-REF',?,repeat('a',64),
              'DIRECT_ACCOUNT','BASE_PER_SETTLEMENT','BANK_STATEMENT',now(),now(),?,?::numeric,?,?::numeric,?::numeric,?::numeric,0,?,?,?,?::numeric,
              a.style_id,system_posting_style_id('CUSTOMER_ADVANCE'),CASE WHEN ?::numeric>0 THEN system_posting_style_id('BANK_FEE_EXPENSE') ELSE NULL END
            FROM accounts a WHERE a.id=?
            """,id,client,settlementCurrency,rate,original,netLocal.add(feeLocal),feeLocal,maker,"bank-actual-"+id,
            accountCurrency,accountRate,same?"SETTLEMENT_RATE":"BASE_CURRENCY_IDENTITY",actual,netLocal,bankFee,
            bankFee.signum()==0?"NONE":"DEDUCTED_FROM_PROCEEDS",bankFee.signum()==0?"NONE":"COMPANY",accountCurrency,accountRate,feeLocal,account);
        return id;
    }
    static void approve(Connection c,UUID id,UUID approver)throws Exception {
        c.setAutoCommit(false);
        try {
            execute(c,"UPDATE finance_receipts SET status=1,approver_id=? WHERE id=?",approver,id);
            execute(c,"""
                INSERT INTO ar_ap_ledger(id,direction,source_doc_type,source_doc_id,source_doc_no,bill_no,bill_date,client_id,currency_id,
                  exchange_rate,amount_original,amount_original_local,amount_received_original,amount_received_local,
                  amount_write_off_original,amount_write_off_local,amount_balance_original,amount_settled,amount_balance,status,is_settled)
                SELECT gen_random_uuid(),'AR','DIRECT_RECEIPT',id,bill_no,bill_no,bill_date,client_id,currency_id,exchange_rate,
                  0,0,amount_original,amount_local,0,0,-amount_original,amount_local,-amount_local,1,FALSE FROM finance_receipts WHERE id=?
                """,id);
            execute(c,"UPDATE accounts a SET balance_current=balance_current+r.account_amount,receipts_total=receipts_total+r.account_amount FROM finance_receipts r WHERE r.id=? AND a.id=r.account_id",id);
            execute(c,"""
                INSERT INTO finance_reconciliations(bill_no,source_doc_type,source_doc_id,account_id,account_currency_id,in_amount,out_amount,amount_local,bill_date,settled_date,entry_kind)
                SELECT bill_no,'RECEIPT',id,account_id,account_currency_id,account_amount,0,account_amount_local,bank_booked_at,now(),'POSTING'
                FROM finance_receipts WHERE id=?
                """,id);
            UUID voucher=UUID.randomUUID();
            execute(c,"INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,source_doc_id,status) SELECT ?,bill_no,to_char(bill_date,'YYYY-MM'),bill_date,'AUTO','RECEIPT',id,0 FROM finance_receipts WHERE id=?",voucher,id);
            execute(c,"""
                INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,source_doc_type,source_doc_id,source_bill_no)
                SELECT ?,e.line_no,e.style_id,e.direction,e.amount,r.bill_date,to_char(r.bill_date,'YYYY-MM'),'RECEIPT',r.id,r.bill_no
                FROM v_receipt_expected_gl_entries e JOIN finance_receipts r ON r.id=e.receipt_id WHERE r.id=?
                """,voucher,id);
            execute(c,"UPDATE gl_vouchers SET status=1 WHERE id=?",voucher);c.commit();
        } catch(Exception e){c.rollback();throw e;} finally {c.setAutoCommit(true);}
    }
    static void reverse(Connection c,UUID id)throws Exception {
        c.setAutoCommit(false);
        try {
            UUID original=UUID.fromString(value(c,"SELECT id::text FROM gl_vouchers WHERE source_type='RECEIPT' AND source_doc_id=?",id)),reversal=UUID.randomUUID();
            execute(c,"INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,source_doc_id,source_ref,idempotency_key,reversal_of_voucher_id,status) SELECT ?,bill_no||'-REV',to_char(now() AT TIME ZONE 'Asia/Shanghai','YYYY-MM'),(now() AT TIME ZONE 'Asia/Shanghai')::date,'AUTO','RECEIPT_REV',id,id::text,'RECEIPT_REV:'||id,?,0 FROM finance_receipts WHERE id=?",reversal,original,id);
            execute(c,"INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,source_doc_type,source_doc_id,source_bill_no) SELECT ?,line_no,style_id,-direction,amount,(now() AT TIME ZONE 'Asia/Shanghai')::date,to_char(now() AT TIME ZONE 'Asia/Shanghai','YYYY-MM'),'RECEIPT_REV',source_doc_id,source_bill_no FROM gl_entries WHERE voucher_id=?",reversal,original);
            execute(c,"UPDATE gl_vouchers SET status=1 WHERE id=?",reversal);
            execute(c,"UPDATE gl_vouchers SET reversed_by_voucher_id=? WHERE id=?",reversal,original);
            execute(c,"UPDATE finance_receipts SET status=-1,reversed_at=now() WHERE id=?",id);
            execute(c,"UPDATE ar_ap_ledger SET status=-1,is_deleted=TRUE,deleted_at=now() WHERE source_doc_type='DIRECT_RECEIPT' AND source_doc_id=?",id);
            execute(c,"UPDATE accounts a SET balance_current=balance_current-r.account_amount,receipts_total=receipts_total-r.account_amount FROM finance_receipts r WHERE r.id=? AND a.id=r.account_id",id);
            execute(c,"""
                INSERT INTO finance_reconciliations(bill_no,source_doc_type,source_doc_id,account_id,account_currency_id,in_amount,out_amount,amount_local,bill_date,settled_date,entry_kind,reversal_of_id,reversal_reason)
                SELECT p.bill_no,p.source_doc_type,p.source_doc_id,p.account_id,p.account_currency_id,p.out_amount,p.in_amount,p.amount_local,r.reversed_at,now(),'REVERSAL',p.id,'实际银行反向'
                FROM finance_reconciliations p JOIN finance_receipts r ON r.id=p.source_doc_id WHERE r.id=? AND p.entry_kind='POSTING'
                """,id);c.commit();
        } catch(Exception e){c.rollback();throw e;} finally {c.setAutoCommit(true);}
    }
    static void assertRejected(Connection c,String sql,Object...args)throws Exception {assertThrows(SQLException.class,()->execute(c,sql,args));}
    static void assertAmount(String expected,String actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(new BigDecimal(actual)));}
    static void execute(Connection c,String sql,Object...args)throws SQLException{try(var s=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);s.execute();}}
    static String value(Connection c,String sql,Object...args)throws SQLException{try(var s=c.prepareStatement(sql)){for(int i=0;i<args.length;i++)s.setObject(i+1,args[i]);try(var r=s.executeQuery()){return r.next()?r.getString(1):null;}}}
}
