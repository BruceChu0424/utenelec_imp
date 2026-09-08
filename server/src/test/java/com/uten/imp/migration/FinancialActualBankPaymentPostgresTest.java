package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.sql.*;
import java.time.OffsetDateTime;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import static org.junit.jupiter.api.Assertions.*;
import static com.uten.imp.migration.FinancialActualBankReceiptPostgresTest.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinancialActualBankPaymentPostgresTest {
    private static final AtomicInteger SEQUENCE=new AtomicInteger();
    @Test void actualDebitFeeBookFxAndMultiplePayablesAreConservedAndAppendExactReversals() throws Exception {
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine")) {
            pg.start();migrate(pg,"508");Fixture f;
            try(var c=connect(pg)){f=seedPayables(c);}
            migrate(pg,"523");
            try(var c=connect(pg)) {
                UUID baseBank=bank(c,f.base(),"BASE"),foreignBank=bank(c,f.currency(),"FOREIGN");
                verifyExpenseAndIncomeItemPrecision(c,f,baseBank);
                UUID payment=draft(c,f,baseBank,BigDecimal.ONE,new BigDecimal("7.2"),new BigDecimal("327.8885"),new BigDecimal("3"),
                    List.of(new Part(f.sources().get(0),new BigDecimal("50.1234"))));
                assertRejected(c,"UPDATE finance_payments SET status=1,approver_id=? WHERE id=?",f.approver(),payment);
                assertAmount("0",value(c,"SELECT amount_received_original FROM ar_ap_ledger WHERE id=?",f.sources().getFirst()));
                approvePayment(c,f,payment);
                assertAmount("672.1115",value(c,"SELECT balance_current FROM accounts WHERE id=?",baseBank));
                assertAmount("324.8885",value(c,"SELECT amount_received_local FROM ar_ap_ledger WHERE id=?",f.sources().getFirst()));
                assertAmount("350.8638",value(c,"SELECT amount_settled FROM ar_ap_ledger WHERE id=?",f.sources().getFirst()));
                assertAmount("-25.9753",value(c,"SELECT exchange_diff FROM finance_payment_lines WHERE payment_id=?",payment));
                assertAmount("0",value(c,"SELECT sum(e.direction*e.amount) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_doc_id=?",payment));
                assertRejected(c,"SELECT fn_post_payment_v2_gl(?)",payment);
                assertRejected(c,"UPDATE finance_payments SET account_amount=NULL WHERE id=?",payment);
                assertRejected(c,"UPDATE gl_entries SET amount=amount+1e-30::numeric WHERE source_doc_id=?",payment);
                UUID otherDraft=draft(c,f,baseBank,BigDecimal.ONE,new BigDecimal("7.2"),new BigDecimal("7.2"),BigDecimal.ZERO,
                    List.of(new Part(f.sources().get(1),BigDecimal.ONE)));
                assertRejected(c,"UPDATE finance_payment_lines SET payment_id=? WHERE payment_id=?",otherDraft,payment);
                UUID manual=UUID.randomUUID();
                execute(c,"INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,status) VALUES(?,'V523-MOVE-PROBE','2026-09',DATE '2026-09-07','MANUAL',0)",manual);
                assertRejected(c,"UPDATE gl_entries SET voucher_id=? WHERE source_doc_id=?",manual,payment);
                reversePayment(c,payment);
                assertAmount("1000",value(c,"SELECT balance_current FROM accounts WHERE id=?",baseBank));
                assertAmount("100",value(c,"SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",f.sources().getFirst()));
                assertAmount("700",value(c,"SELECT amount_balance FROM ar_ap_ledger WHERE id=?",f.sources().getFirst()));
                assertAmount("327.8885",value(c,"SELECT account_amount FROM finance_payments WHERE id=?",payment));

                BigDecimal tiny=new BigDecimal("1e-24"),rate=new BigDecimal("7.000001");
                assertThrows(SQLException.class,()->draft(c,f,foreignBank,rate,rate,tiny.multiply(new BigDecimal("2")),BigDecimal.ZERO,List.of(new Part(f.sources().get(1),tiny))));
                UUID small=draft(c,f,foreignBank,rate,rate,tiny.multiply(new BigDecimal("2")),tiny,List.of(new Part(f.sources().get(1),tiny)));
                approvePayment(c,f,small);
                assertAmount("0.000000000000000000000014000002",value(c,"SELECT account_amount_local FROM finance_payments WHERE id=?",small));
                assertAmount("0.000000000000000000000007000001",value(c,"SELECT bank_fee_local FROM finance_payments WHERE id=?",small));
                assertAmount("0.000000000000000000000000000001",value(c,"SELECT exchange_diff FROM finance_payment_lines WHERE payment_id=?",small));
                reversePayment(c,small);assertAmount("1000",value(c,"SELECT balance_current FROM accounts WHERE id=?",foreignBank));

                UUID multiple=draft(c,f,baseBank,BigDecimal.ONE,new BigDecimal("3.333333"),BigDecimal.TEN,BigDecimal.ZERO,
                    List.of(new Part(f.sources().getFirst(),BigDecimal.ONE),new Part(f.sources().get(2),new BigDecimal("2"))));
                assertAmount("3.333333333333333333333333333333",value(c,"SELECT amount_local FROM finance_payment_lines WHERE payment_id=? AND line_no=1",multiple));
                assertAmount("6.666666666666666666666666666667",value(c,"SELECT amount_local FROM finance_payment_lines WHERE payment_id=? AND line_no=2",multiple));
                approvePayment(c,f,multiple);execute(c,"SELECT fn_assert_payment_v2_terminal(?)",multiple);
                reversePayment(c,multiple);assertAmount("1000",value(c,"SELECT balance_current FROM accounts WHERE id=?",baseBank));
                assertAmount("0",value(c,"SELECT sum(in_amount-out_amount) FROM finance_reconciliations WHERE source_doc_type='PAYMENT'"));
                assertEquals("6",value(c,"SELECT count(*) FROM gl_vouchers WHERE source_type IN('PAYMENT','PAYMENT_REV') AND status=1"));
                System.out.println("V523 actual payment: base bank 327.8885 incl fee3, foreign 24*6=30-digit debit/fee/FX, two-payable 1/3 bank remainder, AP/account/flow/GL commit, guards and original-amount reversals passed");
            }
        }
    }
    private static UUID draft(Connection c,Fixture f,UUID account,BigDecimal accountRate,BigDecimal quote,BigDecimal debit,BigDecimal fee,List<Part> requested)throws Exception {
        UUID id=UUID.randomUUID();String bill="CF20260907%06d".formatted(SEQUENCE.incrementAndGet());
        UUID accountCurrency=UUID.fromString(value(c,"SELECT currency_id FROM accounts WHERE id=?",account));
        BigDecimal original=requested.stream().map(Part::amount).reduce(BigDecimal.ZERO,BigDecimal::add);
        BigDecimal net=debit.subtract(fee).multiply(accountRate),beforeA=original,beforeB=net,fx=BigDecimal.ZERO;
        List<Planned> plans=new ArrayList<>();
        for(Part part:requested) {
            BigDecimal sourceA=new BigDecimal(value(c,"SELECT amount_balance_original FROM ar_ap_ledger WHERE id=?",part.source()));
            BigDecimal sourceB=new BigDecimal(value(c,"SELECT amount_balance FROM ar_ap_ledger WHERE id=?",part.source()));
            BigDecimal book=new BigDecimal(value(c,"SELECT fn_financial_book_part(?::numeric,?::numeric,?::numeric)",part.amount(),sourceA,sourceB));
            BigDecimal cash=new BigDecimal(value(c,"SELECT fn_financial_book_part(?::numeric,?::numeric,?::numeric)",part.amount(),beforeA,beforeB));
            plans.add(new Planned(part,beforeA,beforeB,cash,sourceA,sourceB,book));beforeA=beforeA.subtract(part.amount());beforeB=beforeB.subtract(cash);fx=fx.add(cash.subtract(book));
        }
        c.setAutoCommit(false);
        try {
            execute(c,"""
                INSERT INTO finance_payments(id,bill_no,bill_date,supplier_id,account_id,currency_id,exchange_rate,
                  amount_original,amount_local,amount_authority_version,maker_id,status,create_idempotency_key,create_request_hash,
                  account_currency_id,account_exchange_rate,account_amount,account_amount_local,bank_fee_account_amount,bank_fee_local,
                  bank_reference,bank_booked_at,gl_account_style_id,gl_ap_style_id,gl_fx_style_id,gl_bank_fee_style_id)
                SELECT ?,?,DATE '2026-09-07',?,a.id,?,?::numeric,?::numeric,?::numeric,2,?,0,?,repeat('b',64),
                  ?,?::numeric,?::numeric,?::numeric,?::numeric,?::numeric,'BANK-ACTUAL-PAYMENT',now(),a.style_id,
                  system_posting_style_id('AP_CONTROL'),CASE WHEN ?::numeric<>0 THEN system_posting_style_id('FX_GAIN_LOSS') END,
                  CASE WHEN ?::numeric>0 THEN system_posting_style_id('BANK_FEE_EXPENSE') END FROM accounts a WHERE a.id=?
                """,id,bill,f.supplier(),f.currency(),quote,original,net,f.maker(),"actual-payment-"+id,
                accountCurrency,accountRate,debit,debit.multiply(accountRate),fee,fee.multiply(accountRate),fx,fee,account);
            int seq=0;
            for(Planned p:plans) execute(c,"""
                INSERT INTO finance_payment_lines(payment_id,bill_no,bill_date,line_no,applied_ledger_id,applied_bill_no,supplier_id,
                  amount_original,amount_local,exchange_diff,cash_rate,recognition_rate,applied_amount_local,
                  balance_before_original,balance_after_original,bank_basis_before_original,bank_basis_before_local,
                  bank_basis_after_original,bank_basis_after_local,book_balance_before_local,book_balance_after_local)
                SELECT ?,?,DATE '2026-09-07',?,ledger.id,ledger.bill_no,ledger.supplier_id,?::numeric,?::numeric,?::numeric,?::numeric,
                  ledger.exchange_rate,?::numeric,?::numeric,?::numeric,?::numeric,?::numeric,?::numeric,?::numeric,?::numeric,?::numeric
                FROM ar_ap_ledger ledger WHERE id=?
                """,id,bill,++seq,p.part().amount(),p.cash(),p.cash().subtract(p.book()),quote,p.book(),p.sourceA(),p.sourceA().subtract(p.part().amount()),
                p.beforeA(),p.beforeB(),p.beforeA().subtract(p.part().amount()),p.beforeB().subtract(p.cash()),p.sourceB(),p.sourceB().subtract(p.book()),p.part().source());
            c.commit();return id;
        }catch(Exception e){c.rollback();throw e;}finally{c.setAutoCommit(true);}
    }
    private static void approvePayment(Connection c,Fixture f,UUID id)throws Exception {
        c.setAutoCommit(false);
        try {
            execute(c,"UPDATE finance_payments SET status=1,approver_id=? WHERE id=?",f.approver(),id);
            execute(c,"""
                UPDATE ar_ap_ledger ledger SET amount_received_original=ledger.amount_received_original+line.amount_original,
                  amount_received_local=ledger.amount_received_local+line.amount_local,amount_settled=ledger.amount_settled+line.applied_amount_local,
                  amount_balance_original=ledger.amount_balance_original-line.amount_original,amount_balance=ledger.amount_balance-line.applied_amount_local,
                  is_settled=(ledger.amount_balance_original=line.amount_original AND ledger.amount_balance=line.applied_amount_local),
                  settled_date=CASE WHEN ledger.amount_balance_original=line.amount_original AND ledger.amount_balance=line.applied_amount_local THEN CURRENT_DATE END
                FROM finance_payment_lines line WHERE line.payment_id=? AND ledger.id=line.applied_ledger_id
                """,id);
            execute(c,"UPDATE accounts a SET balance_current=a.balance_current-p.account_amount,payments_total=a.payments_total+p.account_amount FROM finance_payments p WHERE p.id=? AND a.id=p.account_id",id);
            execute(c,"INSERT INTO finance_reconciliations(bill_no,source_doc_type,source_doc_id,account_id,account_currency_id,in_amount,out_amount,amount_local,bill_date,settled_date,entry_kind) SELECT bill_no,'PAYMENT',id,account_id,account_currency_id,0,account_amount,account_amount_local,bank_booked_at,now(),'POSTING' FROM finance_payments WHERE id=?",id);
            execute(c,"SELECT fn_post_payment_v2_gl(?)",id);c.commit();
        }catch(Exception e){c.rollback();throw e;}finally{c.setAutoCommit(true);}
    }
    private static void reversePayment(Connection c,UUID id)throws Exception {
        c.setAutoCommit(false);
        try {
            OffsetDateTime at;
            try(var s=c.createStatement();var r=s.executeQuery("SELECT now()")){r.next();at=r.getObject(1,OffsetDateTime.class);}
            execute(c,"SELECT fn_reverse_payment_v2_gl(?,?)",id,at);
            execute(c,"UPDATE finance_payments SET status=-1,reversed_at=? WHERE id=?",at,id);
            execute(c,"""
                UPDATE ar_ap_ledger ledger SET amount_received_original=ledger.amount_received_original-line.amount_original,
                  amount_received_local=ledger.amount_received_local-line.amount_local,amount_settled=ledger.amount_settled-line.applied_amount_local,
                  amount_balance_original=ledger.amount_balance_original+line.amount_original,amount_balance=ledger.amount_balance+line.applied_amount_local,
                  is_settled=FALSE,settled_date=NULL FROM finance_payment_lines line WHERE line.payment_id=? AND ledger.id=line.applied_ledger_id
                """,id);
            execute(c,"UPDATE accounts a SET balance_current=a.balance_current+p.account_amount,payments_total=a.payments_total-p.account_amount FROM finance_payments p WHERE p.id=? AND a.id=p.account_id",id);
            execute(c,"INSERT INTO finance_reconciliations(bill_no,source_doc_type,source_doc_id,account_id,account_currency_id,in_amount,out_amount,amount_local,bill_date,settled_date,entry_kind,reversal_of_id,reversal_reason) SELECT f.bill_no,f.source_doc_type,f.source_doc_id,f.account_id,f.account_currency_id,f.out_amount,f.in_amount,f.amount_local,p.reversed_at,now(),'REVERSAL',f.id,'actual bank payment reversal' FROM finance_reconciliations f JOIN finance_payments p ON p.id=f.source_doc_id WHERE p.id=? AND f.entry_kind='POSTING'",id);
            c.commit();execute(c,"SELECT fn_assert_payment_v2_terminal(?)",id);
        }catch(Exception e){c.rollback();throw e;}finally{c.setAutoCommit(true);}
    }
    private static UUID bank(Connection c,UUID currency,String suffix)throws Exception {
        UUID id=UUID.randomUUID(),style=UUID.randomUUID();
        execute(c,"INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,'ACCOUNT',0,'使用')",style,"ACTUAL-PAYMENT-STYLE-"+suffix,"actual payment style "+suffix);
        execute(c,"INSERT INTO accounts(id,code,name,currency_id,style_id,status,init_balance,balance_current,receipts_total,payments_total) VALUES(?,?,?,?,?,'使用',1000,1000,0,0)",id,"ACTUAL-PAYMENT-ACCOUNT-"+suffix,"actual payment bank "+suffix,currency,style);return id;
    }
    private static void verifyExpenseAndIncomeItemPrecision(Connection c,Fixture f,UUID account)throws Exception {
        UUID incomeStyle=UUID.randomUUID();
        execute(c,"INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,'V523-EXACT-INCOME','exact income','INCOME',0,'使用')",incomeStyle);
        for(String kind:List.of("expense","income")) {
            String header=kind.equals("expense")?"finance_expenses":"finance_other_incomes";
            String items=kind.equals("expense")?"finance_expense_items":"finance_other_income_items";
            String parent=kind.equals("expense")?"expense_id":"income_id",styleColumn=kind.equals("expense")?"expense_style_id":"income_style_id";
            UUID style=kind.equals("expense")?UUID.fromString(value(c,"SELECT system_posting_style_id('BANK_FEE_EXPENSE')")):incomeStyle;
            int seq=0;
            for(String actual:List.of("0.000000000000000000000001","0.0000000001")) {
                UUID id=UUID.randomUUID(),item=UUID.randomUUID();BigDecimal amount=new BigDecimal(actual),local=amount.multiply(new BigDecimal("7.000001"));
                String bill=(kind.equals("expense")?"YF":"QS")+"20260907"+String.format("%06d",700+ ++seq);
                execute(c,"INSERT INTO "+header+"(id,bill_no,bill_date,account_id,currency_id,exchange_rate,amount_original,amount_local,status,maker_id) VALUES(?,?,DATE '2026-09-07',?,?,7.000001,?::numeric,?::numeric,0,?)",id,bill,account,f.currency(),amount,local,f.maker());
                execute(c,"INSERT INTO "+items+"(id,"+parent+",bill_no,bill_date,"+styleColumn+",line_no,qty,price,amount_original,amount_local) VALUES(?,?,?,DATE '2026-09-07',?,1,1,?::numeric,?::numeric,?::numeric)",item,id,bill,style,seq==2?amount:null,amount,local);
                assertAmount(actual,value(c,"SELECT amount_original FROM "+items+" WHERE id=?",item));
                assertAmount(local.toPlainString(),value(c,"SELECT amount_local FROM "+items+" WHERE id=?",item));
                if(seq==2)assertAmount(actual,value(c,"SELECT price FROM "+items+" WHERE id=?",item));
                assertRejected(c,"UPDATE "+items+" SET amount_original=1e-25::numeric WHERE id=?",item);
            }
        }
    }
    private static Fixture seedPayables(Connection c)throws Exception {
        UUID supplier=UUID.randomUUID(),currency=UUID.randomUUID(),approver=UUID.randomUUID();
        UUID maker=UUID.fromString(value(c,"SELECT id FROM employees WHERE code='ADMIN'")),base=UUID.fromString(value(c,"SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted"));
        UUID unit=UUID.randomUUID(),goods=UUID.randomUUID(),warehouse=UUID.randomUUID();List<UUID> sources=new ArrayList<>();
        c.setAutoCommit(false);
        try {
            execute(c,"INSERT INTO suppliers(id,code,name,status,code_sequence) VALUES(?,'ACTUAL-PAY-SUPPLIER','actual payment supplier','使用',100500)",supplier);
            execute(c,"INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,'ACTUAL-PAY-CURRENCY','actual payment currency',7,'使用')",currency);
            execute(c,"INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,'ACTUAL-PAY-APPROVER','actual payment approver',id_type,department_id,CURRENT_DATE,'active','regular' FROM employees WHERE id=?",approver,maker);
            execute(c,"INSERT INTO units(id,code,name) VALUES(?,'ACTUAL-PAY-UNIT','piece')",unit);
            execute(c,"INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES(?,'ACTUAL-PAY-GOODS','actual payment goods',?,100500)",goods,unit);
            execute(c,"INSERT INTO warehouses(id,code,name) VALUES(?,'ACTUAL-PAY-WH','actual payment warehouse')",warehouse);
            int index=0;
            for(String original:List.of("100","1","2")) {
                UUID receipt=UUID.randomUUID(),ledger=UUID.randomUUID();String bill="CJ20260907%06d".formatted(500+ ++index);BigDecimal a=new BigDecimal(original),b=a.multiply(new BigDecimal("7"));
                execute(c,"INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,currency_id,exchange_rate,total_original,total_local,warehouse_id,status) VALUES(?,?,DATE '2026-09-07',?,?,7,?::numeric,?::numeric,?,1)",receipt,bill,supplier,currency,a,b,warehouse);
                execute(c,"INSERT INTO purchase_receipt_items(id,bill_no,bill_date,receipt_id,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,goods_snapshot_source) VALUES(?,?,DATE '2026-09-07',?,?,?,1,?::numeric,1,?::numeric,?::numeric,'MASTER_AT_SAVE')",UUID.randomUUID(),bill,receipt,goods,unit,a,a,b);
                execute(c,"INSERT INTO ar_ap_ledger(id,direction,source_doc_type,source_doc_id,source_doc_no,bill_no,bill_date,supplier_id,currency_id,exchange_rate,amount_original,amount_original_local,amount_balance_original,amount_balance,amount_received_original,amount_received_local,amount_write_off_original,amount_write_off_local,status,is_settled) VALUES(?,'AP','PURCHASE_RECEIPT',?,?,?,DATE '2026-09-07',?,?,7,?::numeric,?::numeric,?::numeric,?::numeric,0,0,0,0,1,FALSE)",ledger,receipt,bill,bill,supplier,currency,a,b,a,b);sources.add(ledger);
            }
            c.commit();return new Fixture(supplier,currency,base,maker,approver,List.copyOf(sources));
        }catch(Exception e){c.rollback();throw e;}finally{c.setAutoCommit(true);}
    }
    private record Fixture(UUID supplier,UUID currency,UUID base,UUID maker,UUID approver,List<UUID> sources){}
    private record Part(UUID source,BigDecimal amount){}
    private record Planned(Part part,BigDecimal beforeA,BigDecimal beforeB,BigDecimal cash,BigDecimal sourceA,BigDecimal sourceB,BigDecimal book){}
    private static Connection connect(PostgreSQLContainer<?> pg)throws SQLException{return DriverManager.getConnection(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword());}
    private static void migrate(PostgreSQLContainer<?> pg,String target){Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("filesystem:src/main/resources/db/migration","filesystem:../.codex-tmp/valuation-positions","filesystem:../.codex-tmp/iqc-consideration","filesystem:../.codex-tmp/financial-exact","filesystem:../.codex-tmp/financial-payment").target(target).load().migrate();}
}
