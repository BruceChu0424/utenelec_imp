package com.uten.imp.responsibility;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.client.*;
import com.uten.imp.features.master.client.dto.*;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.*;
import java.math.BigDecimal;
import java.util.*;
import java.util.function.Supplier;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real migrated-database coverage of field and object boundaries, including batch access and handover. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ClientFinancialOwnershipPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static EntityManagerFactory factory;
    EntityManager em;
    final SecurityContextCurrentUser current = new SecurityContextCurrentUser();
    ClientAccessPolicy policy;
    ClientAccessService access;
    ClientService clients;
    UUID actor, primary, secondary, target, category, client;

    @BeforeAll static void start() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("client_financial_owners");
        var bean=new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.features.master.client","com.uten.imp.features.master.clientcategory");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none","hibernate.physical_naming_strategy","org.hibernate.boot.model.naming.CamelCaseToUnderscoresNamingStrategy"));
        bean.afterPropertiesSet(); factory=bean.getObject();
    }
    @AfterAll static void stop() throws Exception { if(factory!=null)factory.close(); if(database!=null)database.close(); }
    @BeforeEach void prepare() {
        em=factory.createEntityManager();
        inTx(()->{
            primary=staff("primary"); secondary=staff("secondary"); target=staff("target");
            actor=(UUID)em.createNativeQuery("SELECT id FROM users WHERE employee_id=:id").setParameter("id",primary).getSingleResult();
            category=UUID.randomUUID();
            em.createNativeQuery("INSERT INTO client_categories(id,code,name) VALUES(:id,:code,'owners test')").setParameter("id",category).setParameter("code","C-"+category).executeUpdate();
            client=UUID.randomUUID();
            em.createNativeQuery("INSERT INTO clients(id,category_id,code,name,status,owner_employee_id,credit_floor,init_total,bank,code_sequence) VALUES(:id,:category,:code,'客户原名','使用',:owner,100,200,'原银行',(SELECT coalesce(max(code_sequence),0)+1 FROM clients))")
                .setParameter("id",client).setParameter("category",category).setParameter("code","C-"+client).setParameter("owner",primary).executeUpdate(); return null;
        });
        var ownerVisibility=new OwnerVisibility(current,em,mock(EmployeeHandoverVisibility.class));
        policy=new ClientAccessPolicy(ownerVisibility,current,em);
        var tx=mock(TxSessionVars.class);
        doAnswer(call->{provenance();return null;}).when(tx).bind();
        access=new ClientAccessService(em,tx,current,policy);
        var repositories=new JpaRepositoryFactory(em);
        var codes=mock(CategoryDrivenCodeService.class);
        when(codes.allocateForUpdate(any(),any(),any(),nullable(String.class),any())).thenAnswer(call->call.getArgument(4,CategoryCodeAllocation.class));
        clients=new ClientService(repositories.getRepository(ClientRepository.class),repositories.getRepository(ClientCategoryRepository.class),tx,em,codes,policy,mock(EmployeeRepository.class),new EmployeeNameResolver(em));
        login(primary,Set.of("client:view","client:edit"),false);
    }
    @AfterEach void close() { SecurityContextHolder.clearContext(); if(em.getTransaction().isActive())em.getTransaction().rollback(); em.close(); }

    @Test void salesCanEditOwnProfileAndOmittedFinanceIsPreservedWhileTamperingFails() {
        inTx(()->{var req=ordinary();req.setName("客户新名称");clients.update(client,req);return null;});
        assertEquals("客户新名称",value("SELECT name FROM clients WHERE id=:id",client));
        assertEquals("100.0000",value("SELECT credit_floor::text FROM clients WHERE id=:id",client));
        for(String field:ClientFinancialPolicy.FINANCIAL_FIELDS) {
            assertThrows(ApiException.class,()->inTx(()->{
                var req=ordinary();
                switch(field) {
                    case "bank"->req.setBank("越权银行"); case "bankAccount"->req.setBankAccount("123");
                    case "taxId"->req.setTaxId("tax");case "credit"->req.setCredit(BigDecimal.ONE);
                    case "initTotal"->req.setInitTotal(BigDecimal.ONE);case "tday"->req.setTday(30);
                    case "creditFloor"->req.setCreditFloor(BigDecimal.ONE);
                    case "defaultSettlementMethodId"->req.setDefaultSettlementMethodId(UUID.randomUUID());
                    case "defaultCurrencyId"->req.setDefaultCurrencyReference(UUID.randomUUID());
                }
                clients.update(client,req);return null;
            }),field);
        }
        assertEquals("原银行",value("SELECT bank FROM clients WHERE id=:id",client));
    }

    @Test void financeOnlyCanUpdateFinanceWithoutSendingOrOverwritingOrdinaryProfile() {
        login(primary,Set.of("client:view","client:view:all","client:finance"),false);
        inTx(()->{var req=new ClientSaveRequest();req.setCreditFloor(new BigDecimal("350.25"));req.setInitTotal(new BigDecimal("500"));req.setVersion(em.find(Client.class,client).getVersion());
            var saved=clients.update(client,req);assertTrue(saved.isFinancialWritable());return null;});
        assertEquals("客户原名",value("SELECT name FROM clients WHERE id=:id",client));
        assertEquals("350.2500",value("SELECT credit_floor::text FROM clients WHERE id=:id",client));
        assertThrows(ApiException.class,()->inTx(()->{var req=new ClientSaveRequest();req.setName("财务越权改名");req.setCreditFloor(BigDecimal.ONE);clients.update(client,req);return null;}));
    }

    @Test void batchReplacesDifferentPrimaryWithMultipleOwnersAndPreservesReadOnlyPreviousOwner() {
        login(primary,Set.of("client:view","client:view:all","client:assign"),false);
        var saved=inTx(()->access.updateBatch(new ClientAccessBatchUpdateRequest(List.of(client),null,null,"财务设置共同负责人",List.of(target,secondary))).getFirst());
        assertEquals(target,saved.ownerEmployeeId());
        assertEquals(List.of(target,secondary),saved.owners().stream().map(ClientAccessViewer::employeeId).toList());
        assertTrue(saved.viewers().stream().anyMatch(viewer->viewer.employeeId().equals(primary)));
        assertEquals(2,((Number)em.createNativeQuery("SELECT cardinality(new_owner_ids) FROM client_access_change_events WHERE client_id=:id ORDER BY created_at DESC LIMIT 1").setParameter("id",client).getSingleResult()).intValue());
        login(secondary,Set.of("client:view","client:edit"),false);
        assertTrue(policy.canWrite(em.find(Client.class,client),policy.evaluate()));
        var filter=new ObjectMapper().convertValue(Map.of(),ClientQueryFilter.class);
        assertEquals(1,clients.list(filter,1,30,null,null).getTotal());
        var ownerFilter=new ObjectMapper().convertValue(Map.of("ownerEmployeeId",secondary.toString()),ClientQueryFilter.class);
        assertEquals(1,clients.list(ownerFilter,1,30,null,null).getTotal());
        assertTrue(clients.dict().stream().anyMatch(row->row.id().equals(client)));
        assertTrue(clients.facets(null).getEmpId().stream().anyMatch(bucket->bucket.getValue().equals(secondary.toString())));
        login(primary,Set.of("client:view","client:edit"),false);
        assertTrue(policy.canRead(em.find(Client.class,client),policy.evaluate()));
        assertFalse(policy.canWrite(em.find(Client.class,client),policy.evaluate()));
        login(primary,Set.of("client:view","client:finance"),false);
        assertFalse(clients.detail(client).isFinancialWritable());
        assertThrows(ApiException.class,()->inTx(()->{var req=new ClientSaveRequest();req.setCreditFloor(BigDecimal.ONE);clients.update(client,req);return null;}));
        login(target,Set.of("client:view","client:assign"),false);
        assertThrows(ApiException.class,()->inTx(()->access.update(client,new ClientAccessUpdateRequest(target,List.of(),saved.accessVersion()-1,"过期版本",List.of(target)))));
    }

    @Test void handoverOfSecondaryOwnerKeepsPrimaryAndTransfersOnlyThatResponsibility() {
        login(primary,Set.of("client:view","client:view:all","client:assign"),false);
        inTx(()->access.update(client,new ClientAccessUpdateRequest(primary,List.of(),0L,"增加共同负责人",List.of(primary,secondary))));
        inTx(()->{new ClientHandoverEventRecorder(em).transfer(secondary,target,null,actor,"共同负责人离职交接",false);return null;});
        assertEquals(primary.toString(),value("SELECT owner_employee_id::text FROM clients WHERE id=:id",client));
        assertEquals(target.toString(),value("SELECT employee_id::text FROM client_co_owners WHERE client_id=:id",client));
        inTx(()->{em.createNativeQuery("UPDATE employees SET status='resigned' WHERE id=:id").setParameter("id",secondary).executeUpdate();return null;});
        assertEquals("resigned",value("SELECT status FROM employees WHERE id=:id",secondary));
    }

    @Test void ownerColumnSearchFindsSecondaryOwnerBeforeCountAndPagination() {
        login(primary,Set.of("client:view","client:view:all","client:assign"),false);
        inTx(()->access.update(client,new ClientAccessUpdateRequest(primary,List.of(),0L,"共同负责列搜索",List.of(primary,secondary))));
        login(secondary,Set.of("client:view","client:edit"),false);
        var filter=new ObjectMapper().convertValue(Map.of(),ClientQueryFilter.class)
                .withColumnSearch(Map.of("ownerEmployeeName","secondary"));
        var page=clients.list(filter,1,30,null,null);
        assertEquals(1,page.getTotal());
        assertEquals(client,page.getItems().getFirst().getId());
        assertEquals(List.of(primary,secondary),page.getItems().getFirst().getOwnerEmployeeIds());
    }

    @Test void dataScopeCandidatesIncludeCoOwnersOncePerLiveCustomerAndExcludeFinanceStubs() throws Exception {
        login(primary,Set.of("client:view","client:view:all","client:assign"),false);
        inTx(()->access.update(client,new ClientAccessUpdateRequest(primary,List.of(),0L,"数据范围共同负责人",List.of(primary,secondary))));
        inTx(()->{
            // The UNION contract must not count a legacy duplicate primary/co-owner membership twice.
            em.createNativeQuery("INSERT INTO client_co_owners(client_id,employee_id,sort_order) VALUES(:client,:owner,2)")
                    .setParameter("client",client).setParameter("owner",primary).executeUpdate();
            for(boolean deleted:List.of(false,true)) {
                UUID excluded=UUID.randomUUID();
                em.createNativeQuery("INSERT INTO clients(id,category_id,code,name,status,owner_employee_id,is_deleted,deleted_at,code_sequence) VALUES(:id,:category,:code,'排除候选','使用',:owner,:deleted,CASE WHEN :deleted THEN now() ELSE NULL END,(SELECT coalesce(max(code_sequence),0)+1 FROM clients))")
                        .setParameter("id",excluded).setParameter("category",category)
                        .setParameter("code",deleted ? "deleted-"+excluded : "legacy-fin-cl-"+excluded)
                        .setParameter("owner",secondary).setParameter("deleted",deleted).executeUpdate();
                em.createNativeQuery("INSERT INTO client_co_owners(client_id,employee_id,sort_order) VALUES(:client,:owner,1)")
                        .setParameter("client",excluded).setParameter("owner",primary).executeUpdate();
            }
            return null;
        });
        var capturedSql=new java.util.concurrent.atomic.AtomicReference<String>();
        EntityManager capture=mock(EntityManager.class); Query empty=mock(Query.class);
        when(capture.createNativeQuery(anyString())).thenAnswer(call->{capturedSql.set(call.getArgument(0));return empty;});
        when(empty.getResultList()).thenReturn(List.of());
        // Package-private admin guards remain mocked; execute the owning service's exact generated SQL on real PostgreSQL.
        var constructor=com.uten.imp.features.admin.DataScopeAdminService.class.getConstructors()[0];
        Object[] dependencies=Arrays.stream(constructor.getParameterTypes()).map(type->type==EntityManager.class ? capture : mock(type)).toArray();
        var candidates=(com.uten.imp.features.admin.DataScopeAdminService)constructor.newInstance(dependencies);
        candidates.ownerCandidates("client");
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery(capturedSql.get()).getResultList();
        for(UUID employee:List.of(primary,secondary)) {
            Object[] row=rows.stream().filter(value->employee.equals(value[0])).findFirst().orElseThrow();
            assertEquals(1L,((Number)row[4]).longValue());
        }
    }

    @Test void handoverToExistingCoOwnerRecordsActualOrderAndNeverAddsOwnersAsViewers() {
        login(primary,Set.of("client:view","client:view:all","client:assign"),false);
        UUID middle=inTx(()->staff("middle"));
        inTx(()->access.update(client,new ClientAccessUpdateRequest(primary,List.of(),0L,"四人共同负责",List.of(primary,secondary,middle,target))));
        inTx(()->{
            provenance();
            em.createNativeQuery("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(:actor,'client',:source)")
                    .setParameter("actor",actor).setParameter("source",secondary).executeUpdate();
            new ClientHandoverEventRecorder(em).transfer(secondary,target,null,actor,"合并共同责任",false);
            return null;
        });
        var saved=inTx(()->access.get(client));
        assertEquals(List.of(primary,middle,target),saved.owners().stream().map(ClientAccessViewer::employeeId).toList());
        assertTrue(saved.viewers().isEmpty());
        String eventOwners=value("SELECT array_to_string(new_owner_ids,',') FROM client_access_change_events WHERE client_id=:id ORDER BY resulting_access_version DESC LIMIT 1",client);
        assertEquals(String.join(",",List.of(primary,middle,target).stream().map(UUID::toString).toList()),eventOwners);
    }

    private ClientSaveRequest ordinary() {
        Client c=em.find(Client.class,client);var req=new ClientSaveRequest();req.setCategoryId(category);req.setName(c.getName());req.setCode(c.getCode());req.setStatus(c.getStatus());req.setVersion(c.getVersion());return req;
    }
    private UUID staff(String tag) {
        UUID id=UUID.randomUUID();
        em.createNativeQuery("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT :id,:code,:name,'其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'")
            .setParameter("id",id).setParameter("code","T-"+id).setParameter("name",tag).executeUpdate();
        em.createNativeQuery("INSERT INTO users(employee_id,login_account,password_hash,must_change_password,is_super_admin,status,remote_access) VALUES(:id,:login,'test-not-used',false,false,'active',false)")
            .setParameter("id",id).setParameter("login","T-"+id).executeUpdate();return id;
    }
    private void login(UUID employee,Set<String> permissions,boolean admin) {
        UUID user=(UUID)em.createNativeQuery("SELECT id FROM users WHERE employee_id=:id").setParameter("id",employee).getSingleResult();
        var principal=new AuthUser(user,employee,"test-"+employee,permissions,false,true,admin);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,"unused",principal.getAuthorities()));
    }
    private void provenance() {
        for(var value:Map.of("app.actor_id",current.requireId().toString(),"app.actor_account","test","app.audit_request_id",UUID.randomUUID().toString(),"app.audit_request_path","/api/master/clients/"+client,"app.audit_request_method","PUT").entrySet())
            em.createNativeQuery("SELECT set_config(:key,:value,true)").setParameter("key",value.getKey()).setParameter("value",value.getValue()).getSingleResult();
    }
    private String value(String sql,UUID id) {return Objects.toString(em.createNativeQuery(sql).setParameter("id",id).getSingleResult(),null);}
    private <T>T inTx(Supplier<T> work) {
        em.getTransaction().begin();try{T result=work.get();em.getTransaction().commit();em.clear();return result;}
        catch(RuntimeException|Error failure){if(em.getTransaction().isActive())em.getTransaction().rollback();em.clear();throw failure;}
    }
}
