package com.uten.imp.common.readsnapshot;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.sql.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Actual MVCC/commit ordering and runtime-role contracts; isolated disposable PostgreSQL only. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class VersionedSummaryPagesPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
            .withCreateContainerCmdModifier(cmd->cmd.getHostConfig().withMemory(768L*1024*1024).withNanoCPUs(1_000_000_000L));
    private static DriverManagerDataSource source;
    private static JdbcTemplate db;
    private static String runtimePassword;
    private String domain;
    private VersionedSummaryPages pages;
    private ReadScopeVersionAuthority authority;
    private SummaryReadMarkerCompactor compactor;
    private DataSourceTransactionManager manager;
    @BeforeAll static void start() {
        PG.start();source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);
        runtimePassword=UUID.randomUUID().toString();
        com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE ROLE uten LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE",runtimePassword);
        TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()).load().migrate();
        db.execute("CREATE TABLE summary_protocol_fixture(id integer PRIMARY KEY,value text NOT NULL)");
        db.execute("CREATE TABLE summary_protocol_auth(id integer PRIMARY KEY,token text NOT NULL)");
        db.update("INSERT INTO summary_protocol_auth VALUES(1,'initial')");
        db.execute("GRANT USAGE ON SCHEMA public TO uten");
        db.execute("GRANT SELECT,INSERT,UPDATE,DELETE ON summary_protocol_fixture,summary_read_markers,summary_read_domains TO uten");
        db.execute("GRANT SELECT,UPDATE ON departments TO uten");
        db.execute("GRANT SELECT,UPDATE(business_reset_generation) ON authorization_state TO uten");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void prepare() {
        db.execute("DROP TRIGGER IF EXISTS summary_fixture_marker ON summary_protocol_fixture");
        db.execute("DROP TRIGGER IF EXISTS summary_fixture_marker_update ON summary_protocol_fixture");
        db.execute("DROP TRIGGER IF EXISTS summary_fixture_marker_delete ON summary_protocol_fixture");
        db.execute("DROP TRIGGER IF EXISTS summary_fixture_marker_truncate ON summary_protocol_fixture");
        db.execute("TRUNCATE summary_protocol_fixture");
        domain="test-summary-"+UUID.randomUUID();db.update("INSERT INTO summary_read_domains(domain) VALUES(?)",domain);
        com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE TRIGGER summary_fixture_marker AFTER INSERT ON summary_protocol_fixture REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain(%L)",domain);
        com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE TRIGGER summary_fixture_marker_update AFTER UPDATE ON summary_protocol_fixture REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain(%L)",domain);
        com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE TRIGGER summary_fixture_marker_delete AFTER DELETE ON summary_protocol_fixture REFERENCING OLD TABLE AS summary_old_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain(%L)",domain);
        com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE TRIGGER summary_fixture_marker_truncate AFTER TRUNCATE ON summary_protocol_fixture FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain(%L)",domain);
        db.update("UPDATE summary_protocol_auth SET token=? WHERE id=1",UUID.randomUUID().toString());
        var current=mock(SecurityContextCurrentUser.class);
        UUID actor=UUID.randomUUID();when(current.get()).thenReturn(Optional.of(new AuthUser(actor,actor,"summary-fixture",Set.of("finance_report:view"),false,true,false)));
        authority=mock(ReadScopeVersionAuthority.class);
        when(authority.scopeForCurrentSnapshot(anyString(),any())).thenAnswer(call->{
            assertThat(db.queryForObject("SHOW transaction_isolation",String.class)).isEqualTo("repeatable read");
            assertThat(db.queryForObject("SHOW transaction_read_only",String.class)).isEqualTo("on");
            return db.queryForObject("SELECT token FROM summary_protocol_auth WHERE id=1",String.class);
        });
        manager=new DataSourceTransactionManager(source);
        pages=new VersionedSummaryPages(db,authority,current,new ObjectMapper(),manager);
        compactor=new SummaryReadMarkerCompactor(db,manager);
    }
    private VersionedSummaryPages.Request request(int page,int size,String expected) {
        return new VersionedSummaryPages.Request(domain,"finance",Map.of("filter","all"),"all",page,size,1000,expected);
    }
    private VersionedSummaryPages.Page<Map<String,Object>> page(int page,int size,String expected) {
        return pages.page(request(page,size,expected),()->db.queryForObject("SELECT count(*) FROM summary_protocol_fixture",Long.class),
                (p,n)->db.queryForList("SELECT id,value FROM summary_protocol_fixture ORDER BY id LIMIT ? OFFSET ?",n,(long)(p-1)*n));
    }
    private static void changed(Runnable read) {
        assertThatThrownBy(read::run).isInstanceOfSatisfying(ApiException.class,e->assertThat(e.getCode()).isEqualTo(ErrorCode.SNAPSHOT_CHANGED));
    }
    @Test void full1001RowsReachTheLiteralTailAndKeepExactTextAndIdenticalPayloads() {
        db.update("INSERT INTO summary_protocol_fixture SELECT n,'9007199254740993.123456789012345678901234' FROM generate_series(1,1001) n");
        var first=page(1,1000,null);var tail=page(2,1000,first.readSnapshotRevision());
        assertThat(first.total()).isEqualTo(1001);assertThat(first.totalPages()).isEqualTo(2);assertThat(first.items()).hasSize(1000);
        assertThat(tail.items()).singleElement().satisfies(row->{assertThat(row.get("id")).isEqualTo(1001);assertThat(row.get("value")).isEqualTo("9007199254740993.123456789012345678901234");});
        assertThat(tail.readSnapshotRevision()).isEqualTo(first.readSnapshotRevision());assertThat(tail.readDataVersion()).isEqualTo(first.readDataVersion());
        assertThatThrownBy(()->page(2,999,first.readSnapshotRevision())).isInstanceOf(ApiException.class);
    }
    @Test void sameCountValueChangeRejectsTheOldSnapshotAndNeverPublishesAPrefix() {
        db.update("INSERT INTO summary_protocol_fixture VALUES(1,'before'),(2,'tail')");var first=page(1,1,null);
        db.update("UPDATE summary_protocol_fixture SET value='after' WHERE id=1");changed(()->page(2,1,first.readSnapshotRevision()));
        assertThat(page(1,1000,null).total()).isEqualTo(first.total());
    }
    @Test void olderTransactionCommittingAfterNewerTransactionCannotHideBehindMaxTxid() throws Exception {
        db.update("INSERT INTO summary_protocol_fixture VALUES(1,'one'),(2,'two')");
        try(Connection older=source.getConnection();Connection newer=source.getConnection()) {
            older.setAutoCommit(false);newer.setAutoCommit(false);
            update(older,"UPDATE summary_protocol_fixture SET value='older' WHERE id=1");
            update(newer,"UPDATE summary_protocol_fixture SET value='newer' WHERE id=2");
            newer.commit();var middle=page(1,1,null);older.commit();changed(()->page(2,1,middle.readSnapshotRevision()));
        }
    }
    @Test void rollbackAndSavepointRollbackDoNotPublishARevisionWhileZeroRowDmlDoesNotInventOne() throws Exception {
        db.update("INSERT INTO summary_protocol_fixture VALUES(1,'one')");var before=page(1,1000,null);
        try(Connection c=source.getConnection()) {
            c.setAutoCommit(false);Savepoint save=c.setSavepoint();update(c,"UPDATE summary_protocol_fixture SET value='discard' WHERE id=1");
            c.rollback(save);c.commit();
            update(c,"UPDATE summary_protocol_fixture SET value='discard-again' WHERE id=1");c.rollback();
        }
        db.update("UPDATE summary_protocol_fixture SET value='missing' WHERE id=-1");
        assertThat(page(1,1000,before.readSnapshotRevision()).readDataVersion()).isEqualTo(before.readDataVersion());
    }
    @Test void compactionPreservesTheLogicalVersionAndAnInFlightCommitStillAdvancesIt() throws Exception {
        db.update("INSERT INTO summary_protocol_fixture VALUES(1,'one'),(2,'two')");
        try(Connection late=source.getConnection()) {
            late.setAutoCommit(false);update(late,"UPDATE summary_protocol_fixture SET value='late' WHERE id=2");
            var before=page(1,1,null);assertThat(compactor.compactDomain(domain)).isPositive();
            assertThat(page(1,1,before.readSnapshotRevision()).readDataVersion()).isEqualTo(before.readDataVersion());
            late.commit();changed(()->page(2,1,before.readSnapshotRevision()));
        }
    }
    @Test void dataCountAndRowsUseOneRrSnapshotEvenInsideAReadCommittedCallerAndFreshFenceRejectsDrift() {
        db.update("INSERT INTO summary_protocol_fixture VALUES(1,'old')");var outer=new TransactionTemplate(manager);
        outer.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
        AtomicBoolean sawOldBatch=new AtomicBoolean();
        outer.execute(status->{
            assertThat(db.queryForObject("SHOW transaction_isolation",String.class)).isEqualTo("read committed");
            changed(()->pages.page(request(1,1000,null),()->{
                long count=db.queryForObject("SELECT count(*) FROM summary_protocol_fixture",Long.class);
                try(Connection independent=source.getConnection()){update(independent,"INSERT INTO summary_protocol_fixture VALUES(2,'new')");}
                catch(SQLException e){throw new RuntimeException(e);}return count;
            },(p,n)->{var old=db.queryForList("SELECT id,value FROM summary_protocol_fixture ORDER BY id");sawOldBatch.set(old.size()==1);return old;}));
            assertThat(db.queryForObject("SHOW transaction_isolation",String.class)).isEqualTo("read committed");return null;
        });assertThat(sawOldBatch).isTrue();
    }
    @Test void authorizationChangesBetweenDataAndPublicationFailClosedAndTruncateChangesDataEvenWhenEmpty() {
        db.update("INSERT INTO summary_protocol_fixture VALUES(1,'one')");
        assertThatThrownBy(()->pages.page(request(1,1000,null),()->db.queryForObject("SELECT count(*) FROM summary_protocol_fixture",Long.class),(p,n)->{
            var items=db.queryForList("SELECT id,value FROM summary_protocol_fixture ORDER BY id");
            try(Connection independent=source.getConnection()){update(independent,"UPDATE summary_protocol_auth SET token='changed' WHERE id=1");}
            catch(SQLException e){throw new RuntimeException(e);}return items;
        })).isInstanceOfSatisfying(ApiException.class,e->assertThat(e.getCode()).isEqualTo(ErrorCode.READ_SCOPE_CHANGED));
        db.execute("TRUNCATE summary_protocol_fixture");var empty=page(1,1000,null);db.execute("TRUNCATE summary_protocol_fixture");changed(()->page(1,1000,empty.readSnapshotRevision()));
    }
    @Test void inverseDomainOrderOnDistinctBusinessRowsDoesNotCreateSharedRevisionRowDeadlocks() throws Exception {
        String second=domain+"-second";db.update("INSERT INTO summary_read_domains(domain) VALUES(?)",second);
        db.execute("CREATE TABLE summary_protocol_second(id integer PRIMARY KEY,value text)");
        try {
            com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE TRIGGER summary_second_marker AFTER UPDATE ON summary_protocol_second REFERENCING NEW TABLE AS summary_new_rows FOR EACH STATEMENT EXECUTE FUNCTION fn_mark_summary_read_domain(%L)",second);
            db.update("INSERT INTO summary_protocol_fixture VALUES(1,'one'),(2,'two')");db.update("INSERT INTO summary_protocol_second VALUES(1,'one'),(2,'two')");
            CyclicBarrier bothFirst=new CyclicBarrier(2);ExecutorService pool=Executors.newFixedThreadPool(2);
            try {
                var a=pool.submit(()->inverseWrite(ProbeTable.PRIMARY,ProbeTable.SECONDARY,1,bothFirst));
                var b=pool.submit(()->inverseWrite(ProbeTable.SECONDARY,ProbeTable.PRIMARY,2,bothFirst));
                a.get(15,TimeUnit.SECONDS);b.get(15,TimeUnit.SECONDS);
            } finally {pool.shutdownNow();assertThat(pool.awaitTermination(10,TimeUnit.SECONDS)).isTrue();}
        } finally {db.execute("DROP TABLE summary_protocol_second");}
    }
    private void inverseWrite(ProbeTable first,ProbeTable second,int id,CyclicBarrier barrier) {
        try(Connection c=source.getConnection();var local=c.createStatement()) {
            c.setAutoCommit(false);local.execute("SET LOCAL statement_timeout='10s'");
            update(c,first.sql,id);
            barrier.await(10,TimeUnit.SECONDS);update(c,second.sql,id);c.commit();
        } catch(Exception e){throw new RuntimeException(e);}
    }
    @Test void actualRuntimeRoleCanPublishAndCompactButCannotForgeMetadataDdlHistoryOrRetiredReset() throws Exception {
        db.update("INSERT INTO summary_protocol_fixture VALUES(1,'one')");var before=page(1,1000,null);
        try(Connection runtime=DriverManager.getConnection(PG.getJdbcUrl(),"uten",runtimePassword);var runtimeSql=runtime.createStatement()) {
            assertThat(runtime.getMetaData().getUserName()).isEqualTo("uten");runtime.setAutoCommit(false);
            try(var rows=runtimeSql.executeQuery("SELECT current_user,rolsuper FROM pg_roles WHERE rolname=current_user")){assertThat(rows.next()).isTrue();assertThat(rows.getString(1)).isEqualTo("uten");assertThat(rows.getBoolean(2)).isFalse();}
            assertThat(runtimeSql.executeUpdate("UPDATE departments SET name=name WHERE code='DEPT_PROD'")).isPositive();runtime.rollback();
            assertThat(page(1,1000,before.readSnapshotRevision()).readDataVersion()).isEqualTo(before.readDataVersion());
            runtime.setAutoCommit(true);
            assertThatThrownBy(()->update(runtime,"UPDATE summary_read_domains SET compacted_markers=0 WHERE domain=?",domain))
                    .isInstanceOfSatisfying(SQLException.class,e->assertThat(e.getSQLState()).isEqualTo("42501"));
            assertThatThrownBy(()->update(runtime,"DELETE FROM summary_read_markers WHERE domain=?",domain))
                    .isInstanceOfSatisfying(SQLException.class,e->assertThat(e.getSQLState()).isEqualTo("42501"));
            try(var compact=runtime.prepareStatement("SELECT fn_compact_summary_read_domain(?)")){compact.setString(1,domain);try(var rows=compact.executeQuery()){assertThat(rows.next()).isTrue();assertThat(rows.getInt(1)).isPositive();}}
            assertThat(page(1,1000,before.readSnapshotRevision()).readDataVersion()).isEqualTo(before.readDataVersion());
            assertThatThrownBy(()->runtimeSql.execute("CREATE TABLE forbidden_summary_runtime(id integer)"))
                    .isInstanceOfSatisfying(SQLException.class,e->assertThat(e.getSQLState()).isEqualTo("42501"));
            assertThatThrownBy(()->runtimeSql.executeUpdate("UPDATE flyway_schema_history SET checksum=checksum"))
                    .isInstanceOfSatisfying(SQLException.class,e->assertThat(e.getSQLState()).isEqualTo("42501"));
            assertThatThrownBy(()->runtimeSql.executeUpdate("UPDATE authorization_state SET business_reset_generation=business_reset_generation+1 WHERE singleton_id=1"))
                    .isInstanceOfSatisfying(SQLException.class,e->assertThat(e.getSQLState()).isEqualTo("55000"));
        }
    }

    private enum ProbeTable {
        PRIMARY("UPDATE summary_protocol_fixture SET value='done' WHERE id=?"),
        SECONDARY("UPDATE summary_protocol_second SET value='done' WHERE id=?");
        final String sql;
        ProbeTable(String sql) { this.sql=sql; }
    }
    private static int update(Connection connection,String sql,Object...values) throws SQLException {
        try(var statement=connection.prepareStatement(sql)) {
            for(int i=0;i<values.length;i++) { statement.setObject(i+1,values[i]); }
            return statement.executeUpdate();
        }
    }

    @Test void nativeFacet1001LabeledBucketsUseTheSameRrAndTaskAudienceAndRejectSameCountChanges() {
        when(authority.scopeForCurrentSnapshot(anyString(),any(),eq(true))).thenAnswer(call->{
            assertThat(db.queryForObject("SHOW transaction_isolation",String.class)).isEqualTo("repeatable read");
            assertThat(db.queryForObject("SHOW transaction_read_only",String.class)).isEqualTo("on");
            return "task-"+db.queryForObject("SELECT token FROM summary_protocol_auth WHERE id=1",String.class);
        });
        db.update("INSERT INTO summary_protocol_fixture SELECT n,CASE WHEN n=1001 THEN '中文 %_ 末尾' ELSE '中文客户'||n END FROM generate_series(1,1001) n");
        var jdbc=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(db);
        java.util.function.BiFunction<Integer,String,com.uten.imp.common.web.NativeFacetCandidates.Page> read=(page,expected)->{
            try(var scope=com.uten.imp.common.web.NativeFacetCandidates.open("clientId","中文",page,100)) {
                scope.requireSnapshot();
                var request=new VersionedSummaryPages.Request(domain,"native_workshop_tasks",Map.of("field","clientId","keyword","中文"),"all",page,100,100,expected);
                var snapshot=pages.read(request,()->{},()->{
                    assertThat(db.queryForObject("SHOW transaction_isolation",String.class)).isEqualTo("repeatable read");
                    return Map.of("clientId",com.uten.imp.common.web.NativeFacets.jdbcRows(jdbc,"clientId",
                        "SELECT lpad(id::text,6,'0'),value,COUNT(*) FROM summary_protocol_fixture GROUP BY id,value",
                        new org.springframework.jdbc.core.namedparam.MapSqlParameterSource(),true));
                },true);
                scope.snapshot(snapshot.readScopeVersion(),snapshot.readSnapshotRevision(),snapshot.readDataVersion());
                return scope.result(snapshot.value(),snapshot.readScopeVersion());
            }
        };
        var first=read.apply(1,null);assertThat(first.items()).hasSize(100);assertThat(first.hasMore()).isTrue();
        List<Map<String,Object>> all=new ArrayList<>(first.items());
        for(int page=2;page<=11;page++) {
            var next=read.apply(page,first.readSnapshotRevision());assertThat(next.readDataVersion()).isEqualTo(first.readDataVersion());assertThat(next.hasMore()).isEqualTo(page<11);all.addAll(next.items());
        }
        assertThat(all).hasSize(1001);assertThat(all.getLast()).containsEntry("value","001001").containsEntry("label","中文 %_ 末尾").containsEntry("count",1L);
        assertThat(all.stream().map(row->row.get("value")).distinct().count()).isEqualTo(1001);
        try(var scope=com.uten.imp.common.web.NativeFacetCandidates.open("clientId","中文 %_",1,100)) {
            var request=new VersionedSummaryPages.Request(domain,"native_workshop_tasks",Map.of("field","clientId","keyword","中文 %_","mode","positional"),"all",1,100,100,null);
            var exact=pages.read(request,()->{},()->com.uten.imp.common.web.NativeFacets.jdbcRows(db,"clientId",
                    "SELECT lpad(id::text,6,'0'),value,COUNT(*) FROM summary_protocol_fixture WHERE id>? AND value<>? GROUP BY id,value",
                    new Object[]{0,"never-a-visible-label"},true),true);
            assertThat(exact.value()).singleElement().satisfies(row->assertThat(row).containsEntry("value","001001").containsEntry("label","中文 %_ 末尾").containsEntry("count",1L));
        }
        db.update("UPDATE summary_protocol_fixture SET value='中文已变化' WHERE id=1");changed(()->read.apply(2,first.readSnapshotRevision()));
        verify(authority,atLeastOnce()).scopeForCurrentSnapshot(anyString(),any(),eq(true));
        assertThat(com.uten.imp.common.web.NativeFacetCandidates.active()).isFalse();
    }
}
