package com.uten.imp.features.master.goods.history;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.auth.AuthSessionService;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.lifecycle.MasterReferenceGuard;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;

import java.time.Clock;
import java.sql.SQLException;
import java.util.*;
import java.util.function.Supplier;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Account/scope matrix against real capture, replay, grants and handover tables. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsOperationHistoryAccountPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static EntityManagerFactory factory;
    private static DriverManagerDataSource dataSource;
    private EntityManager em;
    private SecurityContextCurrentUser current;
    private AuthUser principal;
    private GoodsOperationHistoryService service;
    private Person a,b,c;
    private record Person(UUID account,UUID employee) {}
    private static final Set<String> EDIT=Set.of("goods:view","goods:edit");

    @BeforeAll static void start() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("goods_history_accounts");
        maintainReplayTables();
        dataSource=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        var bean=new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(dataSource);bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.security");bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));
        bean.afterPropertiesSet();factory=bean.getObject();
    }
    @AfterAll static void stop() throws Exception {
        if (factory != null) {
            factory.close();
        }
        if (database != null) {
            database.close();
        }
    }
    @BeforeEach void prepare() {
        em=factory.createEntityManager();a=person();b=person();c=person();
        current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenAnswer(i->Optional.ofNullable(principal));
        when(current.requireId()).thenAnswer(i->principal.getId());
        var tx=mock(TxSessionVars.class);
        doAnswer(i->{provenance("/api/master/goods/history","POST");return null;}).when(tx).bind();
        var access=mock(MasterObjectAccess.class);when(access.readableLabelOwner(anyString())).thenReturn(owner->true);
        service=new GoodsOperationHistoryService(em,new ObjectMapper(),current,tx,new MasterReferenceGuard(em,access),
                new OwnerVisibility(current,em,new EmployeeHandoverVisibility(em)),mock(BusinessEventPublisher.class));
        login(a,Set.of(),true);
    }
    @AfterEach void close() throws SQLException {
        if (em.getTransaction().isActive()) {
            em.getTransaction().rollback();
        }
        em.close();
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
        maintainReplayTables();
    }

    /** Keep automatic maintenance enabled, but reset this private matrix's
     * cumulative dead/modification counts between cases, after every client
     * transaction has closed. ANALYZE/VACUUM take ShareUpdateExclusiveLock,
     * which intentionally conflicts with production replay's NOWAIT lock. */
    private static void maintainReplayTables() throws SQLException {
        try (var connection=database.openConnection();var statement=connection.createStatement()) {
            statement.execute("VACUUM (ANALYZE) colors,units,material_categories,goods,goods_bom_items");
        }
    }

    @Test void maintenanceContentionRetainsHistoryUntilTheLockIsReleased() throws Exception {
        UUID goods=goods(null,"maintenance original"),operation=edit(goods,"maintenance changed");
        login(a,EDIT,false);
        try (var maintenance=database.openConnection();var contender=database.openConnection();
             var observer=database.openConnection()) {
            maintenance.setAutoCommit(false);
            contender.setAutoCommit(false);
            int maintenancePid;
            try (var statement=maintenance.createStatement();var result=statement.executeQuery("SELECT pg_backend_pid()")) {
                assertTrue(result.next());maintenancePid=result.getInt(1);
            }
            try (var statement=maintenance.createStatement()) {
                statement.execute("ANALYZE goods");
            }
            try (var statement=observer.prepareStatement("SELECT mode FROM pg_locks WHERE pid=? AND relation='goods'::regclass AND granted")) {
                statement.setInt(1,maintenancePid);
                try (var result=statement.executeQuery()) {
                    assertTrue(result.next());
                    assertEquals("ShareUpdateExclusiveLock",result.getString(1));
                }
            }
            try (var statement=observer.createStatement();var result=statement.executeQuery("SHOW autovacuum")) {
                assertTrue(result.next());assertEquals("on",result.getString(1));
            }
            try (var statement=contender.createStatement()) {
                SQLException blocked=assertThrows(SQLException.class,()->statement.execute(
                        "LOCK TABLE colors,units,material_categories,goods,goods_bom_items IN SHARE ROW EXCLUSIVE MODE NOWAIT"));
                assertEquals("55P03",blocked.getSQLState());
            }
            contender.rollback();
            assertEquals("maintenance changed",text("SELECT name FROM goods WHERE id=:id",goods));
            assertEquals(0,entry(operation).version());assertEvents(0);
            maintenance.rollback();
        }
        inTx(()->service.undo(operation,0));
        assertEquals("maintenance original",text("SELECT name FROM goods WHERE id=:id",goods));
        assertTrue(entry(operation).canRedo());assertEquals(1,entry(operation).version());
        inTx(()->service.redo(operation,1));
        assertEquals("maintenance changed",text("SELECT name FROM goods WHERE id=:id",goods));
        assertEquals(2,entry(operation).version());assertEvents(2);
    }

    @Test void eachAccountKeepsItsOwnUndoAndRedoBranchWhenTheOtherAccountWrites() {
        UUID ga=goods(null,"account A"),gb=goods(null,"account B");
        UUID oa=edit(ga,"A changed");inTx(()->service.undo(oa,0));
        login(b,EDIT,false);UUID ob=edit(gb,"B changed");
        assertEquals(List.of(ob),service.list().entries().stream().map(GoodsOperationHistoryService.Entry::id).toList());
        inTx(()->service.undo(ob,0));
        login(a,EDIT,false);assertTrue(entry(oa).canRedo());
        edit(goods(null,"new A record"),"new A action");
        login(b,EDIT,false);assertTrue(entry(ob).canRedo());inTx(()->service.redo(ob,1));
        assertEquals("B changed",text("SELECT name FROM goods WHERE id=:id",gb));
        assertEquals(2,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",b.account()));
        assertEquals(1,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",a.account()));
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void anotherAccountIncludingASuperAdministratorCannotReplayAnOwnedHistoryUuid(boolean superAdmin) {
        UUID goods=goods(null,"owner action"),operation=edit(goods,"owner changed");
        login(b,EDIT,superAdmin);
        assertTrue(service.list().entries().isEmpty());
        assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));
        assertThrows(ApiException.class,()->inTx(()->service.redo(operation,0)));
        assertEquals("owner changed",text("SELECT name FROM goods WHERE id=:id",goods));assertEvents(0);
    }

    @Test void anotherAccountsLaterEditCannotBeOverwrittenButItsOwnUndoCanRestoreTheLineage() {
        UUID goods=goods(null,"initial"),first=edit(goods,"A edit");
        login(b,EDIT,false);UUID second=edit(goods,"B edit");
        login(a,EDIT,false);assertFalse(entry(first).canUndo());
        assertThrows(ApiException.class,()->inTx(()->service.undo(first,0)));
        assertEquals("B edit",text("SELECT name FROM goods WHERE id=:id",goods));assertEvents(0);
        login(b,EDIT,false);inTx(()->service.undo(second,0));
        login(a,EDIT,false);assertTrue(entry(first).canUndo());inTx(()->service.undo(first,0));
        assertEquals("initial",text("SELECT name FROM goods WHERE id=:id",goods));
    }

    @Test void theSameAccountHasOneStackAcrossSessionIdentitiesAndStaleDeviceVersionsAreRejected() {
        UUID goods=goods(null,"cross device"),operation=edit(goods,"changed");
        UUID firstSession=UUID.randomUUID(),secondSession=UUID.randomUUID();
        principal=user(a,EDIT,false,false,true,null,firstSession);
        assertEquals(operation,service.list().entries().getFirst().id());
        principal=user(a,EDIT,false,false,true,null,secondSession);
        inTx(()->service.undo(operation,0));
        principal=user(a,EDIT,false,false,true,null,firstSession);
        assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));
        assertTrue(entry(operation).canRedo());inTx(()->service.redo(operation,1));
        assertEvents(2);
    }

    @Test void aRealNewLoginRevokesTheOldSessionWithoutRemovingTheAccountsHistory() {
        UUID goods=goods(null,"session history"),operation=edit(goods,"changed");
        SystemSettingsService settings=mock(SystemSettingsService.class);
        when(settings.readLong(SystemSettingKey.JWT_REFRESH_TTL_DAYS)).thenReturn(7L);
        var sessions=new AuthSessionService(new NamedParameterJdbcTemplate(dataSource),settings,Clock.systemUTC());
        UUID old=sessions.openStaffSession(a.account(),null).sid();UUID fresh=sessions.openStaffSession(a.account(),null).sid();
        assertEquals("true",text("SELECT (revoked_at IS NOT NULL)::text FROM auth_sessions WHERE sid=:id",old));
        assertEquals("false",text("SELECT (revoked_at IS NOT NULL)::text FROM auth_sessions WHERE sid=:id",fresh));
        principal=user(a,EDIT,false,false,true,null,fresh);
        assertTrue(entry(operation).canUndo());inTx(()->service.undo(operation,0));
    }

    private static Stream<Arguments> permissionCases() {
        return Stream.of(
            Arguments.of("name", "", "PUT", "name='changed'",Set.of("goods:view"),false),
            Arguments.of("name edit", "", "PUT", "name='changed'",EDIT,true),
            Arguments.of("name en only", "/name-en", "PUT", "name_en='Changed'",Set.of("goods:view","goods:name_en:edit"),true),
            Arguments.of("name en sales edit", "/name-en", "PUT", "name_en='Changed'",Set.of("goods:view","goods:sales:edit"),true),
            Arguments.of("name en missing", "/name-en", "PUT", "name_en='Changed'",Set.of("goods:view","goods:status"),false),
            Arguments.of("status only", "/status", "PATCH", "status='禁用'",Set.of("goods:view","goods:status"),true),
            Arguments.of("status missing", "/status", "PATCH", "status='禁用'",EDIT,false),
            Arguments.of("price missing", "", "PUT", "price=19",EDIT,false),
            Arguments.of("price granted", "", "PUT", "price=19",Set.of("goods:view","goods:edit","goods:price:edit"),true),
            Arguments.of("discount missing", "", "PUT", "zk=0.8",EDIT,false),
            Arguments.of("discount missing price edit", "", "PUT", "zk=0.8",Set.of("goods:view","goods:edit","goods:discount:view"),false),
            Arguments.of("discount missing visibility", "", "PUT", "zk=0.8",Set.of("goods:view","goods:edit","goods:price:edit"),false),
            Arguments.of("discount granted", "", "PUT", "zk=0.8",Set.of("goods:view","goods:edit","goods:price:edit","goods:discount:view"),true),
            Arguments.of("cost missing", "", "PUT", "g_total=29",EDIT,false),
            Arguments.of("cost granted", "", "PUT", "g_total=29",Set.of("goods:view","goods:edit","goods:cost:view"),true),
            Arguments.of("purchase policy", "/purchase-receipt-policy", "PUT", "purchase_allowed_over_receipt_pct=3",Set.of("goods:view","goods:purchase:edit"),true),
            Arguments.of("subcontract policy missing cost", "/subcontract-loss-policy", "PUT", "subcontract_allowed_loss_pct=3",Set.of("goods:view","goods:purchase:edit"),false),
            Arguments.of("subcontract policy granted", "/subcontract-loss-policy", "PUT", "subcontract_allowed_loss_pct=3",Set.of("goods:view","goods:purchase:edit","goods:cost:view"),true),
            Arguments.of("name en base edit lacks sales", "/name-en", "PUT", "name_en='Changed'",EDIT,false),
            Arguments.of("purchase policy base edit lacks purchase", "/purchase-receipt-policy", "PUT", "purchase_allowed_over_receipt_pct=3",EDIT,false),
            Arguments.of("subcontract policy missing purchase", "/subcontract-loss-policy", "PUT", "subcontract_allowed_loss_pct=3",Set.of("goods:view","goods:edit","goods:cost:view"),false));
    }
    @ParameterizedTest(name="{0}") @MethodSource("permissionCases")
    void originalActionAndFieldPermissionsAreRecheckedWithoutRequiringUnrelatedPermissions(String name,String suffix,String method,String changes,Set<String> permissions,boolean allowed) {
        UUID goods=goods(null,"permission object");
        UUID operation=command("/api/master/goods/"+goods+suffix,method,()->execute("UPDATE goods SET "+changes+",version=version+1 WHERE id=:id",goods));
        login(a,permissions,false);assertEquals(allowed,entry(operation).canUndo(),name);
        if(allowed){inTx(()->service.undo(operation,0));assertTrue(entry(operation).canRedo());}
        else{assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));assertEvents(0);}
    }

    @Test void permissionRevocationAfterUndoAlsoBlocksRedoAndRetainsTheAuditEvent() {
        UUID operation=edit(goods(null,"revoke redo"),"changed");login(a,EDIT,false);inTx(()->service.undo(operation,0));
        login(a,Set.of("goods:view"),false);assertFalse(entry(operation).canRedo());
        assertThrows(ApiException.class,()->inTx(()->service.redo(operation,1)));assertEvents(1);
        assertEquals("UNDO",service.list().events().getFirst().action());
    }

    @Test void readOnlyOwnerGrantsAllowTheSummaryButOnlyAFormalHandoverAllowsMutation() {
        UUID goods=goods(b.employee(),"visible transferred goods"),operation=edit(goods,"changed");
        login(a,EDIT,false);scope(true);grant(a,b.employee());
        assertTrue(entry(operation).summary().contains("changed"));assertFalse(entry(operation).canUndo());
        assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));
        handover(b,a);assertTrue(entry(operation).canUndo());inTx(()->service.undo(operation,0));
        assertEquals("visible transferred goods",text("SELECT name FROM goods WHERE id=:id",goods));
        assertEquals(a.account().toString(),text("SELECT actor_id::text FROM goods_operation_history WHERE id=:id",operation));
    }

    @Test void revokingVisibilityRedactsBothEntryAndEventPresentationWithoutDeletingEvidence() throws Exception {
        UUID goods=goods(b.employee(),"PRIVATE-OLD"),operation=edit(goods,"PRIVATE-NEW");
        login(a,EDIT,false);scope(true);handover(b,a);inTx(()->service.undo(operation,0));
        handover(b,c);var history=service.list();
        assertEquals("",entry(operation).summary());assertFalse(entry(operation).canRedo());
        String json=new ObjectMapper().findAndRegisterModules().writeValueAsString(history);
        assertFalse(json.contains("PRIVATE-OLD"));assertFalse(json.contains("PRIVATE-NEW"));
        assertEquals(1,history.events().size());assertEquals("UNDO",history.events().getFirst().action());
    }

    @Test void theDisabledOwnerScopeFeatureRetainsThePlatformsExistingUnscopedWriteBehavior() {
        UUID goods=goods(b.employee(),"unscoped"),operation=edit(goods,"changed");login(a,EDIT,false);
        scope(false);assertTrue(entry(operation).canUndo());inTx(()->service.undo(operation,0));
        assertEquals("unscoped",text("SELECT name FROM goods WHERE id=:id",goods));
    }

    @Test void bomAuditOnlyNeedsTheVisibleParentAndNeverDisclosesTheHiddenComponentsName() {
        UUID parent=goods(b.employee(),"visible BOM parent"),component=goods(c.employee(),"PRIVATE-COMPONENT"),edge=bom(parent,component);
        UUID operation=command("/api/master/goods/"+parent+"/bom/"+edge+"/audit","PUT",()->execute("UPDATE goods_bom_items SET audited_at=now() WHERE id=:id",edge));
        login(a,Set.of("goods:view","goods:bom:audit"),false);scope(true);grant(a,b.employee());
        assertTrue(entry(operation).canUndo());assertTrue(entry(operation).summary().contains("visible BOM parent"));assertFalse(entry(operation).summary().contains("PRIVATE-COMPONENT"));
        inTx(()->service.undo(operation,0));assertTrue(entry(operation).canRedo());inTx(()->service.redo(operation,1));assertEvents(2);
    }

    @Test void aBomOnlyEditorCanUndoDerivedParentCostsWithoutGoodsEditOrCostPermissions() {
        UUID parent=goods(b.employee(),"BOM owned elsewhere"),component=goods(c.employee(),"component"),edge=bom(parent,component);
        UUID operation=command("/api/master/goods/"+parent+"/bom/"+edge,"PUT",()->{execute("UPDATE goods_bom_items SET qty=2 WHERE id=:id",edge);execute("UPDATE goods SET source_e=2,version=version+1 WHERE id=:id",parent);});
        login(a,Set.of("goods:view","goods:bom:edit"),false);scope(true);grant(a,b.employee());grant(a,c.employee());
        assertTrue(entry(operation).canUndo());inTx(()->service.undo(operation,0));assertEvents(1);
        assertEquals("1.00000",text("SELECT qty::text FROM goods_bom_items WHERE id=:id",edge));
    }

    @Test void categoryCascadeRequiresWriteScopeForGoodsAndReadScopeForReintroducedComponents() {
        UUID category=category("cascade category"),parent=goodsIn(category,b.employee(),"owned cascade parent"),component=goods(c.employee(),"private cascade component"),edge=bom(parent,component);
        UUID operation=command("/api/master/material-categories/"+category,"DELETE",()->{
            execute("UPDATE goods_bom_items SET is_deleted=true,deleted_at=now() WHERE id=:id",edge);
            execute("UPDATE goods SET is_deleted=true,deleted_at=now(),version=version+1 WHERE id=:id",parent);
            execute("UPDATE material_categories SET is_deleted=true,deleted_at=now(),version=version+1 WHERE id=:id",category);
        });
        login(a,Set.of("goods:view","material_category:view","material_category:delete"),false);scope(true);grant(a,b.employee());
        assertFalse(entry(operation).canUndo());assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));
        handover(b,a);assertFalse(entry(operation).canUndo());assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));
        grant(a,c.employee());assertTrue(entry(operation).canUndo());inTx(()->service.undo(operation,0));
        assertEquals("false",text("SELECT is_deleted::text FROM goods WHERE id=:id",parent));assertEquals("false",text("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id",edge));
        inTx(()->{em.createNativeQuery("DELETE FROM user_data_scopes WHERE user_id=:user AND owner_employee_id=:owner").setParameter("user",a.account()).setParameter("owner",c.employee()).executeUpdate();return null;});
        assertTrue(entry(operation).canRedo());inTx(()->service.redo(operation,1));assertEvents(2);
    }

    @Test void categoryNamesAreNotReturnedWhenTheAccountLosesCategoryReadPermission() {
        UUID category=category("PRIVATE-CATEGORY");
        UUID operation=command("/api/master/material-categories/"+category,"PUT",()->execute("UPDATE material_categories SET name='PRIVATE-CATEGORY-CHANGED',version=version+1 WHERE id=:id",category));
        login(a,Set.of("goods:view"),false);assertEquals("",entry(operation).summary());assertFalse(entry(operation).canUndo());
    }

    @ParameterizedTest @ValueSource(strings={"import-only","undo-only","both"})
    void importedCreationRequiresBothCurrentImportAndImportUndoPermissions(String mode) {
        UUID goods=UUID.randomUUID();
        UUID operation=command("/api/master/goods/import/commit","POST",()->insertGoods(goods,null,null,"import capability"));
        Set<String> permissions=new HashSet<>(Set.of("goods:view"));
        if(!mode.equals("undo-only"))permissions.add("goods:import");
        if(!mode.equals("import-only"))permissions.add("goods:import:undo");
        login(a,permissions,false);
        assertEquals(mode.equals("both"),entry(operation).canUndo());
        if(mode.equals("both")){inTx(()->service.undo(operation,0));inTx(()->service.redo(operation,1));assertEvents(2);}
        else{assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));assertEvents(0);}
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void replacementBomPasteKeepsItsOriginalCreateAndDeletePermissionIntersection(boolean hasDelete) {
        UUID parent=goods(null,"paste parent"),first=goods(null,"first component"),second=goods(null,"second component"),oldEdge=bom(parent,first),newEdge=UUID.randomUUID();
        UUID operation=command("/api/master/goods/bom/paste","POST",()->{
            execute("UPDATE goods_bom_items SET is_deleted=true,deleted_at=now() WHERE id=:id",oldEdge);
            em.createNativeQuery("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(:id,:parent,:component,1)").setParameter("id",newEdge).setParameter("parent",parent).setParameter("component",second).executeUpdate();
        });
        Set<String> permissions=new HashSet<>(Set.of("goods:view","goods:bom:create"));
        if (hasDelete) {
            permissions.add("goods:bom:delete");
        }
        login(a,permissions,false);
        assertEquals(hasDelete,entry(operation).canUndo());
        if(hasDelete){inTx(()->service.undo(operation,0));assertEquals("false",text("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id",oldEdge));}
        else assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));
    }

    private static Stream<Arguments> categoryCases(){return Stream.of(
            Arguments.of("name",Set.of("material_category:edit"),true),
            Arguments.of("name",Set.of("material_category:move"),false),
            Arguments.of("reorder",Set.of("material_category:reorder"),true),
            Arguments.of("reorder",Set.of("material_category:edit"),false),
            Arguments.of("move",Set.of("material_category:move"),true),
            Arguments.of("mixed",Set.of("material_category:edit"),false),
            Arguments.of("mixed",Set.of("material_category:edit","material_category:reorder"),true));}
    @ParameterizedTest(name="category {0} {1}") @MethodSource("categoryCases")
    void categoryEditingRechecksEachActuallyChangedAction(String action,Set<String> permissions,boolean allowed) {
        UUID category=category("category actions"),parent=category("move parent");
        UUID operation=command("/api/master/material-categories/"+category,"PUT",()->{
            if(action.equals("move"))em.createNativeQuery("UPDATE material_categories SET parent_id=:parent,version=version+1 WHERE id=:id").setParameter("parent",parent).setParameter("id",category).executeUpdate();
            else {
                var update=em.createNativeQuery("UPDATE material_categories SET "+switch(action){case "name"->"name=:editedName";case "reorder"->"sort_order=3";default->"name=:editedName,sort_order=3";}+",version=version+1 WHERE id=:id").setParameter("id",category);
                if(!action.equals("reorder"))update.setParameter("editedName","edited "+category);
                update.executeUpdate();
            }
        });
        Set<String> granted=new HashSet<>(permissions);granted.addAll(Set.of("goods:view","material_category:view"));login(a,granted,false);
        assertEquals(allowed,entry(operation).canUndo());
        if(allowed)inTx(()->service.undo(operation,0));else assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));
    }

    private static Stream<String> principalCases(){return Stream.of("visitor","locked","must-change-password","missing-employee","missing-principal");}
    @ParameterizedTest @MethodSource("principalCases")
    void invalidPrincipalsAreRejectedEvenIfTheyContainGoodsPermissions(String state) {
        UUID operation=edit(goods(null,"principal guarded"),"changed");
        principal=switch(state){
            case "visitor"->AuthUser.visitor(a.account(),"visitor","V-1",EDIT,UUID.randomUUID());
            case "locked"->user(a,EDIT,false,false,false,null,UUID.randomUUID());
            case "must-change-password"->user(a,EDIT,false,true,true,null,UUID.randomUUID());
            case "missing-employee"->new AuthUser(a.account(),null,"test",EDIT,false,true,false);
            default->null;
        };
        assertThrows(ApiException.class,service::list);assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));
        assertEquals(0,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",a.account()));
    }

    @Test void impersonationMayReadTheTargetsPermittedHistoryButCannotUndoOrRedoIt() {
        UUID operation=edit(goods(null,"impersonation"),"changed");
        principal=user(a,EDIT,false,false,true,b.account(),UUID.randomUUID());assertEquals(operation,service.list().entries().getFirst().id());
        assertFalse(entry(operation).canUndo());
        assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));assertEvents(0);
        login(a,EDIT,false);inTx(()->service.undo(operation,0));
        principal=user(a,EDIT,false,false,true,b.account(),UUID.randomUUID());
        assertFalse(entry(operation).canRedo());
        assertThrows(ApiException.class,()->inTx(()->service.redo(operation,1)));assertEvents(1);
    }

    private void login(Person person,Set<String> permissions,boolean superAdmin){principal=user(person,permissions,superAdmin,false,true,null,UUID.randomUUID());}
    private static AuthUser user(Person person,Set<String> permissions,boolean superAdmin,boolean mustChange,boolean unlocked,UUID impersonatedBy,UUID session){return new AuthUser(person.account(),person.employee(),"history-account",permissions,mustChange,unlocked,superAdmin,false,impersonatedBy,session);}
    private Person person(){UUID employee=UUID.randomUUID(),account=UUID.randomUUID();return inTx(()->{
        em.createNativeQuery("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT :id,:code,:name,'其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'")
                .setParameter("id",employee).setParameter("code","AH-"+employee)
                .setParameter("name",com.uten.imp.support.SyntheticEmployeeIdentity.name("history account",employee)).executeUpdate();
        em.createNativeQuery("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin) VALUES(:id,:employee,:login,'test-only',false,'active',false)")
                .setParameter("id",account).setParameter("employee",employee).setParameter("login","account-history-"+account).executeUpdate();return new Person(account,employee);
    });}
    private UUID goods(UUID owner,String name){return goodsIn(null,owner,name);}
    private UUID goodsIn(UUID category,UUID owner,String name){UUID id=UUID.randomUUID();return inTx(()->{insertGoods(id,category,owner,name);return id;});}
    private void insertGoods(UUID id,UUID category,UUID owner,String name){em.createNativeQuery("INSERT INTO goods(id,code,name,category_id,owner_employee_id,code_sequence) VALUES(:id,:code,:name,:category,:owner,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))")
            .setParameter("id",id).setParameter("code","AHG-"+id).setParameter("name",name).setParameter("category",category).setParameter("owner",owner).executeUpdate();}
    private UUID category(String name){UUID id=UUID.randomUUID();return inTx(()->{em.createNativeQuery("INSERT INTO material_categories(id,code,name) VALUES(:id,:code,:name)").setParameter("id",id).setParameter("code","AHC-"+id).setParameter("name",name+" "+id).executeUpdate();return id;});}
    private UUID bom(UUID parent,UUID component){UUID id=UUID.randomUUID();return inTx(()->{em.createNativeQuery("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(:id,:parent,:component,1)").setParameter("id",id).setParameter("parent",parent).setParameter("component",component).executeUpdate();return id;});}
    private UUID edit(UUID id,String name){return command("/api/master/goods/"+id,"PUT",()->em.createNativeQuery("UPDATE goods SET name=:name,version=version+1 WHERE id=:id").setParameter("name",name).setParameter("id",id).executeUpdate());}
    private UUID command(String path,String method,Runnable action){return inTx(()->{provenance(path,method);action.run();return (UUID)em.createNativeQuery("SELECT id FROM goods_operation_history WHERE actor_id=:actor ORDER BY created_at DESC,id DESC LIMIT 1").setParameter("actor",principal.getId()).getSingleResult();});}
    private void scope(boolean enabled){ReflectionTestUtils.setField(service,"goodsOwnerScopeEnabled",enabled);}
    private void grant(Person recipient,UUID owner){inTx(()->{em.createNativeQuery("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(:user,'goods',:owner) ON CONFLICT DO NOTHING").setParameter("user",recipient.account()).setParameter("owner",owner).executeUpdate();return null;});}
    private void handover(Person from,Person to){UUID id=UUID.randomUUID();inTx(()->{
        em.createNativeQuery("INSERT INTO employee_data_handovers(id,request_id,source_employee_id,target_employee_id,mode,effective_date,reason,status,created_by_user_id,source_employment_generation,target_employment_generation,requested_scopes) VALUES(:id,:request,:source,:target,'MANUAL',current_date,'history scope test','EXECUTING',:actor,0,0,ARRAY['goods'])")
                .setParameter("id",id).setParameter("request",UUID.randomUUID()).setParameter("source",from.employee()).setParameter("target",to.employee()).setParameter("actor",a.account()).executeUpdate();
        em.createNativeQuery("INSERT INTO employee_data_handover_scopes(handover_id,scope) VALUES(:id,'goods')").setParameter("id",id).executeUpdate();
        em.createNativeQuery("UPDATE employee_data_handovers SET status='COMPLETED' WHERE id=:id").setParameter("id",id).executeUpdate();return null;
    });}
    private GoodsOperationHistoryService.Entry entry(UUID id){return service.list().entries().stream().filter(e->e.id().equals(id)).findFirst().orElseThrow();}
    private void provenance(String path,String method){set("app.actor_id",principal.getId().toString());set("app.audit_request_id",UUID.randomUUID().toString());set("app.audit_request_path",path);set("app.audit_request_method",method);
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended('goods-history:'||CAST(:actor AS text),0))").setParameter("actor",principal.getId()).getSingleResult();set("app.goods_history_prelocked_actor",principal.getId().toString());}
    private void set(String key,String value){em.createNativeQuery("SELECT set_config(:key,:value,true)").setParameter("key",key).setParameter("value",value).getSingleResult();}
    private void execute(String sql,UUID id){em.createNativeQuery(sql).setParameter("id",id).executeUpdate();}
    private String text(String sql,UUID id){Object value=em.createNativeQuery(sql).setParameter("id",id).getSingleResult();return value==null?null:value.toString();}
    private int count(String sql,UUID id){
        Number value=assertInstanceOf(Number.class,em.createNativeQuery(sql).setParameter("id",id).getSingleResult());
        return Math.toIntExact(value.longValue());
    }
    private void assertEvents(int expected){assertEquals(expected,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",principal.getId()));}
    private <T>T inTx(Supplier<T> body) {
        em.getTransaction().begin();
        try {
            T value=body.get();
            em.getTransaction().commit();
            return value;
        } catch (RuntimeException|Error error) {
            if (em.getTransaction().isActive()) {
                em.getTransaction().rollback();
            }
            throw error;
        }
    }

}
