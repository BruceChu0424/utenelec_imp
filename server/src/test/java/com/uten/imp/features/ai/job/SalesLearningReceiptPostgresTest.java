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
