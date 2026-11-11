package com.uten.imp.businesschain;
import java.util.*;import java.util.concurrent.atomic.*;import java.math.*;
import org.springframework.context.*;import org.springframework.boot.test.util.TestPropertyValues;
import org.springframework.test.context.ContextConfiguration;import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;import org.testcontainers.postgresql.PostgreSQLContainer;
import org.junit.jupiter.api.*;import com.uten.imp.common.export.*;import static org.assertj.core.api.Assertions.*;
@ContextConfiguration(initializers=StagedExportAudit.Prepare.class,inheritInitializers=false)
public class StagedExportAudit extends ExportAudit {
 static final String PREFIX="SAUDIT10K";
 public static class Prepare implements ApplicationContextInitializer<ConfigurableApplicationContext> {
   @Override public void initialize(ConfigurableApplicationContext context){
     var pg=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("audit_historical_goods").withReuse(false)
       .withCreateContainerCmdModifier(create->create.getHostConfig().withNanoCPUs(2_000_000_000L).withMemory(1536L*1024*1024));
     pg.start();Runtime.getRuntime().addShutdownHook(new Thread(pg::stop));
     var conf=com.uten.imp.testsupport.TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration");
     conf.target("897").load().migrate();
     var jdbc=new JdbcTemplate(new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()));
     var cat=UUID.randomUUID(); long start=System.nanoTime();
     jdbc.update("INSERT INTO material_categories(id,code,name) VALUES(?,?,?)",cat,"ZSAUDITCAT","隔离历史货品");
     var seq=jdbc.queryForObject("SELECT coalesce(max(code_sequence),0) FROM goods",Long.class);
     for(int i=0;i<100000;i+=250){
       int n=jdbc.update("""
         INSERT INTO goods(id,code,name,status,category_id,code_sequence,auto_created,price,zk)
         SELECT gen_random_uuid(),?||lpad(i::text,6,'0'),?||lpad(i::text,6,'0'),'使用',?,?+i+1,false,1.2345,0.9500
         FROM generate_series(?,?) AS i""",PREFIX,PREFIX,cat,seq,i,i+249);assertThat(n).isEqualTo(250);
       if(i==0||(i+250)%10000==0)System.out.println("AUDIT_V897_SEED count="+(i+250)+" milliseconds="+(System.nanoTime()-start)/1000000);
     }
     long prepared=(System.nanoTime()-start)/1000000;start=System.nanoTime();
     com.uten.imp.testsupport.TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration").load().migrate();
     var success=jdbc.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE version='1129' AND success",Integer.class);assertThat(success).isEqualTo(1);
     var enabled=jdbc.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid='goods'::regclass AND NOT tgisinternal AND tgenabled<>'D'",Integer.class);
     System.out.println("AUDIT_V1129_EXISTING_GOODS prepMillis="+prepared+" upgradeMillis="+(System.nanoTime()-start)/1000000+" activeGoodsTriggers="+enabled);
     TestPropertyValues.of("spring.datasource.url="+pg.getJdbcUrl(),"spring.datasource.username="+pg.getUsername(),"spring.datasource.password="+pg.getPassword(),
       "spring.flyway.url="+pg.getJdbcUrl(),"spring.flyway.user="+pg.getUsername(),"spring.flyway.password="+pg.getPassword()).applyTo(context.getEnvironment());
   }
 }
 @Override @Test @Order(1) void hundredThousandGoodsFromPostgres() throws Exception {
   exporter("goods","goods:price:view","goods:discount:view");var req=request("goods",Map.of("keyword",PREFIX));
   var stored=jdbc.queryForMap("select count(*) as cnt,sum(price) as sum,min(price) as lo,max(price) as hi from goods where left(code,?)=?",PREFIX.length(),PREFIX);
   assertThat(((Number)stored.get("cnt")).longValue()).isEqualTo(100000);
   for(String k:List.of("lo","hi"))assertThat((BigDecimal)stored.get(k)).isEqualByComparingTo("1.2345");
   assertThat((BigDecimal)stored.get("sum")).isEqualByComparingTo("123450.0000");
   System.out.println("AUDIT_INDEPENDENT_DB_ORACLE "+stored);
   AtomicInteger rows=new AtomicInteger(),batches=new AtomicInteger(),peak=new AtomicInteger();final BigDecimal[] sum={BigDecimal.ZERO};long start=System.nanoTime();
   try(var sink=ExportPageSink.open(page->{
     assertThat(page.rows()).hasSize(100);batches.incrementAndGet();peak.accumulateAndGet(em.unwrap(org.hibernate.Session.class).getStatistics().getEntityCount(),Math::max);
     for(var row:page.rows()){assertThat(row.get("code")).isEqualTo(PREFIX+"%06d".formatted(rows.getAndIncrement()));var exactPrice=(BigDecimal)row.get("price");assertThat(exactPrice).isEqualByComparingTo("1.2345");sum[0]=sum[0].add(exactPrice);}
   })){var result=master.read(req);assertThat(result.total()).isEqualTo(100000);assertThat(result.rows()).isEmpty();}
   assertThat(rows).hasValue(100000);assertThat(batches).hasValue(1000);assertThat(sum[0]).isEqualByComparingTo("123450.0000");assertThat(peak.get()).isLessThan(2000);
   System.out.println("AUDIT_100K_COMPLETE rows="+rows+" batches="+batches+" sum="+sum[0]+" peakManaged="+peak+" readMillis="+(System.nanoTime()-start)/1000000);
 }
}

