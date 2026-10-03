package com.uten.imp.features.attachment;

import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort.Confirmation;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.LocalDiskStorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.storage.InternalStorageService;
import com.uten.imp.common.storage.InternalStorageResetTestSupport;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Private real migrated PG + immutable LocalDisk files. Does not call a business DB or service. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class BusinessTestObjectCleanupPostgresTest {
    @TempDir Path files;
    MigratedSchemaBaseline.ScopedDatabase database;
    JdbcTemplate jdbc;TransactionTemplate tx;LocalDiskStorageService local;BusinessTestObjectCleanup cleanup;
    SecurityContextCurrentUser current;UUID actor;String account;AuditService audit;
    byte[] bytes="precise original content, never reconstructed from a hash".getBytes(StandardCharsets.UTF_8);

    @BeforeEach void start() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("business_test_originals");
        var ds=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        jdbc=new JdbcTemplate(ds);var manager=new DataSourceTransactionManager(ds);tx=new TransactionTemplate(manager);
        jdbc.execute("DO $role$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='uten') THEN CREATE ROLE uten NOLOGIN; END IF; END $role$");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE success AND version='782'",Long.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT to_regclass('public.business_test_object_cleanup_intents') IS NOT NULL",Boolean.class)).isTrue();
        var admin=jdbc.queryForList("SELECT id,login_account FROM users WHERE is_super_admin AND status='active' AND NOT is_deleted LIMIT 1");
        if(admin.isEmpty()) {
            UUID employee=UUID.randomUUID();actor=UUID.randomUUID();account="test-reset-"+actor;
            assertThat(jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'测试清空操作人','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"RST-"+employee)).isEqualTo(1);
            jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin) VALUES(?,?,?,'test-only',false,'active',true)",actor,employee,account);
        } else {actor=(UUID)admin.getFirst().get("id");account=(String)admin.getFirst().get("login_account");}
        current=mock(SecurityContextCurrentUser.class);when(current.get()).thenReturn(Optional.of(new AuthUser(actor,UUID.randomUUID(),account,Set.of(),false,true,true)));
        var binding=mock(TxSessionVars.class);
        doAnswer(call->{jdbc.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());
            jdbc.queryForObject("SELECT set_config('app.actor_account',?,true)",String.class,account);
            jdbc.queryForObject("SELECT set_config('app.audit_request_id',?,true)",String.class,UUID.randomUUID().toString());return null;}).when(binding).bind();
        var properties=new StorageProperties();properties.setLocalDir(files.toString());
        local=new LocalDiskStorageService(properties);ReflectionTestUtils.invokeMethod(local,"init");
        audit=mock(AuditService.class);var crypto=new CryptoProperties();crypto.setHmacKey("private-test-only-key-never-production");
        cleanup=new BusinessTestObjectCleanup(jdbc,new StorageProviderRegistry(local,properties),properties,current,binding,audit,new BusinessTestObjectSignature(crypto),manager);
    }
    @AfterEach void stop() throws Exception {if(database!=null)database.close();}

    @Test void retainedFinalNeedsNewTestProofAndOrdinaryWorkerCannotConsumeIt() throws Exception {
        String key=finalFile();UUID id=attachment("SALES_QUOTE",key,"RETAINED_HISTORY");
        assertThat(cleanup.preview(actor).items()).anySatisfy(item->assertThat(item.id()).isEqualTo(id));
        String fingerprintUtc=tx.execute(s->{jdbc.execute("SET LOCAL TIME ZONE 'UTC'");return cleanup.preview(actor).fingerprint();});
        String fingerprintShanghai=tx.execute(s->{jdbc.execute("SET LOCAL TIME ZONE 'Asia/Shanghai'");return jdbc.queryForObject("SELECT source_fingerprint FROM v_business_test_object_sources WHERE source_id=?",String.class,id.toString());});
        String sourceUtc=jdbc.queryForObject("SELECT source_fingerprint FROM v_business_test_object_sources WHERE source_id=?",String.class,id.toString());
        assertThat(fingerprintShanghai).isEqualTo(sourceUtc);assertThat(fingerprintUtc).isEqualTo(cleanup.preview(actor).fingerprint());
        UUID attempt=prepare();
        var properties=new StorageProperties();properties.setLocalDir(files.toString());
        var normal=new AttachmentObjectOutboxProcessor(jdbc,new StorageProviderRegistry(local,properties),properties,
            mock(AttachmentPreviewEvictor.class),tx.getTransactionManager());
        assertThat(normal.processNext()).isFalse();assertThat(Files.readAllBytes(files.resolve("final").resolve(key))).isEqualTo(bytes);
        assertThat(cleanup.drain(attempt)).isTrue();assertThat(cleanup.drain(attempt)).isFalse();
        assertThat(Files.exists(files.resolve("final").resolve(key))).isFalse();assertThat(cleanup.succeeded(attempt)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT lifecycle_state FROM attachments WHERE id=?",String.class,id)).isEqualTo("RETAINED_HISTORY");
        tx.executeWithoutResult(s->{testContext();jdbc.queryForObject("SELECT fn_clear_business_test_object_metadata()::text",String.class);});
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachments WHERE id=?",Long.class,id)).isZero();
    }
    @Test void rejectedSoleStagingIsTestClearableButValidUploadGrantStillBlocks() throws Exception {
        String key=stagingFile();UUID id=session(key,"REJECTED",Instant.now().minusSeconds(60));
        UUID live=session(UUID.randomUUID().toString().replace("-","")+".txt","PENDING",Instant.now().plusSeconds(3600));
        assertThat(cleanup.blockers(actor)).anySatisfy(group->assertThat(group.reason()).contains("上传凭证"));
        assertThatThrownBy(this::prepare).hasMessageContaining("上传凭证");
        jdbc.update("UPDATE attachment_upload_sessions SET expires_at=now()-interval '1 minute',status='EXPIRED' WHERE id=?",live);
        UUID attempt=prepare();while(cleanup.drain(attempt)){}
        assertThat(Files.exists(files.resolve("staging").resolve(key))).isFalse();
        assertThat(jdbc.queryForObject("SELECT status FROM attachment_upload_sessions WHERE id=?",String.class,id)).isEqualTo("REJECTED");
        assertThat(cleanup.preview(actor).blockingCount()).isZero();
    }
    @Test void masterSharedReferenceProtectsExactBytesAndLateReferencePreventsDeletion() throws Exception {
        String key=finalFile();UUID business=attachment("SALES_QUOTE",key,"CLEAN");
        UUID protectedId=sessionFor("GOODS",key,"EXPIRED",Instant.now().minusSeconds(60),"local",null,null);
        assertThat(cleanup.preview(actor).items()).noneSatisfy(item->assertThat(item.id()).isEqualTo(business));
        tx.executeWithoutResult(s->{testContext();jdbc.queryForObject("SELECT fn_clear_business_test_object_metadata()::text",String.class);});
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachments WHERE id=?",Long.class,business)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_upload_sessions WHERE id=?",Long.class,protectedId)).isEqualTo(1);
        assertThat(Files.readAllBytes(files.resolve("final").resolve(key))).isEqualTo(bytes);
        String late=finalFile();attachment("SALES_QUOTE",late,"CLEAN");UUID attempt=prepare();sessionFor("EMPLOYEE",late,"EXPIRED",Instant.now().minusSeconds(60),"local",null,null);
        assertThat(cleanup.drain(attempt)).isTrue();assertThat(Files.readAllBytes(files.resolve("final").resolve(late))).isEqualTo(bytes);
        assertThat(jdbc.queryForObject("SELECT status FROM business_test_object_cleanup_intents WHERE attempt_id=?",String.class,attempt)).isEqualTo("FAILED");
    }
    @Test void aiOriginalAndCandidateHistoryHaveMetadataOnlySourcesAndRealPhysicalProof() throws Exception {
        String original=finalFile();UUID job=UUID.randomUUID();
        jdbc.update("""
            INSERT INTO ai_input_originals(job_id,actor_user_id,original_name,input_kind,content_type,availability,
              declared_size,declared_sha256,storage_provider,storage_key,storage_size,storage_sha256,captured_at)
            VALUES(?,?,'original.pdf','PDF','application/pdf','AVAILABLE',?,?,'local',?,?,?,now())
            """,job,actor,bytes.length,sha(),original,bytes.length,sha());
        String history=finalFile();jdbc.update("""
            INSERT INTO sales_quote_template_candidate_history(job_id,payload,storage_provider,storage_key,operation)
            VALUES(?,jsonb_build_object('source_name','prior.xlsx','storage_size',?::bigint,'storage_sha256',?::text,'workbook_bytes',repeat('large-secret',10000)),'local',?,'UPDATE')
            """,UUID.randomUUID(),bytes.length,sha(),history);
        assertThat(jdbc.queryForList("SELECT column_name FROM information_schema.columns WHERE table_name='v_business_test_object_sources'",String.class))
            .doesNotContain("legacy_bytes","workbook_bytes","payload");
        UUID attempt=prepare();while(cleanup.drain(attempt)){}
        assertThat(Files.exists(files.resolve("final").resolve(original))).isFalse();assertThat(Files.exists(files.resolve("final").resolve(history))).isFalse();
        assertThat(cleanup.preview(actor).blockingCount()).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_candidate_history",Long.class)).isEqualTo(1);
    }
    @Test void directRuntimeWritesBadSignatureAndWrongCompletionIdentityCannotManufactureProof() throws Exception {
        String key=finalFile();UUID id=attachment("SALES_QUOTE",key,"CLEAN");UUID attempt=prepare();
        deniedSql(()->tx.executeWithoutResult(s->{bindActor();jdbc.execute("SET LOCAL ROLE uten");
            jdbc.update("UPDATE business_test_object_cleanup_intents SET status='SUCCEEDED',completed_at=now() WHERE attempt_id=?",attempt);
        }),"permission denied");
        // The preceding permission failure rolled its transaction back. Ticket is still pending.
        tx.executeWithoutResult(s->{bindActor();assertThat(jdbc.queryForObject("SELECT fn_test_object_complete(?,?,?,0,NULL,?,true,NULL)",Boolean.class,
            jdbc.queryForObject("SELECT id FROM business_test_object_cleanup_intents WHERE attempt_id=?",UUID.class,attempt),UUID.randomUUID(),actor,"0".repeat(64))).isFalse();});
        UUID badAttempt=UUID.randomUUID();
        tx.executeWithoutResult(state->{bindActor();jdbc.queryForObject("""
            SELECT fn_test_object_prepare(?::uuid,?::uuid,0,?::uuid,?::text,current_database(),source_type,source_id,source_fingerprint,
                object_location,storage_provider,storage_key,storage_version,true,size_bytes,sha256,repeat('b',64),now()+interval '5 minutes')::text
            FROM v_business_test_object_sources WHERE source_type='ATTACHMENT' AND source_id=?
            """,String.class,UUID.randomUUID(),badAttempt,actor,account,id.toString());});
        assertThat(cleanup.drain(badAttempt)).isTrue();
        assertThat(jdbc.queryForObject("SELECT status FROM business_test_object_cleanup_intents WHERE attempt_id=?",String.class,badAttempt)).isEqualTo("FAILED");
        assertThat(cleanup.preview(actor).blockingCount()).isEqualTo(1);assertThat(Files.exists(files.resolve("final").resolve(key))).isTrue();
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor,UUID.randomUUID(),account,Set.of(),false,true,false)));
        assertThatThrownBy(()->cleanup.drain(attempt)).hasMessageContaining("超级管理员");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM business_test_object_cleanup_intents WHERE status='SUCCEEDED'",Long.class)).isZero();
    }
    @Test void generationFenceRejectsOldTicketAndSourceChangeNeverDeletesNewBytes() throws Exception {
        String key=finalFile();UUID id=attachment("SALES_QUOTE",key,"CLEAN");UUID attempt=prepare();
        tx.executeWithoutResult(s->{testContext();jdbc.update("UPDATE authorization_state SET business_reset_generation=business_reset_generation+1 WHERE singleton_id=1");});
        assertThat(cleanup.drain(attempt)).isFalse();assertThat(cleanup.preview(actor).blockingCount()).isEqualTo(1);
        assertThat(Files.exists(files.resolve("final").resolve(key))).isTrue();
        UUID currentAttempt=prepare();
        // Legitimate mutable source-state change invalidates the reviewed fingerprint.
        jdbc.update("UPDATE attachments SET lifecycle_state='DELETE_PENDING' WHERE id=?",id);
        assertThat(cleanup.drain(currentAttempt)).isTrue();
        assertThat(Files.readAllBytes(files.resolve("final").resolve(key))).isEqualTo(bytes);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM business_test_object_cleanup_intents WHERE status='SUCCEEDED'",Long.class)).isZero();
    }
    @Test void incompleteMasterCostReferenceWithUnknownInternalVersionProtectsEveryVersion() {
        UUID goods=UUID.randomUUID();assertThat(jdbc.update("INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,'历史主档证据',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",goods,"RST-COST-"+goods)).isEqualTo(1);
        jdbc.update("""
            INSERT INTO goods_cost_imports(id,goods_id,actor_id,source_name,storage_provider,storage_key,storage_version,storage_size,storage_sha256,preview)
            VALUES(?,?,?,'old-cost.xlsx','internal','shared-internal-key',NULL,1,repeat('a',64),'{}'::jsonb)
            """,UUID.randomUUID(),goods,actor);
        assertThat(jdbc.queryForObject("SELECT fn_business_test_object_protected('internal','FINAL','shared-internal-key','actual-v1')",Boolean.class)).isTrue();
        assertThat(jdbc.queryForObject("SELECT fn_business_test_object_protected('internal','FINAL','shared-internal-key','actual-v2')",Boolean.class)).isTrue();
    }
    @Test void completedProofAllowsSameGenerationRetryButCannotAuthorizeOrdinaryRowDeletion() throws Exception {
        String key=finalFile();UUID id=attachment("SALES_QUOTE",key,"CLEAN");UUID attempt=prepare();assertThat(cleanup.drain(attempt)).isTrue();
        assertThat(cleanup.preview(actor).blockingCount()).isZero();
        assertThatThrownBy(()->jdbc.update("DELETE FROM attachments WHERE id=?",id)).hasMessageContaining("retained");
        deniedSql(()->jdbc.queryForObject("SELECT fn_clear_business_test_object_metadata()::text",String.class),"trusted test-reset context");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachments WHERE id=?",Long.class,id)).isEqualTo(1);
    }
    @Test void localOfflineNamespaceCannotCreateSucceededProofWhileNormalMissingLeafCan() throws Exception {
        String key=finalFile();attachment("SALES_QUOTE",key,"CLEAN");UUID attempt=prepare();
        Path saved=files.resolve("offline-final");Files.move(files.resolve("final"),saved);
        assertThat(cleanup.drain(attempt)).isTrue();
        assertThat(jdbc.queryForObject("SELECT status FROM business_test_object_cleanup_intents WHERE attempt_id=?",String.class,attempt)).isEqualTo("FAILED");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM business_test_object_cleanup_intents WHERE status='SUCCEEDED'",Long.class)).isZero();
        assertThat(Files.readAllBytes(saved.resolve(key))).isEqualTo(bytes);
        Files.move(saved,files.resolve("final"));
        UUID retry=prepare();assertThat(cleanup.drain(retry)).isTrue();assertThat(cleanup.preview(actor).blockingCount()).isZero();
        String missing=StorageService.generateStorageKey("absent.txt");attachment("SALES_QUOTE",missing,"DELETED");
        UUID absent=prepare();assertThat(cleanup.drain(absent)).isTrue();assertThat(cleanup.succeeded(absent)).isZero();
        String flat=StorageService.generateStorageKey("flat.txt");Files.write(files.resolve(flat),bytes);attachment("SALES_QUOTE",flat,"DELETED");
        assertThatThrownBy(this::prepare).hasMessageContaining("历史本地平铺原件");assertThat(Files.readAllBytes(files.resolve(flat))).isEqualTo(bytes);
    }
    @Test void internalFinalPhysicalDeletionCompletesWithExactTypedAbsence() throws Exception {
        InternalStorageService internal=useInternal();String key=StorageService.generateStorageKey("original.txt");
        internal.store(key,new ByteArrayInputStream(bytes),bytes.length,"text/plain");
        var object=internal.promoteToFinal(key,internal.describe(key));UUID id=internalAttachment(key,object,"CLEAN");
        UUID attempt=prepare();assertThat(cleanup.drain(attempt)).isTrue();assertThat(cleanup.drain(attempt)).isFalse();
        assertThat(jdbc.queryForMap("SELECT status,object_exists,storage_version,completed_at FROM business_test_object_cleanup_intents WHERE attempt_id=?",attempt))
            .containsEntry("status","SUCCEEDED").containsEntry("object_exists",true).containsEntry("storage_version",object.versionId()).doesNotContainEntry("completed_at",null);
        assertThat(cleanup.preview(actor).blockingCount()).isZero();
        assertThatThrownBy(()->internal.openFinal(key,object.versionId())).hasRootCauseInstanceOf(java.nio.file.NoSuchFileException.class);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachments WHERE id=?",Long.class,id)).isEqualTo(1);
    }
    @Test void selfContainedStagingDeleteTicketNeedsNoOwnerReconciliation() throws Exception {
        // AiInputOriginalStore 入队的 DELETE_STAGING 清理票不挂 attachment/session（外键 RESTRICT
        // 也保证了 UNKNOWN 属主的票必然双链接为空）：不得要求业务对账，物理缺席证明即完成。
        String key=UUID.randomUUID().toString().replace("-","")+".txt";
        jdbc.update("""
            INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key,status)
            VALUES('DELETE_STAGING','local',?,NULL,?,'SUCCEEDED')
            """,key,"local|DELETE_STAGING|"+key+"|<local>");
        UUID attempt=prepare();while(cleanup.drain(attempt)){}
        assertThat(cleanup.preview(actor).blockingCount()).isZero();
        // 票据行本身由 business_data_reset() 在清库时删除（见其函数体）；清理编排
        // 只负责把物理完成证明落账——此处断言证明已 SUCCEEDED 且不再阻塞。
        assertThat(jdbc.queryForObject("""
            SELECT count(*) FROM business_test_object_cleanup_intents
            WHERE storage_key=? AND status='SUCCEEDED' AND completed_at IS NOT NULL
            """,Long.class,key)).isEqualTo(1);
    }
    @Test void internalSoleStagingAndMissingFinalConvergeWithoutGenericIoAsSuccess() throws Exception {
        InternalStorageService internal=useInternal();String key=StorageService.generateStorageKey("original.txt");
        internal.store(key,new ByteArrayInputStream(bytes),bytes.length,"text/plain");var object=internal.describe(key);
        UUID id=sessionFor("SALES_QUOTE",key,"REJECTED",Instant.now().minusSeconds(60),"internal",object.versionId(),sha());
        UUID attempt=prepare();while(cleanup.drain(attempt)){}
        assertThat(internal.describe(key).exists()).isFalse();assertThat(cleanup.preview(actor).blockingCount()).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM business_test_object_cleanup_intents WHERE attempt_id=? AND status='SUCCEEDED'",Long.class,attempt)).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM business_test_object_cleanup_intents WHERE attempt_id=? AND status='SUCCEEDED' AND object_exists",Long.class,attempt)).isEqualTo(1);
    }
    @Test void preexistingMissingInternalOriginalCanBeProvenAbsentWhileDirectoriesRemainErrors() throws Exception {
        InternalStorageService internal=useInternal();String key=StorageService.generateStorageKey("original.txt");
        internal.store(key,new ByteArrayInputStream(bytes),bytes.length,"text/plain");var object=internal.promoteToFinal(key,internal.describe(key));
        internalAttachment(key,object,"DELETED");internal.delete(key,object.versionId());UUID attempt=prepare();assertThat(cleanup.drain(attempt)).isTrue();
        assertThat(cleanup.preview(actor).blockingCount()).isZero();assertThat(cleanup.succeeded(attempt)).isZero();
        String directory=StorageService.generateStorageKey("bad.txt");Files.createDirectory(files.resolve("internal/final").resolve(directory));
        internalAttachment(directory,object,"CLEAN");
        assertThatThrownBy(this::prepare).hasRootCauseMessage("Object is not a regular file");
        assertThat(Files.isDirectory(files.resolve("internal/final").resolve(directory))).isTrue();
    }
    private InternalStorageService useInternal() throws Exception {
        Path path=Files.createDirectories(files.resolve("internal"));var properties=new StorageProperties();properties.setProvider("internal");
        properties.getInternal().setRoot(path.toString());properties.getInternal().setMinFreeBytes(0);
        InternalStorageService internal=InternalStorageResetTestSupport.open(properties);var manager=new DataSourceTransactionManager(jdbc.getDataSource());
        var binding=mock(TxSessionVars.class);doAnswer(call->{bindActor();return null;}).when(binding).bind();
        var crypto=new CryptoProperties();crypto.setHmacKey("private-test-only-key-never-production");
        cleanup=new BusinessTestObjectCleanup(jdbc,new StorageProviderRegistry(internal,properties),properties,current,binding,audit,new BusinessTestObjectSignature(crypto),manager);
        return internal;
    }
    private UUID internalAttachment(String key,StorageService.StoredObject object,String state) {
        UUID id=UUID.randomUUID();jdbc.update("""
            INSERT INTO attachments(id,owner_type,owner_id,storage_key,storage_version,original_name,content_type,size_bytes,sha256,
                storage_provider,stored_size_bytes,storage_encoding,lifecycle_state,scan_engine,scanned_at,promoted_at)
            VALUES(?,'SALES_QUOTE',?,?,?,'internal original.txt','text/plain',?,?,'internal',?,? ,?,'private-test-clean',now(),now())
            """,id,UUID.randomUUID(),key,object.versionId(),bytes.length,sha(),object.storedSize(),object.encoding(),state);return id;
    }
    private UUID prepare(){var preview=cleanup.preview(actor);UUID attempt=UUID.randomUUID();cleanup.prepare(actor,account,attempt,new Confirmation(preview.database(),preview.fingerprint()));return attempt;}
    private String sha(){return ImmutableDocumentStore.digest(bytes);}
    private String stagingFile(){String key=UUID.randomUUID().toString().replace("-","")+".txt";local.store(key,new ByteArrayInputStream(bytes),bytes.length,"text/plain");return key;}
    private String finalFile(){String key=stagingFile();local.promoteToFinal(key,local.describe(key));return key;}
    private UUID attachment(String ownerType,String key,String state){UUID id=UUID.randomUUID();jdbc.update("""
        INSERT INTO attachments(id,owner_type,owner_id,storage_key,original_name,content_type,size_bytes,sha256,
            storage_provider,stored_size_bytes,storage_encoding,lifecycle_state,scan_engine,scanned_at,promoted_at)
        VALUES(?,?,?,?,'test original.txt','text/plain',?,?,'local',?,'IDENTITY',?,'private-test-clean',now(),now())
        """,id,ownerType,UUID.randomUUID(),key,bytes.length,sha(),bytes.length,state);return id;}
    private UUID session(String key,String status,Instant expiry){return sessionFor("SALES_QUOTE",key,status,expiry,"local",null,null);}
    private UUID sessionFor(String ownerType,String key,String status,Instant expiry,String provider,String version,String sha) {
        UUID id=UUID.randomUUID();jdbc.update("""
            INSERT INTO attachment_upload_sessions(id,storage_key,owner_type,owner_id,user_id,original_name,content_type,expected_size_bytes,
                expires_at,status,storage_provider,staging_version,sha256)
            VALUES(?,?,?, ?,?,'test upload.txt','text/plain',?,?,?,?,?,?)
            """,id,key,ownerType,UUID.randomUUID(),actor,bytes.length,Timestamp.from(expiry),status,provider,version,sha);return id;
    }
    private static void deniedSql(Runnable action,String reason) {
        Throwable failure=catchThrowable(action::run);assertThat(failure).isNotNull();
        Throwable cause=failure;while(cause.getCause()!=null)cause=cause.getCause();
        assertThat(cause).isInstanceOf(java.sql.SQLException.class);
        assertThat(((java.sql.SQLException)cause).getSQLState()).isEqualTo("42501");
        assertThat(cause.getMessage()).contains(reason);
    }
    private void bindActor(){jdbc.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());jdbc.queryForObject("SELECT set_config('app.actor_account',?,true)",String.class,account);jdbc.queryForObject("SELECT set_config('app.audit_request_id',?,true)",String.class,UUID.randomUUID().toString());}
    private void testContext(){bindActor();jdbc.queryForObject("SELECT set_config('app.test_business_reset','CLEAR_TEST_BUSINESS_WITH_HISTORY',true)",String.class);}
}
