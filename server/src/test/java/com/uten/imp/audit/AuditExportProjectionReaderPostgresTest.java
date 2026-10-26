package com.uten.imp.audit;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.export.ExportResourceLimits;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.*;
import org.hibernate.resource.jdbc.spi.StatementInspector;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.*;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import java.time.OffsetDateTime;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Real migrated column types, detached projections and RR; the private clone
 * deliberately does not claim to exercise append-only command triggers. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class AuditExportProjectionReaderPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase lease;
    private static EntityManagerFactory factory;
    private static NamedParameterJdbcTemplate jdbc;
    private static NamedParameterJdbcTemplate writer;
    private static TransactionTemplate read;
    private static EntityManager shared;
    private static final List<String> sql=Collections.synchronizedList(new ArrayList<>());
    private static final OffsetDateTime AT=OffsetDateTime.parse("2026-10-26T00:00:00Z");
    private final AuditExportProjectionReader reader=new AuditExportProjectionReader();
    private static final Specification<AuditLog> ALL=(root,query,cb)->cb.conjunction();

    @BeforeAll static void open() throws Exception {
        lease=MigratedSchemaBaseline.openDatabase("audit_export_projection");
        var admin=new NamedParameterJdbcTemplate(new DriverManagerDataSource(lease.getJdbcUrl(),lease.getUsername(),lease.getPassword()));
        admin.getJdbcTemplate().execute("CREATE SCHEMA audit_export_fixture");
        admin.getJdbcTemplate().execute("CREATE TABLE audit_export_fixture.audit_log AS SELECT * FROM public.audit_log WITH NO DATA");
        String url=lease.getJdbcUrl()+(lease.getJdbcUrl().contains("?")?"&":"?")+"currentSchema=audit_export_fixture,public";
        var source=new DriverManagerDataSource(url,lease.getUsername(),lease.getPassword());jdbc=new NamedParameterJdbcTemplate(source);
        // A separately owned connection commits late fixtures outside the RR reader.
        writer=new NamedParameterJdbcTemplate(new DriverManagerDataSource(url,lease.getUsername(),lease.getPassword()));
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(source);bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.audit");bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none",
                "hibernate.session_factory.statement_inspector",(StatementInspector)statement->{sql.add(statement);return statement;}));
        bean.afterPropertiesSet();factory=bean.getObject();shared=SharedEntityManagerCreator.createSharedEntityManager(factory);
        read=new TransactionTemplate(new JpaTransactionManager(factory));read.setReadOnly(true);read.setIsolationLevel(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
    }
    @AfterAll static void close() throws Exception {if(factory!=null)factory.close();if(lease!=null)lease.close();}
    @BeforeEach void reset() {jdbc.getJdbcTemplate().execute("TRUNCATE audit_export_fixture.audit_log");sql.clear();ReflectionTestUtils.setField(reader,"em",shared);}
    private void insert(long id,OffsetDateTime time,String after) {
        writer.update("INSERT INTO audit_log(id,created_at,action,target_type,target_id,event_source,result,risk_level,event_category,before,after,user_agent) VALUES(:id,:time,'update','goods','原件-龘','database','success','low','business',CAST('{\"name\":\"旧名称\"}' AS jsonb),CAST(:after AS jsonb),'raw-user-agent-preserved')",
                Map.of("id",id,"time",time,"after",after));
    }
    private String digest(){return jdbc.queryForObject("SELECT md5(string_agg(id::text||created_at::text||before::text||after::text||user_agent,'|' ORDER BY created_at,id)) FROM audit_log",Map.of(),String.class);}

    @Test void tiedTimesAndPartitionIdentityKeepAll201RowsAndOriginalEvidenceBytes() {
        for(int index=1;index<=201;index++)insert(index,AT,"{\"name\":\"新名称\",\"amount\":123.450000000000000001}");
        // A partitioned audit identity is (id,created_at), not id alone.
        insert(201,AT.minusDays(1),"{\"name\":\"历史同号\"}");
        String original=digest();var ids=new ArrayList<String>();var detached=new ArrayList<AuditLog>();var interpreter=new AuditEventInterpreter();
        read.executeWithoutResult(tx->reader.read(ALL,202,rows->{
            assertThat(rows).hasSizeLessThanOrEqualTo(100);
            for(var row:rows){assertThat(shared.contains(row)).isFalse();assertThat(row.getUserAgent()).isNull();
                ids.add(row.getId()+"@"+row.getCreatedAt());detached.add(row);
                var old=new AuditLog();old.setAction(row.getAction());old.setTargetType(row.getTargetType());old.setTargetId(row.getTargetId());old.setEventSource(row.getEventSource());old.setResult(row.getResult());
                old.setBefore(row.getBefore());old.setAfter(row.getAfter());old.setCreatedAt(row.getCreatedAt());old.setRiskLevel(row.getRiskLevel());old.setEventCategory(row.getEventCategory());
                assertThat(interpreter.interpret(row)).isEqualTo(interpreter.interpret(old));
            }
        }));
        assertThat(ids).hasSize(202).doesNotHaveDuplicates();assertThat(ids.getFirst()).startsWith("201@");assertThat(ids.getLast()).startsWith("201@");
        assertThat(detached).allSatisfy(row->{assertThat(row.getBefore()).isNull();assertThat(row.getAfter()).isNull();});
        assertThat(digest()).isEqualTo(original);
        assertThat(sql).hasSize(6).allSatisfy(statement->assertThat(statement).doesNotContain("user_agent"));
        assertThat(sql.getFirst()).contains("octet_length");assertThat(sql.get(1)).doesNotContain("octet_length");
    }
    @Test void lateCommitCannotEnterTheAlreadyCountedRepeatableReadButRefreshFindsIt() {
        for(int index=1;index<=101;index++)insert(index,AT,"{}");
        var seen=new ArrayList<Long>();
        read.executeWithoutResult(tx->reader.read(ALL,101,rows->{
            if(seen.isEmpty())insert(102,AT.plusSeconds(1),"{\"name\":\"迟到提交\"}");
            rows.forEach(row->seen.add(row.getId()));
        }));
        assertThat(seen).hasSize(101).doesNotContain(102L);
        var refreshed=new ArrayList<Long>();read.executeWithoutResult(tx->reader.read(ALL,102,rows->rows.forEach(row->refreshed.add(row.getId()))));
        assertThat(refreshed).hasSize(102).contains(102L);
    }
    @Test void oneOverBudgetOriginalIsRejectedBeforeLoadingItsRawPayloadAndStaysUnchanged() {
        jdbc.update("INSERT INTO audit_log(id,created_at,action,event_source,result,risk_level,event_category,before,after,user_agent) VALUES(1,:time,'update','database','success','low','business','{}',jsonb_build_object('name',repeat('x',CAST(:bytes AS integer))),'original')",
                Map.of("time",AT,"bytes",ExportResourceLimits.SOURCE_BATCH_BYTES));
        String original=digest();
        assertThatThrownBy(()->read.executeWithoutResult(tx->reader.read(ALL,1,rows->{throw new AssertionError("must not load evidence");})))
                .isInstanceOf(ApiException.class).hasMessageContaining("读取预算");
        assertThat(sql).hasSize(1);assertThat(digest()).isEqualTo(original);
    }
}
