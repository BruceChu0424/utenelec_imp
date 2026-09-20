package com.uten.imp.features.finance.payables;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Executes the production dated projection; never invents historical payment lines. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SupplierLegacyOpeningStatementPostgresTest {
    private static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");
    private static NamedParameterJdbcTemplate db;
    private static java.sql.Connection connection;
    private UUID supplier, currency, ledger;

    @BeforeAll static void start() throws Exception {
        PG.start();
        connection=java.sql.DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection,true));
        MigratedProjectionSchema.createCurrentTables(db.getJdbcTemplate(),
                "ar_ap_ledger",
                "legacy_finance_import_sources",
                "finance_payments",
                "finance_payment_lines",
                "supplier_open_item_offsets");
    }
    @AfterAll static void stop() throws Exception { if(connection!=null)connection.close(); PG.stop(); }
    @BeforeEach void clean() {
        db.getJdbcTemplate().execute("DELETE FROM finance_payment_lines; DELETE FROM finance_payments; DELETE FROM supplier_open_item_offsets; DELETE FROM legacy_finance_import_sources; DELETE FROM ar_ap_ledger");
        supplier=UUID.randomUUID(); currency=UUID.randomUUID(); ledger=UUID.randomUUID();
    }

    @Test void originalEightIsOpeningFactAndOnlyNewThreeIsPeriodPayment() {
        imported("2025-01-31T15:59:59Z",true);
        payment("2025-02-10",3);
        List<Object> february=values("2025-02-01");
        assertMoney(february.get(9),17); assertMoney(february.get(10),0);
        assertMoney(february.get(11),3); assertMoney(february.get(13),14);
        assertMoney(february.get(14),17); assertMoney(february.get(16),3); assertMoney(february.get(18),14);
        List<Object> march=values("2025-03-01");
        assertMoney(march.get(9),14); assertMoney(march.get(11),0); assertMoney(march.get(13),14);
        assertThat(unreplayable("2025-01-01")).isEqualTo(1);
        assertThat(unreplayable("2025-02-01")).isZero();
        assertThat(db.getJdbcTemplate().queryForObject("SELECT count(*) FROM finance_payment_lines",Integer.class)).isEqualTo(1);
        assertThat(db.getJdbcTemplate().queryForObject("SELECT initial_state->>'amount_settled' FROM legacy_finance_import_sources",String.class)).isEqualTo("8");
    }

    @Test void historicalReversedCashDoesNotDemandInventedNativeReversalEvents() {
        imported("2025-01-31T15:59:59Z",true);
        db.getJdbcTemplate().update("""
                INSERT INTO finance_payments(id,bill_date,status,supplier_id,currency_id,legacy_import_run_id)
                VALUES(?,'2025-01-02',-1,?,?,?)
                """,UUID.randomUUID(),supplier,currency,UUID.randomUUID());
        var entityManager = org.mockito.Mockito.mock(jakarta.persistence.EntityManager.class);
        var parameters = new java.util.HashMap<String,Object>();
        org.mockito.Mockito.when(entityManager.createNativeQuery(org.mockito.ArgumentMatchers.anyString())).thenAnswer(call -> {
            String sql=call.getArgument(0);
            var query=org.mockito.Mockito.mock(jakarta.persistence.Query.class);
            org.mockito.Mockito.when(query.setParameter(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.any()))
                    .thenAnswer(binding -> { parameters.put(binding.getArgument(0),binding.getArgument(1)); return query; });
            org.mockito.Mockito.when(query.getSingleResult()).thenAnswer(ignored -> db.queryForObject(sql,parameters,Long.class));
            return query;
        });
        var service=new SupplierSettlementService(entityManager,null,null,null,null);
        org.assertj.core.api.Assertions.assertThatCode(() -> org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                service,"assertNoUnreplayablePaymentReversals",supplier,currency,LocalDate.parse("2025-02-28")))
                .doesNotThrowAnyException();
        db.getJdbcTemplate().update("""
                INSERT INTO finance_payments(id,bill_date,status,supplier_id,currency_id)
                VALUES(?,'2025-02-02',-1,?,?)
                """,UUID.randomUUID(),supplier,currency);
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                service,"assertNoUnreplayablePaymentReversals",supplier,currency,LocalDate.parse("2025-02-28")))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("独立反转日期事件");
    }

    @Test void cutoffUsesShanghaiBusinessDateAtExactMonthBoundary() {
        imported("2025-01-31T16:00:00Z",true); // 2025-02-01 00:00 Shanghai
        db.getJdbcTemplate().execute("SET TIME ZONE 'America/Los_Angeles'");
        assertThat(db.getJdbcTemplate().queryForObject("SHOW TimeZone",String.class)).isEqualTo("America/Los_Angeles");
        assertThat(unreplayable("2025-02-01")).isEqualTo(1);
        assertThat(unreplayable("2025-03-01")).isZero();
        db.getJdbcTemplate().execute("SET TIME ZONE 'UTC'");
        assertThat(unreplayable("2025-02-01")).isEqualTo(1);
    }

    @Test void unknownOriginalCurrencyNeverBecomesAZeroStatement() {
        imported("2025-01-31T15:59:59Z",false);
        assertThat(unreplayable("2025-03-01")).isEqualTo(1);
    }

    @Test void oldImportWithoutVerifiedCutoffIsNotReconstructedFromCurrentBalance() {
        imported("2025-01-31T15:59:59Z",true);
        db.getJdbcTemplate().update("UPDATE ar_ap_ledger SET legacy_import_run_id=NULL,legacy_source_resolution=NULL");
        assertThat(unreplayable("2025-03-01")).isEqualTo(1);
    }

    @Test void ordinaryNativeStatementRetainsItsOwnPostingAndPaymentHistory() {
        imported("2025-01-31T15:59:59Z",true);
        db.getJdbcTemplate().update("UPDATE ar_ap_ledger SET open_item_kind='PAYABLE',legacy_id=NULL,legacy_import_run_id=NULL,legacy_source_resolution=NULL,amount_balance_original=22,amount_balance=22");
        payment("2025-02-10",3);
        assertThat(unreplayable("2025-02-01")).isZero();
        List<Object> result=values("2025-02-01");
        assertMoney(result.get(9),25); assertMoney(result.get(11),3); assertMoney(result.get(13),22);
    }

    @Test void unknownNativePaymentBookEvidenceBlocksFreezingAndExplicitFxProvesTheFallback() {
        imported("2025-01-31T15:59:59Z",true); payment("2025-02-10",3);
        db.getJdbcTemplate().update("UPDATE finance_payments SET supplier_id=?,currency_id=?",supplier,currency);
        db.getJdbcTemplate().update("UPDATE finance_payment_lines SET applied_amount_local=NULL,exchange_diff=NULL");
        var em=org.mockito.Mockito.mock(jakarta.persistence.EntityManager.class);
        org.mockito.Mockito.when(em.createNativeQuery(org.mockito.ArgumentMatchers.anyString())).thenAnswer(call->{
            String sql=call.getArgument(0); var parameters=new java.util.HashMap<String,Object>();
            var query=org.mockito.Mockito.mock(jakarta.persistence.Query.class);
            org.mockito.Mockito.when(query.setParameter(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.any()))
                    .thenAnswer(binding->{parameters.put(binding.getArgument(0),binding.getArgument(1));return query;});
            org.mockito.Mockito.when(query.getSingleResult()).thenAnswer(ignored->db.queryForObject(sql,parameters,Long.class));
            return query;
        });
        var service=new SupplierSettlementService(em,null,null,null,null);
        org.assertj.core.api.Assertions.assertThatThrownBy(()->org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                service,"assertCashBookKnown",supplier,currency,LocalDate.parse("2025-02-28")))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("本币账面金额尚未核验");
        db.getJdbcTemplate().update("UPDATE finance_payment_lines SET exchange_diff=0");
        org.assertj.core.api.Assertions.assertThatCode(()->org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                service,"assertCashBookKnown",supplier,currency,LocalDate.parse("2025-02-28"))).doesNotThrowAnyException();
        assertMoney(values("2025-02-01").get(18),14);
        db.getJdbcTemplate().update("UPDATE finance_payments SET legacy_id=9101");
        // An old original cash row is not replayed against an opening which already includes it.
        assertMoney(values("2025-02-01").get(18),17);
    }

    private void imported(String cutoff,boolean knownOriginal) {
        UUID run=UUID.randomUUID();
        db.getJdbcTemplate().update("""
                INSERT INTO ar_ap_ledger(id,supplier_id,currency_id,direction,status,bill_date,business_type,
                  open_item_kind,source_doc_type,source_doc_no,exchange_rate,amount_original,amount_original_local,
                  amount_balance_original,amount_balance,legacy_id,legacy_import_run_id,legacy_source_resolution)
                VALUES(?,?,?,'AP',1,'2025-01-02','PURCHASE','LEGACY_UNVERIFIED','PURCHASE_RECEIPT','synthetic',1,?,25,?,14,9001,?,
                  jsonb_build_object('snapshotAsOfUtc',CAST(? AS text)))
                """,ledger,supplier,currency,knownOriginal?new BigDecimal("25"):null,knownOriginal?new BigDecimal("14"):null,run,cutoff);
        db.getJdbcTemplate().update("""
                INSERT INTO legacy_finance_import_sources(run_id,target_id,target_table,initial_state) VALUES(?,?,'ar_ap_ledger',
                  jsonb_build_object('amount_original',25,'amount_original_local',25,'amount_settled',8,
                    'amount_balance',17,'amount_balance_original',CAST(? AS numeric)))
                """,run,ledger,knownOriginal?new BigDecimal("17"):null);
    }
    private void payment(String date,int amount) {
        UUID id=UUID.randomUUID();
        db.getJdbcTemplate().update("INSERT INTO finance_payments(id,bill_date,status,amount_original,amount_local) VALUES(?,?::date,1,?,?)",id,date,amount,amount);
        db.getJdbcTemplate().update("INSERT INTO finance_payment_lines(payment_id,applied_ledger_id,amount_original,amount_local,applied_amount_local,exchange_diff) VALUES(?,?,?,?,?,0)",id,ledger,amount,amount,amount);
    }
    private MapSqlParameterSource parameters(String start) {
        LocalDate date=LocalDate.parse(start);
        return new MapSqlParameterSource(Map.of("supplierId",supplier,"currencyId",currency,"start",date,"end",date.withDayOfMonth(date.lengthOfMonth())));
    }
    private int unreplayable(String start) { return db.queryForObject(SupplierSettlementSnapshotSql.UNREPLAYABLE_OPENING,parameters(start),Integer.class); }
    private List<Object> values(String start) {
        return db.query(SupplierSettlementSnapshotSql.LINES,parameters(start),(rs,index)->{
            var row=new java.util.ArrayList<Object>();
            for(int column=1;column<=20;column++)row.add(rs.getObject(column));
            return row;
        }).getFirst();
    }
    private static void assertMoney(Object value,int expected) { assertThat((BigDecimal)value).isEqualByComparingTo(BigDecimal.valueOf(expected)); }
}
