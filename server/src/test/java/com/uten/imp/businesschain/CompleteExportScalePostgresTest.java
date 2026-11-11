package com.uten.imp.businesschain;

import com.uten.imp.common.export.ExportPageSink;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.AfterEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.util.TestPropertyValues;
import org.springframework.context.ApplicationContextInitializer;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.context.ContextConfiguration;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.math.BigDecimal;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import static org.assertj.core.api.Assertions.*;

/** Historical preparation with triggers enabled, then the actual complete upgrade and public source. */
@ContextConfiguration(initializers=CompleteExportScalePostgresTest.Prepare.class,inheritInitializers=false)
class CompleteExportScalePostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired com.uten.imp.features.master.export.MasterReportExportSource master;
    @Autowired jakarta.persistence.EntityManager em;
    @AfterEach void logoutScaleReader() {org.springframework.security.core.context.SecurityContextHolder.clearContext();}
    static final String PREFIX="REMEDIATION100K";
    public static class Prepare implements ApplicationContextInitializer<ConfigurableApplicationContext> {
        @Override public void initialize(ConfigurableApplicationContext context) {
            var pg=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("remediation_export_scale").withReuse(false);
            pg.start();Runtime.getRuntime().addShutdownHook(new Thread(pg::stop));
            long start=System.nanoTime();
            com.uten.imp.testsupport.TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())
                    .locations("classpath:db/migration").target("897").load().migrate();
            long initialMigration=(System.nanoTime()-start)/1000000;
            var jdbc=new JdbcTemplate(new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()));
            UUID category=UUID.randomUUID();
            jdbc.update("INSERT INTO material_categories(id,code,name) VALUES(?,?,?)",category,"REMEDIATION100KCAT","本地导出规模合成货品");
            long sequence=jdbc.queryForObject("SELECT coalesce(max(code_sequence),0) FROM goods",Long.class);
            start=System.nanoTime();
            for(int offset=0;offset<100000;offset+=250) {
                assertThat(jdbc.update("""
                    INSERT INTO goods(id,code,name,status,category_id,code_sequence,auto_created,price,zk)
                    SELECT gen_random_uuid(),?||lpad(i::text,6,'0'),?||lpad(i::text,6,'0'),'使用',?,?+i+1,false,1.2345,0.9500
                    FROM generate_series(?,?) AS i
                    """,PREFIX,PREFIX,category,sequence,offset,offset+249)).isEqualTo(250);
            }
            long seed=(System.nanoTime()-start)/1000000;start=System.nanoTime();
            var flyway=com.uten.imp.testsupport.TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())
                    .locations("classpath:db/migration").load();
            flyway.migrate();
            long upgrade=(System.nanoTime()-start)/1000000;
            assertThat(jdbc.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid='goods'::regclass AND NOT tgisinternal AND tgenabled='D'",Integer.class)).isZero();
            System.out.println("D3_SCALE_PREP initialMigrationMs="+initialMigration+" seedMs="+seed+" upgradeMs="+upgrade+" latest="+flyway.info().current().getVersion()+" disabledGoodsTriggers=0");
            TestPropertyValues.of("spring.datasource.url="+pg.getJdbcUrl(),"spring.datasource.username="+pg.getUsername(),"spring.datasource.password="+pg.getPassword(),
                    "spring.flyway.url="+pg.getJdbcUrl(),"spring.flyway.user="+pg.getUsername(),"spring.flyway.password="+pg.getPassword()).applyTo(context.getEnvironment());
        }
    }
    @Test void hundredThousandAuthoritativeRowsMatchIndependentSqlOrderAndExactAmounts() throws Exception {
        UUID employee=UUID.randomUUID();
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,?,id_type,department_id,CURRENT_DATE,'active','regular' FROM employees WHERE code='ADMIN'",
                employee,"SC-"+employee,com.uten.imp.support.SyntheticEmployeeIdentity.name("Scale reader",employee));
        var user=new com.uten.imp.security.AuthUser(UUID.randomUUID(),employee,"scale-reader",
                java.util.Set.of("goods:export","goods:price:view","goods:discount:view"),false,true,false);
        org.springframework.security.core.context.SecurityContextHolder.getContext().setAuthentication(
                new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
        var sql=jdbc.queryForMap("SELECT count(*) AS count,min(price) AS minimum,max(price) AS maximum,sum(price) AS sum FROM goods WHERE left(code,?)=?",PREFIX.length(),PREFIX);
        assertThat(((Number)sql.get("count")).longValue()).isEqualTo(100000);
        assertThat((BigDecimal)sql.get("minimum")).isEqualByComparingTo("1.2345");
        assertThat((BigDecimal)sql.get("maximum")).isEqualByComparingTo("1.2345");
        assertThat((BigDecimal)sql.get("sum")).isEqualByComparingTo("123450.0000");
        var rows=new AtomicInteger();var batches=new AtomicInteger();var peak=new AtomicInteger();
        BigDecimal[] sum={BigDecimal.ZERO};long started=System.nanoTime();
        try(var sink=ExportPageSink.open(page->{
            assertThat(page.rows()).hasSize(100);batches.incrementAndGet();
            peak.accumulateAndGet(em.unwrap(org.hibernate.Session.class).getStatistics().getEntityCount(),Math::max);
            for(var row:page.rows()) {
                assertThat(row.get("code")).isEqualTo(PREFIX+"%06d".formatted(rows.getAndIncrement()));
                assertThat((BigDecimal)row.get("price")).isEqualByComparingTo("1.2345");
                sum[0]=sum[0].add((BigDecimal)row.get("price"));
            }
        })) {
            var result=master.read(new com.uten.imp.features.reporting.export.ReportExportRequest(UUID.randomUUID(),"master","goods",
                    Map.of("filter",objectMapper.writeValueAsString(Map.of("keyword",PREFIX))),"code","asc",null));
            assertThat(result.total()).isEqualTo(100000);assertThat(result.rows()).isEmpty();
        }
        assertThat(rows).hasValue(100000);assertThat(batches).hasValue(1000);
        assertThat(sum[0]).isEqualByComparingTo("123450.0000");assertThat(peak.get()).isLessThan(2000);
        System.out.println("D3_SCALE_READ sql="+sql+" rows="+rows+" batches="+batches+" peakManaged="+peak+" sourceReadMs="+(System.nanoTime()-started)/1000000);
    }
}
