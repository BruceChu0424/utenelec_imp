package com.uten.imp.features.finance.reconciliation;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationQueryFilter;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.persistenceunit.PersistenceManagedTypes;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceReconciliationHeaderPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;private static jakarta.persistence.EntityManagerFactory emf;
    private EntityManager em;
    @BeforeAll static void start(){
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"finance_reconciliations");
        var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(source);factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setManagedTypes(PersistenceManagedTypes.of(FinanceReconciliation.class.getName()));factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));
        factory.afterPropertiesSet();emf=factory.getObject();
    }
    @AfterAll static void stop() {
        if (emf != null) {
            emf.close();
        }
        PG.stop();
    }
    @BeforeEach void prepare(){db.execute("TRUNCATE finance_reconciliations");em=emf.createEntityManager();}
    @AfterEach void close(){if(em!=null)em.close();}
    @Test void exactOriginalCurrencyAndChineseCalendarHeadersShareCountPageFacetsAndReversalIdentity(){
        UUID account=UUID.randomUUID(),other=UUID.randomUUID(),payment=UUID.randomUUID();
        UUID original=seed(account,"2026-09-30T15:59:59Z","0","90071992547409.1234","PAYMENT","POSTING",payment,null);
        UUID income=seed(account,"2026-09-30T16:00:00Z","90071992547409.1234","0","RECEIPT","POSTING",UUID.randomUUID(),null);
        UUID reversal=seed(account,"2026-10-31T15:59:59Z","90071992547409.1234","0","PAYMENT","REVERSAL",payment,original);
        seed(account,"2026-10-31T16:00:00Z","90071992547409.1234","0","RECEIPT","POSTING",UUID.randomUUID(),null);
        seed(other,"2026-10-15T00:00:00Z","90071992547409.1234","0","RECEIPT","POSTING",UUID.randomUUID(),null);
        seed(account,"2026-10-15T00:00:00Z",null,"0","RECEIPT","POSTING",UUID.randomUUID(),null);
        var service=new FinanceReconciliationService(mock(FinanceReconciliationRepository.class),em);
        var columns=Map.of("billDate","2026-10","counterpartName","对方%_","inAmount",">=90071992547409.1234");
        var filter=new FinanceReconciliationQueryFilter(null,account,null,null,null,null,null,null,null).withColumns(columns,null);
        Specification<FinanceReconciliation> spec=ReflectionTestUtils.invokeMethod(service,"reconciliationSpec",filter);
        var cb=em.getCriteriaBuilder();var count=cb.createQuery(Long.class);var countRoot=count.from(FinanceReconciliation.class);
        count.select(cb.count(countRoot)).where(spec.toPredicate(countRoot,count,cb));assertThat(em.createQuery(count).getSingleResult()).isEqualTo(2);
        var query=cb.createQuery(UUID.class);var root=query.from(FinanceReconciliation.class);
        query.select(root.get("id")).where(spec.toPredicate(root,query,cb)).orderBy(cb.asc(root.get("billDate")));
        assertThat(em.createQuery(query).setMaxResults(1).getResultList()).containsExactly(income);
        assertThat(em.createQuery(query).setFirstResult(1).setMaxResults(1).getResultList()).containsExactly(reversal);
        assertThat(service.facets(filter).get("billNo")).hasSize(2);
        var exact=filter.withColumns(columns,original);
        Specification<FinanceReconciliation> reversed=ReflectionTestUtils.invokeMethod(service,"reconciliationSpec",exact);
        query=cb.createQuery(UUID.class);root=query.from(FinanceReconciliation.class);
        query.select(root.get("id")).where(reversed.toPredicate(root,query,cb));assertThat(em.createQuery(query).getResultList()).containsExactly(reversal);
    }
    @Test void monetarySearchAndSortRequireOneAccountBeforeParsingOrTouchingRepositories(){
        var repo=mock(FinanceReconciliationRepository.class);var emptyEm=mock(EntityManager.class);
        var service=new FinanceReconciliationService(repo,emptyEm);
        var filter=new FinanceReconciliationQueryFilter(null,null,null,null,null,null,null,null,null);
        assertThatThrownBy(()->service.list(filter.withColumns(Map.of("inAmount","NaN"),null),1,20,null,null))
                .isInstanceOf(ApiException.class).hasMessageContaining("选择账户");
        assertThatThrownBy(()->service.facets(filter.withColumns(Map.of("outAmount",">0"),null)))
                .isInstanceOf(ApiException.class).hasMessageContaining("选择账户");
        assertThatThrownBy(()->service.list(filter,1,20,"inAmount","desc"))
                .isInstanceOf(ApiException.class).hasMessageContaining("选择账户");
        verifyNoInteractions(repo,emptyEm);
    }
    private UUID seed(UUID account,String at,String incoming,String outgoing,String source,String kind,UUID document,UUID reversal){
        UUID id=UUID.randomUUID();db.update("INSERT INTO finance_reconciliations(id,bill_no,bill_date,account_id,counterpart_name,in_amount,out_amount,source_doc_type,source_doc_id,entry_kind,reversal_of_id,is_deleted) VALUES(?,?,?,?,?,?,?,?,?,?,?,false)",
                id,"FLOW-"+id,OffsetDateTime.parse(at),account,"对方%_快照",incoming==null?null:new BigDecimal(incoming),new BigDecimal(outgoing),source,document,kind,reversal);return id;
    }
}
