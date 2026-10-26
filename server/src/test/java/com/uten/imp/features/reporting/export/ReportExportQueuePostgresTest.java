package com.uten.imp.features.reporting.export;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.*;
import java.util.concurrent.*;
import static org.junit.jupiter.api.Assertions.*;

/** Real migrated PostgreSQL queue: no fixtures or migrations touch a shared database. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ReportExportQueuePostgresTest {
    @org.junit.jupiter.api.io.TempDir java.nio.file.Path directory;
    static final PostgreSQLContainer POSTGRES=new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("b1_export_queue").withReuse(false)
            .withCreateContainerCmdModifier(cmd -> cmd.getHostConfig().withMemory(768L*1024*1024).withNanoCPUs(1_000_000_000L));
    static JdbcTemplate jdbc;
    static DriverManagerDataSource dataSource;
    static ReportExportRepository repository;
    static TransactionTemplate tx;
    static UUID owner;
    @BeforeAll static void migrate() {
        POSTGRES.start();
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword())
                .locations("classpath:db/migration").load().migrate();
        dataSource=new DriverManagerDataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());
        jdbc=new JdbcTemplate(dataSource);repository=new ReportExportRepository(new NamedParameterJdbcTemplate(dataSource));
        tx=new TransactionTemplate(new DataSourceTransactionManager(dataSource));
        owner=UUID.randomUUID();
        jdbc.update("""
            INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password)
            SELECT ?,id,'b1_export_fixture','test-only-fixture',false FROM employees WHERE code='ADMIN'
            """,owner);
    }
    @AfterAll static void stop() { POSTGRES.stop(); }
    @AfterEach void releaseFixtureJobs() {
        jdbc.update("UPDATE report_export_jobs SET status='FAILED',finished_at=clock_timestamp(),lease_until=NULL WHERE status IN ('PENDING','RUNNING')");
    }
    private static UUID insert() {
        var id=UUID.randomUUID();var request=new ReportExportRequest(id,"sales","ORDER/detail",Map.of(),null,null,null);
        tx.executeWithoutResult(s -> repository.insert(request,owner,1,1,"{\"id\":\""+id+"\",\"domain\":\"sales\",\"report\":\"ORDER/detail\"}","fixture-build","a".repeat(64)));
        return id;
    }
    private static ReportExportRepository.Job claim() { return tx.execute(s -> repository.claim().orElseThrow()); }
    @Test void cancellationRetainsTheWorkerSlotUntilAcknowledgedAndCannotPublish() {
        UUID first=insert(),second=insert();var running=claim();assertEquals(first,running.id());
        tx.executeWithoutResult(s -> repository.cancel(first,owner));
        var pendingCancel=repository.find(first).orElseThrow();
        assertTrue(pendingCancel.cancelRequested());assertEquals("RUNNING",pendingCancel.status());
        assertEquals(Boolean.TRUE,tx.execute(s -> repository.claim().isEmpty()));
        assertEquals(Boolean.FALSE,tx.execute(s -> repository.heartbeat(running,20)));
        assertEquals(Boolean.FALSE,tx.execute(s -> repository.succeed(running,20,100,"a".repeat(64))));
        tx.executeWithoutResult(s -> repository.acknowledgeCancellation(running));
        assertEquals("CANCELLED",repository.find(first).orElseThrow().status());
        assertEquals(second,claim().id());
    }
    @Test void crashedSnapshotFailsExplicitlyAndOldWorkerCannotUpdateNewWork() {
        UUID first=insert(),second=insert();var old=claim();
        String original=old.request();
        jdbc.update("UPDATE report_export_jobs SET lease_until=clock_timestamp()-interval '1 second' WHERE id=?",first);
        assertEquals(second,claim().id());
        assertEquals("FAILED",repository.find(first).orElseThrow().status());
        assertEquals(original,repository.find(first).orElseThrow().request());
        assertEquals(Boolean.FALSE,tx.execute(s -> repository.heartbeat(old,500)));
        assertEquals(Boolean.FALSE,tx.execute(s -> repository.succeed(old,500,100,"a".repeat(64))));
    }
    @Test void sessionSlotPreventsOverlapEvenWhenTheRowLeaseExpires() throws Exception {
        UUID first=insert();var running=claim();insert();
        try(var connection=dataSource.getConnection();var statement=connection.createStatement()) {
            statement.execute("SELECT pg_advisory_lock(935,2)");
            jdbc.update("UPDATE report_export_jobs SET lease_until=clock_timestamp()-interval '1 second' WHERE id=?",first);
            assertEquals(Boolean.TRUE,tx.execute(s -> repository.claim().isEmpty()));
            assertEquals("RUNNING",repository.find(running.id()).orElseThrow().status());
            statement.execute("SELECT pg_advisory_unlock(935,2)");
        }
        assertNotEquals(first,claim().id());
    }
    @Test void simultaneousClaimsStartOnlyOneTask() throws Exception {
        insert();insert();var start=new CountDownLatch(1);var executor=Executors.newFixedThreadPool(2);
        try {
            Callable<Integer> task=() -> {start.await();return tx.execute(s -> repository.claim().isPresent()?1:0);};
            var a=executor.submit(task);var b=executor.submit(task);start.countDown();
            assertEquals(1,a.get(15,TimeUnit.SECONDS)+b.get(15,TimeUnit.SECONDS));
        } finally {executor.shutdownNow();}
    }
    @Test void taskIdentityRequestAndExpiryHistoryRemainImmutable() {
        UUID id=insert();var running=claim();String request=running.request();
        assertEquals(Boolean.TRUE,tx.execute(s -> repository.succeed(running,0,100,"b".repeat(64))));
        assertThrows(org.springframework.dao.DataAccessException.class,() -> jdbc.update("DELETE FROM report_export_jobs WHERE id=?",id));
        assertThrows(org.springframework.dao.DataAccessException.class,() -> jdbc.execute("TRUNCATE report_export_jobs"));
        assertThrows(org.springframework.dao.DataAccessException.class,() -> jdbc.update("UPDATE report_export_jobs SET request='{}'::jsonb WHERE id=?",id));
        jdbc.update("UPDATE report_export_jobs SET expires_at=clock_timestamp()-interval '1 second' WHERE id=?",id);
        assertTrue(repository.expired().stream().anyMatch(job -> job.id().equals(id)));
        tx.executeWithoutResult(s -> repository.expire(id));
        assertEquals("EXPIRED",repository.find(id).orElseThrow().status());
        assertEquals(request,repository.find(id).orElseThrow().request());
    }
    @Test void rollbackDoesNotLeaveAPartiallySubmittedTask() {
        UUID id=UUID.randomUUID();
        assertThrows(IllegalStateException.class,() -> tx.executeWithoutResult(s -> {
            repository.insert(new ReportExportRequest(id,"sales","ORDER/detail",Map.of(),null,null,null),owner,1,1,"{}","fixture-build","a".repeat(64));
            throw new IllegalStateException("fixture rollback");
        }));
        assertTrue(repository.find(id).isEmpty());
    }
    @Test void workerKeepsOneRealSnapshotAcrossPagesAndDownloadRechecksAuthorization() throws Exception {
        jdbc.execute("CREATE TABLE IF NOT EXISTS b1_export_facts(id integer PRIMARY KEY,qty numeric,note text)");
        jdbc.execute("TRUNCATE b1_export_facts");
        jdbc.execute("INSERT INTO b1_export_facts SELECT i,1234567890123456.01,'原文-'||i FROM generate_series(1,600) i");
        UUID id=UUID.randomUUID();
        var request=new ReportExportRequest(id,"sales","ORDER/detail",Map.of(),null,null,null);
        var mapper=new com.fasterxml.jackson.databind.ObjectMapper();
        String json=mapper.writeValueAsString(request);
        tx.executeWithoutResult(s -> repository.insert(request,owner,1,1,json,"fixture-build","a".repeat(64)));
        var running=claim();
        var user=new com.uten.imp.security.AuthUser(owner,UUID.randomUUID(),"fixture",Set.of("sales_report:view","sales_report:export"),false,true,false);
        var users=org.mockito.Mockito.mock(com.uten.imp.security.SecurityContextCurrentUser.class);
        org.mockito.Mockito.when(users.get()).thenReturn(Optional.of(user));
        var restorer=org.mockito.Mockito.mock(com.uten.imp.security.SubmitterPrincipalRestorer.class);
        org.mockito.Mockito.when(restorer.restore(owner,1,1L)).thenReturn(user);
        var identity=org.mockito.Mockito.mock(ReportExportBuildIdentity.class);
        org.mockito.Mockito.when(identity.revision()).thenReturn("fixture-build");
        var readScopes=org.mockito.Mockito.mock(com.uten.imp.security.ReadScopeVersionAuthority.class);
        org.mockito.Mockito.when(readScopes.scopeFor(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.any())).thenReturn("a".repeat(64));
        org.springframework.beans.factory.ObjectProvider<com.uten.imp.common.export.ExportProjectionAccessGuard> projectionAccess=org.mockito.Mockito.mock(org.springframework.beans.factory.ObjectProvider.class);
        var service=new ReportExportService(repository,users,restorer,mapper,identity,org.mockito.Mockito.mock(com.uten.imp.security.ExportRateLimiter.class),readScopes,projectionAccess,directory.toString());
        var source=org.mockito.Mockito.mock(ReportExportSource.class);
        var columns=List.of(new com.uten.imp.common.export.ExportColumn("qty","数量","qty"),new com.uten.imp.common.export.ExportColumn("note","原文","text"));
        record Batch(List<Map<String,Object>> rows) { }
        var outside=new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword()));
        org.mockito.Mockito.when(source.read(request)).thenAnswer(call -> com.uten.imp.common.report.ReportQueryKit.paginateAll(1000,(page,size) -> {
            var rows=jdbc.queryForList("SELECT qty,note FROM b1_export_facts ORDER BY id LIMIT ? OFFSET ?",size,(page-1)*size);
            if(page==1) {
                outside.update("UPDATE b1_export_facts SET note='晚提交更正' WHERE id=600");
                outside.update("INSERT INTO b1_export_facts VALUES(601,1,'晚到行')");
            }
            return new Batch(rows);
        },batch -> -1,batch -> columns,Batch::rows));
        var worker=new ReportExportWorker(repository,service,source,restorer,new com.uten.imp.common.export.XlsxExportService(),jdbc,
                new DataSourceTransactionManager(dataSource));
        try {org.springframework.test.util.ReflectionTestUtils.invokeMethod(worker,"runWithSlot",running);} finally {worker.close();}
        var completed=repository.find(id).orElseThrow();
        assertEquals("SUCCEEDED",completed.status(),completed.error());assertEquals(600,completed.rows());
        assertNotNull(completed.snapshotAt());assertEquals(601,jdbc.queryForObject("SELECT count(*) FROM b1_export_facts",Integer.class));
        try(var input=java.nio.file.Files.newInputStream(service.artifact(completed));var book=new org.apache.poi.xssf.usermodel.XSSFWorkbook(input)) {
            assertEquals(600,book.getSheetAt(0).getLastRowNum());
            assertEquals("原文-600",book.getSheetAt(0).getRow(600).getCell(1).getStringCellValue());
            assertEquals("1234567890123456.01",book.getSheetAt(0).getRow(1).getCell(0).getStringCellValue());
        }
        var audit=org.mockito.Mockito.mock(com.uten.imp.audit.AuditService.class);
        var controller=new ReportExportController(service,new com.uten.imp.common.export.WorkbookDownloadService(),audit,users);
        var response=new org.springframework.mock.web.MockHttpServletResponse();
        controller.download(id,new com.uten.imp.common.export.ExportPasswordRequest(null),response);
        assertTrue(response.getContentAsByteArray().length>100);
        org.mockito.Mockito.when(restorer.restore(owner,1,1L)).thenThrow(new com.uten.imp.security.SubmitterPrincipalRestorer.PrincipalChangedException("revoked"));
        assertThrows(com.uten.imp.common.web.ApiException.class,() -> controller.download(id,
                new com.uten.imp.common.export.ExportPasswordRequest(null),new org.springframework.mock.web.MockHttpServletResponse()));
        try(var files=java.nio.file.Files.list(directory)) {
            assertEquals(List.of(service.artifact(completed)),files.toList());
        }
    }
}
