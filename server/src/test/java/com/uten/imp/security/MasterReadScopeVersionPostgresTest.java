package com.uten.imp.security;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.*;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;

import java.sql.Connection;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Full migrated V938 triggers, actual ownership SQL and fresh authorization transactions. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MasterReadScopeVersionPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static DriverManagerDataSource source;
    static JdbcTemplate db;
    static EntityManagerFactory factory;
    static JpaTransactionManager transactions;
    final Set<String> permissions=Set.of("goods:export","client:export","supplier:export","account:export","currency:export",
            "color:export","unit:export","mould:export","warehouse:export","settlement_method:export");
    UUID actor, employee, owner;
    AuthUser subject;
    SubmitterPrincipalRestorer restorer;
    ReadScopeVersionAuthority authority;
    GoodsReadScopePolicy policy;

    @BeforeAll static void baseline() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("b1_master_scope_v938");
        source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        db=new JdbcTemplate(source);
        var bean=new LocalContainerEntityManagerFactoryBean(); bean.setDataSource(source);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());bean.setPackagesToScan("com.uten.imp.security");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));bean.afterPropertiesSet();
        factory=bean.getObject();transactions=new JpaTransactionManager(factory);
    }
    @AfterAll static void close() throws Exception {if(factory!=null)factory.close();if(database!=null)database.close();}
    @BeforeEach void actor() {
        actor=UUID.randomUUID();employee=employee("actor");owner=employee("owner");
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin) VALUES(?,?,?,'test-fixture-only',false,false)",actor,employee,"master-scope-"+actor);
        var engine=mock(PermissionResolver.class);
        when(engine.authorizationSnapshot(actor,employee,false)).thenReturn(new PermissionResolver.AuthorizationSnapshot(permissions,true));
        restorer=new SubmitterPrincipalRestorer(new NamedParameterJdbcTemplate(source),new StaffAuthorityResolver(engine));
        var em=SharedEntityManagerCreator.createSharedEntityManager(factory);
        var visibility=new OwnerVisibility(new SecurityContextCurrentUser(),em,new EmployeeHandoverVisibility(em));
        policy=new GoodsReadScopePolicy(visibility);
        var target=new ReadScopeVersionAuthority(new NamedParameterJdbcTemplate(source),restorer,visibility,policy);
        var proxy=new ProxyFactory(target);proxy.setProxyTargetClass(true);
        var transactionAdvice = new TransactionInterceptor();
        transactionAdvice.setTransactionManager(transactions);
        transactionAdvice.setTransactionAttributeSource(new AnnotationTransactionAttributeSource());
        transactionAdvice.afterPropertiesSet();
        proxy.addAdvice(transactionAdvice);
        authority=(ReadScopeVersionAuthority)proxy.getProxy();
        subject=new AuthUser(actor,employee,"master-export-only",permissions,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(subject,null,subject.getAuthorities()));
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void everyMasterDomainHasAlwaysOnQualificationWatchersWithoutAddingViewPermissions(){
        Set<String> domains=Set.of("master_goods","master_account","master_currency","master_color","master_unit","master_mould","master_warehouse","master_settlement_method");
        assertThat(new HashSet<>(db.queryForList("SELECT domain FROM read_scope_domains WHERE domain LIKE 'master_%'",String.class))).isEqualTo(domains);
        for(String domain:domains)assertThat(authority.scopeFor(domain,subject)).matches("[0-9a-f]{64}");
        assertThat(db.queryForList("SELECT c.relname FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND t.tgname='trg_read_scope_master_qualification' AND t.tgenabled='A'",String.class))
                .containsExactlyInAnyOrder("goods","accounts","currencies","colors","units","moulds","warehouses","settlement_methods");
        UUID color=UUID.randomUUID();db.update("INSERT INTO colors(id,code,name,status) VALUES(?,?,?,'使用')",color,"MC-"+color,"Scope qualification");
        String before=authority.scopeFor("master_color",subject);
        db.update("UPDATE colors SET is_deleted=true WHERE id=?",color);
        assertThat(authority.scopeFor("master_color",subject)).isNotEqualTo(before);
    }
    @Test void goodsUsesItsConfiguredPolicyAndDataScopeAbaDoesNotReviveAnOldProof(){
        String feature=authority.scopeFor("master_goods",subject);
        ReflectionTestUtils.setField(policy,"ownerScopeEnabled",true);
        String own=authority.scopeFor("master_goods",subject); assertThat(own).isNotEqualTo(feature);
        var stamps=restorer.currentStamps(actor).orElseThrow();
        grant(actor,owner);String wide=authority.scopeFor("master_goods",subject);
        db.update("DELETE FROM user_data_scopes WHERE user_id=? AND scope='goods'",actor);
        String narrow=authority.scopeFor("master_goods",subject);
        grant(actor,owner);String wideAgain=authority.scopeFor("master_goods",subject);
        assertThat(wide).isNotEqualTo(narrow).isNotEqualTo(wideAgain);
        assertThat(restorer.currentStamps(actor).orElseThrow()).isEqualTo(stamps);
        assertThat(authority.scopeFor("master_account",subject)).matches("[0-9a-f]{64}");
    }
    @Test void lateGoodsGrantCommitCountsBothTransactionsWithoutAGlobalCounterLock() throws Exception {
        long before=generation(); UUID secondActor=UUID.randomUUID(),secondEmployee=employee("second"),secondOwner=employee("second-owner");
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin) VALUES(?,?,?,'test-fixture-only',false,false)",secondActor,secondEmployee,"master-scope-"+secondActor);
        try(Connection older=source.getConnection();Connection newer=source.getConnection()){
            older.setAutoCommit(false);newer.setAutoCommit(false);
            for(var pair:List.of(new Object[]{older,actor,owner},new Object[]{newer,secondActor,secondOwner})){
                try(var sql=((Connection)pair[0]).prepareStatement("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(?,'goods',?)")){
                    sql.setObject(1,pair[1]);sql.setObject(2,pair[2]);sql.setQueryTimeout(5);sql.executeUpdate();
                }
            }
            newer.commit();assertThat(generation()).isEqualTo(before+1);
            older.commit();assertThat(generation()).isEqualTo(before+2);
        }
    }
    private void grant(UUID user,UUID owner){db.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(?,'goods',?)",user,owner);}
    private long generation(){return db.queryForObject("SELECT generation FROM read_scope_generations WHERE domain='master_goods'",Long.class);}
    private UUID employee(String label){UUID id=UUID.randomUUID();db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,?,id_type,department_id,CURRENT_DATE,'active','regular' FROM employees WHERE code='ADMIN'",id,"MS-"+id,label);return id;}
}
