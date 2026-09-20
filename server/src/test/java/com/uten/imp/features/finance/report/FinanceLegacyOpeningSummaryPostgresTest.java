package com.uten.imp.features.finance.report;

import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import org.hibernate.Session;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Runs the real service, window guard, SQL, pagination and totals against nonempty PostgreSQL data. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceLegacyOpeningSummaryPostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate jdbc;
    private static SessionFactory sessions;
    private UUID party,ledger,run,currency;

    @BeforeAll static void start() {
        PG.start();
        jdbc=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        MigratedProjectionSchema.createCurrentTables(jdbc,
                "clients",
                "suppliers",
                "employees",
                "client_director_v",
                "ar_ap_ledger",
                "legacy_finance_import_sources",
                "finance_receipts",
                "finance_receipt_lines",
                "finance_payments",
                "finance_payment_lines",
                "customer_open_item_offsets",
                "customer_open_item_offset_batches",
                "supplier_open_item_offsets");
        sessions=new Configuration().setProperty("hibernate.connection.url",PG.getJdbcUrl())
                .setProperty("hibernate.connection.username",PG.getUsername()).setProperty("hibernate.connection.password",PG.getPassword())
                .setProperty("hibernate.hbm2ddl.auto","none").buildSessionFactory();
    }
    @AfterAll static void stop(){if(sessions!=null)sessions.close();PG.stop();}
    @BeforeEach void clear() {
        jdbc.execute("TRUNCATE clients,suppliers,ar_ap_ledger,legacy_finance_import_sources,finance_receipts,finance_receipt_lines,finance_payments,finance_payment_lines");
        party=UUID.randomUUID();ledger=UUID.randomUUID();run=UUID.randomUUID();currency=UUID.randomUUID();
        jdbc.update("INSERT INTO clients(id,code,name,sales_payment_type) VALUES (?,'SYN-PARTY','known party','MONTHLY')",party);
        jdbc.update("INSERT INTO suppliers(id,code,name) VALUES (?,'SYN-PARTY','known party')",party);
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void importedTwentyFiveLessOldEightStartsAtSeventeenAndOnlyNewThreeReducesIt(String direction) {
        opening(direction,"17","2025-01-31T15:59:59Z");
        cash(direction,"2025-01-02",8,true);
        cash(direction,"2025-02-10",3,false);
        assertAmounts(summary(direction,"2025-02-01",null),"17","3","14",direction);
        assertAmounts(summary(direction,"2025-03-01",null),"14","0","14",direction);
        assertThat(jdbc.queryForObject("SELECT initial_state->>'amount_balance' FROM legacy_finance_import_sources",String.class)).isEqualTo("17");
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void nativeDatedCashStillReplaysTheOrdinaryOriginalAmount(String direction) {
        nativeLedger(direction,"25");
        cash(direction,"2025-01-15",8,false);
        cash(direction,"2025-02-10",3,false);
        assertAmounts(summary(direction,"2025-02-01",null),"17","3","14",direction);
        assertAmounts(summary(direction,"2025-03-01",null),"14","0","14",direction);
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void negativeOpeningRemainsNegativeAndNeverBecomesFictitiousCash(String direction) {
        opening(direction,"-7","2025-01-31T15:59:59Z");
        assertAmounts(summary(direction,"2025-02-01",null),"-7","0","-7",direction);
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void beforeOrAcrossShanghaiCutoffIsRejectedWhileTheNextWindowIsValid(String direction) {
        opening(direction,"17","2025-01-31T16:00:00Z"); // February 1, Shanghai.
        assertThatThrownBy(()->summary(direction,"2025-01-01",null)).isInstanceOf(ApiException.class).hasMessageContaining("快照截止日");
        assertThatThrownBy(()->summary(direction,"2025-02-01",null)).isInstanceOf(ApiException.class).hasMessageContaining("快照截止日");
        assertAmounts(summary(direction,"2025-03-01",null),"17","0","17",direction);
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void unknownOriginalCurrencyIsCountedWithoutErasingProvedLocalBalance(String direction) {
        opening(direction,"17","2025-01-31T15:59:59Z");
        jdbc.update("UPDATE ar_ap_ledger SET amount_original=NULL,amount_balance_original=NULL,currency_id=NULL");
        jdbc.update("UPDATE legacy_finance_import_sources SET initial_state=initial_state||'{\"amount_balance_original\":null}'::jsonb");
        ReportTableResponse result=summary(direction,"2025-02-01",null);
        assertAmounts(result,"17","0","17",direction);
        assertThat(result.columns()).anySatisfy(column->{
            assertThat(column.key()).isEqualTo("unverifiedOriginalCount");
            assertThat(column.label()).isEqualTo("币种/原币待核验项数");
        });
        assertThat(((Number)result.rows().getFirst().get("unverifiedOriginalCount")).longValue()).isEqualTo(1);
        assertThat(result.totals()).anySatisfy(total->{
            assertThat(total.key()).isEqualTo("unverifiedOriginalCount");
            assertThat(total.groups().getFirst().value()).isEqualByComparingTo("1");
        });
        assertThat(jdbc.queryForObject("SELECT amount_original FROM ar_ap_ledger",BigDecimal.class)).isNull();
        assertThat(jdbc.queryForObject("SELECT currency_id FROM ar_ap_ledger",UUID.class)).isNull();
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void unknownLocalBalanceCutoffOrSourceProofIsRejected(String direction) {
        opening(direction,"17","2025-01-31T15:59:59Z");
        jdbc.update("UPDATE legacy_finance_import_sources SET initial_state=initial_state-'amount_balance'");
        assertThatThrownBy(()->summary(direction,"2025-02-01",null)).isInstanceOf(ApiException.class);
        jdbc.update("UPDATE legacy_finance_import_sources SET initial_state=initial_state||'{\"amount_balance\":17}'::jsonb");
        jdbc.update("UPDATE ar_ap_ledger SET legacy_source_resolution='{}'::jsonb");
        assertThatThrownBy(()->summary(direction,"2025-02-01",null)).isInstanceOf(ApiException.class);
        jdbc.update("UPDATE ar_ap_ledger SET legacy_source_resolution=jsonb_build_object('snapshotAsOfUtc','2025-01-31T15:59:59Z'),legacy_import_run_id=NULL");
        assertThatThrownBy(()->summary(direction,"2025-02-01",null)).isInstanceOf(ApiException.class);
        jdbc.update("UPDATE ar_ap_ledger SET legacy_import_run_id=?",run);
        jdbc.update("DELETE FROM legacy_finance_import_sources");
        assertThatThrownBy(()->summary(direction,"2025-02-01",null)).isInstanceOf(ApiException.class);
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void keywordLimitsBothTheGuardAndTheActualRows(String direction) {
        nativeLedger(direction,"25");
        UUID other=UUID.randomUUID();
        jdbc.update("INSERT INTO clients(id,code,name) VALUES (?,'BAD-PARTY','unverified party')",other);
        jdbc.update("INSERT INTO suppliers(id,code,name) VALUES (?,'BAD-PARTY','unverified party')",other);
        jdbc.update("""
                INSERT INTO ar_ap_ledger(id,client_id,supplier_id,direction,status,bill_date,source_doc_type,open_item_kind,legacy_id)
                VALUES (?,?,?,?,1,'2025-01-02','LEGACY_OPENING','LEGACY_UNVERIFIED',9002)
                """,UUID.randomUUID(),other,other,direction);
        assertAmounts(summary(direction,"2025-02-01","SYN-PARTY"),"25","0","25",direction);
        assertThatThrownBy(()->summary(direction,"2025-02-01",null)).isInstanceOf(ApiException.class);
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void nativeCashReversalKeepsTheOriginalMonthAndReversesOnlyOnItsActualDate(String side) {
        nativeLedger(side,"25"); cash(side,"2025-02-10",3,false);
        String table=side.equals("AR")?"finance_receipts":"finance_payments";
        jdbc.update("UPDATE "+table+" SET status=-1,reversed_at='2025-02-28T16:00:00Z',updated_at='2025-04-01T00:00:00Z'");
        assertAmounts(summary(side,"2025-02-01",null),"25","3","22",side);
        assertAmounts(summary(side,"2025-03-01",null),"22","-3","25",side);
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void nativePostingReversalDoesNotEraseTheOriginalMonth(String side) {
        nativeLedger(side,"25");
        jdbc.update("UPDATE ar_ap_ledger SET bill_date='2025-02-10',status=-1,is_deleted=true,deleted_at='2025-02-28T16:00:00Z'");
        assertAmounts(summary(side,"2025-02-01",null),"0","0","25",side);
        assertAmounts(summary(side,"2025-03-01",null),"25","0","0",side);
    }

    @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void incompleteNativeBookEvidenceCannotDisappearAsZeroInsideSummary(String side) {
        nativeLedger(side,"25"); cash(side,"2025-02-10",3,false);
        String lines=side.equals("AR")?"finance_receipt_lines":"finance_payment_lines";
        jdbc.update("UPDATE "+lines+" SET applied_amount_local=NULL,exchange_diff=NULL");
        assertThatThrownBy(()->summary(side,"2025-02-01",null)).isInstanceOf(ApiException.class)
                .hasMessageContaining("本币账面金额尚未核验");
        if(side.equals("AP")) {
            jdbc.update("UPDATE finance_payment_lines SET exchange_diff=0");
            assertAmounts(summary(side,"2025-02-01",null),"25","3","22",side);
        }
        // An actual native cash header without allocation lines remains authoritative.
        jdbc.update("DELETE FROM "+lines);
        assertAmounts(summary(side,"2025-02-01",null),"25","3","22",side);
    }

    private void opening(String direction,String balance,String cutoff) {
        BigDecimal initialBalance=new BigDecimal(balance);
        BigDecimal original=initialBalance.signum()<0?initialBalance:new BigDecimal("25");
        BigDecimal historicalSettled=original.subtract(initialBalance);
        BigDecimal currentBalance=initialBalance.signum()<0?initialBalance:new BigDecimal("14");
        jdbc.update("""
                INSERT INTO ar_ap_ledger(id,client_id,supplier_id,currency_id,direction,status,bill_date,
                  source_doc_type,open_item_kind,amount_original,amount_original_local,amount_balance_original,
                  legacy_id,legacy_import_run_id,legacy_source_resolution)
                VALUES (?,?,?,?,?,1,'2025-01-02','LEGACY_OPENING','LEGACY_UNVERIFIED',?,?,?,9001,?,
                  jsonb_build_object('snapshotAsOfUtc',CAST(? AS text)))
                """,ledger,party,party,currency,direction,original,original,currentBalance,run,cutoff);
        jdbc.update("""
                INSERT INTO legacy_finance_import_sources(run_id,target_id,target_table,initial_state) VALUES (?,?,'ar_ap_ledger',jsonb_build_object(
                  'amount_original_local',CAST(? AS numeric),'amount_settled',CAST(? AS numeric),
                  'amount_balance',CAST(? AS numeric),'amount_balance_original',CAST(? AS numeric)))
                """,run,ledger,original,historicalSettled,initialBalance,initialBalance);
    }
    private void nativeLedger(String direction,String amount) {
        jdbc.update("""
                INSERT INTO ar_ap_ledger(id,client_id,supplier_id,currency_id,direction,status,bill_date,
                  source_doc_type,open_item_kind,amount_original,amount_original_local,amount_balance_original)
                VALUES (?,?,?,?,?,1,'2025-01-02',?,?,CAST(? AS numeric),CAST(? AS numeric),14)
                """,ledger,party,party,currency,direction,"AR".equals(direction)?"SALES_SHIPMENT":"PURCHASE_RECEIPT",
                "AR".equals(direction)?"RECEIVABLE":"PAYABLE",amount,amount);
    }
    private void cash(String direction,String date,int amount,boolean historical) {
        UUID id=UUID.randomUUID();
        if("AR".equals(direction)) {
            jdbc.update("INSERT INTO finance_receipts(id,client_id,bill_date,status,is_deleted,amount_local,receipt_kind,legacy_id) VALUES (?,?,?,1,false,?,'AR_SETTLEMENT',?)",id,party,LocalDate.parse(date),amount,historical?9101:null);
            if(!historical)jdbc.update("INSERT INTO finance_receipt_lines(receipt_id,amount_local,write_off_local,applied_amount_local,exchange_diff) VALUES (?,?,0,?,0)",id,amount,amount);
        } else {
            jdbc.update("INSERT INTO finance_payments(id,supplier_id,bill_date,status,amount_local,legacy_id) VALUES (?,?,?,1,?,?)",id,party,LocalDate.parse(date),amount,historical?9101:null);
            if(!historical)jdbc.update("INSERT INTO finance_payment_lines(payment_id,amount_local,applied_amount_local,exchange_diff) VALUES (?,?,?,0)",id,amount,amount);
        }
    }
    private ReportTableResponse summary(String direction,String start,String keyword) {
        try(Session session=sessions.openSession()) {
            var transaction=session.beginTransaction();
            try {
                session.createNativeQuery("SET TIME ZONE 'America/Los_Angeles'", Object.class).executeUpdate();
                assertThat(session.createNativeQuery("SHOW TimeZone", Object.class).getSingleResult()).isEqualTo("America/Los_Angeles");
                FinanceDocumentAccessPolicy access=mock(FinanceDocumentAccessPolicy.class);
                when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
                FinanceReportService service=new FinanceReportService(session,access,null,null,null,null,null);
                LocalDate from=LocalDate.parse(start),to=from.withDayOfMonth(from.lengthOfMonth());
                ReportTableResponse result="AR".equals(direction)?service.receivableSummary(keyword,from,to,1,50)
                        :service.payableSummary(keyword,from,to,Map.of(),1,50,null,null);
                transaction.commit();
                return result;
            } catch(RuntimeException|Error failure) {
                if(transaction.isActive())transaction.rollback();
                throw failure;
            }
        }
    }
    private static void assertAmounts(ReportTableResponse result,String opening,String paid,String balance,String direction) {
        assertThat(result.rows()).hasSize(1);
        Map<String,Object> row=result.rows().getFirst();
        assertThat((BigDecimal)row.get("prevBalance")).isEqualByComparingTo(opening);
        assertThat((BigDecimal)row.get("AR".equals(direction)?"receivedAmount":"paidAmount")).isEqualByComparingTo(paid);
        assertThat((BigDecimal)row.get("balance")).isEqualByComparingTo(balance);
        assertThat(result.totals()).anySatisfy(total->{
            assertThat(total.key()).isEqualTo("balance");
            assertThat(total.groups()).hasSize(1);
            assertThat(total.groups().getFirst().value()).isEqualByComparingTo(balance);
        });
    }
}
