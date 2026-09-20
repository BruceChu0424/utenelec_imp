package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.support.MigratedProjectionSchema;
import org.hibernate.Session;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Executes real report SQL using complete migrated table shapes, not business-guard substitutes. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceLegacyOpeningStatementPostgresTest {
    static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    static final String[] TABLES={"currencies","clients","suppliers","ar_ap_ledger","legacy_finance_import_sources",
            "finance_receipts","finance_receipt_lines","finance_payments","finance_payment_lines",
            "customer_open_item_offset_batches","customer_open_item_offsets","supplier_open_item_offsets"};
    static JdbcTemplate jdbc;
    static SessionFactory sessions;
    UUID party,currency,ledger,run;

    @BeforeAll static void start() {
        PG.start();
        jdbc=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        MigratedProjectionSchema.createCurrentTables(jdbc,TABLES);
        sessions=new Configuration().setProperty("hibernate.connection.url",PG.getJdbcUrl())
                .setProperty("hibernate.connection.username",PG.getUsername()).setProperty("hibernate.connection.password",PG.getPassword())
                .setProperty("hibernate.hbm2ddl.auto","none").buildSessionFactory();
    }
    @AfterAll static void stop(){if(sessions!=null)sessions.close();PG.stop();}
    @BeforeEach void clear() {
        jdbc.execute("TRUNCATE "+String.join(",",TABLES));
        party=UUID.randomUUID();currency=UUID.randomUUID();ledger=UUID.randomUUID();run=UUID.randomUUID();
        jdbc.update("INSERT INTO clients(id,code,name,code_sequence) VALUES(?,'SYN-PARTY','Synthetic party',1)",party);
        jdbc.update("INSERT INTO suppliers(id,code,name,code_sequence) VALUES(?,'SYN-PARTY','Synthetic party',1)",party);
        jdbc.update("INSERT INTO currencies(id,code,name,exchange_rate) VALUES(?,'SYN','Synthetic currency',1)",currency);
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void allFiveViewsUseOriginalOpeningSeventeenAndOnlyNewCashThree(String side) {
        opening(side,"17","2025-01-31T15:59:59Z"); cash(side,"2025-01-02",8,true);
        cash(side,"2026-02-10",3,false);
        for(boolean detail:new boolean[]{false,true}) {
            ReportTableResponse report=flow(side,"2026-02-01",detail,1,50);
            assertThat(report.rows()).hasSize(1);
            assertMoney(report.rows().getFirst(),"balanceLocal","14");
            assertMoney(report.rows().getFirst(),"balanceOriginal","14");
            assertMoney(report.rows().getFirst(),"receiptLocal","3");
            assertThat(report.rows().getFirst().get("originalStatus")).isEqualTo("已核验");
            assertThat(report.totals()).anySatisfy(total->{
                assertThat(total.key()).isEqualTo("receiptLocal");
                assertThat(total.groups().getFirst().value()).isEqualByComparingTo("3");
            });
        }
        ReportTableResponse annual=annual(side,2026);
        assertThat(annual.rows()).hasSize(12);
        Map<String,Object> february=annual.rows().get(1);
        assertMoney(february,"prevBalance","17"); assertMoney(february,"posted","0");
        assertMoney(february,"settled","3"); assertMoney(february,"balance","14");
        assertMoney(annual.rows().get(2),"prevBalance","14");
        assertThat(jdbc.queryForObject("SELECT initial_state->>'amount_balance' FROM legacy_finance_import_sources",String.class)).isEqualTo("17");
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void offsetKeepsBothLegsAndPreservesThePartyNetBalance(String side) {
        opening(side,"17","2025-01-31T15:59:59Z"); cash(side,"2026-02-10",3,false);
        UUID source=sourceCredit(side);
        offset(side,source,false);
        ReportTableResponse detail=flow(side,"2026-02-01",true,1,50);
        assertThat(detail.rows()).hasSize(3); // New cash, target application, source release.
        assertMoney(detail.rows().getLast(),"balanceLocal","10");
        assertThat(detail.rows()).extracting(row->row.get("type"))
                .contains(side.equals("AR")?"预收转销":"应付抵销",side.equals("AR")?"预收使用":"贷项使用");
        Map<String,Object> february=annual(side,2026).rows().get(1);
        assertMoney(february,"prevBalance","13"); assertMoney(february,"posted","4");
        assertMoney(february,"settled","7"); assertMoney(february,"balance","10");
        ReportTableResponse page=flow(side,"2026-02-01",true,2,1);
        assertThat(page.rows()).hasSize(1); assertThat(page.total()).isEqualTo(3);
        assertMoney(page.rows().getFirst(),"balanceLocal","6");
        // Footer totals cover the entire requested period, not the one row page.
        assertThat(page.totals()).anySatisfy(total->{
            assertThat(total.key()).isEqualTo("receiptLocal");
            assertThat(total.groups().getFirst().value()).isEqualByComparingTo("7");
        });
        offset(side,source,true);
        assertMoney(flow(side,"2026-02-01",true,1,50).rows().getLast(),"balanceLocal","10");
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void unknownOriginalStaysNullWhileLocalAndNegativeOpeningsRemainVisible(String side) {
        opening(side,"-7","2025-01-31T15:59:59Z");
        jdbc.update("UPDATE ar_ap_ledger SET currency_id=NULL,amount_original=NULL,amount_balance_original=NULL");
        jdbc.update("UPDATE legacy_finance_import_sources SET initial_state=initial_state||'{\"amount_balance_original\":null}'::jsonb");
        Map<String,Object> row=flow(side,null,true,1,50).rows().getFirst();
        assertThat(row.get("salesOriginal")).isNull(); assertThat(row.get("balanceOriginal")).isNull();
        assertThat(row.get("originalStatus")).isEqualTo("待核验"); assertMoney(row,"balanceLocal","-7");
        assertThat(flow(side,null,false,1,50).totals()).noneSatisfy(total->assertThat(total.key()).isEqualTo("salesOriginal"));
        assertMoney(annual(side,2026).rows().getFirst(),"balance","-7");
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void cutoffUsesShanghaiAndDoesNotDependOnTheSessionTimezone(String side) {
        opening(side,"17","2025-01-31T16:00:00Z"); // Shanghai February 1.
        assertThatThrownBy(()->flow(side,"2025-02-01",false,1,50)).isInstanceOf(ApiException.class).hasMessageContaining("截止日");
        assertThatThrownBy(()->annual(side,2025)).isInstanceOf(ApiException.class).hasMessageContaining("截止日");
        assertThat(flow(side,"2025-02-02",true,1,50).rows()).isEmpty();
        assertMoney(annual(side,2026).rows().getFirst(),"balance","17");
        jdbc.update("DELETE FROM legacy_finance_import_sources");
        assertThatThrownBy(()->flow(side,"2026-02-01",false,1,50)).isInstanceOf(ApiException.class);
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void nativeCashAndReversalsRetainTheirActualDates(String side) {
        nativeLedger(side,ledger,"25","2025-01-02");
        UUID paid=cash(side,"2025-12-15",8,false); cash(side,"2026-02-10",3,false);
        assertMoney(flow(side,"2026-02-01",false,1,50).rows().getFirst(),"balanceLocal","14");
        String table=side.equals("AR")?"finance_receipts":"finance_payments";
        jdbc.update("UPDATE "+table+" SET status=-1,reversed_at='2026-03-01T00:00:00Z',updated_at='2026-04-01T00:00:00Z' WHERE id=?",paid);
        ReportTableResponse annual=annual(side,2026);
        assertMoney(annual.rows().get(1),"balance","14"); assertMoney(annual.rows().get(2),"balance","22");
        assertMoney(annual.rows().get(3),"settled","0");
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void unknownBookEvidenceBlocksAllStatementViewsInsteadOfBecomingZero(String side) {
        nativeLedger(side,ledger,"25","2025-01-02"); cash(side,"2026-02-10",3,false);
        String lines=side.equals("AR")?"finance_receipt_lines":"finance_payment_lines";
        jdbc.update("UPDATE "+lines+" SET applied_amount_local=NULL,exchange_diff=NULL");
        for(boolean detail:new boolean[]{false,true}) {
            assertThatThrownBy(()->flow(side,"2026-02-01",detail,1,50)).isInstanceOf(ApiException.class)
                    .hasMessageContaining("本币账面金额尚未核验");
        }
        assertThatThrownBy(()->annual(side,2026)).isInstanceOf(ApiException.class)
                .hasMessageContaining("本币账面金额尚未核验");
        if(side.equals("AP")) {
            jdbc.update("UPDATE finance_payment_lines SET exchange_diff=0");
            assertMoney(annual(side,2026).rows().get(1),"balance","22");
        }
        jdbc.update("DELETE FROM "+lines);
        assertMoney(annual(side,2026).rows().get(1),"balance","22");
    }

    void opening(String side,String balance,String cutoff) {
        nativeLedger(side,ledger,"25","2025-01-02");
        jdbc.update("UPDATE ar_ap_ledger SET legacy_id=9001,legacy_import_run_id=?,open_item_kind='LEGACY_UNVERIFIED',amount_balance_original=?::numeric,legacy_source_resolution=jsonb_build_object('snapshotAsOfUtc',CAST(? AS text)) WHERE id=?",run,balance,cutoff,ledger);
        jdbc.update("""
                INSERT INTO legacy_finance_import_sources(id,run_id,target_id,target_table,source_kind,source_legacy_id,initial_state)
                VALUES(?,?,?,'ar_ap_ledger',?,9001,jsonb_build_object('amount_balance',CAST(? AS numeric),'amount_balance_original',CAST(? AS numeric)))
                """,UUID.randomUUID(),run,ledger,side+"_OPENING",balance,balance);
    }
    void nativeLedger(String side,UUID id,String amount,String date) {
        String partyColumn=side.equals("AR")?"client_id":"supplier_id";
        jdbc.update("INSERT INTO ar_ap_ledger(id,"+partyColumn+",currency_id,direction,status,bill_no,bill_date,source_doc_type,amount_original,amount_original_local,amount_balance_original,exchange_rate) VALUES(?,?,?, ?,1,?,?::date,?,?::numeric,?::numeric,?::numeric,1)",
                id,party,currency,side,"SYN-"+id,date,side.equals("AR")?"SALES_SHIPMENT":"PURCHASE_RECEIPT",amount,amount,amount);
    }
    UUID cash(String side,String date,int amount,boolean historical) {
        UUID id=UUID.randomUUID(); boolean ar=side.equals("AR");
        String table=ar?"finance_receipts":"finance_payments",partyColumn=ar?"client_id":"supplier_id";
        jdbc.update("INSERT INTO "+table+"(id,"+partyColumn+",currency_id,bill_no,bill_date,status,amount_original,amount_local,exchange_rate,legacy_id) VALUES(?,?,?,?,?::date,1,?,?,1,?)",
                id,party,currency,"CASH-"+id,date,amount,amount,historical?9002:null);
        if(ar) jdbc.update("UPDATE finance_receipts SET receipt_kind=? WHERE id=?",historical?"LEGACY_UNCLASSIFIED":"AR_SETTLEMENT",id);
        if(!historical) {
            String child=ar?"finance_receipt_lines":"finance_payment_lines",parent=ar?"receipt_id":"payment_id";
            jdbc.update("INSERT INTO "+child+"(id,"+parent+",applied_ledger_id,amount_original,amount_local,applied_amount_local,exchange_diff"+(ar?",write_off_amount":"")+") VALUES(?,?,?,?,?,?,0"+(ar?",0":"")+")",
                    UUID.randomUUID(),id,ledger,amount,amount,amount);
        }
        return id;
    }
    UUID sourceCredit(String side) {
        UUID source=UUID.randomUUID();
        if(side.equals("AP")) nativeLedger(side,source,"-4","2025-01-02");
        else {
            nativeLedger(side,source,"0","2025-01-02");
            UUID receipt=cash(side,"2025-01-02",4,false);
            jdbc.update("DELETE FROM finance_receipt_lines WHERE receipt_id=?",receipt);
            jdbc.update("UPDATE finance_receipts SET receipt_kind='CUSTOMER_PREPAYMENT' WHERE id=?",receipt);
        }
        return source;
    }
    void offset(String side,UUID source,boolean reverse) {
        String table=side.equals("AR")?"customer_open_item_offsets":"supplier_open_item_offsets";
        if(reverse) {
            jdbc.update("UPDATE "+table+" SET status='REVERSED',reversed_at='2026-03-10T00:00:00Z'");
            if(side.equals("AR"))jdbc.update("UPDATE customer_open_item_offset_batches SET status='REVERSED',reversed_at='2026-03-10T00:00:00Z',reverse_reason='synthetic reversal'");
            return;
        }
        UUID batch=UUID.randomUUID();
        if(side.equals("AR")) jdbc.update("INSERT INTO customer_open_item_offset_batches(id,client_id,currency_id,reason) VALUES(?,?,?,'synthetic application')",batch,party,currency);
        jdbc.update("INSERT INTO "+table+"(id,offset_batch_id,"+(side.equals("AR")?"client_id":"supplier_id")+",currency_id,source_ledger_id,target_ledger_id,effective_date,amount_original,source_amount_local,target_amount_local,source_rate,target_rate,status) VALUES(?,?,?,?,?,?,'2026-02-20',4,4,4,1,1,'APPLIED')",
                UUID.randomUUID(),batch,party,currency,source,ledger);
    }
    ReportTableResponse flow(String side,String from,boolean detail,int page,int size) {
        return call(service->detail ? service.partyStatementDetail(party,side,from==null?null:LocalDate.parse(from),LocalDate.parse("2026-12-31"),page,size)
                :service.partyStatementFlow(party,side,from==null?null:LocalDate.parse(from),LocalDate.parse("2026-12-31"),page,size));
    }
    ReportTableResponse annual(String side,int year) { return call(service->service.partyAnnualStatement(party,side,year,1,50)); }
    ReportTableResponse call(Function<FinanceReportService,ReportTableResponse> operation) {
        try(Session session=sessions.openSession()) {
            var tx=session.beginTransaction();
            session.createNativeQuery("SET TIME ZONE 'America/Los_Angeles'", Object.class).executeUpdate();
            assertThat(session.createNativeQuery("SHOW TimeZone", Object.class).getSingleResult()).isEqualTo("America/Los_Angeles");
            var access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
            try { return operation.apply(new FinanceReportService(session,access,null,null,null,null,null)); }
            finally { tx.rollback(); }
        }
    }
    static void assertMoney(Map<String,Object> row,String key,String amount) { assertThat((BigDecimal)row.get(key)).as(key).isEqualByComparingTo(amount); }
}
