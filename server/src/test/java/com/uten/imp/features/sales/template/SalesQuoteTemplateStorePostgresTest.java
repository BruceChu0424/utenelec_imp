package com.uten.imp.features.sales.template;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.LocalDiskStorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.sales.intake.SalesIntakeUsedEvent;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.file.Path;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SalesQuoteTemplateStorePostgresTest {
    private static final PostgreSQLContainer<?> DB = MigratedSchemaBaseline.startMigratedContainer("quote_template_store");
    @TempDir Path files;
    private JdbcTemplate jdbc;
    private TransactionTemplate tx;
    private SalesQuoteTemplateStore store;
    private MasterIntakeLookupPort lookup;
    private SecurityContextCurrentUser current;
    private UUID actor;
    private UUID client;
    private UUID otherClient;

    @AfterAll static void close() { DB.stop(); }
    @BeforeEach void setup() throws Exception {
        var source = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(source);
        tx = new TransactionTemplate(new DataSourceTransactionManager(source));
        actor = UUID.randomUUID(); UUID employee = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,'模板测试','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'
                """, employee, "TE-" + employee);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-only',false,'active')",
                actor, employee, "template-" + actor);
        client = client(employee); otherClient = client(employee);
        current = mock(SecurityContextCurrentUser.class); when(current.id()).thenReturn(Optional.of(actor));
        lookup = mock(MasterIntakeLookupPort.class); when(lookup.canLearnClientDocument(any())).thenReturn(true);
        var properties = new StorageProperties(); properties.setLocalDir(files.toString());
        var local = new LocalDiskStorageService(properties); ReflectionTestUtils.invokeMethod(local, "init");
        var storage = new SalesQuoteTemplateStorage(new com.uten.imp.common.storage.ImmutableDocumentStore(local, new StorageProviderRegistry(local, properties), com.uten.imp.common.files.malware.DocumentSafetyTestSupport.scanning()));
        store = new SalesQuoteTemplateStore(new NamedParameterJdbcTemplate(source), new ObjectMapper(), lookup, current,
                mock(AuditService.class), storage);
    }

    @Test void sameLayoutLearnsOncePerJobAndUsesPrivateFilesWithoutNewVersionForZipDifferences() {
        var candidate = QuoteTemplateWorkbook.defaultTemplate();
        UUID job = job(); stage(job, candidate); succeed(job);
        var event = event(job, client);
        tx.executeWithoutResult(s -> store.adopt(event));
        tx.executeWithoutResult(s -> store.adopt(event));
        UUID secondJob = job(); stage(secondJob, QuoteTemplateWorkbook.defaultTemplate()); succeed(secondJob);
        tx.executeWithoutResult(s -> store.adopt(event(secondJob, client)));
        var list = store.list(client);
        assertThat(list).hasSize(1); assertThat(list.getFirst().useCount()).isEqualTo(2); assertThat(list.getFirst().version()).isEqualTo(1);
        assertThat(store.load(client, list.getFirst().id()).bytes()).isEqualTo(candidate.xlsx());
        assertThat(jdbc.queryForObject("SELECT workbook_bytes IS NULL AND storage_provider='local' FROM sales_quote_template_versions WHERE template_id=?", Boolean.class, list.getFirst().id())).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_evidence WHERE template_id=?", Integer.class, list.getFirst().id())).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE operation='DELETE_FINAL' AND storage_key IN (SELECT storage_key FROM sales_quote_template_versions WHERE template_id=?)", Integer.class, list.getFirst().id())).isZero();
    }

    @Test void differentSemanticsRemainSelectableAndCannotLoadAnotherCustomersTemplate() {
        var normal = QuoteTemplateWorkbook.defaultTemplate();
        UUID first = job(); stage(first, normal); succeed(first);
        tx.executeWithoutResult(s -> store.adopt(event(first, client)));
        Set<String> changed = new TreeSet<>(normal.features()); changed.remove("role:G:UNIT_PRICE"); changed.add("role:G:DISCOUNT");
        var different = new QuoteTemplateWorkbook.Candidate(normal.xlsx(), "b".repeat(64), normal.mapping(), changed);
        UUID second = job(); stage(second, different); succeed(second);
        tx.executeWithoutResult(s -> store.adopt(event(second, client)));
        assertThat(store.list(client)).hasSize(2);
        UUID template = store.list(client).getFirst().id();
        assertThatThrownBy(() -> store.load(otherClient, template)).hasMessageContaining("不属于此客户");
        when(lookup.canLearnClientDocument(otherClient)).thenReturn(false);
        UUID forbidden = job(); stage(forbidden, normal); succeed(forbidden);
        tx.executeWithoutResult(s -> store.adopt(event(forbidden, otherClient)));
        assertThat(store.list(otherClient)).isEmpty();
    }

    @Test void concurrentRepeatedAdoptionHasSingleEvidenceAndVersionsAreImmutable() throws Exception {
        var candidate = QuoteTemplateWorkbook.defaultTemplate(); UUID job = job(); stage(job, candidate); succeed(job);
        var event = event(job, client); var start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(2)) {
            var tasks = new ArrayList<Future<?>>();
            for (int i = 0; i < 2; i++) tasks.add(pool.submit(() -> {
                try { start.await(); } catch (InterruptedException e) { throw new RuntimeException(e); }
                tx.executeWithoutResult(s -> store.adopt(event));
            }));
            start.countDown(); for (var task : tasks) task.get(20, TimeUnit.SECONDS);
        }
        assertThat(store.list(client)).hasSize(1); assertThat(store.list(client).getFirst().useCount()).isEqualTo(1);
        UUID template = store.list(client).getFirst().id();
        assertThatThrownBy(() -> jdbc.update("UPDATE sales_quote_template_versions SET source_name='overwrite' WHERE template_id=?", template))
                .hasMessageContaining("不可覆盖");
    }

    @Test void explicitTemplateAdoptionIsBoundToActorCustomerQuoteAndPurposeAndIsIdempotent() throws Exception {
        UUID quote = UUID.randomUUID(), job = job();
        stage(job, QuoteTemplateWorkbook.defaultTemplate()); succeed(job);
        String params = new ObjectMapper().writeValueAsString(Map.of("docType", "quote", "templateOnly", "true",
                "docId", quote.toString(), "clientId", client.toString()));
        jdbc.update("UPDATE ai_jobs SET params=CAST(? AS jsonb) WHERE id=?", params, job);
        when(current.id()).thenReturn(Optional.of(UUID.randomUUID()));
        assertThatThrownBy(() -> tx.execute(s -> store.adoptUploaded(quote, client, job))).hasMessageContaining("不属于");
        when(current.id()).thenReturn(Optional.of(actor));
        assertThatThrownBy(() -> tx.execute(s -> store.adoptUploaded(UUID.randomUUID(), client, job))).hasMessageContaining("不属于");
        assertThatThrownBy(() -> tx.execute(s -> store.adoptUploaded(quote, otherClient, job))).hasMessageContaining("不属于");
        jdbc.update("UPDATE ai_jobs SET params=params-'templateOnly' WHERE id=?", job);
        assertThatThrownBy(() -> tx.execute(s -> store.adoptUploaded(quote, client, job))).hasMessageContaining("不属于");
        jdbc.update("UPDATE ai_jobs SET params=CAST(? AS jsonb) WHERE id=?", params, job);
        when(lookup.canLearnClientDocument(client)).thenReturn(false);
        assertThatThrownBy(() -> tx.execute(s -> store.adoptUploaded(quote, client, job))).hasMessageContaining("权限");
        when(lookup.canLearnClientDocument(client)).thenReturn(true);
        UUID saved = tx.execute(s -> store.adoptUploaded(quote, client, job));
        UUID repeated = tx.execute(s -> store.adoptUploaded(quote, client, job));
        assertThat(repeated).isEqualTo(saved);
        assertThat(store.list(client)).hasSize(1);
        assertThat(store.list(client).getFirst().useCount()).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_evidence WHERE job_id=?", Integer.class, job)).isEqualTo(1);
        assertThat(store.adoptedView(quote,client,job).version()).isEqualTo(1);
    }

    @Test void retryAndDownloadRemainBoundToOriginallyAdoptedVersionAfterAnotherUpload() throws Exception {
        UUID quote=UUID.randomUUID(), firstJob=job();
        var first=QuoteTemplateWorkbook.defaultTemplate(); stage(firstJob,first); succeed(firstJob);
        String params=new ObjectMapper().writeValueAsString(Map.of("docType","quote","templateOnly","true","docId",quote.toString(),"clientId",client.toString()));
        jdbc.update("UPDATE ai_jobs SET params=CAST(? AS jsonb) WHERE id=?",params,firstJob);
        UUID id=tx.execute(s -> store.adoptUploaded(quote,client,firstJob));
        UUID secondJob=job();
        var second=new QuoteTemplateWorkbook.Candidate(QuoteTemplateWorkbook.defaultTemplate().xlsx(),"b".repeat(64),first.mapping(),first.features());
        stage(secondJob,second); succeed(secondJob);
        tx.executeWithoutResult(s -> store.adopt(event(secondJob,client)));
        assertThat(store.list(client).getFirst().version()).isEqualTo(2);
        UUID repeated=tx.execute(s -> store.adoptUploaded(quote,client,firstJob));
        assertThat(repeated).isEqualTo(id);
        assertThat(store.adoptedView(quote,client,firstJob).version()).isEqualTo(1);
        assertThat(store.load(client,id,1).bytes()).isEqualTo(first.xlsx());
        assertThatThrownBy(() -> store.load(otherClient,id,1)).hasMessageContaining("不属于此客户");
        assertThatThrownBy(() -> store.load(client,id,999)).hasMessageContaining("不存在");
        assertThatThrownBy(() -> jdbc.update("UPDATE sales_quote_template_evidence SET template_version=2 WHERE job_id=?",firstJob))
                .hasMessageContaining("不可改写");
        UUID legacyJob=UUID.randomUUID();
        jdbc.update("INSERT INTO sales_quote_template_evidence(job_id,template_id,client_id,doc_type,doc_id) VALUES(?,?,?,'quote',?)",legacyJob,id,client,quote);
        assertThatThrownBy(() -> store.adoptedView(quote,client,legacyJob)).hasMessageContaining("无法确认原版本");
    }

    @Test void expiredUnadoptedJobCannotBeRevivedThroughTheExplicitAdoptionEndpoint() throws Exception {
        UUID quote=UUID.randomUUID(), job=job(); stage(job,QuoteTemplateWorkbook.defaultTemplate()); succeed(job);
        String params=new ObjectMapper().writeValueAsString(Map.of("docType","quote","templateOnly","true","docId",quote.toString(),"clientId",client.toString()));
        jdbc.update("UPDATE ai_jobs SET params=CAST(? AS jsonb) WHERE id=?",params,job);
        jdbc.update("UPDATE sales_quote_template_candidates SET expires_at=now()-interval '1 second' WHERE job_id=?",job);
        assertThatThrownBy(() -> tx.execute(s -> store.adoptUploaded(quote,client,job))).hasMessageContaining("已失效");
        assertThat(store.list(client)).isEmpty();
    }

    @Test void versionMigrationBackfillsOnlyUniquelyAttributableSourceJobs() throws Exception {
        String schema="template_version_"+UUID.randomUUID().toString().replace("-","");
        try (var connection=java.sql.DriverManager.getConnection(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
             var statement=connection.createStatement()) {
            statement.execute("CREATE SCHEMA "+schema); connection.setSchema(schema);
            statement.execute("CREATE TABLE sales_quote_template_versions(template_id uuid, version int, source_job_id uuid, PRIMARY KEY(template_id,version))");
            statement.execute("CREATE TABLE sales_quote_template_evidence(job_id uuid PRIMARY KEY, template_id uuid)");
            UUID template=UUID.randomUUID(), first=UUID.randomUUID(), reused=UUID.randomUUID(), ambiguous=UUID.randomUUID();
            try (var insert=connection.prepareStatement("INSERT INTO sales_quote_template_versions VALUES(?,?,?)")) {
                for (int version=1;version<=3;version++) {
                    insert.setObject(1,template); insert.setInt(2,version); insert.setObject(3,version==1?first:ambiguous); insert.executeUpdate();
                }
            }
            try (var insert=connection.prepareStatement("INSERT INTO sales_quote_template_evidence VALUES(?,?)")) {
                for (UUID job:List.of(first,reused,ambiguous)) { insert.setObject(1,job); insert.setObject(2,template); insert.executeUpdate(); }
            }
            try (var resource=getClass().getResourceAsStream("/db/migration/V791__sales_quote_template_evidence_version.sql")) {
                statement.execute(new String(Objects.requireNonNull(resource).readAllBytes(),java.nio.charset.StandardCharsets.UTF_8));
            }
            try (var rows=statement.executeQuery("SELECT job_id,template_version FROM sales_quote_template_evidence")) {
                while(rows.next()) assertThat(rows.getObject(2,Integer.class)).isEqualTo(first.equals(rows.getObject(1,UUID.class))?1:null);
            }
            connection.setSchema("public"); statement.execute("DROP SCHEMA "+schema+" CASCADE");
        }
    }

    @Test void confirmedMappingsAreCustomerScopedReusableAndCannotBeChangedByRetry() throws Exception {
        UUID quote=UUID.randomUUID(), job=job();var base=QuoteTemplateWorkbook.defaultTemplate();
        Map<String,Object> mapping=new LinkedHashMap<>(base.mapping());mapping.put("intakeFingerprint","a".repeat(64));
        var candidate=new QuoteTemplateWorkbook.Candidate(base.xlsx(),base.fingerprint(),mapping,base.features());
        stage(job,candidate);succeed(job);
        jdbc.update("UPDATE ai_jobs SET params=CAST(? AS jsonb),result='{\"originalEvidence\":true}'::jsonb WHERE id=?",
                new ObjectMapper().writeValueAsString(Map.of("docType","quote","templateOnly","true","docId",quote.toString(),"clientId",client.toString())),job);
        Map<String,String> choices=new LinkedHashMap<>(QuoteTemplateWorkbook.columnChoices(mapping));
        choices.put("G","AMOUNT");choices.put("I","UNIT_PRICE");
        UUID id=tx.execute(s -> store.adoptUploaded(quote,client,job,choices));
        assertThat(store.load(client,id,1).mapping().get("roles")).isInstanceOf(Map.class);
        assertThat(((Map<?,?>)store.load(client,id,1).mapping().get("roles")).get("G")).isEqualTo("AMOUNT");
        assertThat(store.latestConfirmedRoles(client,"a".repeat(64))).isEqualTo(choices);
        assertThat(store.latestConfirmedRoles(otherClient,"a".repeat(64))).isEmpty();
        assertThat(jdbc.queryForObject("SELECT result->>'originalEvidence' FROM ai_jobs WHERE id=?",String.class,job)).isEqualTo("true");
        assertThat(jdbc.queryForObject("SELECT mapping->'roles'->>'G' FROM sales_quote_template_candidates WHERE job_id=?",String.class,job)).isEqualTo("UNIT_PRICE");
        tx.executeWithoutResult(s -> store.adoptUploaded(quote,client,job,choices));
        Map<String,String> different=new LinkedHashMap<>(choices);different.put("J","IGNORED");
        assertThatThrownBy(() -> tx.execute(s -> store.adoptUploaded(quote,client,job,different))).hasMessageContaining("不能覆盖首次采用");
        assertThat(store.list(client).getFirst().useCount()).isEqualTo(1);
        UUID automatic=job();stage(automatic,candidate);succeed(automatic);
        tx.executeWithoutResult(s -> store.adopt(event(automatic,client)));
        assertThat(jdbc.queryForObject("SELECT confirmed_column_roles IS NULL FROM sales_quote_template_evidence WHERE job_id=?",Boolean.class,automatic)).isTrue();
        assertThat(store.latestConfirmedRoles(client,"a".repeat(64))).isEqualTo(choices);
    }

    @Test void expiryQueuesExactObjectButAdoptionKeepsReferencedObjectAndDoesNotCapTwentyTemplates() {
        var candidate = QuoteTemplateWorkbook.defaultTemplate(); UUID job = job(); stage(job, candidate);
        String key = jdbc.queryForObject("SELECT storage_key FROM sales_quote_template_candidates WHERE job_id=?", String.class, job);
        jdbc.update("UPDATE sales_quote_template_candidates SET expires_at=now()-interval '1 second' WHERE job_id=?", job);
        succeed(job);
        tx.executeWithoutResult(s -> store.purgeExpired());
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE operation='DELETE_FINAL' AND storage_key=?", Integer.class, key)).isZero();
        for (int i = 0; i < 21; i++) {
            Set<String> different = new TreeSet<>(candidate.features()); different.add("extra:" + i + ":variant");
            UUID another = job(); stage(another, new QuoteTemplateWorkbook.Candidate(candidate.xlsx(), String.format("%064x", i + 1), candidate.mapping(), different)); succeed(another);
            tx.executeWithoutResult(s -> store.adopt(event(another, client)));
        }
        assertThat(store.list(client)).hasSize(21);
    }

    @Test void expiredCandidateRemainsWhileItsAiWorkerOrLearningRetryStillOwnsIt() {
        UUID job=job();stage(job,QuoteTemplateWorkbook.defaultTemplate());
        jdbc.update("UPDATE sales_quote_template_candidates SET expires_at=now()-interval '1 second' WHERE job_id=?",job);
        tx.executeWithoutResult(s->store.purgeExpired());
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_candidates WHERE job_id=?",Integer.class,job)).isEqualTo(1);
        succeed(job);
        jdbc.update("UPDATE ai_jobs SET learning_retry_until=now()+interval '1 day' WHERE id=?",job);
        tx.executeWithoutResult(s->store.purgeExpired());
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_candidates WHERE job_id=?",Integer.class,job)).isEqualTo(1);
        jdbc.update("UPDATE ai_jobs SET learning_retry_until=now()-interval '1 second' WHERE id=?",job);
        tx.executeWithoutResult(s->store.purgeExpired());
        assertThat(jdbc.queryForObject("SELECT archived_at IS NOT NULL FROM sales_quote_template_candidates WHERE job_id=?",Boolean.class,job)).isTrue();
    }

    @ParameterizedTest @ValueSource(strings={"intakeJobId","additionalIntakeJobIds"})
    void claimedReceiptKeepsItsTemplateCandidateBeforeAiReservation(String field) throws Exception {
        UUID job=job();stage(job,QuoteTemplateWorkbook.defaultTemplate());succeed(job);
        jdbc.update("UPDATE sales_quote_template_candidates SET expires_at=now()-interval '1 second' WHERE job_id=?",job);
        UUID receipt=UUID.randomUUID();String payload=new ObjectMapper().writeValueAsString(Map.of(field,
                "intakeJobId".equals(field)?job.toString():List.of(job.toString())));
        jdbc.update("""
                INSERT INTO sales_document_learning_receipts(id,doc_type,doc_id,actor_user_id,request_payload,steps,retry_until)
                VALUES(?,'quote',?,?,CAST(? AS jsonb),'{"TEMPLATE":{"status":"RUNNING","attempts":1}}'::jsonb,now()-interval '1 second')
                """,receipt,UUID.randomUUID(),actor,payload);
        tx.executeWithoutResult(s->store.purgeExpired());
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_candidates WHERE job_id=?",Integer.class,job)).isEqualTo(1);
        jdbc.update("UPDATE sales_document_learning_receipts SET steps='{\"TEMPLATE\":{\"status\":\"SUCCEEDED\",\"attempts\":1}}'::jsonb WHERE id=?",receipt);
        tx.executeWithoutResult(s->store.purgeExpired());
        assertThat(jdbc.queryForObject("SELECT archived_at IS NOT NULL FROM sales_quote_template_candidates WHERE job_id=?",Boolean.class,job)).isTrue();
    }

    @Test void onlyContributingServerSourceRowsCanTeachATemplateAndResetQueuesStagedObjects() {
        var candidate = QuoteTemplateWorkbook.defaultTemplate(); UUID job = job(); stage(job, candidate);
        jdbc.update("UPDATE ai_jobs SET status='SUCCEEDED',result='{\"lines\":[{\"key\":\"S1R5\"}]}'::jsonb WHERE id=?", job);
        tx.executeWithoutResult(s -> store.adopt(new SalesIntakeUsedEvent(job, actor, "quote", UUID.randomUUID(), client, List.of("forged"))));
        assertThat(store.list(client)).isEmpty();
        tx.executeWithoutResult(s -> store.adopt(new SalesIntakeUsedEvent(job, actor, "quote", UUID.randomUUID(), client, List.of())));
        assertThat(store.list(client)).isEmpty();
        tx.executeWithoutResult(s -> store.adopt(new SalesIntakeUsedEvent(job, actor, "quote", UUID.randomUUID(), client, List.of("S1R5"))));
        assertThat(store.list(client)).hasSize(1);
        UUID pending = job(); stage(pending, candidate);
        String key = jdbc.queryForObject("SELECT storage_key FROM sales_quote_template_candidates WHERE job_id=?", String.class, pending);
        assertThatThrownBy(()->jdbc.execute("TRUNCATE sales_quote_template_candidates")).isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE storage_key=? AND operation='DELETE_FINAL'", Integer.class, key)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_candidates WHERE job_id=?",Integer.class,pending)).isEqualTo(1);
        assertThat(store.list(client)).hasSize(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE operation='DELETE_FINAL' AND storage_key IN (SELECT storage_key FROM sales_quote_template_versions WHERE template_id=?)",
                Integer.class, store.list(client).getFirst().id())).isZero();
    }

    private UUID client(UUID owner) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO clients(id,code,name,status,code_sequence,owner_employee_id) VALUES(?,?,?,'使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients),?)",
                id, "TC-" + id, "模板客户" + id, owner);
        return id;
    }
    private UUID job() {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,
                    submitted_by_user,submitted_auth_version)
                VALUES(?,'SALES_DOCUMENT_INTAKE','RUNNING','template.xlsx','application/octet-stream','XLSX',1,repeat('a',64),?,1)
                """, id, actor);
        return id;
    }
    private void stage(UUID job, QuoteTemplateWorkbook.Candidate candidate) { tx.executeWithoutResult(s -> store.stage(job, actor, "template.xlsx", candidate)); }
    private void succeed(UUID job) { jdbc.update("UPDATE ai_jobs SET status='SUCCEEDED',result='{}'::jsonb WHERE id=?", job); }
    private SalesIntakeUsedEvent event(UUID job, UUID client) { return new SalesIntakeUsedEvent(job, actor, "quote", UUID.randomUUID(), client); }
}
