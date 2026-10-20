package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.GoodsBomEditService;
import com.uten.imp.features.master.goods.GoodsBomService;
import com.uten.imp.features.master.goods.history.GoodsOperationHistoryService;
import com.uten.imp.features.master.goods.dto.BomEditPreview;
import com.uten.imp.features.master.goods.dto.BomEditRequest;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomMoveRequest;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.master.goods.dto.BomEditRequest.Type.*;
import static org.junit.jupiter.api.Assertions.*;

/** Real PostgreSQL proof that autosaved drafts have no canonical effects until confirmation. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
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
class GoodsBomEditEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired GoodsBomEditService edits;
    @Autowired GoodsBomService bom;
    @Autowired GoodsOperationHistoryService history;
    @Autowired JdbcTemplate db;
    UUID actor;
    UUID employee;
    UUID session;

    @BeforeEach void before() {
        actor = db.queryForObject("SELECT id FROM users WHERE login_account='full-chain-bootstrap-admin-test'", UUID.class);
        employee = db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);
        session = UUID.randomUUID();
        login(Set.of("goods:view", "goods:bom:edit", "goods:bom:create", "goods:bom:delete", "goods:bom:audit"), session);
    }
    @AfterEach void after() {
        RequestContextHolder.resetRequestAttributes();
        SecurityContextHolder.clearContext();
        // Evidence and fixtures deliberately remain in this disposable container.
    }

    @Test void previewRollsBackRecipeOutboxAuditAndHistoryThenNestedCommitIsSharedAndRetryIsInert() {
        UUID root=goods("root"), other=goods("other"), shared=goods("shared"), leaf=goods("leaf");
        edge(root,shared); edge(other,shared);
        UUID temp=UUID.randomUUID();
        BomEditRequest request=draft(List.of(create(shared,temp,leaf)),root,shared);
        String canonical=canonicalState();
        long outbox=count("business_outbox"), audit=bomAuditCount(), history=count("goods_operation_history");
        route(root,"preview");
        BomEditPreview preview=edits.preview(root,request);
        assertEquals(1,preview.otherUsageCount());
        assertEquals(canonical,canonicalState());
        assertEquals(outbox,count("business_outbox"));
        assertEquals(audit,bomAuditCount());
        assertEquals(history,count("goods_operation_history"));
        assertTrue(bom.list(shared).isEmpty());
        route(root,"commit");
        var committed=edits.commit(root,confirmed(request,preview));
        assertEquals(leaf,bom.list(shared).getFirst().getComponentGoodsId());
        assertEquals(shared,bom.list(root).getFirst().getComponentGoodsId());
        assertEquals(shared,bom.list(other).getFirst().getComponentGoodsId());
        assertNotEquals(temp,committed.itemIds().get(temp));
        assertEquals(history+1,count("goods_operation_history"));
        String after=canonicalState();
        long afterOutbox=count("business_outbox");
        assertEquals(committed,edits.commit(root,confirmed(request,preview)));
        assertEquals(after,canonicalState());
        assertEquals(afterOutbox,count("business_outbox"));
    }

    @Test void nestedUpdateResetsOnlyChangedAuditAndPreservesQuantityAndSourceIdentity() {
        UUID root=goods("root"), shared=goods("shared"), leaf=goods("leaf"), keep=goods("keep");
        edge(root,shared); UUID changing=edge(shared,leaf), untouched=edge(shared,keep);
        bom.setAudited(shared,changing,true,actor); bom.setAudited(shared,untouched,true,actor);
        BomEditRequest request=draft(List.of(update(shared,changing,leaf,"2.5")),root,shared);
        var preview=edits.preview(root,request);
        edits.commit(root,confirmed(request,preview));
        var rows=bom.list(shared);
        var changed=rows.stream().filter(row->row.getId().equals(changing)).findFirst().orElseThrow();
        assertEquals(0,new BigDecimal("2.5").compareTo(changed.getQty()));
        assertNull(changed.getAuditedAt());
        assertNotNull(rows.stream().filter(row->row.getId().equals(untouched)).findFirst().orElseThrow().getAuditedAt());
        assertEquals(changing,db.queryForObject("SELECT id FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",UUID.class,shared,leaf));
    }

    @Test void createsCanOpenANewSubtreeAndTemporaryIdsSurviveMoveAndFurtherUpdate() {
        UUID root=goods("root"), sub=goods("sub"), leaf=goods("leaf");
        UUID subTemp=UUID.randomUUID(), leafTemp=UUID.randomUUID();
        BomMoveRequest.Move move=new BomMoveRequest.Move(); move.setItemId(leafTemp); move.setTargetParentGoodsId(sub);
        BomEditRequest request=draft(List.of(create(root,subTemp,sub),create(root,leafTemp,leaf),
                new BomEditRequest.Operation(MOVE,null,null,null,null,null,List.of(move)),
                update(sub,leafTemp,leaf,"3")),root,sub);
        var preview=edits.preview(root,request);
        var result=edits.commit(root,confirmed(request,preview));
        assertEquals(List.of(sub),bom.list(root).stream().map(row->row.getComponentGoodsId()).toList());
        assertEquals(0,new BigDecimal("3").compareTo(bom.list(sub).getFirst().getQty()));
        assertEquals(bom.list(sub).getFirst().getId(),result.itemIds().get(leafTemp));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND is_deleted",Integer.class,root,leaf));
    }

    @Test void staleContentAndNewExternalUsageRejectWholeCommit() {
        UUID root=goods("root"), shared=goods("shared"), leaf=goods("leaf"), other=goods("other");
        edge(root,shared); UUID row=edge(shared,leaf);
        BomEditRequest request=draft(List.of(update(shared,row,leaf,"2")),root,shared);
        var preview=edits.preview(root,request);
        edge(other,shared);
        assertThrows(ApiException.class,()->edits.commit(root,confirmed(request,preview)));
        assertEquals(0,BigDecimal.ONE.compareTo(bom.list(shared).getFirst().getQty()));
        BomEditRequest fresh=draft(List.of(update(shared,row,leaf,"4")),root,shared);
        var freshPreview=edits.preview(root,fresh);
        db.update("UPDATE goods_bom_items SET qty=9 WHERE id=?",row);
        assertThrows(ApiException.class,()->edits.commit(root,confirmed(fresh,freshPreview)));
        assertEquals(0,new BigDecimal("9").compareTo(bom.list(shared).getFirst().getQty()));
    }

    @Test void cycleAndMissingSnapshotAfterEarlierValidOperationLeaveNoWrites() {
        UUID root=goods("root"), shared=goods("shared"), leaf=goods("leaf"); edge(root,shared);
        String initial=canonicalState();
        BomEditRequest cycle=draft(List.of(create(shared,UUID.randomUUID(),leaf),create(shared,UUID.randomUUID(),root)),root,shared);
        assertThrows(ApiException.class,()->edits.preview(root,cycle));
        assertEquals(initial,canonicalState());
        BomEditRequest missing=draft(List.of(create(root,UUID.randomUUID(),leaf),create(shared,UUID.randomUUID(),leaf)),root);
        assertThrows(ApiException.class,()->edits.preview(root,missing));
        assertEquals(initial,canonicalState());
    }

    @Test void confirmationSessionAndRevokedSplitPermissionAreEnforcedAtCommit() {
        UUID root=goods("root"), leaf=goods("leaf");
        BomEditRequest request=draft(List.of(create(root,UUID.randomUUID(),leaf)),root);
        var preview=edits.preview(root,request);
        assertThrows(ApiException.class,()->edits.commit(root,new BomEditRequest(request.operations(),request.snapshots(),preview.previewToken(),false)));
        login(Set.of("goods:view","goods:bom:edit","goods:bom:create"),UUID.randomUUID());
        assertThrows(ApiException.class,()->edits.commit(root,confirmed(request,preview)));
        login(Set.of("goods:view","goods:bom:edit"),session);
        assertThrows(ApiException.class,()->edits.commit(root,confirmed(request,preview)));
        assertTrue(bom.list(root).isEmpty());
        login(Set.of("goods:view","goods:bom:create"),session);
        assertThrows(org.springframework.security.access.AccessDeniedException.class,
                ()->edits.commit(root,confirmed(request,preview)));
        login(Set.of("goods:view","goods:bom:edit","goods:bom:create"),session);
        edits.commit(root,confirmed(request,preview));
        assertEquals(1,bom.list(root).size());
    }

    @Test void batchDeleteAcrossParentsAndCreateThenDeleteTemporaryRowAreAtomic() {
        UUID root=goods("root"), shared=goods("shared"), a=goods("a"), b=goods("b"), transientLeaf=goods("temp");
        edge(root,shared); UUID ra=edge(root,a), rb=edge(shared,b); UUID temp=UUID.randomUUID();
        BomEditRequest request=draft(List.of(create(shared,temp,transientLeaf),
                new BomEditRequest.Operation(DELETE,null,null,null,null,List.of(ra,rb,temp),null)),root,shared);
        var preview=edits.preview(root,request);
        edits.commit(root,confirmed(request,preview));
        assertEquals(List.of(shared),bom.list(root).stream().map(row->row.getComponentGoodsId()).toList());
        assertTrue(bom.list(shared).isEmpty());
    }

    @Test void parentOutsideCurrentTreeCannotBeSmuggledThroughAnUnchangedSnapshot() {
        UUID root=goods("root"), unrelated=goods("other"), leaf=goods("leaf");
        BomEditRequest request=draft(List.of(create(unrelated,UUID.randomUUID(),leaf)),root,unrelated);
        assertThrows(ApiException.class,()->edits.preview(root,request));
        assertTrue(bom.list(unrelated).isEmpty());
    }

    @Test void nestedPeriodicWeightWarningsReachPreviewAndOnlyDescribeTheFinalDraftValue() {
        UUID kg=UUID.randomUUID();
        db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,'千克','使用')",kg,"ED-KG-"+kg);
        db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES(?,'MASS','KG','MANUAL_GOVERNANCE')",kg);
        UUID root=goods("root"), shared=goods("shared"), material=UUID.randomUUID();
        db.update("UPDATE goods SET m_weight=.01,m_weight_unit_id=? WHERE id=?",kg,shared);
        // Seed its initial identity directly. Changing an existing goods' issue method must use its governed command.
        db.update("""
                INSERT INTO goods(id,code,name,model,code_sequence,unit_id,source_type,
                                  issue_method,periodic_cost_basis,order_multiple_qty)
                VALUES(?,?,?,'',(SELECT COALESCE(max(code_sequence),0)+1 FROM goods),?,'采购','PERIODIC','OWN',25)
                """,material,"ED-PERIODIC-"+material,"组装编辑期间物料",kg);
        edge(root,shared);
        UUID temp=UUID.randomUUID();
        BomItemSaveRequest first=new BomItemSaveRequest();
        first.setComponentGoodsId(material); first.setUnitWeightGrams(new BigDecimal("12.5"));
        var create=new BomEditRequest.Operation(CREATE,shared,null,temp,first,null,null);
        BomEditRequest initial=draft(List.of(create),root,shared);
        var initialPreview=edits.preview(root,initial);
        assertEquals(1,initialPreview.warnings().size());
        assertTrue(initialPreview.warnings().getFirst().contains("25%"));
        assertTrue(bom.list(shared).isEmpty(),"a warning preview must still roll back all recipe writes");
        BomItemSaveRequest edited=new BomItemSaveRequest();
        edited.setComponentGoodsId(material); edited.setUnitWeightGrams(new BigDecimal("15"));
        BomEditRequest updated=new BomEditRequest(List.of(create,
                new BomEditRequest.Operation(UPDATE,shared,temp,null,edited,null,null)),initial.snapshots(),null,null);
        var updatedPreview=edits.preview(root,updated);
        assertEquals(1,updatedPreview.warnings().size());
        assertTrue(updatedPreview.warnings().getFirst().contains("50%"));
        assertFalse(updatedPreview.warnings().getFirst().contains("12.5"),"an intermediate draft warning must not survive a later edit");
        edits.commit(root,confirmed(updated,updatedPreview));
        assertEquals(0,new BigDecimal(".015").compareTo(bom.list(shared).getFirst().getQty()));
        BomItemSaveRequest matching=new BomItemSaveRequest();
        matching.setComponentGoodsId(material); matching.setUnitWeightGrams(BigDecimal.TEN);
        BomEditRequest corrected=draft(List.of(new BomEditRequest.Operation(UPDATE,shared,
                bom.list(shared).getFirst().getId(),null,matching,null,null)),root,shared);
        assertTrue(edits.preview(root,corrected).warnings().isEmpty());
    }

    @Test void editOnlyCrossParentMoveRetainsItsExactPermissionForUndoAndRedo() {
        UUID root=goods("root"), sub=goods("sub"), leaf=goods("leaf");
        edge(root,sub); UUID oldEdge=edge(root,leaf);
        login(Set.of("goods:view","goods:bom:edit"),session);
        BomMoveRequest.Move move=new BomMoveRequest.Move(); move.setItemId(oldEdge); move.setTargetParentGoodsId(sub);
        BomEditRequest request=draft(List.of(new BomEditRequest.Operation(MOVE,null,null,null,null,null,List.of(move))),root,sub);
        var preview=edits.preview(root,request);
        route(root,"commit"); edits.commit(root,confirmed(request,preview));
        var entry=history.list().entries().getFirst();
        assertTrue(entry.canUndo(),entry.blockedReason());
        assertEquals("goods:bom:edit",db.queryForObject("SELECT array_to_string(required_permissions,',') FROM goods_operation_history WHERE id=?",String.class,entry.id()));
        historyRoute(entry.id(),"undo");
        var undone=history.undo(entry.id(),entry.version()).entries().stream().filter(e->e.id().equals(entry.id())).findFirst().orElseThrow();
        assertTrue(undone.canRedo(),undone.blockedReason());
        assertTrue(bom.list(root).stream().anyMatch(row->row.getId().equals(oldEdge)));
        assertTrue(bom.list(sub).isEmpty());
        historyRoute(entry.id(),"redo"); history.redo(entry.id(),undone.version());
        assertEquals(List.of(sub),bom.list(root).stream().map(row->row.getComponentGoodsId()).toList());
        assertEquals(leaf,bom.list(sub).getFirst().getComponentGoodsId());
    }

    @Test void actualCreateAndDeleteCommandsStillRequireTheirOriginalSplitPermissionForHistory() {
        UUID createRoot=goods("create-root"), createdLeaf=goods("new"), deleteRoot=goods("delete-root"), deletedLeaf=goods("old");
        UUID oldEdge=edge(deleteRoot,deletedLeaf);
        BomEditRequest creating=draft(List.of(create(createRoot,UUID.randomUUID(),createdLeaf)),createRoot);
        var creatingPreview=edits.preview(createRoot,creating);
        route(createRoot,"commit"); edits.commit(createRoot,confirmed(creating,creatingPreview));
        login(Set.of("goods:view","goods:bom:edit"),session);
        var createEntry=history.list().entries().getFirst();
        assertFalse(createEntry.canUndo()); assertTrue(createEntry.blockedReason().contains("goods:bom:create"));
        historyRoute(createEntry.id(),"undo");
        assertThrows(ApiException.class,()->history.undo(createEntry.id(),createEntry.version()));
        login(Set.of("goods:view","goods:bom:edit","goods:bom:delete"),session);
        BomEditRequest deleting=draft(List.of(new BomEditRequest.Operation(DELETE,null,oldEdge,null,null,null,null)),deleteRoot);
        var deletingPreview=edits.preview(deleteRoot,deleting);
        route(deleteRoot,"commit"); edits.commit(deleteRoot,confirmed(deleting,deletingPreview));
        login(Set.of("goods:view","goods:bom:edit"),session);
        var deleteEntry=history.list().entries().getFirst();
        assertFalse(deleteEntry.canUndo()); assertTrue(deleteEntry.blockedReason().contains("goods:bom:delete"));
        historyRoute(deleteEntry.id(),"undo");
        assertThrows(ApiException.class,()->history.undo(deleteEntry.id(),deleteEntry.version()));
        assertTrue(bom.list(deleteRoot).isEmpty());
        assertEquals(1,bom.list(createRoot).size());
    }

    @Test void simultaneousCommitsFromTheSameOriginalSnapshotPublishExactlyOneRecipeChange() throws Exception {
        UUID root=goods("race-root"), a=goods("race-a"), b=goods("race-b");
        BomEditRequest first=draft(List.of(create(root,UUID.randomUUID(),a)),root);
        BomEditRequest second=draft(List.of(create(root,UUID.randomUUID(),b)),root);
        var firstPreview=edits.preview(root,first); var secondPreview=edits.preview(root,second);
        AuthUser user=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var start=new java.util.concurrent.CountDownLatch(1);
        try(var workers=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var firstResult=workers.submit(()->raceCommit(user,root,confirmed(first,firstPreview),start));
            var secondResult=workers.submit(()->raceCommit(user,root,confirmed(second,secondPreview),start));
            start.countDown();
            boolean firstSaved=firstResult.get(30,java.util.concurrent.TimeUnit.SECONDS);
            boolean secondSaved=secondResult.get(30,java.util.concurrent.TimeUnit.SECONDS);
            assertNotEquals(firstSaved,secondSaved,"the losing snapshot must conflict, never merge implicitly or overwrite");
        }
        assertEquals(1,bom.list(root).size());
    }

    private boolean raceCommit(AuthUser user,UUID root,BomEditRequest request,
                               java.util.concurrent.CountDownLatch start) throws InterruptedException {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
        try {
            assertTrue(start.await(10,java.util.concurrent.TimeUnit.SECONDS));
            try { edits.commit(root,request); return true; }
            catch(ApiException conflict) {
                assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,conflict.getCode());
                return false;
            }
        } finally { SecurityContextHolder.clearContext(); }
    }

    private void login(Set<String> grants,UUID sid) {
        AuthUser user=new AuthUser(actor,employee,"bom-edit-test",grants,false,true,false,false,null,sid);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
    }
    private void route(UUID root,String suffix) {
        MockHttpServletRequest request=new MockHttpServletRequest("POST","/api/master/goods/"+root+"/bom/edit/"+suffix);
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
    }
    private void historyRoute(UUID operation,String action) {
        MockHttpServletRequest request=new MockHttpServletRequest("POST","/api/master/goods/history/"+operation+"/"+action);
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
    }
    private UUID goods(String tag) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO goods(id,code,name,model,code_sequence) VALUES(?,?,?,'',(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))",
                id,"ED-"+tag+"-"+UUID.randomUUID().toString().substring(0,8),"组装编辑测试"+tag);
        return id;
    }
    private UUID edge(UUID parent,UUID component) {
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,sort_order) VALUES(?,?,?,1,0)",id,parent,component);
        return id;
    }
    private BomEditRequest draft(List<BomEditRequest.Operation> operations,UUID... parents) {
        List<BomEditRequest.Snapshot> snapshots=java.util.Arrays.stream(parents)
                .map(id->new BomEditRequest.Snapshot(id,edits.snapshot(id).fingerprint())).toList();
        return new BomEditRequest(operations,snapshots,null,null);
    }
    private static BomEditRequest.Operation create(UUID parent,UUID temporary,UUID component) {
        return new BomEditRequest.Operation(CREATE,parent,null,temporary,body(component,"1"),null,null);
    }
    private static BomEditRequest.Operation update(UUID parent,UUID id,UUID component,String qty) {
        return new BomEditRequest.Operation(UPDATE,parent,id,null,body(component,qty),null,null);
    }
    private static BomItemSaveRequest body(UUID component,String qty) {
        BomItemSaveRequest body=new BomItemSaveRequest(); body.setComponentGoodsId(component); body.setQty(new BigDecimal(qty)); return body;
    }
    private static BomEditRequest confirmed(BomEditRequest request,BomEditPreview preview) {
        return new BomEditRequest(request.operations(),request.snapshots(),preview.previewToken(),true);
    }
    private long count(String table) { return db.queryForObject("SELECT count(*) FROM "+table,Long.class); }
    private long bomAuditCount() {
        return db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type IN ('goods','goods_bom_items')",Long.class);
    }
    private String canonicalState() {
        return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.id),'[]'::jsonb)::text FROM goods_bom_items b",String.class);
    }
}
