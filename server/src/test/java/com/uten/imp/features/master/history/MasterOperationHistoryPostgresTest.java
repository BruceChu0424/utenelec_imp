package com.uten.imp.features.master.history;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.lifecycle.MasterReferenceGuard;
import com.uten.imp.features.master.warehouse.WarehouseMasterRules;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

import java.util.*;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MasterOperationHistoryPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static EntityManagerFactory factory;
    EntityManager em;UUID actor;SecurityContextCurrentUser current;MasterOperationHistoryService service;
    @BeforeAll static void start() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("master_history_service");
        var bean=new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());bean.setPackagesToScan("com.uten.imp.security");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));bean.afterPropertiesSet();factory=bean.getObject();
    }
    @AfterAll static void stop() throws Exception {if(factory!=null)factory.close();if(database!=null)database.close();}
    @BeforeEach void prepare() {
        actor=UUID.randomUUID();em=factory.createEntityManager();current=mock(SecurityContextCurrentUser.class);login(Set.of(),true);
        var tx=mock(TxSessionVars.class);doAnswer(call->{set("app.actor_id",actor.toString());set("app.audit_request_path","/api/master/operation-history");return null;}).when(tx).bind();
        var access=mock(MasterObjectAccess.class);when(access.readableLabelOwner(anyString())).thenReturn(owner->true);
        var clientPolicy=mock(ClientAccessPolicy.class);
        when(clientPolicy.canRead(any(UUID.class),nullable(UUID.class),any())).thenReturn(true);
        when(clientPolicy.canWriteOwner(nullable(UUID.class),any())).thenReturn(true);
        service=new MasterOperationHistoryService(em,new ObjectMapper(),current,tx,clientPolicy,new MasterReferenceGuard(em,access),new WarehouseMasterRules(em));
    }
    @AfterEach void close() {if(em.getTransaction().isActive())em.getTransaction().rollback();em.close();}

    @Test void selectedIndependentEditUndoRedoIsDurableAndActorScoped() {
        UUID a=color("original A"),b=color("original B");UUID first=edit(a,"changed A"),second=edit(b,"changed B");
        inTx(()->service.undo("colors",first,0));assertEquals("original A",value("SELECT name FROM colors WHERE id=:id",a));
        assertEquals("changed B",value("SELECT name FROM colors WHERE id=:id",b));
        assertThrows(ApiException.class,()->inTx(()->service.undo("colors",second,1)));
        inTx(()->service.redo("colors",first,1));assertEquals("changed A",value("SELECT name FROM colors WHERE id=:id",a));
        assertEquals(2,service.list("colors").events().size());
        actor=UUID.randomUUID();login(Set.of(),true);assertTrue(service.list("colors").entries().isEmpty());
        assertThrows(ApiException.class,()->inTx(()->service.undo("colors",second,0)));
    }
    @Test void aLaterEditAndAnOutsideAbaWriterCannotBeOverwritten() {
        UUID id=color("initial");UUID first=edit(id,"first"),second=edit(id,"second");
        assertThrows(ApiException.class,()->inTx(()->service.undo("colors",first,0)));
        inTx(()->service.undo("colors",second,0));inTx(()->service.undo("colors",first,0));
        inTx(()->service.redo("colors",first,1));
        inTx(()->{em.createNativeQuery("UPDATE colors SET updated_at=clock_timestamp() WHERE id=:id").setParameter("id",id).executeUpdate();return null;});
        assertThrows(ApiException.class,()->inTx(()->service.redo("colors",second,1)));
        assertEquals("first",value("SELECT name FROM colors WHERE id=:id",id));
    }
    @Test void originalPermissionIsRecheckedAndSnapshotsAreNotReturned() throws Exception {
        UUID id=color("private");UUID op=edit(id,"changed");login(Set.of("color:view"),false);
        var entry=service.list("colors").entries().getFirst();assertFalse(entry.canUndo());assertTrue(entry.blockedReason().contains("color:edit"));
        assertThrows(ApiException.class,()->inTx(()->service.undo("colors",op,0)));
        String json=new ObjectMapper().findAndRegisterModules().writeValueAsString(service.list("colors"));
        assertFalse(json.contains("before_row"));assertFalse(json.contains("expected_row"));assertFalse(json.contains("created_by"));
    }
    @Test void aNewCommandInvalidatesRedoAndHistoryWindowIsTen() {
        UUID id=color("initial");UUID op=edit(id,"changed");inTx(()->service.undo("colors",op,0));
        edit(color("other"),"other changed");assertThrows(ApiException.class,()->inTx(()->service.redo("colors",op,1)));
        for(int i=0;i<11;i++)edit(color("window "+i),"changed "+i);
        assertEquals(10,service.list("colors").entries().size());assertThrows(ApiException.class,()->inTx(()->service.undo("colors",op,1)));
    }
    @Test void inlineRouteCapturesOneTransactionAndUnsupportedNumberingNeverPartiallyReplays() {
        UUID id=color("original");UUID op=inTx(()->{provenance("/api/master/inline-edit/colors/"+id,"PATCH");
            em.createNativeQuery("UPDATE colors SET name='changed',code=:code WHERE id=:id").setParameter("id",id).setParameter("code","N-"+id).executeUpdate();return latest();});
        var entry=service.list("colors").entries().getFirst();assertFalse(entry.canUndo());assertTrue(entry.blockedReason().contains("编号"));
        assertThrows(ApiException.class,()->inTx(()->service.undo("colors",op,0)));assertEquals("changed",value("SELECT name FROM colors WHERE id=:id",id));
    }
    @Test void creationUndoKeepsIdentityAndLaterReferencesBlockIt() {
        UUID id=UUID.randomUUID();UUID op=inTx(()->{provenance("/api/master/colors","POST");insertColor(id,"created");return latest();});
        inTx(()->service.undo("colors",op,0));assertEquals("true",value("SELECT is_deleted::text FROM colors WHERE id=:id",id));
        inTx(()->service.redo("colors",op,1));assertEquals("false",value("SELECT is_deleted::text FROM colors WHERE id=:id",id));
        inTx(()->{em.createNativeQuery("INSERT INTO goods(id,code,name,color_id,code_sequence) VALUES(:id,:code,'referencing',:color,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))")
            .setParameter("id",UUID.randomUUID()).setParameter("code","G-"+UUID.randomUUID()).setParameter("color",id).executeUpdate();return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo("colors",op,2)));assertEquals("false",value("SELECT is_deleted::text FROM colors WHERE id=:id",id));
    }
    @Test void profileOnlyUnitChangesAreVisibleButCannotPartiallyUndo() {
        UUID id=UUID.randomUUID();inTx(()->{em.createNativeQuery("INSERT INTO units(id,code,name) VALUES(:id,:code,'unit profile')").setParameter("id",id).setParameter("code","U-"+id).executeUpdate();return null;});
        inTx(()->{provenance("/api/master/units/"+id,"PUT");em.createNativeQuery("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES(:id,'MASS','KG','MANUAL_GOVERNANCE')").setParameter("id",id).executeUpdate();return null;});
        var history=service.list("units");assertEquals(1,history.entries().size());assertFalse(history.entries().getFirst().canUndo());assertTrue(history.entries().getFirst().blockedReason().contains("计量"));
    }
    @Test void financialAndHierarchyFieldsFailClosedInDatabase() {
        inTx(()->{assertNotNull(em.createNativeQuery("SELECT fn_master_history_unsupported('accounts',CAST('{\"init_balance\":1}' AS jsonb),CAST('{\"init_balance\":2}' AS jsonb))").getSingleResult());
            assertNotNull(em.createNativeQuery("SELECT fn_master_history_unsupported('payment_styles',CAST('{\"parent_id\":null}' AS jsonb),CAST('{\"parent_id\":\"00000000-0000-0000-0000-000000000001\"}' AS jsonb))").getSingleResult());return null;});
    }
    @Test void accountWarningPermissionIsRecheckedForTheLastExactDecimalDigit() {
        UUID account=UUID.randomUUID();
        inTx(()->{em.createNativeQuery("INSERT INTO accounts(id,code,name,status,account_type,balance_floor) VALUES(:id,:code,'precise warning','禁用','GENERAL',99999999999999.9998)").setParameter("id",account).setParameter("code","A-"+account).executeUpdate();return null;});
        UUID op=inTx(()->{provenance("/api/master/accounts/"+account,"PUT");em.createNativeQuery("UPDATE accounts SET balance_floor=99999999999999.9999 WHERE id=:id").setParameter("id",account).executeUpdate();return latest();});
        login(Set.of("account:view","account:edit"),false);
        var entry=service.list("accounts").entries().getFirst();assertFalse(entry.canUndo());assertTrue(entry.blockedReason().contains("account:warning:manage"));
        assertThrows(ApiException.class,()->inTx(()->service.undo("accounts",op,0)));
    }
    @Test void directoryCreationAndPhysicalDeletionReplayWithParentFlatFieldsAndIdentity() {
        UUID supplier=supplier(),contact=UUID.randomUUID();
        UUID creation=inTx(()->{provenance("/api/master/suppliers/"+supplier+"/contact-methods","POST");
            em.createNativeQuery("INSERT INTO party_contact_methods(id,party_type,party_id,kind,value,is_primary) VALUES(:id,'SUPPLIER',:party,'MOBILE','18800001111',true)").setParameter("id",contact).setParameter("party",supplier).executeUpdate();
            em.createNativeQuery("UPDATE suppliers SET mobile='18800001111' WHERE id=:id").setParameter("id",supplier).executeUpdate();return latest();});
        assertEquals(2,service.list("suppliers").entries().getFirst().affectedCount());
        inTx(()->service.undo("suppliers",creation,0));assertTrue(em.createNativeQuery("SELECT id FROM party_contact_methods WHERE id=:id").setParameter("id",contact).getResultList().isEmpty());
        inTx(()->service.redo("suppliers",creation,1));assertEquals("18800001111",value("SELECT mobile FROM suppliers WHERE id=:id",supplier));
        UUID deletion=inTx(()->{provenance("/api/master/suppliers/"+supplier+"/contact-methods/"+contact,"DELETE");
            em.createNativeQuery("DELETE FROM party_contact_methods WHERE id=:id").setParameter("id",contact).executeUpdate();
            em.createNativeQuery("UPDATE suppliers SET mobile='' WHERE id=:id").setParameter("id",supplier).executeUpdate();return latest();});
        inTx(()->service.undo("suppliers",deletion,0));assertEquals("18800001111",value("SELECT value FROM party_contact_methods WHERE id=:id",contact));
        inTx(()->service.redo("suppliers",deletion,1));assertEquals("",value("SELECT mobile FROM suppliers WHERE id=:id",supplier));
    }
    @Test void addressDirectoryRestoresDefaultFlagsAndDetectsOutsideAba() {
        UUID supplier=supplier(),first=UUID.randomUUID(),second=UUID.randomUUID();
        inTx(()->{em.createNativeQuery("INSERT INTO party_addresses(id,party_type,party_id,address,is_default) VALUES(:id,'SUPPLIER',:party,'first original address',true)").setParameter("id",first).setParameter("party",supplier).executeUpdate();return null;});
        UUID operation=inTx(()->{provenance("/api/master/suppliers/"+supplier+"/addresses","POST");
            em.createNativeQuery("INSERT INTO party_addresses(id,party_type,party_id,address,is_default) VALUES(:id,'SUPPLIER',:party,'second original address',true)").setParameter("id",second).setParameter("party",supplier).executeUpdate();
            em.createNativeQuery("UPDATE party_addresses SET is_default=false WHERE id=:id").setParameter("id",first).executeUpdate();return latest();});
        inTx(()->service.undo("suppliers",operation,0));assertEquals("true",value("SELECT is_default::text FROM party_addresses WHERE id=:id",first));
        inTx(()->service.redo("suppliers",operation,1));assertEquals("false",value("SELECT is_default::text FROM party_addresses WHERE id=:id",first));
        inTx(()->{em.createNativeQuery("UPDATE party_addresses SET address=address WHERE id=:id").setParameter("id",first).executeUpdate();return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo("suppliers",operation,2)));
    }
    @Test void activityEvidenceIsRecordedWithExplicitReasonAndNeverReplayed() {
        UUID supplier=supplier();inTx(()->{provenance("/api/master/suppliers/"+supplier+"/activity-records","POST");
            em.createNativeQuery("INSERT INTO party_activity_records(party_type,party_id,kind,content) VALUES('SUPPLIER',:party,'FOLLOW_UP','test follow up evidence')").setParameter("party",supplier).executeUpdate();
            em.createNativeQuery("INSERT INTO party_activity_records(party_type,party_id,kind,content) VALUES('SUPPLIER',:party,'FOLLOW_UP','another follow up evidence')").setParameter("party",supplier).executeUpdate();return null;});
        var entry=service.list("suppliers").entries().getFirst();assertFalse(entry.canUndo());assertTrue(entry.blockedReason().contains("追加业务证据"));
    }
    @Test void manualShippingAddressUsesItsOwnPermissionsAndLaterLearningBlocksReplay() {
        UUID client=client(),address=UUID.randomUUID();
        UUID operation=inTx(()->{provenance("/api/master/clients/"+client+"/ship-addresses","POST");
            em.createNativeQuery("INSERT INTO client_ship_addresses(id,client_id,address,usage_count,last_used_at) VALUES(:id,:client,'manual address',1,now())").setParameter("id",address).setParameter("client",client).executeUpdate();return latest();});
        login(Set.of("client:view","client_address:create"),false);
        UUID employee=current.get().orElseThrow().getEmployeeId();
        inTx(()->{em.createNativeQuery("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT :id,:code,'history address actor','其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'")
            .setParameter("id",employee).setParameter("code","H-"+employee).executeUpdate();return null;});
        assertTrue(service.list("clients").entries().getFirst().canUndo());
        inTx(()->service.undo("clients",operation,0));assertEquals("true",value("SELECT is_deleted::text FROM client_ship_addresses WHERE id=:id",address));
        inTx(()->service.redo("clients",operation,1));
        // Automatic learning has a business-document request path, so it does
        // not become a personal master edit but advances the row's version.
        inTx(()->{em.createNativeQuery("UPDATE client_ship_addresses SET usage_count=usage_count+1,last_used_at=now() WHERE id=:id").setParameter("id",address).executeUpdate();return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo("clients",operation,2)));
        assertEquals("false",value("SELECT is_deleted::text FROM client_ship_addresses WHERE id=:id",address));
    }
    @Test void clientObjectScopeLossBlocksDirectoryReplayAndRedactsItsSummary() {
        UUID client=client(),address=UUID.randomUUID();
        UUID operation=inTx(()->{provenance("/api/master/clients/"+client+"/addresses","POST");
            em.createNativeQuery("INSERT INTO party_addresses(id,party_type,party_id,address) VALUES(:id,'CLIENT',:party,'private address')").setParameter("id",address).setParameter("party",client).executeUpdate();return latest();});
        ClientAccessPolicy policy=(ClientAccessPolicy)org.springframework.test.util.ReflectionTestUtils.getField(service,"clientAccess");
        when(policy.canRead(any(UUID.class),nullable(UUID.class),any())).thenReturn(false);
        var entry=service.list("clients").entries().getFirst();assertFalse(entry.canUndo());assertEquals("",entry.summary());
        assertThrows(ApiException.class,()->inTx(()->service.undo("clients",operation,0)));
    }
    @Test void restoringDeletedPrimaryContactDoesNotOverwriteALaterPrimaryChoice() {
        UUID supplier=supplier(),old=UUID.randomUUID(),later=UUID.randomUUID();
        inTx(()->{em.createNativeQuery("INSERT INTO party_contact_methods(id,party_type,party_id,kind,value,is_primary) VALUES(:id,'SUPPLIER',:party,'OTHER','old primary',true)").setParameter("id",old).setParameter("party",supplier).executeUpdate();return null;});
        UUID deletion=inTx(()->{provenance("/api/master/suppliers/"+supplier+"/contact-methods/"+old,"DELETE");em.createNativeQuery("DELETE FROM party_contact_methods WHERE id=:id").setParameter("id",old).executeUpdate();return latest();});
        inTx(()->{em.createNativeQuery("INSERT INTO party_contact_methods(id,party_type,party_id,kind,value,is_primary) VALUES(:id,'SUPPLIER',:party,'OTHER','later primary',true)").setParameter("id",later).setParameter("party",supplier).executeUpdate();return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo("suppliers",deletion,0)));
        assertEquals("true",value("SELECT is_primary::text FROM party_contact_methods WHERE id=:id",later));
        assertTrue(em.createNativeQuery("SELECT id FROM party_contact_methods WHERE id=:id").setParameter("id",old).getResultList().isEmpty());
    }
    @Test void restoringDeletedDefaultAddressDoesNotOverwriteALaterDefaultChoice() {
        UUID supplier=supplier(),old=UUID.randomUUID(),later=UUID.randomUUID();
        inTx(()->{em.createNativeQuery("INSERT INTO party_addresses(id,party_type,party_id,address,is_default) VALUES(:id,'SUPPLIER',:party,'old default address',true)").setParameter("id",old).setParameter("party",supplier).executeUpdate();return null;});
        UUID deletion=inTx(()->{provenance("/api/master/suppliers/"+supplier+"/addresses/"+old,"DELETE");em.createNativeQuery("DELETE FROM party_addresses WHERE id=:id").setParameter("id",old).executeUpdate();return latest();});
        inTx(()->{em.createNativeQuery("INSERT INTO party_addresses(id,party_type,party_id,address,is_default) VALUES(:id,'SUPPLIER',:party,'later default address',true)").setParameter("id",later).setParameter("party",supplier).executeUpdate();return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo("suppliers",deletion,0)));
        assertEquals("true",value("SELECT is_default::text FROM party_addresses WHERE id=:id",later));
        assertTrue(em.createNativeQuery("SELECT id FROM party_addresses WHERE id=:id").setParameter("id",old).getResultList().isEmpty());
    }
    @Test void mouldCategoryCascadeRestoresParentsFirstAndRedoIgnoresOnlyItsOwnDeletingReferences() {
        UUID root=UUID.randomUUID(),child=UUID.randomUUID(),mould=UUID.randomUUID();
        inTx(()->{em.createNativeQuery("INSERT INTO mould_categories(id,code,name) VALUES(:id,:code,'cascade root')").setParameter("id",root).setParameter("code","R-"+root).executeUpdate();
            em.createNativeQuery("INSERT INTO mould_categories(id,code,name,parent_id) VALUES(:id,:code,'cascade child',:parent)").setParameter("id",child).setParameter("code","C-"+child).setParameter("parent",root).executeUpdate();
            insertMould(mould,child);return null;});
        UUID deletion=inTx(()->{provenance("/api/master/mould-categories/"+root,"DELETE");
            em.createNativeQuery("UPDATE moulds SET is_deleted=true,deleted_at=now() WHERE id=:id").setParameter("id",mould).executeUpdate();
            em.createNativeQuery("UPDATE mould_categories SET is_deleted=true,deleted_at=now() WHERE id=:id").setParameter("id",child).executeUpdate();
            em.createNativeQuery("UPDATE mould_categories SET is_deleted=true,deleted_at=now() WHERE id=:id").setParameter("id",root).executeUpdate();return latest();});
        login(Set.of("mould:view","mould_category:delete"),false);
        inTx(()->service.undo("moulds",deletion,0));assertEquals("false",value("SELECT is_deleted::text FROM moulds WHERE id=:id",mould));
        inTx(()->service.redo("moulds",deletion,1));assertEquals("true",value("SELECT is_deleted::text FROM mould_categories WHERE id=:id",root));
        inTx(()->service.undo("moulds",deletion,2));
        UUID later=UUID.randomUUID();inTx(()->{insertMould(later,child);return null;});
        assertThrows(ApiException.class,()->inTx(()->service.redo("moulds",deletion,3)));
        assertEquals("false",value("SELECT is_deleted::text FROM mould_categories WHERE id=:id",root));
        assertEquals("false",value("SELECT is_deleted::text FROM moulds WHERE id=:id",mould));
        assertEquals("false",value("SELECT is_deleted::text FROM moulds WHERE id=:id",later));
    }
    @Test @Timeout(10) void replayRejectsAnInFlightReferenceLockBeforeCheckingReferences() {
        UUID color=color("reference lock"),operation=edit(color,"edited");
        EntityManager writer=factory.createEntityManager();writer.getTransaction().begin();
        try {
            writer.createNativeQuery("SELECT id FROM colors WHERE id=:id FOR KEY SHARE").setParameter("id",color).getResultList();
            assertThrows(ApiException.class,()->inTx(()->service.undo("colors",operation,0)));
            assertEquals("edited",value("SELECT name FROM colors WHERE id=:id",color));
        } finally {writer.getTransaction().rollback();writer.close();}
    }
    private void insertMould(UUID id,UUID category) {em.createNativeQuery("INSERT INTO moulds(id,code,name,status,category_id,code_sequence,code_managed) VALUES(:id,:code,'cascade mould','使用',:category,(SELECT coalesce(max(code_sequence),0)+1 FROM moulds),false)")
        .setParameter("id",id).setParameter("code","M-"+id).setParameter("category",category).executeUpdate();}
    private UUID client() {UUID id=UUID.randomUUID();return inTx(()->{em.createNativeQuery("INSERT INTO clients(id,code,name,status,code_sequence) VALUES(:id,:code,'directory client','使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients))").setParameter("id",id).setParameter("code","C-"+id).executeUpdate();return id;});}
    private UUID supplier() {UUID id=UUID.randomUUID();return inTx(()->{em.createNativeQuery("INSERT INTO suppliers(id,code,name,status,code_sequence) VALUES(:id,:code,'directory supplier','使用',(SELECT coalesce(max(code_sequence),0)+1 FROM suppliers))").setParameter("id",id).setParameter("code","S-"+id).executeUpdate();return id;});}
    private UUID color(String name) {UUID id=UUID.randomUUID();return inTx(()->{insertColor(id,name);return id;});}
    private void insertColor(UUID id,String name) {em.createNativeQuery("INSERT INTO colors(id,code,name) VALUES(:id,:code,:name)").setParameter("id",id).setParameter("code","H-"+id).setParameter("name",name).executeUpdate();}
    private UUID edit(UUID id,String name) {return inTx(()->{provenance("/api/master/colors/"+id,"PUT");em.createNativeQuery("UPDATE colors SET name=:name,updated_at=clock_timestamp() WHERE id=:id").setParameter("name",name).setParameter("id",id).executeUpdate();return latest();});}
    private UUID latest() {return (UUID)em.createNativeQuery("SELECT id FROM master_operation_history WHERE actor_id=:actor ORDER BY created_at DESC,id DESC LIMIT 1").setParameter("actor",actor).getSingleResult();}
    private void login(Set<String> permissions,boolean admin) {when(current.get()).thenReturn(Optional.of(new AuthUser(actor,UUID.randomUUID(),"master-history-test",permissions,false,true,admin)));}
    private void provenance(String path,String method) {set("app.actor_id",actor.toString());set("app.audit_request_id",UUID.randomUUID().toString());set("app.audit_request_path",path);set("app.audit_request_method",method);}
    private void set(String key,String value) {em.createNativeQuery("SELECT set_config(:key,:value,true)").setParameter("key",key).setParameter("value",value).getSingleResult();}
    private String value(String sql,UUID id) {return Objects.toString(em.createNativeQuery(sql).setParameter("id",id).getSingleResult(),null);}
    private <T>T inTx(Supplier<T> action) {em.getTransaction().begin();try {T result=action.get();em.getTransaction().commit();return result;}catch(RuntimeException|Error failure){if(em.getTransaction().isActive())em.getTransaction().rollback();throw failure;}}
}
