package com.uten.imp.features.master.goods.history;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.lifecycle.MasterReferenceGuard;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
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
import org.springframework.test.util.ReflectionTestUtils;

import java.util.*;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Real service/driver tests against a disposable clone of the migrated schema. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsOperationHistoryPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static EntityManagerFactory factory;
    EntityManager em;
    UUID actor;
    SecurityContextCurrentUser current;
    GoodsOperationHistoryService service;

    @BeforeAll static void start() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("goods_history_service");
        var bean=new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.security");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));
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
        actor=UUID.randomUUID();em=factory.createEntityManager();current=mock(SecurityContextCurrentUser.class);
        when(current.requireId()).thenAnswer(invocation->actor);
        login(Set.of(),true);
        var tx=mock(TxSessionVars.class);
        doAnswer(invocation->{set("app.actor_id",actor.toString());set("app.audit_request_path","/api/master/goods/history");return null;}).when(tx).bind();
        var access=mock(MasterObjectAccess.class);
        when(access.readableLabelOwner(anyString())).thenReturn(owner->true);
        service=new GoodsOperationHistoryService(em,new ObjectMapper(),current,tx,new MasterReferenceGuard(em,access),mock(OwnerVisibility.class),mock(BusinessEventPublisher.class));
    }
    @AfterEach void close() {
        if (em.getTransaction().isActive()) {
            em.getTransaction().rollback();
        }
        em.close();
    }

    @Test void selectedOlderIndependentOperationCanUndoWhileAnotherActorCannotSeeOrReplayIt() {
        UUID first=goods("first"),second=goods("second");
        UUID firstOp=edit(first,"first changed"),secondOp=edit(second,"second changed");
        inTx(()->service.undo(firstOp,0));
        assertEquals("first",scalar("SELECT name FROM goods WHERE id=:id",first));
        assertEquals("second changed",scalar("SELECT name FROM goods WHERE id=:id",second));
        UUID originalActor=actor;actor=UUID.randomUUID();login(Set.of(),true);
        assertTrue(service.list().entries().isEmpty());
        assertThrows(ApiException.class,()->inTx(()->service.undo(secondOp,0)));
        actor=originalActor;login(Set.of(),true);
        assertEquals(2,service.list().entries().size());
    }

    @Test void fieldPermissionsAreRecheckedForDiscountAndCostsAfterTheOriginalEdit() {
        UUID id=goods("permission");
        UUID op=inTx(()->{
            provenance("/api/master/goods/"+id,"PUT");
            update("UPDATE goods SET zk=0.9,g_total=17,version=version+1 WHERE id=:id",id);
            return latest();
        });
        login(Set.of("goods:view","goods:edit"),false);
        var entry=service.list().entries().getFirst();
        assertFalse(entry.canUndo());assertTrue(entry.blockedReason().contains("goods:price:edit"));assertTrue(entry.blockedReason().contains("goods:cost:view"));
        assertThrows(ApiException.class,()->inTx(()->service.undo(op,0)));
        assertEquals("0.9000",scalar("SELECT zk::text FROM goods WHERE id=:id",id));
        assertEquals(0,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",actor));
    }
    @Test void costPermissionIsRecheckedEvenForDecimalDifferencesBeyondDoublePrecision() {
        UUID id=goods("precise cost permission");
        inTx(()->{update("UPDATE goods SET g_total=99999999999999.9998 WHERE id=:id",id);return null;});
        UUID op=inTx(()->{provenance("/api/master/goods/"+id,"PUT");update("UPDATE goods SET g_total=99999999999999.9999,version=version+1 WHERE id=:id",id);return latest();});
        login(Set.of("goods:view","goods:edit"),false);
        var entry=service.list().entries().getFirst();assertFalse(entry.canUndo());assertTrue(entry.blockedReason().contains("goods:cost:view"));
        assertThrows(ApiException.class,()->inTx(()->service.undo(op,0)));
    }
    @Test void revokingGeneralGoodsEditBlocksCostOnlyUndoAndRedoEvenWithCostVisibility() {
        UUID id=goods("cost field group");
        inTx(()->{update("UPDATE goods SET g_total=16 WHERE id=:id",id);return null;});
        UUID operation=inTx(()->{provenance("/api/master/goods/"+id,"PUT");update("UPDATE goods SET g_total=17,version=version+1 WHERE id=:id",id);return latest();});
        login(Set.of("goods:view","goods:cost:view"),false);
        assertFalse(service.list().entries().getFirst().canUndo());
        assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));
        assertEquals("17.0000",scalar("SELECT g_total::text FROM goods WHERE id=:id",id));
        assertEquals(0,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",actor));
        login(Set.of("goods:view","goods:edit","goods:cost:view"),false);
        inTx(()->service.undo(operation,0));
        assertEquals("16.0000",scalar("SELECT g_total::text FROM goods WHERE id=:id",id));
        login(Set.of("goods:view","goods:cost:view"),false);
        assertThrows(ApiException.class,()->inTx(()->service.redo(operation,1)));
        assertEquals("16.0000",scalar("SELECT g_total::text FROM goods WHERE id=:id",id));
        assertEquals(1,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",actor));
    }
    @Test void importedPriceDiscountAndStatusChangesRecheckTheirRightsForUndoAndRedo() {
        UUID id=goods("imported field rights");
        inTx(()->{update("UPDATE goods SET price=10,zk=1,status='使用' WHERE id=:id",id);return null;});
        UUID operation=inTx(()->{provenance("/api/master/goods/import/commit","POST");update("UPDATE goods SET price=20,zk=0.9,status='禁用',version=version+1 WHERE id=:id",id);return latest();});
        assertEquals("GOODS_IMPORT",scalar("SELECT operation_type FROM goods_operation_history WHERE id=:id",operation));
        login(Set.of("goods:view","goods:edit","goods:import","goods:import:undo","goods:discount:view"),false);
        var entry=service.list().entries().getFirst();assertFalse(entry.canUndo());
        assertTrue(entry.blockedReason().contains("goods:price:edit"));assertTrue(entry.blockedReason().contains("goods:status"));
        assertThrows(ApiException.class,()->inTx(()->service.undo(operation,0)));
        assertEquals("禁用",scalar("SELECT status FROM goods WHERE id=:id",id));
        login(Set.of("goods:view","goods:edit","goods:import","goods:import:undo","goods:price:edit","goods:discount:view","goods:status"),false);
        inTx(()->service.undo(operation,0));
        assertEquals("10.0000",scalar("SELECT price::text FROM goods WHERE id=:id",id));assertEquals("使用",scalar("SELECT status FROM goods WHERE id=:id",id));
        login(Set.of("goods:view","goods:edit","goods:import","goods:import:undo","goods:discount:view"),false);
        assertThrows(ApiException.class,()->inTx(()->service.redo(operation,1)));
        assertEquals("10.0000",scalar("SELECT price::text FROM goods WHERE id=:id",id));
        assertEquals(1,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",actor));
    }

    @Test void aRestoredGoodsCannotPointToItsNowDeletedCategory() {
        UUID category=category("original"),other=category("other"),id=goodsIn(category,"reference");
        UUID op=inTx(()->{
            provenance("/api/master/goods/"+id,"PUT");
            em.createNativeQuery("UPDATE goods SET category_id=:category,version=version+1 WHERE id=:id").setParameter("category",other).setParameter("id",id).executeUpdate();
            return latest();
        });
        inTx(()->{update("UPDATE material_categories SET is_deleted=true,deleted_at=now() WHERE id=:id",category);return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo(op,0)));
        assertEquals(other.toString(),scalar("SELECT category_id::text FROM goods WHERE id=:id",id));
        assertEquals(0,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",actor));
    }

    @Test void deletionUndoRestoresTheExactGoodsAndBomIdsAndRedoDeletesOnlyThoseRowsAgain() {
        UUID parent=goods("parent"),component=goods("component"),edge=UUID.randomUUID();
        inTx(()->{
            em.createNativeQuery("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(:id,:parent,:component,2)")
                    .setParameter("id",edge).setParameter("parent",parent).setParameter("component",component).executeUpdate();return null;
        });
        UUID op=inTx(()->{
            provenance("/api/master/goods/batch-delete","POST");
            update("UPDATE goods_bom_items SET is_deleted=true,deleted_at=now() WHERE id=:id",edge);
            update("UPDATE goods SET is_deleted=true,deleted_at=now(),version=version+1 WHERE id=:id",parent);
            return latest();
        });
        inTx(()->service.undo(op,0));
        assertEquals("false",scalar("SELECT is_deleted::text FROM goods WHERE id=:id",parent));
        assertEquals("false",scalar("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id",edge));
        assertEquals(component.toString(),scalar("SELECT component_goods_id::text FROM goods_bom_items WHERE id=:id",edge));
        inTx(()->service.redo(op,1));
        assertEquals("true",scalar("SELECT is_deleted::text FROM goods WHERE id=:id",parent));
        assertEquals("true",scalar("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id",edge));
        inTx(()->service.undo(op,2));
        assertEquals("false",scalar("SELECT is_deleted::text FROM goods WHERE id=:id",parent));
        assertEquals(3,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",actor));
    }

    @Test void restoringAnOldBomEdgeCannotCreateACycleAndTheWholeReplayRollsBack() {
        UUID a=goods("cycle A"),b=goods("cycle B"),edge=UUID.randomUUID();
        inTx(()->{bom(edge,a,b);return null;});
        UUID op=inTx(()->{provenance("/api/master/goods/"+a+"/bom/"+edge,"DELETE");update("UPDATE goods_bom_items SET is_deleted=true,deleted_at=now() WHERE id=:id",edge);return latest();});
        inTx(()->{bom(UUID.randomUUID(),b,a);return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo(op,0)));
        assertEquals("true",scalar("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id",edge));
        assertEquals(0,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",actor));
    }

    @Test void recentWindowLimitsSelectableOperationsAndANewWriteInvalidatesTheRedoBranch() {
        UUID id=goods("window");List<UUID> history=new ArrayList<>();
        for(int n=0;n<11;n++)history.add(edit(id,"edit "+n));
        assertEquals(10,service.list().entries().size());
        assertThrows(ApiException.class,()->inTx(()->service.undo(history.getFirst(),0)));
        UUID latest=history.getLast();inTx(()->service.undo(latest,0));
        assertTrue(service.list().entries().stream().anyMatch(GoodsOperationHistoryService.Entry::canRedo));
        edit(goods("new branch"),"new branch changed");
        assertTrue(service.list().entries().stream().noneMatch(GoodsOperationHistoryService.Entry::canRedo));
        assertThrows(ApiException.class,()->inTx(()->service.redo(latest,1)));
    }

    @Test void importedCreationCannotUndoAfterAnotherGoodsStartsUsingItsNewMaster() {
        UUID color=UUID.randomUUID(),created=UUID.randomUUID();
        UUID op=inTx(()->{
            provenance("/api/master/goods/import/commit","POST");
            em.createNativeQuery("INSERT INTO colors(id,code,name) VALUES(:id,:code,'history color')").setParameter("id",color).setParameter("code","HC-"+color).executeUpdate();
            insertGoods(created,null,"imported");
            em.createNativeQuery("UPDATE goods SET color_id=:color WHERE id=:id").setParameter("color",color).setParameter("id",created).executeUpdate();
            return latest();
        });
        UUID later=goods("later user");
        inTx(()->{em.createNativeQuery("UPDATE goods SET color_id=:color WHERE id=:id").setParameter("color",color).setParameter("id",later).executeUpdate();return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo(op,0)));
        assertEquals("false",scalar("SELECT is_deleted::text FROM goods WHERE id=:id",created));
        assertEquals("false",scalar("SELECT is_deleted::text FROM colors WHERE id=:id",color));
    }

    @Test void aColorDisabledAfterChangingToAnotherColorCannotBeReintroducedByUndo() {
        UUID red=UUID.randomUUID(),blue=UUID.randomUUID(),id=goods("color policy");
        inTx(()->{
            em.createNativeQuery("INSERT INTO colors(id,code,name,status) VALUES(:red,:redCode,'history red','使用'),(:blue,:blueCode,'history blue','使用')").setParameter("red",red).setParameter("blue",blue).setParameter("redCode","HC-"+red).setParameter("blueCode","HC-"+blue).executeUpdate();
            em.createNativeQuery("UPDATE goods SET color_id=:red WHERE id=:id").setParameter("red",red).setParameter("id",id).executeUpdate();return null;
        });
        UUID op=inTx(()->{
            provenance("/api/master/goods/"+id,"PUT");
            em.createNativeQuery("UPDATE goods SET color_id=:blue,version=version+1 WHERE id=:id").setParameter("blue",blue).setParameter("id",id).executeUpdate();return latest();
        });
        inTx(()->{update("UPDATE colors SET status='禁用' WHERE id=:id",red);return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo(op,0)));
        assertEquals(blue.toString(),scalar("SELECT color_id::text FROM goods WHERE id=:id",id));
        assertEquals(0,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",actor));
    }

    @Test void aBomAuditWithoutAGoodsSnapshotStillRechecksVisibilityAndRedactsItsSummary() {
        UUID parent=goods("private parent"),child=goods("child"),edge=UUID.randomUUID();
        UUID owner=UUID.randomUUID(),department=UUID.randomUUID();
        inTx(()->{
            em.createNativeQuery("INSERT INTO departments(id,code,name,level) VALUES(:id,:code,'history dept','公司')").setParameter("id",department).setParameter("code","HDEP-"+department).executeUpdate();
            em.createNativeQuery("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(:id,:code,'history owner','其他',:dept,current_date,'active','regular')")
                    .setParameter("id",owner).setParameter("code","HEMP-"+owner).setParameter("dept",department).executeUpdate();
            bom(edge,parent,child);return null;
        });
        UUID op=inTx(()->{
            provenance("/api/master/goods/"+parent+"/bom/"+edge+"/audit","PUT");
            update("UPDATE goods_bom_items SET audited_at=now() WHERE id=:id",edge);return latest();
        });
        assertEquals(0,count("SELECT count(*) FROM goods_operation_history_rows WHERE operation_id=:id AND table_name='goods'",op));
        assertTrue(service.list().entries().getFirst().summary().contains("private parent"));
        inTx(()->{em.createNativeQuery("UPDATE goods SET owner_employee_id=:owner,version=version+1 WHERE id=:id").setParameter("owner",owner).setParameter("id",parent).executeUpdate();return null;});
        ReflectionTestUtils.setField(service,"goodsOwnerScopeEnabled",true);
        var visibility=(OwnerVisibility)ReflectionTestUtils.getField(service,"ownerVisibility");
        when(visibility.evaluate("goods","goods:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(),Set.of()));
        var entry=service.list().entries().getFirst();
        assertEquals("",entry.summary());assertFalse(entry.canUndo());assertTrue(entry.blockedReason().contains("权限"));
        assertThrows(ApiException.class,()->inTx(()->service.undo(op,0)));
        assertEquals(0,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",actor));
    }

    @Test void legacyBomSnapshotsStayUndoableWithoutRewritingTheirRetainedBeforeAndAfter() {
        UUID parent=goods("legacy recipe"),component=goods("legacy material"),edge=UUID.randomUUID();
        inTx(()->{bom(edge,parent,component);return null;});
        UUID operation=inTx(()->{
            provenance("/api/master/goods/"+parent+"/bom/"+edge,"PUT");
            update("UPDATE goods_bom_items SET qty=2 WHERE id=:id",edge);return latest();
        });
        inTx(()->{
            update("""
                    UPDATE goods_operation_history_rows SET
                      before_row=before_row-'retirement_reason'-'retirement_resolved_at',
                      after_row=after_row-'retirement_reason'-'retirement_resolved_at',
                      expected_row=expected_row-'retirement_reason'-'retirement_resolved_at',
                      before_token=before_token-'retirement_reason'-'retirement_resolved_at',
                      after_token=after_token-'retirement_reason'-'retirement_resolved_at'
                    WHERE operation_id=:id AND table_name='goods_bom_items'
                    """,operation);return null;
        });
        assertTrue(service.list().entries().getFirst().canUndo());
        inTx(()->service.undo(operation,0));
        assertEquals(0,new java.math.BigDecimal("1").compareTo(new java.math.BigDecimal(
                scalar("SELECT qty::text FROM goods_bom_items WHERE id=:id",edge))));
        inTx(()->service.redo(operation,1));
        assertEquals(0,new java.math.BigDecimal("2").compareTo(new java.math.BigDecimal(
                scalar("SELECT qty::text FROM goods_bom_items WHERE id=:id",edge))));
        assertEquals(1,count("""
                SELECT count(*) FROM goods_operation_history_rows WHERE operation_id=:id
                  AND table_name='goods_bom_items' AND NOT jsonb_exists(before_row,'retirement_reason')
                  AND NOT jsonb_exists(after_row,'retirement_reason')
                """,operation));
    }

    @Test void undoingAnOlderPriceEditPreservesTheMaterialCostRecalculatedByALaterBomUndo() {
        UUID parent=goods("cost parent"),component=goods("cost component"),edge=UUID.randomUUID();
        inTx(()->{bom(edge,parent,component);update("UPDATE goods SET price=5,source_e=10 WHERE id=:id",parent);update("UPDATE goods SET price=10 WHERE id=:id",component);return null;});
        UUID priceEdit=inTx(()->{provenance("/api/master/goods/"+parent,"PUT");update("UPDATE goods SET price=7,version=version+1 WHERE id=:id",parent);return latest();});
        UUID bomEdit=inTx(()->{
            provenance("/api/master/goods/"+parent+"/bom/"+edge,"PUT");
            update("UPDATE goods_bom_items SET qty=2 WHERE id=:id",edge);
            update("UPDATE goods SET source_e=20,version=version+1 WHERE id=:id",parent);return latest();
        });
        inTx(()->{update("UPDATE goods SET price=15,version=version+1 WHERE id=:id",component);return null;});
        inTx(()->service.undo(bomEdit,0));
        assertEquals(0,new java.math.BigDecimal("15").compareTo(new java.math.BigDecimal(scalar("SELECT source_e::text FROM goods WHERE id=:id",parent))));
        inTx(()->service.undo(priceEdit,0));
        assertEquals(0,new java.math.BigDecimal("5").compareTo(new java.math.BigDecimal(scalar("SELECT price::text FROM goods WHERE id=:id",parent))));
        assertEquals(0,new java.math.BigDecimal("15").compareTo(new java.math.BigDecimal(scalar("SELECT source_e::text FROM goods WHERE id=:id",parent))));
    }

    @Test void categoryMoveDetectsLaterSubtreeMembersEvenWithAnOlderTransactionTimestamp() {
        UUID oldParent=category("old parent"),newParent=category("new parent"),child=category("moving child");
        inTx(()->{em.createNativeQuery("UPDATE material_categories SET parent_id=:parent WHERE id=:id").setParameter("parent",oldParent).setParameter("id",child).executeUpdate();return null;});
        goodsIn(child,"existing unchanged goods");
        UUID move=inTx(()->{
            provenance("/api/master/material-categories/"+child,"PUT");
            em.createNativeQuery("UPDATE material_categories SET parent_id=:parent,version=version+1 WHERE id=:id").setParameter("parent",newParent).setParameter("id",child).executeUpdate();return latest();
        });
        UUID late=goodsIn(child,"later committed goods");
        inTx(()->{update("UPDATE goods SET created_at='2000-01-01',updated_at='2000-01-01' WHERE id=:id",late);return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo(move,0)));
        assertEquals(newParent.toString(),scalar("SELECT parent_id::text FROM material_categories WHERE id=:id",child));
        assertEquals(0,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",actor));
    }

    @Test void undoCreationCannotLeaveALaterZeroCostBomUnderADeletedParent() {
        UUID parent=UUID.randomUUID(),component=goods("zero cost component"),edge=UUID.randomUUID();
        UUID creation=inTx(()->{provenance("/api/master/goods","POST");insertGoods(parent,null,"created parent");return latest();});
        // A zero-cost component can add an edge without changing source_e or
        // producing a goods-row update. The parent snapshot alone is insufficient.
        inTx(()->{bom(edge,parent,component);return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo(creation,0)));
        assertEquals("false",scalar("SELECT is_deleted::text FROM goods WHERE id=:id",parent));
        assertEquals("false",scalar("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id",edge));
        assertEquals(0,count("SELECT count(*) FROM goods_operation_history_events WHERE actor_id=:id",actor));
    }

    @Test void restoringADeletedEdgeRejectsACycleIntroducedByALaterIndependentEdge() {
        UUID parent=goods("cycle parent"),component=goods("cycle component"),edge=UUID.randomUUID();
        inTx(()->{bom(edge,parent,component);return null;});
        UUID deletion=inTx(()->{provenance("/api/master/goods/"+parent+"/bom/"+edge,"DELETE");
            update("UPDATE goods_bom_items SET is_deleted=true,deleted_at=now() WHERE id=:id",edge);return latest();});
        inTx(()->{bom(UUID.randomUUID(),component,parent);return null;});
        assertThrows(ApiException.class,()->inTx(()->service.undo(deletion,0)));
        assertEquals("true",scalar("SELECT is_deleted::text FROM goods_bom_items WHERE id=:id",edge));
    }

    @Test void dragRouteCapturesAReversibleMoveAndInlineRouteCapturesGoodsEdit() {
        UUID parent=goods("drag parent"),component=goods("drag component"),edge=UUID.randomUUID();
        inTx(()->{bom(edge,parent,component);return null;});
        UUID move=inTx(()->{provenance("/api/master/goods/"+parent+"/bom/move","PUT");
            update("UPDATE goods_bom_items SET sort_order=7 WHERE id=:id",edge);return latest();});
        assertEquals("BOM_MOVE",service.list().entries().getFirst().operationType());
        inTx(()->service.undo(move,0));assertEquals("0",scalar("SELECT sort_order::text FROM goods_bom_items WHERE id=:id",edge));
        UUID edit=inTx(()->{provenance("/api/master/inline-edit/goods/"+parent,"PATCH");
            update("UPDATE goods SET name='inline changed',version=version+1 WHERE id=:id",parent);return latest();});
        assertEquals("GOODS_EDIT",service.list().entries().getFirst().operationType());
        inTx(()->service.undo(edit,0));assertEquals("drag parent",scalar("SELECT name FROM goods WHERE id=:id",parent));
    }

    private void login(Set<String> permissions,boolean superAdmin) {when(current.get()).thenReturn(Optional.of(new AuthUser(actor,UUID.randomUUID(),"history-test",permissions,false,true,superAdmin)));}
    private UUID goods(String name){return goodsIn(null,name);}
    private UUID goodsIn(UUID category,String name){UUID id=UUID.randomUUID();return inTx(()->{insertGoods(id,category,name);return id;});}
    private void insertGoods(UUID id,UUID category,String name){em.createNativeQuery("INSERT INTO goods(id,code,name,category_id,code_sequence) VALUES(:id,:code,:name,:category,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))")
            .setParameter("id",id).setParameter("code","H-"+id).setParameter("name",name).setParameter("category",category).executeUpdate();}
    private UUID category(String name){UUID id=UUID.randomUUID();return inTx(()->{em.createNativeQuery("INSERT INTO material_categories(id,code,name) VALUES(:id,:code,:name)").setParameter("id",id).setParameter("code","C-"+id).setParameter("name",name).executeUpdate();return id;});}
    private UUID edit(UUID id,String name){return inTx(()->{provenance("/api/master/goods/"+id,"PUT");em.createNativeQuery("UPDATE goods SET name=:name,version=version+1 WHERE id=:id").setParameter("name",name).setParameter("id",id).executeUpdate();return latest();});}
    private void bom(UUID id,UUID parent,UUID child){em.createNativeQuery("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(:id,:parent,:child,1)").setParameter("id",id).setParameter("parent",parent).setParameter("child",child).executeUpdate();}
    private UUID latest(){return (UUID)em.createNativeQuery("SELECT id FROM goods_operation_history WHERE actor_id=:actor ORDER BY created_at DESC,id DESC LIMIT 1").setParameter("actor",actor).getSingleResult();}
    private void provenance(String path,String method){set("app.actor_id",actor.toString());set("app.audit_request_id",UUID.randomUUID().toString());set("app.audit_request_path",path);set("app.audit_request_method",method);}
    private void set(String key,String value){em.createNativeQuery("SELECT set_config(:key,:value,true)").setParameter("key",key).setParameter("value",value).getSingleResult();}
    private void update(String sql,UUID id){em.createNativeQuery(sql).setParameter("id",id).executeUpdate();}
    private String scalar(String sql,UUID id){Object value=em.createNativeQuery(sql).setParameter("id",id).getSingleResult();return value==null?null:value.toString();}
    private int count(String sql,UUID id){
        Number value=assertInstanceOf(Number.class,em.createNativeQuery(sql).setParameter("id",id).getSingleResult());
        return Math.toIntExact(value.longValue());
    }
    private <T>T inTx(Supplier<T> action) {
        em.getTransaction().begin();
        try {
            T result=action.get();
            em.getTransaction().commit();
            return result;
        } catch (RuntimeException|Error error) {
            if (em.getTransaction().isActive()) {
                em.getTransaction().rollback();
            }
            throw error;
        }
    }
}
