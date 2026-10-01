package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import java.util.UUID;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

/** Real claim SQL and durable staging intents; physical storage is injected, no business/server writes. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class AttachmentCleanupLeasePostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private JdbcTemplate jdbc;
    private StorageService storage;
    private StorageProperties properties;
    private StorageProviderRegistry providers;
    private AttachmentObjectOutboxProcessor processor;
    @BeforeAll static void open() throws Exception { database=MigratedSchemaBaseline.openDatabase("attachment_cleanup_lease"); }
    @AfterAll static void close() throws Exception { if(database!=null)database.close(); }
    @BeforeEach void setup() {
        jdbc=new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
        jdbc.execute("TRUNCATE attachment_object_outbox,attachment_upload_sessions,attachment_reconciliation_findings CASCADE");
        storage=mock(StorageService.class);properties=new StorageProperties();properties.getOutbox().setStaleProcessingMinutes(1);
        providers=mock(StorageProviderRegistry.class);when(providers.require("local")).thenReturn(storage);
        processor=new AttachmentObjectOutboxProcessor(jdbc,providers,properties,mock(AttachmentPreviewEvictor.class),new DataSourceTransactionManager(jdbc.getDataSource()));
    }
    @Test void lateSuccessCannotCompleteTheNewerProcessingPhysicalDeletionAttempt() throws Exception {
        UUID id=operation();AtomicInteger calls=new AtomicInteger();
        CountDownLatch claimed=new CountDownLatch(1),release=new CountDownLatch(1);
        try(var worker=Executors.newSingleThreadExecutor()) {
            doAnswer(invocation->{
                if(calls.incrementAndGet()==1){
                    jdbc.update("UPDATE attachment_object_outbox SET locked_at=now()-interval '2 minutes' WHERE id=?",id);
                    worker.submit(processor::processNext);
                    assertThat(claimed.await(10,TimeUnit.SECONDS)).isTrue();return null;
                }
                claimed.countDown();assertThat(release.await(10,TimeUnit.SECONDS)).isTrue();
                return null;
            }).when(storage).deleteStaging("test-staging",null);
            try {
                assertThat(processor.processNext()).isTrue();
                assertThat(jdbc.queryForObject("SELECT status||':'||attempts FROM attachment_object_outbox WHERE id=?",String.class,id)).isEqualTo("PROCESSING:2");
            } finally {release.countDown();}
        }
        assertThat(jdbc.queryForObject("SELECT status||':'||attempts FROM attachment_object_outbox WHERE id=?",String.class,id)).isEqualTo("SUCCEEDED:2");
    }
    @Test void lateFailureCannotFailTheNewerProcessingPhysicalDeletionAttempt() throws Exception {
        UUID id=operation();AtomicInteger calls=new AtomicInteger();
        CountDownLatch claimed=new CountDownLatch(1),release=new CountDownLatch(1);
        try(var worker=Executors.newSingleThreadExecutor()) {
            doAnswer(invocation->{
                if(calls.incrementAndGet()==1){
                    jdbc.update("UPDATE attachment_object_outbox SET locked_at=now()-interval '2 minutes' WHERE id=?",id);
                    worker.submit(processor::processNext);
                    assertThat(claimed.await(10,TimeUnit.SECONDS)).isTrue();
                    throw new IllegalStateException("old attempt storage failure");
                }
                claimed.countDown();assertThat(release.await(10,TimeUnit.SECONDS)).isTrue();return null;
            }).when(storage).deleteStaging("test-staging",null);
            try {
                assertThat(processor.processNext()).isTrue();
                assertThat(jdbc.queryForObject("SELECT status||':'||attempts FROM attachment_object_outbox WHERE id=?",String.class,id)).isEqualTo("PROCESSING:2");
            } finally {release.countDown();}
        }
        assertThat(jdbc.queryForObject("SELECT status||':'||attempts FROM attachment_object_outbox WHERE id=?",String.class,id)).isEqualTo("SUCCEEDED:2");
    }
    @Test void absenceAtExpiryStillQueuesADelayedCheckForALateStagingWrite() {
        UUID session=upload("PENDING");
        when(storage.describe("late-upload")).thenReturn(new StorageService.StoredObject(false,0,null,null,null));
        var sessions=new AttachmentUploadSessionStore(jdbc,properties);
        var expiry=new AttachmentUploadExpiryScheduler(sessions,new AttachmentObjectOutboxStore(jdbc),providers);
        expiry.expire();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE upload_session_id=? AND operation='DELETE_STAGING' AND available_at>now()",Integer.class,session)).isEqualTo(1);
        jdbc.update("UPDATE attachment_object_outbox SET available_at=now() WHERE upload_session_id=?",session);
        assertThat(processor.processNext()).isTrue();
        verify(storage).deleteStaging("late-upload",null);
        verify(storage,never()).delete(anyString(),any());
    }

    @Test void failedExpiryLookupRetriesOneDurableVerificationAndProtectsScanningGrace() {
        UUID session=upload("SCANNING");
        var sessions=new AttachmentUploadSessionStore(jdbc,properties);
        var expiry=new AttachmentUploadExpiryScheduler(sessions,new AttachmentObjectOutboxStore(jdbc),providers);
        expiry.expire();verifyNoInteractions(storage);
        jdbc.update("UPDATE attachment_upload_sessions SET expires_at=now()-interval '2 minutes' WHERE id=?",session);
        when(storage.describe("late-upload")).thenThrow(new IllegalStateException("test-only lookup failure"))
                .thenReturn(new StorageService.StoredObject(false,0,null,null,null));
        expiry.expire();
        assertThat(jdbc.queryForObject("SELECT last_failure_code FROM attachment_upload_sessions WHERE id=?",String.class,session)).isEqualTo("CLEANUP_LOOKUP_FAILED");
        jdbc.update("UPDATE attachment_upload_sessions SET updated_at=now()-interval '2 minutes' WHERE id=?",session);
        expiry.expire();
        assertThat(jdbc.queryForObject("SELECT last_failure_code FROM attachment_upload_sessions WHERE id=?",String.class,session)).isEqualTo("NO_STAGING_OBJECT");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE upload_session_id=?",Integer.class,session)).isEqualTo(1);
    }

    private UUID upload(String status) {
        UUID session=UUID.randomUUID();
        UUID employee=UUID.randomUUID(),actor=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,'清理回归','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'
                """,employee,"EX-"+employee);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-only',false,'active')",actor,employee,"expiry-"+actor);
        jdbc.update("""
                INSERT INTO attachment_upload_sessions(id,storage_key,owner_type,owner_id,user_id,original_name,
                    content_type,expected_size_bytes,expires_at,storage_provider,status)
                VALUES(?,'late-upload','GOODS',?,?,'test.txt','text/plain',1,now()-interval '1 second','local',?)
                """,session,UUID.randomUUID(),actor,status);
        return session;
    }
    @Test void internalLateStagingPinsItsObservedVersionBeforePhysicalDeletion() {
        UUID id=UUID.randomUUID();String key="i1_GOODS_202610_"+UUID.randomUUID()+".txt";
        jdbc.update("INSERT INTO attachment_object_outbox(id,operation,storage_key,dedupe_key,storage_provider) VALUES(?,'DELETE_STAGING',?,?,'internal')",id,key,id.toString());
        when(providers.require("internal")).thenReturn(storage);
        when(storage.describe(key)).thenReturn(new StorageService.StoredObject(true,1,"text/plain","observed-version",null));
        doAnswer(invocation->{
            assertThat(jdbc.queryForObject("SELECT storage_version FROM attachment_object_outbox WHERE id=?",String.class,id)).isEqualTo("observed-version");
            return null;
        }).when(storage).deleteStaging(key,"observed-version");
        assertThat(processor.processNext()).isTrue();
        verify(storage).deleteStaging(key,"observed-version");verify(storage,never()).deleteStaging(key,null);
        assertThat(jdbc.queryForObject("SELECT status FROM attachment_object_outbox WHERE id=?",String.class,id)).isEqualTo("SUCCEEDED");
    }

    @Test void failedReceiptTransactionRollsBackCompletionAndRetriesTheWholeReceipt() {
        UUID id=operation();UUID finding=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO attachment_reconciliation_findings(id,object_location,storage_key,size_bytes,
                    finding_state,evidence_sha256,approved_at,approved_by,approval_reference,storage_provider)
                VALUES(?,'STAGING','test-staging',1,'QUEUED',repeat('a',64),now(),?,'test-only','local')
                """,finding,UUID.randomUUID());
        jdbc.execute("CREATE FUNCTION lifecycle_fixture_receipt_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'private fixture receipt failure'; END $$");
        jdbc.execute("CREATE TRIGGER lifecycle_fixture_receipt_failure BEFORE UPDATE ON attachment_reconciliation_findings FOR EACH ROW EXECUTE FUNCTION lifecycle_fixture_receipt_failure()");
        try {
            assertThat(processor.processNext()).isTrue();
            assertThat(jdbc.queryForObject("SELECT status FROM attachment_object_outbox WHERE id=?",String.class,id)).isEqualTo("FAILED");
            assertThat(jdbc.queryForObject("SELECT finding_state FROM attachment_reconciliation_findings WHERE id=?",String.class,finding)).isEqualTo("QUEUED");
        } finally {
            jdbc.execute("DROP TRIGGER lifecycle_fixture_receipt_failure ON attachment_reconciliation_findings");
            jdbc.execute("DROP FUNCTION lifecycle_fixture_receipt_failure()");
        }
        jdbc.update("UPDATE attachment_object_outbox SET available_at=now() WHERE id=?",id);
        assertThat(processor.processNext()).isTrue();
        assertThat(jdbc.queryForObject("SELECT status FROM attachment_object_outbox WHERE id=?",String.class,id)).isEqualTo("SUCCEEDED");
        assertThat(jdbc.queryForObject("SELECT finding_state FROM attachment_reconciliation_findings WHERE id=?",String.class,finding)).isEqualTo("RESOLVED");
    }

    private UUID operation() {
        UUID id=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO attachment_object_outbox(id,operation,storage_key,dedupe_key,storage_provider)
                VALUES(?,'DELETE_STAGING','test-staging',?,'local')
                """,id,id.toString());
        return id;
    }
}
