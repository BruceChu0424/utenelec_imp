package com.uten.imp.features.ai.job;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiJobHandler.AiJobInput;
import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.jdbc.core.*;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Exact filesystem bytes plus current Flyway/JDBC transactions; no external AI or business database. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class AiInputOriginalPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static final AtomicInteger NUMBERS=new AtomicInteger(800000);
    @TempDir Path files;
    private JdbcTemplate jdbc;private TransactionTemplate tx;private AiJobRepository jobs;private AiJobUsageAdapter usage;
    private NamedParameterJdbcTemplate named;
    private AiInputOriginalStore originals;private ImmutableDocumentStore objects;private LocalDiskStorageService local;
    private SecurityContextCurrentUser current;private AttachmentOwnerAccessPolicy quotePolicy,orderPolicy;
    private UUID actor,employee;private final byte[] input="model,qty,price\r\nMODEL,1,123.45\r\n".getBytes(StandardCharsets.UTF_8);
    @AfterAll static void close() throws Exception {if(database!=null)database.close();}
    @BeforeEach void setup() throws Exception {
        if(database!=null)database.close();database=MigratedSchemaBaseline.openDatabase("ai_original_evidence");
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        jdbc=new JdbcTemplate(source);named=spy(new NamedParameterJdbcTemplate(source));tx=new TransactionTemplate(new DataSourceTransactionManager(source));
        employee=UUID.randomUUID();actor=UUID.randomUUID();
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'来源测试','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"ORI-"+employee);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-only',false,'active')",actor,employee,"original-"+actor);
        var properties=new StorageProperties();properties.setLocalDir(files.toString());local=new LocalDiskStorageService(properties);ReflectionTestUtils.invokeMethod(local,"init");
        objects=new ImmutableDocumentStore(local,new StorageProviderRegistry(local,properties));
        current=mock(SecurityContextCurrentUser.class);when(current.requireId()).thenReturn(actor);
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor,employee,"original-test",Set.of("ai:use","sales_order:price:view"),false,true,false)));
        quotePolicy=mock(AttachmentOwnerAccessPolicy.class);when(quotePolicy.ownerType()).thenReturn("SALES_QUOTE");
        orderPolicy=mock(AttachmentOwnerAccessPolicy.class);when(orderPolicy.ownerType()).thenReturn("SALES_ORDER");
        originals=new AiInputOriginalStore(named,objects,local,current,mock(AuditService.class),List.of(quotePolicy,orderPolicy));
        jobs=new AiJobRepository(named);usage=new AiJobUsageAdapter(jobs,new ObjectMapper(),originals);
    }
    private AiJobInput body(){return new AiJobInput("original.csv","text/csv","CSV",input.length,input,ImmutableDocumentStore.digest(input));}
    private UUID quote() {
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO sales_quotes(id,bill_no,bill_date,status) VALUES(?,'XB'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||?,CURRENT_DATE,0)",id,Integer.toString(NUMBERS.incrementAndGet()));return id;
    }
    private UUID order(UUID quote) {
        UUID client=UUID.randomUUID();jdbc.update("INSERT INTO clients(id,code,name,status,code_sequence,owner_employee_id) VALUES(?,?,?,'使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients),?)",client,"ORI-"+client,"原件客户",employee);
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO sales_orders(id,bill_no,bill_date,status,source_quote_id,client_id,owner_employee_id,maker_id) VALUES(?,'XD'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||?,CURRENT_DATE,0,?,?,?,?)",id,Integer.toString(NUMBERS.incrementAndGet()),quote,client,employee,employee);return id;
    }
    private UUID captured() {
        UUID id=UUID.randomUUID();tx.executeWithoutResult(s->{originals.capture(id,actor,"SALES_DOCUMENT_INTAKE",body());pending(id,input,ImmutableDocumentStore.digest(input),input.length);});
        jdbc.update("UPDATE ai_jobs SET status='SUCCEEDED',input_bytes=NULL,finished_at=now(),result='{\"lines\":[{\"key\":\"S1R2\"}]}'::jsonb WHERE id=?",id);return id;
    }
    private void pending(UUID id,byte[] bytes,String sha,int size) {
        jdbc.update("""
                INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,input_bytes,submitted_by_user,submitted_auth_version)
                VALUES(?,'SALES_DOCUMENT_INTAKE','PENDING','original.csv','text/csv','CSV',?,?,?, ?,1)
                """,id,size,sha,bytes,actor);
    }
    private void bind(UUID job,UUID doc) {tx.executeWithoutResult(s->assertThat(usage.reserveLearningForSave(job,actor,"quote",doc,java.time.OffsetDateTime.now().plusDays(30),Set.of("S1R2"),false)).isTrue());}

    @Test void originalIsBoundWithSavedDocumentBeforeLearningAndSurvivesAllJobAndPayloadExpiry() {
        UUID job=captured(),quote=quote();bind(job,quote);
        assertThat(originals.download("quote",quote,job).bytes()).isEqualTo(input);
        assertThat(jdbc.queryForObject("SELECT temporary_until IS NULL FROM ai_input_originals WHERE job_id=?",Boolean.class,job)).isTrue();
        tx.executeWithoutResult(s->usage.markUsed(job,actor,"quote",quote));
        jdbc.update("UPDATE ai_jobs SET created_at=now()-interval '30 days',finished_at=now()-interval '8 days' WHERE id=?",job);
        assertThat(jobs.deleteFinishedOlderThan(7)).isZero();
        assertThat(originals.purgeExpiredTemporary()).isZero();
        assertThat(originals.download("quote",quote,job).bytes()).isEqualTo(input);
        assertThat(jdbc.queryForObject("SELECT availability FROM ai_input_originals WHERE job_id=?",String.class,job)).isEqualTo("AVAILABLE");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE operation='DELETE_FINAL' AND storage_key=(SELECT storage_key FROM ai_input_originals WHERE job_id=?)",Integer.class,job)).isZero();
        assertThat(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM v_private_document_storage_references r JOIN ai_input_originals o ON r.storage_provider=o.storage_provider AND r.storage_key=o.storage_key AND r.storage_version IS NOT DISTINCT FROM o.storage_version WHERE o.job_id=?)",Boolean.class,job)).isTrue();
    }
    @Test void quoteConversionAddsAnIndependentBindingWithoutReusingTheAiResult() {
        UUID job=captured(),quote=quote();bind(job,quote);tx.executeWithoutResult(s->usage.markUsed(job,actor,"quote",quote));
        UUID order=order(quote);assertThat(originals.download("order",order,job).bytes()).isEqualTo(input);
        assertThat(originals.download("quote",quote,job).bytes()).isEqualTo(input);
        assertThat(jdbc.queryForObject("SELECT source_doc_id FROM ai_input_original_bindings WHERE job_id=? AND doc_type='order'",UUID.class,job)).isEqualTo(quote);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_input_original_bindings WHERE job_id=?",Integer.class,job)).isEqualTo(2);
        assertThat(usage.resultFor(job,actor)).isEmpty();
        assertThatThrownBy(()->jdbc.update("DELETE FROM ai_input_original_bindings WHERE job_id=?",job)).hasMessageContaining("append-only");
    }
    @Test void rollbackCannotPublishABindingOrDestroyThePreviousSuccessfulOriginal() {
        UUID job=captured(),quote=quote();tx.executeWithoutResult(s->{usage.reserveLearningForSave(job,actor,"quote",quote,java.time.OffsetDateTime.now().plusDays(30),Set.of("S1R2"),false);s.setRollbackOnly();});
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_input_original_bindings WHERE job_id=?",Integer.class,job)).isZero();assertThat(usage.resultFor(job,actor)).isPresent();
        bind(job,quote);assertThat(originals.download("quote",quote,job).bytes()).isEqualTo(input);
        UUID failed=UUID.randomUUID();tx.executeWithoutResult(s->{originals.capture(failed,actor,"SALES_DOCUMENT_INTAKE",body());s.setRollbackOnly();});
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_input_originals WHERE job_id=?",Integer.class,failed)).isZero();
        assertThat(originals.download("quote",quote,job).bytes()).isEqualTo(input);
    }
    @Test void oldNodeNewInsertAndTerminalWipePreserveExactLegacyBytesWithoutWeakeningV742() {
        UUID job=UUID.randomUUID(),quote=quote();pending(job,input,ImmutableDocumentStore.digest(input),input.length);
        jdbc.update("UPDATE ai_jobs SET status='SUCCEEDED',input_bytes=NULL,finished_at=now(),result='{\"lines\":[{\"key\":\"S1R2\"}]}'::jsonb WHERE id=?",job);
        assertThat(jdbc.queryForObject("SELECT input_bytes IS NULL FROM ai_jobs WHERE id=?",Boolean.class,job)).isTrue();bind(job,quote);
        assertThat(jdbc.queryForObject("SELECT availability FROM ai_input_originals WHERE job_id=?",String.class,job)).isEqualTo("LEGACY_DB");
        assertThat(originals.download("quote",quote,job).bytes()).isEqualTo(input);
        jdbc.update("DELETE FROM ai_jobs WHERE id=?",job);assertThat(originals.download("quote",quote,job).bytes()).isEqualTo(input);
    }
    @Test void corruptLegacyClaimsArePreservedSeparatelyButCannotBeBoundOrDownloaded() {
        UUID job=UUID.randomUUID(),quote=quote();pending(job,input,"a".repeat(64),input.length+1);
        jdbc.update("UPDATE ai_jobs SET status='SUCCEEDED',input_bytes=NULL,finished_at=now(),result='{\"lines\":[{\"key\":\"S1R2\"}]}'::jsonb WHERE id=?",job);
        assertThat(jdbc.queryForObject("SELECT legacy_bytes FROM ai_input_originals WHERE job_id=?",byte[].class,job)).isEqualTo(input);
        assertThat(jdbc.queryForObject("SELECT availability FROM ai_input_originals WHERE job_id=?",String.class,job)).isEqualTo("LEGACY_CONFLICT");
        assertThatThrownBy(()->bind(job,quote)).hasMessageContaining("Historical original");
        assertThat(jdbc.queryForObject("SELECT used_doc_id IS NULL FROM ai_jobs WHERE id=?",Boolean.class,job)).isTrue();
        jdbc.execute("ALTER TABLE ai_input_original_bindings DISABLE TRIGGER trg_ai_original_binding_guard");
        try {jdbc.update("INSERT INTO ai_input_original_bindings(job_id,doc_type,doc_id,source_doc_type,source_doc_id) VALUES(?,'quote',?,'quote',?)",job,quote,quote);} finally {jdbc.execute("ALTER TABLE ai_input_original_bindings ENABLE TRIGGER trg_ai_original_binding_guard");} // private fixture represents pre-migration historical adoption

        assertThatThrownBy(()->originals.download("quote",quote,job)).hasMessageContaining("不可用或内容异常");
    }
    @Test void missingLegacyBytesAreAnExplicitPlaceholderNotAFabricatedFile() {
        UUID job=UUID.randomUUID(),quote=quote();
        jdbc.update("INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,submitted_by_user,submitted_auth_version,finished_at) VALUES(?,'SALES_DOCUMENT_INTAKE','SUCCEEDED','lost.pdf','application/pdf','PDF',1,repeat('a',64),?,1,now())",job,actor);
        jdbc.execute("ALTER TABLE ai_input_original_bindings DISABLE TRIGGER trg_ai_original_binding_guard");
        try {jdbc.update("INSERT INTO ai_input_original_bindings(job_id,doc_type,doc_id,source_doc_type,source_doc_id) VALUES(?,'quote',?,'quote',?)",job,quote,quote);} finally {jdbc.execute("ALTER TABLE ai_input_original_bindings ENABLE TRIGGER trg_ai_original_binding_guard");} // private fixture represents pre-migration historical adoption

        assertThat(jdbc.queryForObject("SELECT availability FROM ai_input_originals WHERE job_id=?",String.class,job)).isEqualTo("LEGACY_UNAVAILABLE");
        assertThat(jdbc.queryForObject("SELECT legacy_bytes IS NULL FROM ai_input_originals WHERE job_id=?",Boolean.class,job)).isTrue();
        assertThatThrownBy(()->originals.download("quote",quote,job)).hasMessageContaining("不可用或内容异常");
    }
    @Test void unadoptedTemporaryOriginalIsReclaimedButAnActiveLearningSourceAndFormalBindingAreProtected() {
        UUID abandoned=captured(),formal=captured(),quote=quote();bind(formal,quote);
        jdbc.update("UPDATE ai_jobs SET result=NULL WHERE id=?",abandoned);
        jdbc.update("UPDATE ai_input_originals SET temporary_until=now()-interval '1 second' WHERE job_id=?",abandoned);
        assertThat(originals.purgeExpiredTemporary()).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT archived_at IS NOT NULL FROM ai_input_originals WHERE job_id=?",Boolean.class,abandoned)).isTrue();
        tx.executeWithoutResult(s->originals.bind(abandoned,actor,"quote",quote));
        assertThat(originals.download("quote",quote,abandoned).bytes()).isEqualTo(input);
        assertThat(originals.download("quote",quote,formal).bytes()).isEqualTo(input);
    }
    @Test void objectScopeAndSensitivePermissionAreCheckedBeforeOriginalRead() {
        UUID job=captured(),quote=quote();bind(job,quote);
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(quotePolicy).requireCanViewSensitiveOriginalHistory(eq(quote),any());
        assertThatThrownBy(()->originals.download("quote",quote,job)).isInstanceOf(ApiException.class).hasMessageContaining("权限");
        doThrow(new ApiException(ErrorCode.NOT_FOUND)).when(quotePolicy).requireCanViewSensitiveOriginalHistory(eq(quote),any());
        assertThatThrownBy(()->originals.download("quote",quote,job)).isInstanceOf(ApiException.class);
        UUID unrelated=quote();assertThatThrownBy(()->originals.download("quote",unrelated,job)).isInstanceOf(ApiException.class);
    }

    @Test void clearedReceiptShellsAreExcludedFromThePayloadExpiryIndex() {
        jdbc.update("""
                INSERT INTO sales_document_learning_receipts(id,doc_type,doc_id,actor_user_id,request_payload,steps,retry_until)
                SELECT gen_random_uuid(),'quote',gen_random_uuid(),?,
                    '{"lines":[],"clientFields":{}}'::jsonb,'{"MASTER":{"status":"SUCCEEDED"}}'::jsonb,now()-interval '1 year'
                FROM generate_series(1,1000)
                """,actor);
        jdbc.update("""
                INSERT INTO sales_document_learning_receipts(id,doc_type,doc_id,actor_user_id,request_payload,steps,retry_until)
                SELECT gen_random_uuid(),'quote',gen_random_uuid(),?,
                    '{"lines":[{"source":"pending"}],"clientFields":{}}'::jsonb,'{"MASTER":{"status":"FAILED"}}'::jsonb,now()-interval '1 day'
                FROM generate_series(1,3)
                """,actor);
        jdbc.execute("ANALYZE sales_document_learning_receipts");
        String plan=String.join("\n",jdbc.queryForList("""
                EXPLAIN (ANALYZE,BUFFERS,COSTS) SELECT id FROM sales_document_learning_receipts
                WHERE retry_until<now() AND archived_at IS NULL AND (evidence<>'{}'::jsonb OR request_payload->'lines'<>'[]'::jsonb
                    OR request_payload->'clientFields'<>'{}'::jsonb)
                ORDER BY retry_until,id LIMIT 1000
                """,String.class));
        System.out.println("AI_ORIGINAL_RECEIPT_PAYLOAD_PLAN "+plan.replace('\n',' '));
        assertThat(plan).contains("idx_sales_learning_receipts_payload_expiry");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_document_learning_receipts WHERE evidence<>'{}'::jsonb OR request_payload->'lines'<>'[]'::jsonb OR request_payload->'clientFields'<>'{}'::jsonb",Integer.class)).isEqualTo(3);
    }

    @Test void availableAndLegacyDbNullMetadataCannotBypassPostgresChecks() {
        for(String omitted:List.of("storage_provider","storage_size","storage_sha256")) {
            var columns=new LinkedHashMap<String,Object>();columns.put("storage_provider","local");columns.put("storage_size",1L);columns.put("storage_sha256","a".repeat(64));columns.put(omitted,null);
            assertThatThrownBy(()->jdbc.update("INSERT INTO ai_input_originals(job_id,actor_user_id,original_name,input_kind,content_type,availability,storage_provider,storage_key,storage_size,storage_sha256,declared_size,declared_sha256,captured_at) VALUES(?,?,'bad.csv','CSV','text/csv','AVAILABLE',?,'nonempty',?,?,1,repeat('a',64),now())",UUID.randomUUID(),actor,columns.get("storage_provider"),columns.get("storage_size"),columns.get("storage_sha256"))).hasMessageContaining("check constraint");
        }
        byte[] bytes={1};String sha=ImmutableDocumentStore.digest(bytes);
        assertThatThrownBy(()->jdbc.update("INSERT INTO ai_input_originals(job_id,actor_user_id,original_name,input_kind,content_type,availability,declared_size,storage_size,storage_sha256,legacy_bytes) VALUES(?,?,'bad.csv','CSV','text/csv','LEGACY_DB',1,1,?,?)",UUID.randomUUID(),actor,sha,bytes)).hasMessageContaining("check constraint");
        assertThatThrownBy(()->jdbc.update("INSERT INTO ai_input_originals(job_id,actor_user_id,original_name,input_kind,content_type,availability,declared_size,declared_sha256,storage_size,legacy_bytes) VALUES(?,?,'bad.csv','CSV','text/csv','LEGACY_DB',1,?,1,?)",UUID.randomUUID(),actor,sha,bytes)).hasMessageContaining("check constraint");
    }

    @Test void archivalWaitingAndOldAdoptionKeepTheSourceReadableWithoutPhysicalDeletion() throws Exception {
        UUID job=captured(),quote=quote();jdbc.update("UPDATE ai_jobs SET result=NULL WHERE id=?",job);
        var source=Objects.requireNonNull(jdbc.getDataSource());
        try(var owner=source.getConnection();var worker=Executors.newSingleThreadExecutor()) {
            owner.setAutoCommit(false);
            try(var lock=owner.prepareStatement("UPDATE ai_input_originals SET archived_at=now(),archived_by='retention_system',archive_reason='UNUSED_WINDOW_EXPIRED' WHERE job_id=?")) {
                lock.setObject(1,job);lock.executeUpdate();
                CountDownLatch started=new CountDownLatch(1);
                Future<?> adoption=worker.submit(()->{started.countDown();jdbc.update("UPDATE ai_jobs SET used_doc_type='quote',used_doc_id=?,used_at=now() WHERE id=?",quote,job);});
                assertThat(started.await(5,TimeUnit.SECONDS)).isTrue();owner.commit();
                adoption.get(10,TimeUnit.SECONDS);
            } finally {owner.rollback();}
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_input_original_bindings WHERE job_id=?",Integer.class,job)).isEqualTo(1);
        assertThat(originals.download("quote",quote,job).bytes()).isEqualTo(input);
        assertThatThrownBy(()->jdbc.update("UPDATE ai_input_originals SET lifecycle_state='DELETE_PENDING' WHERE job_id=?",job)).isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
    }
}
