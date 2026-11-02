package com.uten.imp.features.finance.report;

import com.uten.imp.common.export.ExportPageSink;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.report.ReportExportCursor;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.testsupport.TestFlyway;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.sql.Connection;
import java.time.Duration;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import org.hibernate.Session;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Full migrated PostgreSQL: old RR snapshots, source producers and projection consumers really overlap. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class PartyMonthlySnapshotPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withCreateContainerCmdModifier(cmd->cmd.getHostConfig().withMemory(768L*1024*1024).withNanoCPUs(1_000_000_000L));
    private static JdbcTemplate db;
    private static SessionFactory sessions;
    private UUID party,currency;
    @BeforeAll static void start() {
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);
        TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()).locations("classpath:db/migration").load().migrate();
        var configuration=new Configuration().setProperty("hibernate.hbm2ddl.auto","none");
        configuration.getProperties().put("hibernate.connection.datasource",source);sessions=configuration.buildSessionFactory();
    }
    @AfterAll static void stop(){if(sessions!=null)sessions.close();PG.stop();}
    @BeforeEach void seedParty() {
        party=UUID.randomUUID();currency=UUID.randomUUID();
        db.update("INSERT INTO clients(id,code,name,code_sequence) VALUES(?,'SN-CL-'||?::text,'快照客户',('x'||substr(?::text,1,7))::bit(28)::int)",party,party,party);
        db.update("INSERT INTO suppliers(id,code,name,code_sequence) VALUES(?,'SN-SU-'||?::text,'快照供应商',('x'||substr(?::text,1,7))::bit(28)::int)",party,party,party);
        db.update("INSERT INTO currencies(id,code,name,exchange_rate) VALUES(?,'SN-'||?::text,'快照币种',1)",currency,currency);
    }
    private void ledger(String side,String amount,String date) { ledger(db,side,amount,date); }
    private void ledger(JdbcTemplate jdbc,String side,String amount,String date) {
        jdbc.update("INSERT INTO ar_ap_ledger(id,"+(side.equals("AR")?"client_id":"supplier_id")+",currency_id,direction,status,bill_no,bill_date,source_doc_type,amount_original,amount_original_local,amount_balance_original,amount_received_original,amount_write_off_original,amount_offset_original,amount_balance,exchange_rate) "
                        +"VALUES(gen_random_uuid(),?,?,?,1,?,?::date,?,?::numeric,?::numeric,?::numeric,0,0,0,?::numeric,1)",
                party,currency,side,"SN-"+UUID.randomUUID(),date,side.equals("AR")?"SALES_SHIPMENT":"PURCHASE_RECEIPT",amount,amount,amount,amount);
    }
    private static void heal(String side,UUID id) {
        try(var session=sessions.openSession()) {var tx=session.beginTransaction();new PartyMonthlySummaryService(session).reconcileNow(side,id);tx.commit();}
    }
    private Session repeatableSession() {
        var session=sessions.openSession();session.doWork(c->c.setTransactionIsolation(Connection.TRANSACTION_REPEATABLE_READ));return session;
    }
    private void anchor(Session session) {session.createNativeQuery("SELECT count(*) FROM party_month_dirty WHERE party_id=:pid",Long.class).setParameter("pid",party).getSingleResult();}
    private FinanceReportService reports(EntityManager em) {
        var access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
        var settings=mock(SystemSettingsService.class);when(settings.readInt(any())).thenReturn(5000);
        var healer=mock(PartyMonthlySummaryService.class);doAnswer(call->{heal(call.getArgument(0),call.getArgument(1));return null;}).when(healer).reconcileNow(anyString(),any(UUID.class));
        return new FinanceReportService(em,access,settings,mock(FinanceStatementService.class),mock(FinanceCostService.class),mock(GlReportService.class),mock(FixedAssetService.class),healer);
    }
    private static void money(Map<String,Object> row,String key,String expected){assertThat((BigDecimal)row.get(key)).as(key).isEqualByComparingTo(expected);}
    private long dirtyCount(String side){return db.queryForObject("SELECT count(*) FROM party_month_dirty WHERE side=? AND party_id=?",Long.class,side,party);}

    @Tag("snapshot-regression") @ParameterizedTest @ValueSource(strings={"AR","AP"})
    void oldRepeatableReadSnapshotMustUseItsOwnDirtyFactsAfterAnExternalHealerCommits(String side) {
        ledger(side,"100","2025-01-02");heal(side,party);
        ledger(side,"20","2025-01-03");ledger(side,"5","2026-02-10");
        try(var session=repeatableSession()) {
            var tx=session.beginTransaction();anchor(session);heal(side,party);
            assertThat(dirtyCount(side)).isZero();
            var service=reports(session);LocalDate from=LocalDate.of(2026,2,1),to=LocalDate.of(2026,2,28);
            var flow=service.partyStatementFlow(party,side,from,to,1,50);
            var detail=service.partyStatementDetail(party,side,from,to,1,50);
            assertThat(flow.rows()).singleElement().satisfies(row->money(row,"balanceLocal","125"));
            assertThat(detail.rows()).singleElement().satisfies(row->money(row,"balanceLocal","125"));
            var annual=service.partyAnnualStatement(party,side,2026,1,50);
            assertThat(annual.rows()).hasSize(12);money(annual.rows().getFirst(),"prevBalance","120");money(annual.rows().get(1),"balance","125");
            assertThat(annual.rows()).allSatisfy(row->assertThat(row.get("returned")).isNull());
            assertThat(annual.columns().stream().filter(c->c.key().equals("returned")).findFirst().orElseThrow().label()).contains("已并入");
            for(String kind:List.of("flow","detail","annual")) {
                var params=new LinkedHashMap<String,String>(Map.of("partyId",party.toString(),"side",side,"dateFrom",from.toString(),"dateTo",to.toString(),"year","2026"));
                var payload=service.export("statement/"+kind,params,null,null);
                assertThat(payload.rows()).hasSize(kind.equals("annual")?12:1);
                money(payload.rows().get(kind.equals("annual")?1:0),kind.equals("annual")?"balance":"balanceLocal","125");
            }
            tx.rollback();
        }
    }
    @Test void backgroundCursorKeepsOneDirtySnapshotAcrossThreeBatchesAndAConcurrentLateCommit() {
        ledger("AR","100","2025-01-02");heal("AR",party);ledger("AR","20","2025-01-03");
        db.update("INSERT INTO ar_ap_ledger(id,client_id,currency_id,direction,status,bill_no,bill_date,source_doc_type,amount_original,amount_original_local,amount_balance_original,amount_received_original,amount_write_off_original,amount_offset_original,amount_balance,exchange_rate) "
                +"SELECT md5(?||n)::uuid,?,?,'AR',1,'SN-CURSOR-'||lpad(n::text,4,'0'),DATE '2026-02-10','SALES_SHIPMENT',.0001,.0001,.0001,0,0,0,.0001,1 FROM generate_series(1,1001)n",party.toString(),party,currency);
        try(var session=repeatableSession()) {
            var tx=session.beginTransaction();anchor(session);heal("AR",party);
            TransactionSynchronizationManager.setActualTransactionActive(true);TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
            TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(Connection.TRANSACTION_REPEATABLE_READ);
            var batches=new ArrayList<ExportPayload>();AtomicBoolean appended=new AtomicBoolean();
            try(var sink=ExportPageSink.open(payload->{batches.add(payload);if(appended.compareAndSet(false,true)){ledger("AR","999","2026-02-10");heal("AR",party);}});
                var plan=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY);var cursor=ReportExportCursor.open()) {
                var payload=reports(session).export("statement/detail",Map.of("partyId",party.toString(),"side","AR","dateFrom","2026-02-01","dateTo","2026-02-28"),null,null);
                assertThat(payload.rows()).isEmpty();assertThat(payload.total()).isEqualTo(1001);
            } finally {TransactionSynchronizationManager.clear();}
            assertThat(batches).hasSize(3);var rows=batches.stream().flatMap(batch->batch.rows().stream()).toList();
            assertThat(rows).hasSize(1001);assertThat(rows.stream().map(row->row.get("refNo")).distinct()).hasSize(1001);
            money(rows.getFirst(),"balanceLocal","120.0001");money(rows.getLast(),"balanceLocal","120.1001");
            tx.rollback();
        }
    }

    /** Insert a source fact after aggregation but before dirty deletion, using real production dirty triggers. */
    @Tag("snapshot-regression") @Test void sourceCommitDuringAggregationMustLeaveItsNewDirtyVersionForTheNextConsumer() {
        ledger("AR","100","2025-01-02");
        try(var session=sessions.openSession()) {
            var tx=session.beginTransaction();
            new PartyMonthlySummaryService(afterAggregation(session,()->ledger("AR","20","2025-01-03"))).reconcileNow("AR",party);tx.commit();
        }
        assertThat(dirtyCount("AR")).isEqualTo(1);
        assertThat(db.queryForObject("SELECT net_local FROM party_monthly_summaries WHERE side='AR' AND party_id=?",BigDecimal.class,party)).isEqualByComparingTo("100");
        try(var session=sessions.openSession()) {var tx=session.beginTransaction();var row=reportsWithoutHealing(session).partyAnnualStatement(party,"AR",2026,1,50).rows().getFirst();money(row,"balance","120");tx.rollback();}
        heal("AR",party);assertThat(dirtyCount("AR")).isZero();
        assertThat(db.queryForObject("SELECT net_local FROM party_monthly_summaries WHERE side='AR' AND party_id=?",BigDecimal.class,party)).isEqualByComparingTo("120");
    }
    @Test void dirtyDeleteWaitsForAProducerThenRechecksXminInsteadOfDeletingItsNewVersion() throws Exception {
        ledger("AR","100","2025-01-02");
        var aggregateReady=new CountDownLatch(1);var consumerPid=new AtomicInteger();var executor=Executors.newSingleThreadExecutor();
        try(var writer=db.getDataSource().getConnection()) {
            writer.setAutoCommit(false);
            var source=new JdbcTemplate(new org.springframework.jdbc.datasource.SingleConnectionDataSource(writer,true));ledger(source,"AR","20","2025-01-03");
            var future=executor.submit(()->{try(var session=sessions.openSession()) {
                var tx=session.beginTransaction();consumerPid.set(session.createNativeQuery("SELECT pg_backend_pid()",Integer.class).getSingleResult());
                new PartyMonthlySummaryService(afterAggregation(session,aggregateReady::countDown)).reconcileNow("AR",party);tx.commit();
            }});
            assertThat(aggregateReady.await(15,TimeUnit.SECONDS)).isTrue();
            long deadline=System.nanoTime()+Duration.ofSeconds(10).toNanos();boolean blocked=false;
            while(System.nanoTime()<deadline) {if(Boolean.TRUE.equals(db.queryForObject("SELECT cardinality(pg_blocking_pids(?))>0",Boolean.class,consumerPid.get()))){blocked=true;break;}Thread.sleep(10);}
            assertThat(blocked).as("consumer DELETE must really wait on the producer's marker tuple").isTrue();
            writer.commit();future.get(15,TimeUnit.SECONDS);
            assertThat(dirtyCount("AR")).isEqualTo(1);heal("AR",party);assertThat(dirtyCount("AR")).isZero();
            assertThat(db.queryForObject("SELECT net_local FROM party_monthly_summaries WHERE side='AR' AND party_id=?",BigDecimal.class,party)).isEqualByComparingTo("120");
        } finally {executor.shutdownNow();}
    }
    private EntityManager afterAggregation(Session session,Runnable hook) {
        EntityManager wrapped=mock(EntityManager.class);AtomicBoolean ran=new AtomicBoolean();
        EntityManager delegate=session;
        when(wrapped.createNativeQuery(anyString())).thenAnswer(call->{String sql=call.getArgument(0);Query query=delegate.createNativeQuery(sql);
            if(!sql.contains(", recompute AS ("))return query;
            Query intercepted=mock(Query.class,org.mockito.AdditionalAnswers.delegatesTo(query));
            doAnswer(ignored->{var rows=query.getResultList();if(ran.compareAndSet(false,true))hook.run();return rows;}).when(intercepted).getResultList();return intercepted;
        });return wrapped;
    }
    private FinanceReportService reportsWithoutHealing(Session session) {
        var access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
        return new FinanceReportService(session,access,mock(SystemSettingsService.class),mock(FinanceStatementService.class),mock(FinanceCostService.class),mock(GlReportService.class),mock(FixedAssetService.class),mock(PartyMonthlySummaryService.class));
    }

    @Test void aBusyBackgroundRebuilderCannotQueueAReportBehindItsPartyLock() throws Exception {
        ledger("AR","100","2025-01-02");heal("AR",party);
        // Production singletons/JDBC code are already initialised. Exclude the
        // fixture's first Mockito-agent attach and SQL class loading from the
        // response deadline; retain the real lock, fallback query and 2s limit.
        try(var warm=sessions.openSession()) {var tx=warm.beginTransaction();reports(warm).partyStatementDetail(party,"AR",LocalDate.of(2026,2,1),LocalDate.of(2026,2,28),1,50);tx.rollback();}
        ledger("AR","20","2025-01-03");ledger("AR","5","2026-02-10");
        var executor=Executors.newSingleThreadExecutor(runnable->new Thread(runnable,"party-busy-report-test"));
        try(var holder=sessions.openSession()) {
            var holding=holder.beginTransaction();
            holder.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))::text",String.class)
                    .setParameter("key","party-month-summary/AR/"+party).getSingleResult();
            try {
                long started=System.nanoTime();
                var future=executor.submit(()->{try(var reader=repeatableSession()) {var tx=reader.beginTransaction();anchor(reader);
                    var result=reports(reader).partyStatementDetail(party,"AR",LocalDate.of(2026,2,1),LocalDate.of(2026,2,28),1,50);tx.rollback();return result;}});
                ReportTableResponse report;
                try {report=future.get(2,TimeUnit.SECONDS);}
                catch(TimeoutException failure) {Thread.getAllStackTraces().forEach((thread,stack)->{if(thread.getName().equals("party-busy-report-test"))System.err.println("PARTY_BUSY_TIMEOUT "+Arrays.toString(stack));});throw failure;}
                assertThat(report.rows()).singleElement().satisfies(row->money(row,"balanceLocal","125"));
                System.out.println("PARTY_BUSY_REBUILDER_REPORT elapsedMs="+Duration.ofNanos(System.nanoTime()-started).toMillis());
            } finally {holding.rollback();}
        } finally {executor.shutdownNow();}
    }

    @Test void cleanQuarterMillionFactHistoryReadsMonthlyOpeningAndOnlyItsDisplayWindow() throws Exception {
        db.execute("ALTER TABLE ar_ap_ledger DISABLE TRIGGER USER");
        try {
            db.update("INSERT INTO ar_ap_ledger(id,client_id,currency_id,direction,status,bill_no,bill_date,source_doc_type,amount_original,amount_original_local,amount_balance_original,amount_received_original,amount_write_off_original,amount_offset_original,amount_balance,exchange_rate,business_type,open_item_kind) "
                    +"SELECT md5(?||n)::uuid,?,?,'AR',1,'SN-SCALE-'||n,DATE '1976-01-01'+((n-1)%18263),'SALES_SHIPMENT',1,1,1,0,0,0,1,1,'SALES','RECEIVABLE' FROM generate_series(1,250000)n",party.toString(),party,currency);
        } finally {db.execute("ALTER TABLE ar_ap_ledger ENABLE TRIGGER USER");}
        db.update("INSERT INTO party_month_dirty(side,party_id,month_start) VALUES ('AR',?,DATE '1900-01-01') ON CONFLICT DO NOTHING",party);heal("AR",party);
        db.execute("VACUUM (ANALYZE) ar_ap_ledger");db.execute("VACUUM (ANALYZE) party_monthly_summaries");
        try(var session=sessions.openSession()) {
            var tx=session.beginTransaction();String sql="EXPLAIN (ANALYZE,BUFFERS,FORMAT TEXT) "+FinancePartyStatementSql.running(FinancePartyStatementSql.events(true,"1=1"),"AR");
            long started=System.nanoTime();var lines=session.createNativeQuery(sql,String.class).setParameter("pid",party)
                    .setParameter("from",LocalDate.of(2025,12,15)).setParameter("to",LocalDate.of(2025,12,31)).setParameter("fromMonth",LocalDate.of(2025,12,1)).getResultList();
            long millis=Duration.ofNanos(System.nanoTime()-started).toMillis();String plan=String.join("\n",lines);
            System.out.println("PARTY_STATEMENT_SCALE rows=250000 years=50 elapsedMs="+millis+"\n"+plan);
            assertThat(millis).isLessThan(5000);assertThat(plan).contains("party_monthly_summaries").contains("Index");
            assertThat(lines.stream().filter(line->line.contains("Seq Scan on ar_ap_ledger")&&!line.contains("never executed"))).isEmpty();tx.rollback();
        }
    }
}
