package com.uten.imp.security;

import com.uten.imp.application.port.*;
import com.uten.imp.features.auth.*;
import com.uten.imp.features.master.warehouse.WarehouseDataScopeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.quality.ProductionFqcTaskAccessPolicy;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.simple.JdbcClient;
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

/** V940 with actual owner, quality-pool, assignment and warehouse algorithms.
 * All writes are synthetic fixtures in this lease's private migrated database. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class NativeReadScopeVersionPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static DriverManagerDataSource source;
    static JdbcTemplate db;
    static EntityManagerFactory factory;
    static JpaTransactionManager transactions;
    UUID actor,employee,other;
    Set<String> permissions;
    AuthUser subject;
    SubmitterPrincipalRestorer restorer;
    ReadScopeVersionAuthority authority;
    OwnerVisibility owners;
    ProductionWorkshopReadScopePolicy workshop;
    WarehouseDataScopeService warehouse;
    ProductionFqcTaskAccessPolicy quality;
    @BeforeAll static void baseline() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("b1_native_scope_v940");
        source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());db=new JdbcTemplate(source);
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(source);bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.security");bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));bean.afterPropertiesSet();
        factory=bean.getObject();transactions=new JpaTransactionManager(factory);
    }
    @AfterAll static void close() throws Exception {if(factory!=null)factory.close();if(database!=null)database.close();}
    @BeforeEach void identities(){
        actor=UUID.randomUUID();employee=employee("reader");other=employee("owner");
        insertUser(actor,employee);
        permissions=new HashSet<>(Set.of("sales_order:progress:view","subcontract_short_delivery:view","production_execution:view",
                "production_quality_inspection:view","production_quality_inspection:approve","stock:view"));
        var engine=mock(PermissionResolver.class);
        when(engine.authorizationSnapshot(actor,employee,false)).thenAnswer(call->new PermissionResolver.AuthorizationSnapshot(Set.copyOf(permissions),true));
        when(engine.grantedPermsOf(actor)).thenAnswer(call->Set.copyOf(permissions));
        var current=new SecurityContextCurrentUser();var em=SharedEntityManagerCreator.createSharedEntityManager(factory);
        owners=new OwnerVisibility(current,em,new EmployeeHandoverVisibility(em));
        restorer=new SubmitterPrincipalRestorer(new NamedParameterJdbcTemplate(source),new StaffAuthorityResolver(engine));
        workshop=new ProductionWorkshopReadScopePolicy(new NamedParameterJdbcTemplate(source));
        warehouse=new WarehouseDataScopeService(JdbcClient.create(source),current);quality=new ProductionFqcTaskAccessPolicy(em,current);
        var target=new ReadScopeVersionAuthority(new NamedParameterJdbcTemplate(source),restorer,owners);
        port(target,"subcontractAccess",new SubcontractDocumentAccessPolicy(owners,current));
        port(target,"productionAccess",new ProductionDocumentAccessPolicy(owners,current));port(target,"qualityAccess",quality);
        port(target,"workshopAccess",workshop);port(target,"warehouseAccess",warehouse);port(target,"taskAudience",new BusinessTaskAudienceService(engine));
        var proxy=new ProxyFactory(target);proxy.setProxyTargetClass(true);
        var transactionAdvice = new TransactionInterceptor();
        transactionAdvice.setTransactionManager(transactions);
        transactionAdvice.setTransactionAttributeSource(new AnnotationTransactionAttributeSource());
        transactionAdvice.afterPropertiesSet();
        proxy.addAdvice(transactionAdvice);authority=(ReadScopeVersionAuthority)proxy.getProxy();
        login();
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    @SuppressWarnings("unchecked") static <T> void port(Object target,String field,T value){
        ObjectProvider<T> provider=mock(ObjectProvider.class);when(provider.getIfAvailable()).thenReturn(value);ReflectionTestUtils.setField(target,field,provider);
    }
    void login(){subject=new AuthUser(actor,employee,"native-scope-reader",Set.copyOf(permissions),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(subject,null,subject.getAuthorities()));}

    @Test void originalOwnerScopesRevokeAndAbaWithoutChangingRoleStamps(){
        var stamps=restorer.currentStamps(actor).orElseThrow();
        for(var pair:List.of(new String[]{"subcontract","native_subcontract_owner"},new String[]{"production_plan","native_production_owner"})){
            grant(actor,pair[0],other);String wide=authority.scopeFor(pair[1],subject);
            assertThat(owners.evaluate(pair[0],pair[0]+":view:all").visibleOwners()).contains(other);
            db.update("DELETE FROM user_data_scopes WHERE user_id=? AND scope=?",actor,pair[0]);String narrow=authority.scopeFor(pair[1],subject);
            grant(actor,pair[0],other);String again=authority.scopeFor(pair[1],subject);
            assertThat(wide).isNotEqualTo(narrow).isNotEqualTo(again);
        }
        assertThat(restorer.currentStamps(actor).orElseThrow()).isEqualTo(stamps);
    }
    @Test void independentLateCommitsBothAdvanceTheNativeOwnerLedgerWithoutAGlobalRowLock() throws Exception {
        long before=generation("native_subcontract_owner");UUID otherUser=UUID.randomUUID();insertUser(otherUser,other);
        UUID extraOwner=employee("late-owner");
        try(Connection earlier=source.getConnection();Connection later=source.getConnection()){
            earlier.setAutoCommit(false);later.setAutoCommit(false);
            for(Object[] row:List.of(new Object[]{earlier,actor,extraOwner},new Object[]{later,otherUser,extraOwner})){
                try(var statement=((Connection)row[0]).prepareStatement("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(?,'subcontract',?)")){
                    statement.setObject(1,row[1]);statement.setObject(2,row[2]);statement.setQueryTimeout(5);statement.executeUpdate();
                }
            }
            later.commit();String afterLater=authority.scopeFor("native_subcontract_owner",subject);
            assertThat(generation("native_subcontract_owner")).isEqualTo(before+1);
            earlier.commit();assertThat(generation("native_subcontract_owner")).isEqualTo(before+2);
            assertThat(authority.scopeFor("native_subcontract_owner",subject)).isNotEqualTo(afterLater);
        }
    }
    @Test void qualityApproverUsesTheCompanyPoolAndViewOnlyFallsBackToTheOriginalPlanOwnerPolicy(){
        assertThat(quality.canAccessQualityPool()).isTrue();String pool=authority.scopeFor("native_fqc_records",subject);
        permissions.remove("production_quality_inspection:approve");login();assertThat(quality.canAccessQualityPool()).isFalse();
        String own=authority.scopeFor("native_fqc_records",subject);assertThat(own).isNotEqualTo(pool);
        grant(actor,"production_plan",other);String granted=authority.scopeFor("native_fqc_records",subject);
        assertThat(granted).isNotEqualTo(own);
        db.update("DELETE FROM user_data_scopes WHERE user_id=? AND scope='production_plan'",actor);
        assertThat(authority.scopeFor("native_fqc_records",subject)).isNotEqualTo(own).isNotEqualTo(granted);
    }
    @Test void workshopDimensionsMatchTheSharedPredicateAndSameRoleMembershipAbaCannotReviveTheOldProof(){
        UUID original=db.queryForObject("SELECT department_id FROM employees WHERE id=?",UUID.class,employee);
        UUID root=department(null),child=department(root),unrelated=department(null);
        db.update("UPDATE employees SET department_id=? WHERE id=?",child,employee);
        var first=workshop.snapshot(subject);assertThat(first.workshops()).contains(root,child).doesNotContain(unrelated);
        assertThat(actualAssignedDepartments()).containsExactlyElementsOf(first.workshops());
        String a=authority.scopeFor("native_workshop_tasks",subject);
        db.update("UPDATE employees SET department_id=? WHERE id=?",unrelated,employee);
        String b=authority.scopeFor("native_workshop_tasks",subject);
        db.update("UPDATE employees SET department_id=? WHERE id=?",child,employee);
        assertThat(authority.scopeFor("native_workshop_tasks",subject)).isNotEqualTo(a).isNotEqualTo(b);
        db.update("INSERT INTO employee_secondary_departments(employee_id,department_id) VALUES(?,?)",employee,unrelated);
        assertThat(workshop.snapshot(subject).workshops()).contains(unrelated);
        db.update("UPDATE employees SET status='resigned' WHERE id=?",employee);
        assertThat(workshop.snapshot(subject).responsibleEmployee()).isNull();assertThat(workshop.snapshot(subject).workshops()).isEmpty();
        assertThat(original).isNotNull();
    }
    @Test void warehousePublicationBypassesTheOldReadWindowAndExcludesTheRequestedFilter(){
        UUID a=warehouse(),b=warehouse();
        db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) VALUES(?,?),(?,?)",a,employee,b,other);
        assertThat(warehouse.access().defaultScope().warehouseIds()).contains(a).doesNotContain(b);
        String initial=authority.scopeFor("native_warehouse_tasks",subject);
        warehouse.withRequestedWarehouse(a,()->{
            assertThat(authority.scopeFor("native_warehouse_tasks",subject)).isEqualTo(initial);
            assertThat(warehouse.current(a).warehouseIds()).contains(a);
            db.update("UPDATE warehouse_keepers SET employee_id=? WHERE warehouse_id=? AND employee_id=?",other,a,employee);
            db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) VALUES(?,?)",b,employee);
            assertThat(authority.scopeFor("native_warehouse_tasks",subject)).isNotEqualTo(initial);
            assertThat(warehouse.access().defaultScope().warehouseIds()).contains(b).doesNotContain(a);
            assertThatThrownBy(()->warehouse.current(a)).isInstanceOf(com.uten.imp.common.web.ApiException.class);
            return null;
        });
    }
    @Test void migrationWatchesRealPhysicalOwnershipSourcesWhileDatasetIdentityAndResetHistoryRemainImmutable(){
        for(String relation:List.of("stock_documents","stock_document_items","production_fqc_inspections","production_execution_segments","procurement_inspection_items"))
            assertThat(db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid=CAST(? AS regclass) AND tgname LIKE 'trg_native_scope_%' AND tgenabled='A'",Long.class,"public."+relation)).isPositive();
        assertThat(db.queryForObject("SELECT to_regclass('public.production_finished_inbound_documents') IS NULL",Boolean.class)).isTrue();
        String initial=authority.scopeFor("native_feature",subject);
        for(String statement:List.of("UPDATE authorization_state SET business_dataset_id=gen_random_uuid() WHERE singleton_id=1",
                "UPDATE authorization_state SET business_reset_generation=business_reset_generation+1 WHERE singleton_id=1",
                "UPDATE authorization_state SET business_reset_generation=business_reset_generation-1 WHERE singleton_id=1"))
            assertThatThrownBy(()->db.update(statement)).isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(authority.scopeFor("native_feature",subject)).isEqualTo(initial);
    }
    @Test void purchasePrintProfileAndSharedNativeGrantMapPreserveTheirSeparateOriginalAuthorities(){
        String companyReport=authority.scopeFor("purchase",subject);
        var stamps=restorer.currentStamps(actor).orElseThrow();
        for(var pair:List.of(new String[]{"purchase","native_purchase_owner"},new String[]{"subcontract","native_subcontract_owner"},new String[]{"production_plan","native_production_owner"})){
            long before=generation(pair[1]);String own=authority.scopeFor(pair[1],subject);
            grant(actor,pair[0],other);String wide=authority.scopeFor(pair[1],subject);
            assertThat(generation(pair[1])).isEqualTo(before+1);assertThat(wide).isNotEqualTo(own);
            db.update("DELETE FROM user_data_scopes WHERE user_id=? AND scope=?",actor,pair[0]);
            String narrow=authority.scopeFor(pair[1],subject);grant(actor,pair[0],other);
            assertThat(authority.scopeFor(pair[1],subject)).isNotEqualTo(wide).isNotEqualTo(narrow);
            assertThat(generation(pair[1])).isEqualTo(before+3);
        }
        assertThat(new com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy(owners,new SecurityContextCurrentUser()).scope().visibleOwners()).contains(other);
        assertThat(authority.scopeFor("purchase",subject)).isEqualTo(companyReport);
        assertThat(restorer.currentStamps(actor).orElseThrow()).isEqualTo(stamps);
        for(String table:List.of("purchase_orders","purchase_receipts","purchase_returns")){
            String definition=db.queryForObject("SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgrelid=CAST(? AS regclass) AND tgname='trg_native_purchase_maker' AND tgenabled='A'",String.class,"public."+table);
            assertThat(definition).contains("UPDATE OF maker_id","IS DISTINCT FROM","native_purchase_owner");
        }
    }
    private List<UUID> actualAssignedDepartments(){return new NamedParameterJdbcTemplate(source).queryForList(
            "SELECT d.id FROM departments d CROSS JOIN LATERAL(SELECT d.id workshop_department_id,NULL::uuid responsible_employee_id) t WHERE "+ProductionWorkshopAssignmentScope.predicate("t")+" ORDER BY d.id",
            Map.of("employeeId",employee),UUID.class);}
    private void grant(UUID recipient,String scope,UUID owner){db.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(?,?,?)",recipient,scope,owner);}
    private static long generation(String domain){return db.queryForObject("SELECT generation FROM read_scope_generations WHERE domain=?",Long.class,domain);}
    private void insertUser(UUID user,UUID employee){db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin) VALUES(?,?,?,'test-fixture-only',false,false)",user,employee,"native-scope-"+user);}
    private static UUID employee(String label){UUID id=UUID.randomUUID();db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,?,id_type,department_id,CURRENT_DATE,'active','regular' FROM employees WHERE code='ADMIN'",id,"NS-"+id,label);return id;}
    private static UUID department(UUID parent){UUID id=UUID.randomUUID();db.update("INSERT INTO departments(id,code,name,level,parent_id) VALUES(?,?,?,'二级班组',?)",id,"NS-"+id,"Native scope fixture",parent);return id;}
    private static UUID warehouse(){
        UUID root=db.queryForObject("SELECT fn_warehouse_root_id()",UUID.class);
        if(root==null){root=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,'001','Native fixture main warehouse','使用')",root);}
        UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,status,parent_id) VALUES(?,?,?,'使用',?)",id,"NS-"+id,"Native scope fixture",root);return id;
    }
}
