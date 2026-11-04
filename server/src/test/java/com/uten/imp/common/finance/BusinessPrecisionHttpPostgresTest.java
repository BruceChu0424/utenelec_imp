package com.uten.imp.common.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.support.StaticListableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.orm.jpa.*;
import org.springframework.orm.jpa.persistenceunit.PersistenceManagedTypes;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.web.bind.annotation.*;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** Real HTTP filter/advice, Hibernate transaction binding and one reused PG connection. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class BusinessPrecisionHttpPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static SingleConnectionDataSource source;static JdbcTemplate db;static EntityManagerFactory emf;
    static TransactionTemplate write,read;static MockMvc mvc;static boolean failBinding;
    @BeforeAll static void start(){
        PG.start();source=new SingleConnectionDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword(),true);
        source.setAutoCommit(true);db=new JdbcTemplate(source);
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_business_decimal_from_integer","fn_business_exact_divide_with_policy","fn_business_exact_divide");
        db.execute("CREATE TABLE precision_http_probe(id int PRIMARY KEY,value numeric)");
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(source);bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setManagedTypes(PersistenceManagedTypes.of());bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));bean.afterPropertiesSet();emf=bean.getObject();
        var vars=new TxSessionVars(null,null,null){@Override public void bindBusinessPrecision(String choices){if(failBinding)throw new IllegalStateException("private binding fault");super.bindBusinessPrecision(choices);}};
        ReflectionTestUtils.setField(vars,"em",SharedEntityManagerCreator.createSharedEntityManager(emf));
        var provider=new StaticListableBeanFactory(Map.of("vars",vars)).getBeanProvider(TxSessionVars.class);
        var manager=new JpaTransactionManager(emf);manager.setDataSource(source);manager.setTransactionExecutionListeners(List.of(new BusinessPrecisionTransactionBinder(provider)));
        write=new TransactionTemplate(manager);read=new TransactionTemplate(manager);read.setReadOnly(true);
        var json=new StaticListableBeanFactory(Map.of("json",new ObjectMapper().findAndRegisterModules())).getBeanProvider(ObjectMapper.class);
        mvc=MockMvcBuilders.standaloneSetup(new ProbeController()).setControllerAdvice(new GlobalExceptionHandler())
            .addFilters(new BusinessPrecisionRequestFilter(json)).build();
    }
    @AfterAll static void stop(){if(emf!=null){emf.close();}if(source!=null){source.destroy();}PG.stop();}
    @BeforeEach void clean(){failBinding=false;db.update("DELETE FROM precision_http_probe");}
    @AfterEach void contextWasReleased(){assertThat(BusinessPrecisionContext.choices()).isEmpty();}

    @Test void sqlRequestAsksBeforeAnyWriteAndExplicitChoiceCommitsExactlyOnce()throws Exception{
        mvc.perform(post("/precision-probe/sql")).andExpect(status().is(422))
            .andExpect(jsonPath("$.code").value("PRECISION_CHOICE_REQUIRED"))
            .andExpect(jsonPath("$.details.notWritten").value(true));
        assertThat(count()).isZero();
        mvc.perform(post("/precision-probe/sql").header(BusinessPrecisionContext.HEADER,choice("HALF_UP")))
            .andExpect(status().isOk()).andExpect(jsonPath("$.value").value("0.67"));
        assertThat(count()).isEqualTo(1);assertThat(db.queryForObject("SELECT value FROM precision_http_probe",BigDecimal.class)).isEqualByComparingTo("0.67");
    }
    @Test void readOnlyTransactionsUseTheChosenPolicyWithoutLeakingToTheNextRequest()throws Exception{
        mvc.perform(get("/precision-probe").header(BusinessPrecisionContext.HEADER,choice("DOWN")))
            .andExpect(status().isOk()).andExpect(jsonPath("$.value").value("0.66"));
        mvc.perform(get("/precision-probe")).andExpect(status().is(422))
            .andExpect(jsonPath("$.details.notWritten").value(true));
        assertThat(count()).isZero();
    }
    @Test void javaCalculationRollsBackTheSameBusinessWriteAndMalformedHeaderNeverRunsIt()throws Exception{
        mvc.perform(post("/precision-probe/java")).andExpect(status().is(422))
            .andExpect(jsonPath("$.details.notWritten").value(true));
        assertThat(count()).isZero();
        mvc.perform(post("/precision-probe/java").header(BusinessPrecisionContext.HEADER,"e30"))
            .andExpect(status().is(422)).andExpect(jsonPath("$.code").value("VALIDATION_FAILED"));
        assertThat(count()).isZero();
    }
    @Test void aCommittedEarlierStepIsNeverAdvertisedAsSafeToReplay()throws Exception{
        mvc.perform(post("/precision-probe/after-commit")).andExpect(status().is(422))
            .andExpect(jsonPath("$.details.notWritten").value(false));
        assertThat(count()).isEqualTo(1);
    }
    @Test void nestedCalculationChoicesCannotEraseARealEarlierCommit()throws Exception{
        mvc.perform(post("/precision-probe/after-commit-nested")).andExpect(status().is(422))
            .andExpect(jsonPath("$.details.notWritten").value(false));
        assertThat(count()).isEqualTo(1);
    }
    @Test void bindingFailureCannotReturnSavedSuccessAndDoesNotPoisonTheNextRequest()throws Exception{
        failBinding=true;
        mvc.perform(post("/precision-probe/java").header(BusinessPrecisionContext.HEADER,choice("HALF_UP")))
            .andExpect(status().isInternalServerError());
        assertThat(count()).isZero();failBinding=false;
        mvc.perform(post("/precision-probe/java").header(BusinessPrecisionContext.HEADER,choice("DOWN")))
            .andExpect(status().isOk()).andExpect(jsonPath("$.value").value("0.66"));
        assertThat(count()).isEqualTo(1);
    }
    static int count(){return db.queryForObject("SELECT count(*) FROM precision_http_probe",Integer.class);}
    static String choice(String mode){return Base64.getUrlEncoder().withoutPadding().encodeToString(("{\"version\":1,\"choices\":{\"http.ratio\":{\"scale\":2,\"rounding\":\""+mode+"\"}}}").getBytes(StandardCharsets.UTF_8));}
    static BigDecimal ratio(){return db.queryForObject("SELECT fn_business_exact_divide(2,3,'http.ratio','本次比例',30)",BigDecimal.class);}
    @RestController static class ProbeController {
        @GetMapping("/precision-probe") Map<String,String> read(){return read.execute(status->Map.of("value",ratio().toPlainString()));}
        @PostMapping("/precision-probe/{kind}") Map<String,String> write(@PathVariable String kind)throws Exception{
            if(kind.startsWith("after-commit")){
                write.executeWithoutResult(status->db.update("INSERT INTO precision_http_probe VALUES(1,1)"));
                if(kind.endsWith("nested"))try(var nested=BusinessPrecisionContext.use(Map.of())){
                    return Map.of("value",BusinessPrecisionContext.divide(BigDecimal.valueOf(2),new BigDecimal("3"),"http.ratio","本次比例",30).toPlainString());
                }
                return Map.of("value",BusinessPrecisionContext.divide(BigDecimal.valueOf(2),new BigDecimal("3"),"http.ratio","本次比例",30).toPlainString());
            }
            return write.execute(status->{
                BusinessPrecisionContext.ensureReady();db.update("INSERT INTO precision_http_probe VALUES(1,0)");
                BigDecimal amount="java".equals(kind)?BusinessPrecisionContext.divide(BigDecimal.valueOf(2),new BigDecimal("3"),"http.ratio","本次比例",30):ratio();
                db.update("UPDATE precision_http_probe SET value=? WHERE id=1",amount);return Map.of("value",amount.toPlainString());
            });
        }
    }
}
