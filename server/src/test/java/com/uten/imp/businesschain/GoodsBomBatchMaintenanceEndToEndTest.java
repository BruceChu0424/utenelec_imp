package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.GoodsBomBatchMaintenanceService;
import com.uten.imp.features.master.goods.GoodsBomService;
import com.uten.imp.features.master.goods.dto.*;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.math.BigDecimal;
import java.util.*;

import static com.uten.imp.features.master.goods.dto.BomBatchMaintenanceRequest.Action.*;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class GoodsBomBatchMaintenanceEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired GoodsBomBatchMaintenanceService batches;
    @Autowired GoodsBomService bom;
    @Autowired JdbcTemplate db;
    UUID actor,employee,session,unit;

    @BeforeEach void before(){
        RequestContextHolder.resetRequestAttributes();
        actor=db.queryForObject("SELECT id FROM users WHERE login_account='full-chain-bootstrap-admin-test'",UUID.class);
        employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);
        session=UUID.randomUUID();login(Set.of("goods:view","goods:bom:edit","goods:bom:create","goods:bom:delete","goods:bom:audit","goods:price:view"),session);
        unit=UUID.randomUUID();db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,'件','使用')",unit,"BOM-BATCH-UNIT-"+unit);
    }
    @AfterEach void after(){RequestContextHolder.resetRequestAttributes();SecurityContextHolder.clearContext();}

    @Test void addSkipsExistingQuantityAuditAndLearningWhilePreviewRollsBackAndCommitHasOneReceipt(){
        UUID a=goods("a"),b=goods("b"),outer=goods("outer"),c=goods("component");
        UUID existing=edge(a,c,"7",1);edge(outer,a,"1",1);
        db.update("INSERT INTO goods_bom_learning_profiles(goods_id,output_unit_id) VALUES(?,?)",a,unit);
        db.update("UPDATE goods_bom_items SET learning_profile_goods_id=?,learning_unit_id=? WHERE id=?",a,unit,existing);
        bom.setAudited(a,existing,true,actor);
        long history=count("goods_operation_history"),outbox=count("business_outbox"),audit=bomAudit();String state=state();
        route("preview");var preview=batches.preview(add(List.of(a,b),line(c,"99")));
        assertEquals(1,preview.added());assertEquals(1,preview.skipped());assertEquals(1,preview.changedTargetCount());
        assertEquals(state,state());assertEquals(history,count("goods_operation_history"));assertEquals(outbox,count("business_outbox"));assertEquals(audit,bomAudit());
        route("commit");var result=batches.commit(confirm(preview));
        assertEquals(1,result.added());assertEquals(1,result.skipped());assertEquals(1,result.affectedProductCount());
        assertEquals(0,new BigDecimal("7").compareTo(bom.list(a).getFirst().getQty()));
        assertNotNull(bom.list(a).getFirst().getAuditedAt());assertTrue(bom.list(a).getFirst().getUsage().systemLearned());
        assertEquals(0,new BigDecimal("99").compareTo(bom.list(b).getFirst().getQty()));
        assertEquals(history+1,count("goods_operation_history"));
        assertEquals("goods:bom:create,goods:bom:edit",lastRequiredPermissions());
        String after=state();long afterOutbox=count("business_outbox");
        assertEquals(result,batches.commit(confirm(preview)));assertEquals(after,state());assertEquals(afterOutbox,count("business_outbox"));
    }

    @Test void removeOnlyTouchesSelectedDirectRelationsAndAllowsDisabledComponentCleanup(){
        UUID a=goods("a"),b=goods("b"),sub=goods("shared-sub"),outer=goods("outer"),c=goods("old");
        UUID direct=edge(a,c,"2",1),nested=edge(sub,c,"3",1);edge(a,sub,"1",2);edge(b,sub,"1",1);edge(outer,a,"1",1);
        db.update("UPDATE goods SET status='禁用' WHERE id=?",c);
        login(Set.of("goods:view","goods:bom:edit","goods:bom:delete"),session);
        route("preview");var preview=batches.preview(new BomBatchMaintenanceRequest(REMOVE,List.of(a,b),null,List.of(c)));
        assertEquals(1,preview.removed());assertEquals(1,preview.skipped());assertEquals(1,preview.otherUsageCount());
        assertTrue(preview.affectedProducts().stream().anyMatch(p->p.goodsId().equals(outer)&&!p.selected()));
        assertFalse(deleted(direct));assertFalse(deleted(nested));
        route("commit");batches.commit(confirm(preview));
        assertTrue(deleted(direct));assertFalse(deleted(nested));assertEquals(1,bom.list(sub).size());
        assertEquals("禁用",db.queryForObject("SELECT status FROM goods WHERE id=?",String.class,c));
        assertEquals("goods:bom:delete,goods:bom:edit",lastRequiredPermissions());
    }

    @Test void overwriteIsSingleTargetPreservesUnchangedIdentityAndReportsActualDifferences(){
        UUID target=goods("overwrite"),keep=goods("keep"),edit=goods("edit"),drop=goods("drop"),fresh=goods("fresh");
        UUID kept=edge(target,keep,"2",1),changed=edge(target,edit,"4",2),removed=edge(target,drop,"1",3);
        db.update("INSERT INTO goods_bom_learning_profiles(goods_id,output_unit_id) VALUES(?,?)",target,unit);
        db.update("UPDATE goods_bom_items SET learning_profile_goods_id=?,learning_unit_id=? WHERE id=?",target,unit,kept);
        bom.setAudited(target,kept,true,actor);bom.setAudited(target,changed,true,actor);
        route("preview");var preview=batches.preview(new BomBatchMaintenanceRequest(OVERWRITE,List.of(target),
                List.of(line(keep,"2"),line(edit,"5"),line(fresh,"3")),null));
        assertEquals(1,preview.added());assertEquals(1,preview.updated());assertEquals(1,preview.removed());assertEquals(1,preview.skipped());
        route("commit");batches.commit(confirm(preview));
        var retained=bom.list(target).stream().filter(row->row.getComponentGoodsId().equals(keep)).findFirst().orElseThrow();
        assertEquals(kept,retained.getId());assertNotNull(retained.getAuditedAt());assertTrue(retained.getUsage().systemLearned());
        assertNull(bom.list(target).stream().filter(row->row.getId().equals(changed)).findFirst().orElseThrow().getAuditedAt());
        assertTrue(deleted(removed));assertEquals("goods:bom:create,goods:bom:delete,goods:bom:edit",lastRequiredPermissions());
        long history=count("goods_operation_history"),events=count("business_outbox");
        route("preview");var unchanged=batches.preview(new BomBatchMaintenanceRequest(OVERWRITE,List.of(target),
                List.of(line(keep,"2"),line(edit,"5"),line(fresh,"3")),null));
        assertEquals(0,unchanged.changedTargetCount());assertEquals(3,unchanged.skipped());
        route("commit");batches.commit(confirm(unchanged));
        assertEquals(history,count("goods_operation_history"));assertEquals(events,count("business_outbox"));
    }

    @Test void staleSharedReferencesAndAConflictingTargetRejectTheWholeBatch(){
        UUID a=goods("a"),b=goods("b"),c=goods("component"),outer=goods("outer");
        var request=add(List.of(a,b),line(c,"1"));var preview=batches.preview(request);
        edge(outer,a,"1",1);
        assertThrows(ApiException.class,()->batches.commit(confirm(preview)));assertTrue(bom.list(a).isEmpty());assertTrue(bom.list(b).isEmpty());
        UUID x=goods("cycle"),y=goods("valid");edge(a,x,"1",1);edge(x,b,"1",1);
        String before=state();
        assertThrows(ApiException.class,()->batches.preview(add(List.of(a,b),line(y,"1"),line(x,"1"))));
        assertEquals(before,state(),"a valid first APPEND group must roll back when the next group creates a cycle");
    }

    @Test void permissionsSessionConfirmationDuplicatesAndEvenSkippedTargetsAreRechecked(){
        UUID a=goods("a"),b=goods("b"),c=goods("component");edge(a,c,"2",1);
        assertThrows(ApiException.class,()->batches.preview(add(List.of(a,a),line(c,"1"))));
        assertThrows(ApiException.class,()->batches.preview(add(List.of(a),line(c,"1"),line(c,"9"))));
        assertThrows(ApiException.class,()->batches.preview(new BomBatchMaintenanceRequest(OVERWRITE,List.of(a,b),List.of(line(c,"1")),null)));
        login(Set.of("goods:view","goods:bom:create"),session);
        assertThrows(AccessDeniedException.class,()->batches.preview(add(List.of(a),line(c,"1"))));
        login(Set.of("goods:view","goods:bom:edit","goods:bom:create"),session);
        var preview=batches.preview(add(List.of(b),line(c,"1")));
        assertThrows(ApiException.class,()->batches.commit(new BomBatchMaintenanceCommit(preview.previewToken(),false)));
        login(Set.of("goods:view","goods:bom:edit","goods:bom:create"),UUID.randomUUID());
        assertThrows(ApiException.class,()->batches.commit(confirm(preview)));
        login(Set.of("goods:view","goods:bom:edit"),session);
        assertThrows(ApiException.class,()->batches.commit(confirm(preview)));
        login(Set.of("goods:view","goods:bom:edit","goods:bom:create","goods:bom:delete"),session);
        db.update("UPDATE goods SET status='禁用' WHERE id=?",a);
        assertThrows(ApiException.class,()->batches.preview(add(List.of(a),line(c,"1"))),"an existing skipped component cannot bypass target validity");
        assertThrows(ApiException.class,()->batches.preview(new BomBatchMaintenanceRequest(REMOVE,List.of(a),null,List.of(b))),"a zero-match removal must still validate the parent");
        assertTrue(bom.list(b).isEmpty());
    }

    @Test void periodicConfirmationAndWeightWarningsReuseTheCanonicalPasteValidation(){
        UUID kg=UUID.randomUUID();db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,'千克','使用')",kg,"BOM-BATCH-KG-"+kg);
        db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES(?,'MASS','KG','MANUAL_GOVERNANCE')",kg);
        UUID a=goods("a"),b=goods("b"),material=UUID.randomUUID();
        db.update("UPDATE goods SET m_weight=.01,m_weight_unit_id=? WHERE id IN(?,?)",kg,a,b);
        db.update("""
                INSERT INTO goods(id,code,name,model,code_sequence,unit_id,source_type,issue_method,periodic_cost_basis,order_multiple_qty)
                VALUES(?,?,?,'',(SELECT COALESCE(max(code_sequence),0)+1 FROM goods),?,'采购','PERIODIC','OWN',25)
                """,material,"BOM-BATCH-PERIODIC-"+material,"期间物料",kg);
        BomItemSaveRequest body=new BomItemSaveRequest();body.setComponentGoodsId(material);body.setUnitWeightGrams(new BigDecimal(".05"));
        ApiException confirm=assertThrows(ApiException.class,()->batches.preview(add(List.of(a,b),body)));
        assertTrue(confirm.getFieldErrors().stream().anyMatch(field->field.field().equals("confirmUnusualWeight")));
        body.setConfirmUnusualWeight(true);var preview=batches.preview(add(List.of(a,b),body));
        assertEquals(2,preview.added());assertEquals(2,preview.warnings().size());assertTrue(bom.list(a).isEmpty());
        batches.commit(confirm(preview));
        assertEquals(0,new BigDecimal(".00005").compareTo(bom.list(a).getFirst().getQty()));assertFalse(bom.list(a).getFirst().isHardGate());
    }

    @Test void actualChangeLimitIsCheckedBeforeAnyAppendGroupWrites(){
        List<UUID> targets=new ArrayList<>();for(int i=0;i<11;i++)targets.add(goods("limit-target"));
        List<BomItemSaveRequest> items=new ArrayList<>();for(int i=0;i<200;i++)items.add(line(goods("limit-component"),"1"));
        String before=state();ApiException error=assertThrows(ApiException.class,()->batches.preview(new BomBatchMaintenanceRequest(ADD,targets,items,null)));
        assertEquals(ErrorCode.VALIDATION_FAILED,error.getCode());assertTrue(error.getMessage().contains("2000"));assertEquals(before,state());
    }

    private BomBatchMaintenanceRequest add(List<UUID> targets,BomItemSaveRequest... items){return new BomBatchMaintenanceRequest(ADD,targets,List.of(items),null);}
    private BomBatchMaintenanceCommit confirm(BomBatchMaintenancePreview preview){return new BomBatchMaintenanceCommit(preview.previewToken(),true);}
    private BomItemSaveRequest line(UUID component,String qty){BomItemSaveRequest body=new BomItemSaveRequest();body.setComponentGoodsId(component);body.setQty(new BigDecimal(qty));return body;}
    private void login(Set<String> grants,UUID sid){AuthUser user=new AuthUser(actor,employee,"bom-batch",grants,false,true,false,false,null,sid);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));}
    private UUID goods(String tag){UUID id=UUID.randomUUID();db.update("INSERT INTO goods(id,code,name,model,code_sequence,unit_id) VALUES(?,?,?,'',(SELECT COALESCE(max(code_sequence),0)+1 FROM goods),?)",id,"BM-"+tag+"-"+id,"批量组装"+tag,unit);return id;}
    private UUID edge(UUID parent,UUID component,String qty,int sort){UUID id=UUID.randomUUID();db.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,sort_order) VALUES(?,?,?,?,?)",id,parent,component,new BigDecimal(qty),sort);return id;}
    private boolean deleted(UUID id){return Boolean.TRUE.equals(db.queryForObject("SELECT is_deleted FROM goods_bom_items WHERE id=?",Boolean.class,id));}
    private void route(String suffix){RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(new MockHttpServletRequest("POST","/api/master/goods/bom/batch-maintenance/"+suffix)));}
    private String state(){return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY id),'[]'::jsonb)::text FROM goods_bom_items b",String.class);}
    private long count(String table){return db.queryForObject("SELECT count(*) FROM "+table,Long.class);}
    private long bomAudit(){return db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type IN('goods','goods_bom_items')",Long.class);}
    private String lastRequiredPermissions(){return db.queryForObject("SELECT array_to_string(required_permissions,',') FROM goods_operation_history WHERE actor_id=? ORDER BY created_at DESC,id DESC LIMIT 1",String.class,actor);}
}
