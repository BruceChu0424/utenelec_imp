package com.uten.imp.features.finance.receipt;

import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.time.OffsetDateTime;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.anyString;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class CustomerActualReceiptContextPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");static JdbcTemplate db;static NamedParameterJdbcTemplate named;
    static final UUID CLIENT=UUID.randomUUID(),CURRENCY=UUID.randomUUID(),ACCOUNT=UUID.randomUUID();
    static final OffsetDateTime AS_OF=OffsetDateTime.parse("2026-11-02T12:00:00+08:00");
    @BeforeAll static void start(){PG.start();var ds=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(ds);named=new NamedParameterJdbcTemplate(ds);MigratedProjectionSchema.createCurrentTables(db,"finance_receipts","finance_reconciliations","currencies");}
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void reset(){db.execute("TRUNCATE finance_receipts,finance_reconciliations,currencies");db.update("INSERT INTO currencies(id,code,name,is_base_currency) VALUES(?,'USD','美金',false)",CURRENCY);}
    @Test void countsOnlyVerifiedCashAndNeverDraftReversalFutureOrGrossAmount(){
        UUID actual=receipt(1,"2026-11-01T10:00:00+08:00",2);flow(actual,"100","700");
        receipt(0,"2026-11-01T10:00:00+08:00",2);receipt(-1,"2026-11-01T10:00:00+08:00",2);UUID future=receipt(1,"2026-11-03T10:00:00+08:00",2);flow(future,"100","700");
        var value=reader().read(CLIENT,CURRENCY,AS_OF);assertThat(value.verifiedCount()).isEqualTo(1);assertThat(new java.math.BigDecimal(value.verifiedCashLocal())).isEqualByComparingTo("700");assertThat(value.receipts()).hasSize(1);assertThat(new java.math.BigDecimal(value.receipts().getFirst().accountAmount())).isEqualByComparingTo("100");assertThat(value.pendingCount()).isZero();
    }
    @Test void absentOrMismatchedAccountProofAndLegacyAmbiguityStayPendingInsteadOfClaimedCash(){
        receipt(1,"2026-11-01T10:00:00+08:00",2);UUID mismatch=receipt(1,"2026-11-01T10:00:00+08:00",2);flow(mismatch,"99","700");UUID legacy=receipt(1,"2026-11-01T10:00:00+08:00",0);flow(legacy,"100","700");
        var value=reader().read(CLIENT,CURRENCY,AS_OF);assertThat(value.pendingCount()).isEqualTo(3);assertThat(value.verifiedCount()).isZero();assertThat(value.receipts()).isEmpty();assertThat(value.basis()).contains("草稿","可用预收");
    }
    @Test void summariesAreFullSetWhileDetailIsBoundedAndCurrencyNeverLeaksAcrossTradeScope(){
        for(int i=0;i<101;i++){UUID id=receipt(1,"2026-11-01T10:00:00+08:00",2);flow(id,"100","700");}
        var value=reader().read(CLIENT,CURRENCY,AS_OF);assertThat(value.verifiedCount()).isEqualTo(101);assertThat(new java.math.BigDecimal(value.verifiedCashLocal())).isEqualByComparingTo("70700");assertThat(value.receipts()).hasSize(20);assertThat(value.more()).isTrue();assertThat(value.receipts().stream().map(r->r.receiptId()).distinct()).hasSize(20);
        assertThat(reader().read(CLIENT,UUID.randomUUID(),AS_OF).verifiedCount()).isZero();
    }
    static UUID receipt(int status,String time,int authority){UUID id=UUID.randomUUID();db.update("""
            INSERT INTO finance_receipts(id,bill_no,bill_date,client_id,receipt_kind,account_id,currency_id,account_currency_id,
                amount_original,amount_local,account_amount,account_amount_local,status,settlement_authority_version,bank_booked_at,bank_reference)
            VALUES(?,?,'2026-11-01',?,'AR_SETTLEMENT',?,?,?,150,1050,100,700,?,?,?::timestamptz,'已核对银行回单')
            """,id,"R"+id,CLIENT,ACCOUNT,CURRENCY,CURRENCY,status,authority,time);return id;}
    static void flow(UUID receipt,String incoming,String local){db.update("INSERT INTO finance_reconciliations(id,bill_no,source_doc_type,source_doc_id,account_id,account_currency_id,in_amount,out_amount,amount_local,entry_kind,bill_date,settled_date) VALUES(gen_random_uuid(),?,'RECEIPT',?,?,?,?::numeric,0,?::numeric,'POSTING','2026-11-01','2026-11-01')","F"+receipt,receipt,ACCOUNT,CURRENCY,incoming,local);}
    static CustomerActualReceiptContext reader(){var em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->{String sql=call.getArgument(0);Map<String,Object> args=new HashMap<>();return mock(Query.class,q->{if(q.getMethod().getName().equals("setParameter")){args.put(q.getArgument(0),q.getArgument(1));return q.getMock();}if(q.getMethod().getName().equals("getResultList"))return named.query(sql,args,(rs,n)->{Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<row.length;i++){row[i]=rs.getObject(i+1);}return row;});return org.mockito.Answers.RETURNS_DEFAULTS.answer(q);});});return new CustomerActualReceiptContext(em);}
}
