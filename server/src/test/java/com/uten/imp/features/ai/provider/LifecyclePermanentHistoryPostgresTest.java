package com.uten.imp.features.ai.provider;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.features.notice.*;
import com.uten.imp.features.visitor.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecretCipher;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.*;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Actual current-schema/JPA contracts; preserved encrypted payloads never appear in the public DTO. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LifecyclePermanentHistoryPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static EntityManagerFactory factory;static JdbcTemplate jdbc;static TransactionTemplate tx;
    static AiProviderRepository providers;static NoticeBlessingRepository blessings;static VisitorSmsCodeRepository sms;
    UUID actor,employee;
    @BeforeAll static void open() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("lifecycle_permanent_history");
        var ds=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());jdbc=new JdbcTemplate(ds);
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(ds);bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.features.ai.provider","com.uten.imp.features.notice","com.uten.imp.features.visitor");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none","hibernate.physical_naming_strategy","org.hibernate.boot.model.naming.CamelCaseToUnderscoresNamingStrategy"));
        bean.afterPropertiesSet();factory=bean.getObject();var em=SharedEntityManagerCreator.createSharedEntityManager(factory);
        var repositories=new JpaRepositoryFactory(em);providers=repositories.getRepository(AiProviderRepository.class);
        blessings=repositories.getRepository(NoticeBlessingRepository.class);sms=repositories.getRepository(VisitorSmsCodeRepository.class);
        tx=new TransactionTemplate(new JpaTransactionManager(factory));
    }
    @AfterAll static void close() throws Exception {if(factory!=null)factory.close();if(database!=null)database.close();}
    @BeforeEach void staff() {
        actor=UUID.randomUUID();employee=UUID.randomUUID();
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'保全测试','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"LIFE-"+employee);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-only',false,'active')",actor,employee,"life-"+actor);
    }
    @Test void providerSoftDeleteAndEarlierConfigurationsStayPrivateAndReadable() throws Exception {
        UUID id=provider();jdbc.update("UPDATE ai_providers SET model='changed-model',version=version+1 WHERE id=?",id);
        var cipher=mock(SecretCipher.class);var service=new AiProviderService(providers,cipher,new AiProperties(),mock(AuditService.class),new NamedParameterJdbcTemplate(jdbc),Clock.systemUTC());
        tx.executeWithoutResult(s->service.delete(id,1L,new AuthUser(actor,employee,"life",Set.of("authorization:manage"),false,true,true)));
        assertThat(providers.findById(id)).isPresent();assertThat(providers.findAllOrdered()).noneMatch(p->id.equals(p.getId()));
        assertThat(jdbc.queryForObject("SELECT payload->>'secret' FROM ai_provider_history WHERE provider_id=? ORDER BY id LIMIT 1",String.class,id)).isEqualTo("encrypted-test-only-secret");
        var history=service.history(id,null,50);assertThat(history.deleted()).isTrue();assertThat(history.revisions()).hasSize(3);
        String body=new ObjectMapper().findAndRegisterModules().writeValueAsString(history);
        assertThat(body).contains("changed-model").doesNotContain("encrypted-test-only-secret","\\\"secret\\\"");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_provider_history WHERE provider_id=? AND jsonb_exists(public_payload,'secret')",Integer.class,id)).isZero();
    }
    @Test void legacyProviderDeleteRetainsTheRowAssociationAndAllowsSafeNameReuse() {
        UUID id=provider();String name=jdbc.queryForObject("SELECT name FROM ai_providers WHERE id=?",String.class,id);
        assertThat(jdbc.update("DELETE FROM ai_providers WHERE id=?",id)).isZero();
        assertThat(jdbc.queryForObject("SELECT is_deleted AND NOT enabled AND NOT is_default FROM ai_providers WHERE id=?",Boolean.class,id)).isTrue();
        jdbc.update("INSERT INTO ai_providers(name,preset,region,protocol,base_url,model) VALUES(?,'OLLAMA','LOCAL','OPENAI_CHAT','http://localhost:11434','another')",name);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ai_providers WHERE name=?",Integer.class,name)).isEqualTo(2);
    }
    @Test void realJpaWithdrawThenReactivationRetainsEachBlessingAndCurrentCounts() {
        UUID notice=UUID.randomUUID(),id=UUID.randomUUID();
        jdbc.update("INSERT INTO notices(id,type,title,content,publisher,kind,audience_scope,interaction_mode,published_at) VALUES(?,'birthday','祝福','内容','测试','NORMAL','all','bless',now())",notice);
        jdbc.update("INSERT INTO notice_blessings(id,notice_id,user_id,sender_name,content) VALUES(?,?,?,'原发送人','原祝福')",id,notice,actor);
        Long withdrawn=tx.execute(s->blessings.deleteByNoticeIdAndUserId(notice,actor));assertThat(withdrawn).isEqualTo(1L);
        assertThat(blessings.countByNoticeId(notice)).isZero();assertThat(blessings.findTop5ByNoticeIdOrderByCreatedAtDesc(notice)).isEmpty();
        tx.executeWithoutResult(s->{var row=blessings.findByNoticeIdAndUserId(notice,actor).orElseThrow();row.setContent("新祝福");row.setDeleted(false);row.setDeletedAt(null);row.setDeletedBy(null);row.setDeletedReason(null);blessings.saveAndFlush(row);});
        assertThat(blessings.countByNoticeId(notice)).isEqualTo(1);assertThat(blessings.findHistory(notice,null,50)).hasSize(3);
        assertThat(jdbc.queryForList("SELECT operation FROM notice_blessing_history WHERE blessing_id=? ORDER BY id",String.class,id)).containsExactly("SEND","WITHDRAW","REACTIVATE");
        assertThat(jdbc.queryForObject("SELECT payload->>'content' FROM notice_blessing_history WHERE blessing_id=? AND operation='WITHDRAW'",String.class,id)).isEqualTo("原祝福");
    }
    @Test void onlyDefinitiveSmsRejectionReleasesQuotaAndDisablesOtpWithoutDeletingFacts() {
        String phone="1380013"+String.format("%04d",Math.floorMod(actor.hashCode(),10000));
        var row=new VisitorSmsCode();row.setPhone(phone);row.setScene("login");row.setCodeHash("test-only-otp-hmac");row.setExpiresAt(OffsetDateTime.now().plusMinutes(5));
        tx.executeWithoutResult(s->sms.saveAndFlush(row));
        assertThat(sms.countByPhoneAndCreatedAtAfter(phone,OffsetDateTime.now().minusDays(1))).isEqualTo(1);
        Integer rejected=tx.execute(s->sms.recordDelivery(row.getId(),"REJECTED","SMS_PROVIDER_DEFINITIVELY_REJECTED"));assertThat(rejected).isEqualTo(1);
        assertThat(sms.findById(row.getId())).isPresent();Optional<VisitorSmsCode> usableRejected=tx.execute(s->sms.findTopByPhoneAndConsumedAtIsNullOrderByCreatedAtDesc(phone));assertThat(usableRejected).isEmpty();
        assertThat(sms.countByPhoneAndCreatedAtAfter(phone,OffsetDateTime.now().minusDays(1))).isZero();
        var uncertain=new VisitorSmsCode();uncertain.setPhone(phone);uncertain.setScene("login");uncertain.setCodeHash("test-only-other-hmac");uncertain.setExpiresAt(OffsetDateTime.now().plusMinutes(5));
        tx.executeWithoutResult(s->{sms.saveAndFlush(uncertain);sms.recordDelivery(uncertain.getId(),"UNCERTAIN","SMS_PROVIDER_UNCERTAIN");});
        assertThat(sms.countByPhoneAndCreatedAtAfter(phone,OffsetDateTime.now().minusDays(1))).isEqualTo(1);
        Optional<VisitorSmsCode> usableUncertain=tx.execute(s->sms.findTopByPhoneAndConsumedAtIsNullOrderByCreatedAtDesc(phone));assertThat(usableUncertain).isPresent();
    }
    @Test void immutableDefinitionSurvivesReplicaModeAndRejectsTruncation() throws Exception {
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO platform_column_definitions(id,scope,name,normalized_name,value_type,price_protected,definition_fingerprint,created_by) VALUES(?,'sales_order','旧敏感列','旧敏感列','TEXT',true,repeat('a',64),?)",id,actor);
        try(var connection=Objects.requireNonNull(jdbc.getDataSource()).getConnection();var statement=connection.createStatement()) {
            statement.execute("SET session_replication_role=replica");
            assertThatThrownBy(()->{try(var update=connection.prepareStatement("UPDATE platform_column_definitions SET price_protected=false WHERE id=?")){update.setObject(1,id);update.executeUpdate();}}).isInstanceOf(java.sql.SQLException.class);
            assertThatThrownBy(()->statement.execute("TRUNCATE platform_column_definitions CASCADE")).isInstanceOf(java.sql.SQLException.class);
        }
        assertThat(jdbc.queryForObject("SELECT price_protected FROM platform_column_definitions WHERE id=?",Boolean.class,id)).isTrue();
    }
    @Test void candidateOverwriteRetainsTheExactPreviousWorkbookAndObjectIdentity() {
        UUID job=UUID.randomUUID();jdbc.update("INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,submitted_by_user,submitted_auth_version,finished_at) VALUES(?,'SALES_DOCUMENT_INTAKE','SUCCEEDED','test.xlsx','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','XLSX',1,repeat('a',64),?,1,now())",job,actor);
        byte[] old={1,2,3},next={4,5,6};jdbc.update("INSERT INTO sales_quote_template_candidates(job_id,actor_user_id,source_name,fingerprint,workbook_bytes,mapping,features) VALUES(?,?,'old.xlsx',repeat('a',64),?,'{}','{}')",job,actor,old);
        jdbc.update("UPDATE sales_quote_template_candidates SET workbook_bytes=?,source_name='next.xlsx' WHERE job_id=?",next,job);
        assertThat(jdbc.queryForObject("SELECT decode(substring(payload->>'workbook_bytes' from 3),'hex') FROM sales_quote_template_candidate_history WHERE job_id=?",byte[].class,job)).isEqualTo(old);
        assertThat(jdbc.queryForObject("SELECT workbook_bytes FROM sales_quote_template_candidates WHERE job_id=?",byte[].class,job)).isEqualTo(next);
    }
    @Test void oldCleanupCannotStripCompletedResultLearningEvidenceOrOriginalRequestKeys() {
        UUID job=UUID.randomUUID(),receipt=UUID.randomUUID();
        jdbc.update("INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,submitted_by_user,submitted_auth_version,finished_at,result) VALUES(?,'PLATFORM_TEST','SUCCEEDED','test.csv','text/csv','CSV',1,repeat('a',64),?,1,now(),'{\"source\":\"original\"}')",job,actor);
        jdbc.update("UPDATE ai_jobs SET result=NULL,result_purged_at=now() WHERE id=?",job);
        assertThat(jdbc.queryForObject("SELECT result::text FROM ai_jobs WHERE id=?",String.class,job)).contains("original");
        String original="{\"lines\":[{\"sourceKey\":\"unknown-原key\"}],\"clientFields\":{\"name\":\"原客户\"},\"otherOriginalKey\":\"保留\"}";
        jdbc.update("INSERT INTO sales_document_learning_receipts(id,doc_type,doc_id,actor_user_id,request_payload,evidence,steps,retry_until) VALUES(?,'quote',?,?,CAST(? AS jsonb),'{\"proof\":\"keep\"}','{}',now())",receipt,UUID.randomUUID(),actor,original);
        String before=jdbc.queryForObject("SELECT request_payload::text FROM sales_document_learning_receipts WHERE id=?",String.class,receipt);
        jdbc.update("UPDATE sales_document_learning_receipts SET request_payload='{}',evidence='{}' WHERE id=?",receipt);
        assertThat(jdbc.queryForObject("SELECT request_payload::text FROM sales_document_learning_receipts WHERE id=?",String.class,receipt)).isEqualTo(before);
        assertThat(jdbc.queryForObject("SELECT evidence::text FROM sales_document_learning_receipts WHERE id=?",String.class,receipt)).contains("keep");
        assertThat(jdbc.update("DELETE FROM sales_document_learning_receipts WHERE id=?",receipt)).isZero();
        assertThat(jdbc.queryForObject("SELECT archived_at IS NOT NULL FROM sales_document_learning_receipts WHERE id=?",Boolean.class,receipt)).isTrue();
    }
    UUID provider(){UUID id=UUID.randomUUID();jdbc.update("INSERT INTO ai_providers(id,name,preset,region,protocol,base_url,model,secret,created_by,updated_by) VALUES(?,?,'OLLAMA','LOCAL','OPENAI_CHAT','http://localhost:11434','original-model','encrypted-test-only-secret',?,?)",id,"provider-"+id,actor,actor);return id;}
}
