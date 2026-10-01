package com.uten.imp.features.ai.job;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiJobUsagePort;
import com.uten.imp.application.port.SalesLearningReceiptPort.StepResult;
import com.uten.imp.application.port.SalesMasterLearningPort.SalesLearningRequest;
import com.uten.imp.application.port.SalesMasterLearningPort.LearnedLine;
import com.uten.imp.features.sales.learning.SalesLearningReceiptService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SalesLearningReceiptPostgresTest {
    private static final PostgreSQLContainer<?> DB=MigratedSchemaBaseline.startMigratedContainer("sales_learning_receipts");
    private JdbcTemplate jdbc;
    private TransactionTemplate tx;
    private SalesLearningReceiptService receipts;
    private AiJobRepository jobs;
    private AiJobUsageAdapter usage;
    private SecurityContextCurrentUser current;
    private UUID actor;
    @AfterAll static void stop(){DB.stop();}
    @BeforeEach @SuppressWarnings("unchecked") void setup(){
        var source=new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        jdbc=new JdbcTemplate(source);var named=new NamedParameterJdbcTemplate(source);var transactions=new DataSourceTransactionManager(source);
        tx=new TransactionTemplate(transactions);actor=UUID.randomUUID();UUID employee=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,'学习回执','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'
                """,employee,"LE-"+employee);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-only',false,'active')",actor,employee,"learning-"+actor);
        current=mock(SecurityContextCurrentUser.class);when(current.requireId()).thenReturn(actor);
        jobs=new AiJobRepository(named);usage=new AiJobUsageAdapter(jobs,new ObjectMapper());
        ObjectProvider<AiJobUsagePort> provider=mock(ObjectProvider.class);when(provider.getIfAvailable()).thenReturn(usage);
        receipts=new SalesLearningReceiptService(named,new ObjectMapper(),current,provider,transactions);
    }
    @Test void partialFailureRetainsTrustedEvidenceAndRetriesOnlyTheFailedStep(){
        UUID job=job(),doc=UUID.randomUUID();var request=request(doc,job);tx.executeWithoutResult(s->receipts.register(request));
        UUID id=request.learningReceiptId();AtomicInteger layout=new AtomicInteger(),master=new AtomicInteger(),template=new AtomicInteger();
        receipts.run(id,"LAYOUT",job,()->{layout.incrementAndGet();return StepResult.done();});
        receipts.run(id,"TEMPLATE",job,()->{template.incrementAndGet();throw new IllegalStateException("PRIVATE CUSTOMER CONTENT");});
        receipts.run(id,"MASTER",null,()->{master.incrementAndGet();return StepResult.done();});
        assertThat(receipts.canConsume(id)).isFalse();
        assertThat(receipts.owned(id).state()).isEqualTo("PARTIAL");
        assertThat(receipts.owned(id).steps().toString()).doesNotContain("PRIVATE CUSTOMER CONTENT");
        jobs.purgeResults(1);jobs.deleteFinishedOlderThan(7);
        assertThat(usage.resultFor(job,actor)).isPresent();
        receipts.run(id,"LAYOUT",job,()->{layout.incrementAndGet();return StepResult.done();});
        receipts.run(id,"MASTER",null,()->{master.incrementAndGet();return StepResult.done();});
        receipts.run(id,"TEMPLATE",job,()->{template.incrementAndGet();return StepResult.done();});
        assertThat(receipts.canConsume(id)).isTrue();
        receipts.run(id,"CONSUME",null,()->{usage.markUsed(job,actor,"quote",doc);return StepResult.done();});
        assertThat(receipts.owned(id).state()).isEqualTo("SUCCEEDED");
        assertThat(layout.get()).isEqualTo(1);assertThat(master.get()).isEqualTo(1);assertThat(template.get()).isEqualTo(2);
        assertThat(usage.resultFor(job,actor)).isEmpty();assertThat(receipts.evidence(id,job)).isPresent();
        assertThat(jdbc.queryForObject("SELECT used_doc_id=? AND learning_retry_until IS NULL FROM ai_jobs WHERE id=?",Boolean.class,doc,job)).isTrue();
        assertThat(receipts.evidence(id,job).orElseThrow().toString()).doesNotContain("clientPrice").doesNotContain("bankAccount");
    }
    @Test void receiptCannotBeReplayedByAnotherActorOrClaimTheSameJobForAnotherDocument(){
        UUID job=job();var first=request(UUID.randomUUID(),job);tx.executeWithoutResult(s->receipts.register(first));
        receipts.run(first.learningReceiptId(),"LAYOUT",job,StepResult::done);
        UUID secondDoc=UUID.randomUUID();var second=request(secondDoc,job);tx.executeWithoutResult(s->receipts.register(second));
        AtomicInteger ran=new AtomicInteger();
        receipts.run(second.learningReceiptId(),"LAYOUT",job,()->{ran.incrementAndGet();return StepResult.done();});
        assertThat(ran.get()).isZero();
        usage.markUsed(job,actor,"quote",secondDoc);
        assertThat(jdbc.queryForObject("SELECT used_doc_id FROM ai_jobs WHERE id=?",UUID.class,job)).isEqualTo(first.docId());
        assertThat(usage.resultFor(job,actor)).isPresent();
        when(current.requireId()).thenReturn(UUID.randomUUID());
        assertThatThrownBy(()->receipts.owned(first.learningReceiptId())).hasMessageContaining("原保存人");
    }
    @Test void immutableReceiptPayloadAndLatestSavedSourceGuardPreventStaleCommands(){
        UUID doc=UUID.randomUUID();jdbc.update("INSERT INTO sales_quotes(id,bill_no,bill_date,status) VALUES(?,'XB'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'999901',CURRENT_DATE,0)",doc);
        var first=new SalesLearningRequest("quote",doc,null,actor,null,List.of(),Map.of(),null,List.of(),UUID.randomUUID());
        tx.executeWithoutResult(s->receipts.register(first));
        tx.executeWithoutResult(s->receipts.requireCurrentSource(first.learningReceiptId()));
        var altered=new SalesLearningRequest("quote",doc,null,actor,null,List.of(),Map.of("email","altered@example.com"),null,List.of(),first.learningReceiptId());
        assertThatThrownBy(()->tx.executeWithoutResult(s->receipts.register(altered))).hasMessageContaining("原回执不一致");
        var second=new SalesLearningRequest("quote",doc,null,actor,null,List.of(),Map.of(),null,List.of(),UUID.randomUUID());
        tx.executeWithoutResult(s->receipts.register(second));
        assertThatThrownBy(()->tx.executeWithoutResult(s->receipts.requireCurrentSource(first.learningReceiptId()))).hasMessageContaining("单据内容已变更");
        tx.executeWithoutResult(s->receipts.requireCurrentSource(second.learningReceiptId()));
    }
    @Test void expiredReceiptsDropUnnecessaryPrivatePayloadAndCannotResume(){
        UUID job=job();var request=request(UUID.randomUUID(),job);tx.executeWithoutResult(s->receipts.register(request));
        receipts.run(request.learningReceiptId(),"LAYOUT",job,StepResult::done);
        jdbc.update("UPDATE sales_document_learning_receipts SET retry_until=now()-interval '1 second' WHERE id=?",request.learningReceiptId());
        receipts.purgeExpiredEvidence();
        assertThat(receipts.owned(request.learningReceiptId()).evidence()).isEmpty();
        assertThat(receipts.owned(request.learningReceiptId()).request().lines()).isEmpty();
        AtomicInteger ran=new AtomicInteger();receipts.run(request.learningReceiptId(),"MASTER",null,()->{ran.incrementAndGet();return StepResult.done();});
        assertThat(ran.get()).isZero();
    }
    @Test void committedLearningIntentProtectsItsSourceBeforeAnyAfterCommitCallbackRuns() {
        UUID job=job();var request=request(UUID.randomUUID(),job);
        tx.executeWithoutResult(s->receipts.register(request));
        assertThat(receipts.owned(request.learningReceiptId()).state()).isEqualTo("PENDING");
        jobs.purgeResults(1);jobs.deleteFinishedOlderThan(7);
        assertThat(jdbc.queryForObject("SELECT used_doc_id FROM ai_jobs WHERE id=?",UUID.class,job)).isEqualTo(request.docId());
        assertThat(usage.resultFor(job,actor)).isPresent();
    }
    @Test void rolledBackDocumentSaveLeavesNeitherReceiptNorSourceReservation() {
        UUID job=job();var request=request(UUID.randomUUID(),job);
        tx.executeWithoutResult(s->{receipts.register(request);s.setRollbackOnly();});
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_document_learning_receipts WHERE id=?",Integer.class,request.learningReceiptId())).isZero();
        assertThat(jdbc.queryForObject("SELECT used_doc_id IS NULL AND learning_retry_until IS NULL FROM ai_jobs WHERE id=?",Boolean.class,job)).isTrue();
    }

    @Test void expiryDoesNotStripEvidenceFromAnExecutingLearningCommand() {
        UUID job=job();var request=request(UUID.randomUUID(),job);tx.executeWithoutResult(s->receipts.register(request));
        UUID id=request.learningReceiptId();receipts.run(id,"LAYOUT",job,StepResult::done);
        receipts.run(id,"MASTER",null,()->{
            jdbc.update("UPDATE sales_document_learning_receipts SET retry_until=now()-interval '1 second' WHERE id=?",id);
            receipts.purgeExpiredEvidence();
            assertThat(receipts.owned(id).request().lines()).hasSize(1);
            assertThat(receipts.evidence(id,job)).isPresent();
            return StepResult.done();
        });
        assertThat(receipts.owned(id).steps().get("MASTER").toString()).contains("SUCCEEDED");
        receipts.purgeExpiredEvidence();
        assertThat(receipts.owned(id).request().lines()).isEmpty();
    }

    @Test void lateFailedAttemptCannotOverwriteANewerSuccessfulAttempt() {
        var request=request(UUID.randomUUID(),null);tx.executeWithoutResult(s->receipts.register(request));
        UUID id=request.learningReceiptId();
        receipts.run(id,"MASTER",null,()->{
            jdbc.update("""
                    UPDATE sales_document_learning_receipts SET steps=jsonb_set(steps,'{MASTER,startedAt}',
                        to_jsonb((now()-interval '6 minutes')::text)) WHERE id=?
                    """,id);
            receipts.run(id,"MASTER",null,StepResult::done);
            throw new IllegalStateException("late attempt failure");
        });
        assertThat(receipts.owned(id).steps().get("MASTER").toString()).contains("SUCCEEDED").contains("attempts=2");
        assertThat(receipts.owned(id).steps().get("MASTER").toString()).doesNotContain("errorClass");
    }

    @Test void anUnclaimedExpiredRetryCannotMarkTheCurrentWorkerFailed() {
        var request=request(UUID.randomUUID(),null);tx.executeWithoutResult(s->receipts.register(request));
        UUID id=request.learningReceiptId();
        receipts.run(id,"MASTER",null,()->{
            jdbc.update("UPDATE sales_document_learning_receipts SET retry_until=now()-interval '1 second' WHERE id=?",id);
            receipts.run(id,"MASTER",null,()->{throw new AssertionError("expired retry ran");});
            assertThat(receipts.owned(id).steps().get("MASTER").toString()).contains("RUNNING").contains("attempts=1");
            return StepResult.done();
        });
        assertThat(receipts.owned(id).steps().get("MASTER").toString()).contains("SUCCEEDED");
    }

    @Test void eachEvidencePurgeIsBoundedAndLeavesTheReceiptIdentityAndOutcomes() throws Exception {
        var request=request(UUID.randomUUID(),null);
        String payload=new ObjectMapper().writeValueAsString(request);
        jdbc.update("""
                INSERT INTO sales_document_learning_receipts(id,doc_type,doc_id,actor_user_id,request_payload,steps,retry_until)
                SELECT gen_random_uuid(),'quote',gen_random_uuid(),?,CAST(? AS jsonb),
                    '{"MASTER":{"status":"FAILED","attempts":2}}'::jsonb,now()-interval '1 day'
                FROM generate_series(1,1001)
                """,actor,payload);
        receipts.purgeExpiredEvidence();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_document_learning_receipts WHERE actor_user_id=? AND request_payload->'lines'<>'[]'::jsonb",Integer.class,actor)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_document_learning_receipts WHERE actor_user_id=? AND steps->'MASTER'->>'status'='FAILED'",Integer.class,actor)).isEqualTo(1001);
    }

    @Test void aLateSuccessCannotEraseTheNewAttemptsFailureOrRepopulateItsEvidence() {
        UUID job=job();var request=request(UUID.randomUUID(),job);tx.executeWithoutResult(s->receipts.register(request));
        UUID id=request.learningReceiptId();receipts.run(id,"LAYOUT",job,StepResult::done);
        receipts.run(id,"MASTER",null,()->{
            jdbc.update("UPDATE sales_document_learning_receipts SET steps=jsonb_set(steps,'{MASTER,startedAt}',to_jsonb((now()-interval '6 minutes')::text)) WHERE id=?",id);
            receipts.run(id,"MASTER",null,()->{throw new IllegalStateException("current attempt failed");});
            assertThatThrownBy(()->receipts.rememberEvidence(id,job,Map.of("lines",List.of(Map.of("key","S1R2","partNo","STALE")))))
                    .hasMessageContaining("单据内容已变更");
            return StepResult.done();
        });
        assertThat(receipts.owned(id).steps().get("MASTER").toString()).contains("FAILED").contains("attempts=2");
        assertThat(receipts.evidence(id,job).orElseThrow().toString()).contains("MODEL").doesNotContain("STALE");
    }

    @Test void executingLearningKeepsItsAiResultAndRowAfterTheRetryDeadline() {
        UUID job=job();var request=request(UUID.randomUUID(),job);tx.executeWithoutResult(s->receipts.register(request));
        receipts.run(request.learningReceiptId(),"MASTER",null,()->{
            jdbc.update("UPDATE sales_document_learning_receipts SET retry_until=now()-interval '1 second' WHERE id=?",request.learningReceiptId());
            jdbc.update("UPDATE ai_jobs SET learning_retry_until=now()-interval '1 second' WHERE id=?",job);
            assertThat(jobs.purgeResults(1)).isZero();assertThat(jobs.deleteFinishedOlderThan(7)).isZero();
            assertThat(usage.resultFor(job,actor)).isPresent();
            return StepResult.done();
        });
        assertThat(jobs.purgeResults(1)).isEqualTo(1);assertThat(jobs.deleteFinishedOlderThan(7)).isEqualTo(1);
    }

    @Test void evidenceCleanupSkipsLockedReceiptsWithoutBlockingOtherCandidates() throws Exception {
        var held=request(UUID.randomUUID(),null);var expired=request(UUID.randomUUID(),null);
        tx.executeWithoutResult(s->{receipts.register(held);receipts.register(expired);});
        jdbc.update("UPDATE sales_document_learning_receipts SET retry_until=now()-interval '1 second' WHERE id IN (?,?)",held.learningReceiptId(),expired.learningReceiptId());
        try(var connection=Objects.requireNonNull(jdbc.getDataSource()).getConnection()) {
            connection.setAutoCommit(false);
            try(var lock=connection.prepareStatement("SELECT id FROM sales_document_learning_receipts WHERE id=? FOR UPDATE")) {
                lock.setObject(1,held.learningReceiptId());lock.executeQuery().close();
                tx.executeWithoutResult(s->{jdbc.execute("SET LOCAL statement_timeout='750ms'");receipts.purgeExpiredEvidence();});
                assertThat(receipts.owned(held.learningReceiptId()).request().lines()).hasSize(1);
                assertThat(receipts.owned(expired.learningReceiptId()).request().lines()).isEmpty();
            } finally {connection.rollback();}
        }
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    @SuppressWarnings("unchecked")
    void claimedSourceIsProtectedBeforeReservationForPrimaryAndAdditionalJobs(boolean additional) {
        UUID job=job(),doc=UUID.randomUUID();
        var request=new SalesLearningRequest("quote",doc,null,actor,null,
                List.of(new LearnedLine(UUID.randomUUID(),"MODEL",null,job+":S1R2",true,false)),Map.of(),
                additional?null:job,additional?List.of(job):List.of(),UUID.randomUUID());
        tx.executeWithoutResult(s->receipts.register(request));
        // A legacy/unreserved receipt has committed its claim before prepareSource reserves the AI row.
        jdbc.update("UPDATE ai_jobs SET used_doc_type=NULL,used_doc_id=NULL,learning_retry_until=NULL WHERE id=?",job);
        UUID ordinaryExpired=job();
        usage=spy(usage);
        doAnswer(invocation->{
            assertThat(jdbc.queryForObject("SELECT steps->?->>'status' FROM sales_document_learning_receipts WHERE id=?",String.class,"LAYOUT:"+job,request.learningReceiptId())).isEqualTo("RUNNING");
            assertThat(jdbc.queryForObject("SELECT used_doc_id IS NULL FROM ai_jobs WHERE id=?",Boolean.class,job)).isTrue();
            jobs.purgeResults(1);
            assertThat(jdbc.queryForObject("SELECT result IS NOT NULL FROM ai_jobs WHERE id=?",Boolean.class,job)).isTrue();
            assertThat(jdbc.queryForObject("SELECT result IS NULL FROM ai_jobs WHERE id=?",Boolean.class,ordinaryExpired)).isTrue();
            jobs.deleteFinishedOlderThan(7);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_jobs WHERE id=?",Integer.class,job)).isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_jobs WHERE id=?",Integer.class,ordinaryExpired)).isZero();
            return invocation.callRealMethod();
        }).when(usage).resultFor(job,actor);
        ObjectProvider<AiJobUsagePort> provider=mock(ObjectProvider.class);when(provider.getIfAvailable()).thenReturn(usage);
        var dataSource=Objects.requireNonNull(jdbc.getDataSource());
        receipts=new SalesLearningReceiptService(new NamedParameterJdbcTemplate(dataSource),new ObjectMapper(),current,provider,new DataSourceTransactionManager(dataSource));
        receipts.run(request.learningReceiptId(),"LAYOUT",job,StepResult::done);
        assertThat(receipts.owned(request.learningReceiptId()).steps().get("LAYOUT:"+job).toString()).contains("SUCCEEDED");
        assertThat(jdbc.queryForObject("SELECT used_doc_id FROM ai_jobs WHERE id=?",UUID.class,job)).isEqualTo(doc);
    }

    private SalesLearningRequest request(UUID doc,UUID job){return new SalesLearningRequest("quote",doc,null,actor,null,
            List.of(new LearnedLine(UUID.randomUUID(),"MODEL",null,"S1R2",true,false)),Map.of(),job,List.of(),UUID.randomUUID());}
    private UUID job(){
        UUID id=UUID.randomUUID();jdbc.update("""
                INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,
                    submitted_by_user,submitted_auth_version,created_at,finished_at,result)
                VALUES(?,'SALES_DOCUMENT_INTAKE','SUCCEEDED','source.xlsx','application/octet-stream','XLSX',1,
                    repeat('a',64),?,1,now()-interval '10 days',now()-interval '10 days',
                    '{"lines":[{"key":"S1R2","partNo":"MODEL","description":"Source name","clientPrice":"99","bankAccount":"PRIVATE"}]}'::jsonb)
                """,id,actor);return id;
    }
}
