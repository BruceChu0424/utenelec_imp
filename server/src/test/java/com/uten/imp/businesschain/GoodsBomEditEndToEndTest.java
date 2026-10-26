package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.GoodsBomEditService;
import com.uten.imp.features.master.goods.GoodsService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.test.util.ReflectionTestUtils;
import com.uten.imp.features.master.goods.GoodsBomService;
import com.uten.imp.features.master.goods.history.GoodsOperationHistoryService;
import com.uten.imp.features.master.goods.dto.BomEditPreview;
import com.uten.imp.features.master.goods.dto.BomEditRequest;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomMoveRequest;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
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
    @Autowired GoodsService goodsService;
    @Autowired ObjectMapper mapper;
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

    @Test void unchangedHistoricalNullStatusSurvivesBomPreviewCommitUndoAndRedo() {
        login(Set.of("goods:view","goods:edit","goods:bom:edit"),session);
        UUID root=editableGoods("unknown-status-root"),shared=editableGoods("unknown-status-shared");
        edge(root,shared);
        assertNull(db.queryForObject("SELECT status FROM goods WHERE id=?",String.class,shared));
        var snapshot=edits.snapshot(shared);
        var request=draft(List.of(updateGoods(shared,snapshot.goods().version(),
                Map.of("model",mapper.valueToTree("unknown-status-edit")))),root,shared);
        route(root,"preview");var preview=edits.preview(root,request);
        assertEquals("",db.queryForObject("SELECT model FROM goods WHERE id=?",String.class,shared));
        assertNull(db.queryForObject("SELECT status FROM goods WHERE id=?",String.class,shared));
        route(root,"commit");edits.commit(root,confirmed(request,preview));
        assertEquals("unknown-status-edit",db.queryForObject("SELECT model FROM goods WHERE id=?",String.class,shared));
        assertNull(db.queryForObject("SELECT status FROM goods WHERE id=?",String.class,shared));
        var operation=history.list().entries().getFirst();
        historyRoute(operation.id(),"undo");
        var undone=history.undo(operation.id(),operation.version()).entries().stream()
                .filter(entry->entry.id().equals(operation.id())).findFirst().orElseThrow();
        assertEquals("",db.queryForObject("SELECT model FROM goods WHERE id=?",String.class,shared));
        assertNull(db.queryForObject("SELECT status FROM goods WHERE id=?",String.class,shared));
        historyRoute(operation.id(),"redo");history.redo(operation.id(),undone.version());
        assertEquals("unknown-status-edit",db.queryForObject("SELECT model FROM goods WHERE id=?",String.class,shared));
        assertNull(db.queryForObject("SELECT status FROM goods WHERE id=?",String.class,shared));
    }

    @Test void aKnownStatusCannotBeClearedAndCreationStillRejectsExplicitNull() {
        login(Set.of("goods:view","goods:edit","goods:create","goods:status"),session);
        UUID id=editableGoods("known-status");
        db.update("UPDATE goods SET status='使用' WHERE id=?",id);
        long version=db.queryForObject("SELECT version FROM goods WHERE id=?",Long.class,id);
        long before=count("goods_operation_history"),goodsCount=count("goods");
        var request=new GoodsSaveRequest();
        request.setCategoryId(db.queryForObject("SELECT category_id FROM goods WHERE id=?",UUID.class,id));
        request.setName(db.queryForObject("SELECT name FROM goods WHERE id=?",String.class,id));
        request.setCode(db.queryForObject("SELECT code FROM goods WHERE id=?",String.class,id));
        request.setStatus(null);
        ApiException rejected=assertThrows(ApiException.class,()->goodsService.update(id,request));
        assertEquals(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,rejected.getCode());
        assertEquals("使用",db.queryForObject("SELECT status FROM goods WHERE id=?",String.class,id));
        assertEquals(version,db.queryForObject("SELECT version FROM goods WHERE id=?",Long.class,id));
        request.setCode("NULL-CREATE-"+UUID.randomUUID());
        ApiException createRejected=assertThrows(ApiException.class,()->goodsService.create(request));
        assertEquals(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,createRejected.getCode());
        assertEquals(goodsCount,count("goods"));assertEquals(before,count("goods_operation_history"));
    }

    @Test void masterCellsAndRecipePublishTogetherAfterRollbackOnlySharedPreviewAndHistoryRetainsGoodsEdit() {
        login(Set.of("goods:view","goods:edit","goods:purchase:edit","goods:bom:edit"),session);
        UUID root=editableGoods("master-root"), other=goods("master-other"), shared=editableGoods("master-shared");
        UUID row=edge(root,shared); edge(other,shared);
        db.update("UPDATE goods SET model='old-model',spec='old-spec',material='old-material',source_type='采购',price=37.1234,source_e=5.4321 WHERE id=?",shared);
        var snapshot=edits.snapshot(shared);
        assertTrue(snapshot.goods().componentGoodsWritable());
        assertEquals(shared,snapshot.goods().id());
        BomEditRequest request=draft(List.of(update(root,row,shared,"2.5"),
                updateGoods(shared,snapshot.goods().version(),Map.of(
                        "model",mapper.valueToTree("new-model"),"spec",mapper.valueToTree("new-spec"),
                        "material",mapper.valueToTree("new-material"),"sourceType",mapper.valueToTree("委外")))),root,shared);
        String before=masterState(shared), recipeBefore=canonicalState();
        long historyBefore=count("goods_operation_history"), auditBefore=bomAuditCount();
        route(root,"preview");
        var preview=edits.preview(root,request);
        assertEquals(1,preview.otherUsageCount());
        assertTrue(preview.affectedParents().stream().anyMatch(parent->parent.goodsId().equals(shared)));
        assertEquals(before,masterState(shared)); assertEquals(recipeBefore,canonicalState());
        assertEquals(historyBefore,count("goods_operation_history")); assertEquals(auditBefore,bomAuditCount());
        route(root,"commit");
        var result=edits.commit(root,confirmed(request,preview));
        assertEquals("new-model",db.queryForObject("SELECT model FROM goods WHERE id=?",String.class,shared));
        assertEquals("new-spec",db.queryForObject("SELECT spec FROM goods WHERE id=?",String.class,shared));
        assertEquals("new-material",db.queryForObject("SELECT material FROM goods WHERE id=?",String.class,shared));
        assertEquals("委外",db.queryForObject("SELECT source_type FROM goods WHERE id=?",String.class,shared));
        assertEquals(0,new BigDecimal("2.5").compareTo(bom.list(root).getFirst().getQty()));
        assertEquals(0,new BigDecimal("37.1234").compareTo(db.queryForObject("SELECT price FROM goods WHERE id=?",BigDecimal.class,shared)));
        assertEquals(0,new BigDecimal("5.4321").compareTo(db.queryForObject("SELECT source_e FROM goods WHERE id=?",BigDecimal.class,shared)));
        assertEquals(historyBefore+1,count("goods_operation_history"));
        String after=masterState(shared), recipeAfter=canonicalState();
        assertEquals(result,edits.commit(root,confirmed(request,preview)));
        assertEquals(after,masterState(shared)); assertEquals(recipeAfter,canonicalState());
        var historyEntry=history.list().entries().getFirst();
        assertEquals("goods:bom:edit,goods:edit",db.queryForObject(
                "SELECT array_to_string(required_permissions,',') FROM goods_operation_history WHERE id=?",String.class,historyEntry.id()));
        login(Set.of("goods:view","goods:bom:edit"),session);
        var blocked=history.list().entries().stream().filter(entry->entry.id().equals(historyEntry.id())).findFirst().orElseThrow();
        assertFalse(blocked.canUndo()); assertTrue(blocked.blockedReason().contains("goods:edit"));
        login(Set.of("goods:view","goods:edit","goods:purchase:edit","goods:bom:edit"),session);
        historyRoute(historyEntry.id(),"undo");
        var undone=history.undo(historyEntry.id(),historyEntry.version()).entries().stream()
                .filter(entry->entry.id().equals(historyEntry.id())).findFirst().orElseThrow();
        assertEquals("old-model",db.queryForObject("SELECT model FROM goods WHERE id=?",String.class,shared));
        assertEquals("old-spec",db.queryForObject("SELECT spec FROM goods WHERE id=?",String.class,shared));
        assertEquals("old-material",db.queryForObject("SELECT material FROM goods WHERE id=?",String.class,shared));
        assertEquals("采购",db.queryForObject("SELECT source_type FROM goods WHERE id=?",String.class,shared));
        assertEquals(0,BigDecimal.ONE.compareTo(bom.list(root).getFirst().getQty()));
        assertTrue(undone.canRedo(),undone.blockedReason());
        historyRoute(historyEntry.id(),"redo"); history.redo(historyEntry.id(),undone.version());
        assertEquals("new-model",db.queryForObject("SELECT model FROM goods WHERE id=?",String.class,shared));
        assertEquals("new-spec",db.queryForObject("SELECT spec FROM goods WHERE id=?",String.class,shared));
        assertEquals("new-material",db.queryForObject("SELECT material FROM goods WHERE id=?",String.class,shared));
        assertEquals("委外",db.queryForObject("SELECT source_type FROM goods WHERE id=?",String.class,shared));
        assertEquals(0,new BigDecimal("2.5").compareTo(bom.list(root).getFirst().getQty()));
    }

    @Test void masterOnlyEditHasSharedImpactWithoutInventingAnyRecipeOperations() {
        login(Set.of("goods:view","goods:edit","goods:bom:edit"),session);
        UUID root=editableGoods("master-only-root"),other=goods("master-only-other"),shared=editableGoods("master-only-shared");
        edge(root,shared);edge(other,shared);
        var snapshot=edits.snapshot(shared);
        var request=draft(List.of(updateGoods(shared,snapshot.goods().version(),Map.of("model",mapper.valueToTree("master-only-new")))),root,shared);
        String recipeBefore=canonicalState();
        route(root,"preview");var preview=edits.preview(root,request);
        assertEquals(1,preview.operationCount());assertEquals(1,preview.otherUsageCount());
        assertEquals(List.of(shared),preview.affectedParents().stream().map(BomEditPreview.AffectedParent::goodsId).toList());
        assertEquals("",db.queryForObject("SELECT model FROM goods WHERE id=?",String.class,shared));
        route(root,"commit");edits.commit(root,confirmed(request,preview));
        assertEquals(recipeBefore,canonicalState());
        assertEquals("master-only-new",db.queryForObject("SELECT model FROM goods WHERE id=?",String.class,shared));
    }

    @Test void ownRecipeCostVersionAdvanceDoesNotInvalidateAnAlreadyProvedMasterBaseline() {
        login(Set.of("goods:view","goods:edit","goods:bom:edit"),session);
        UUID root=editableGoods("master-same-root"),shared=editableGoods("master-same-shared"),leaf=goods("master-same-leaf");
        edge(root,shared);UUID row=edge(shared,leaf);
        db.update("UPDATE goods SET price=3 WHERE id=?",leaf);
        var snapshot=edits.snapshot(shared);
        var request=draft(List.of(update(shared,row,leaf,"5"),updateGoods(shared,snapshot.goods().version(),
                Map.of("spec",mapper.valueToTree("same-draft-spec")))),root,shared);
        route(root,"preview");var preview=edits.preview(root,request);
        assertEquals(0,BigDecimal.ONE.compareTo(bom.list(shared).getFirst().getQty()));
        route(root,"commit");edits.commit(root,confirmed(request,preview));
        assertEquals(0,new BigDecimal("5").compareTo(bom.list(shared).getFirst().getQty()));
        assertEquals("same-draft-spec",db.queryForObject("SELECT spec FROM goods WHERE id=?",String.class,shared));
    }
    @Test void masterOnlyChangeRequiresGoodsEditAndRechecksItBeforeAnyMixedCommit() {
        UUID root=editableGoods("master-auth-root"), shared=editableGoods("master-auth-shared");
        UUID row=edge(root,shared);
        assertFalse(edits.snapshot(shared).goods().componentGoodsWritable());
        long version=edits.snapshot(shared).goods().version();
        BomEditRequest request=draft(List.of(update(root,row,shared,"8"),
                updateGoods(shared,version,Map.of("model",mapper.valueToTree("denied")))),root,shared);
        String before=masterState(shared),recipeBefore=canonicalState();
        route(root,"preview");
        assertThrows(ApiException.class,()->edits.preview(root,request));
        assertEquals(before,masterState(shared)); assertEquals(recipeBefore,canonicalState());
        login(Set.of("goods:view","goods:edit","goods:bom:edit"),session);
        var preview=edits.preview(root,request);
        login(Set.of("goods:view","goods:bom:edit"),session);
        route(root,"commit");
        assertThrows(ApiException.class,()->edits.commit(root,confirmed(request,preview)));
        assertEquals(before,masterState(shared)); assertEquals(recipeBefore,canonicalState());
        login(Set.of("goods:bom:edit"),session);
        assertNull(edits.snapshot(shared).goods(),"BOM permission alone does not disclose editable master snapshots");
    }

    @Test void masterVersionAndFingerprintRejectConcurrentChangesInsteadOfAdoptingTheCurrentVersion() {
        login(Set.of("goods:view","goods:edit","goods:bom:edit"),session);
        UUID root=editableGoods("master-stale-root"), shared=editableGoods("master-stale-shared"); edge(root,shared);
        long version=edits.snapshot(shared).goods().version();
        var operation=updateGoods(shared,version,Map.of("spec",mapper.valueToTree("draft-spec")));
        db.update("UPDATE goods SET version=version+1 WHERE id=?",shared);
        BomEditRequest staleVersion=draft(List.of(operation),root,shared);
        assertThrows(ApiException.class,()->edits.preview(root,staleVersion),"even a new fingerprint cannot replace the original goods version");
        long current=edits.snapshot(shared).goods().version();
        BomEditRequest request=draft(List.of(updateGoods(shared,current,Map.of("spec",mapper.valueToTree("reviewed")))),root,shared);
        var preview=edits.preview(root,request);
        db.update("UPDATE goods SET model='concurrent-direct-model' WHERE id=?",shared);
        assertThrows(ApiException.class,()->edits.commit(root,confirmed(request,preview)),"the fingerprint also binds fields modified by non-JPA writers");
        assertEquals("concurrent-direct-model",db.queryForObject("SELECT model FROM goods WHERE id=?",String.class,shared));
        assertNull(db.queryForObject("SELECT spec FROM goods WHERE id=?",String.class,shared));
    }

    @Test void unrelatedMasterCannotBeEditedBySupplyingItsSnapshotAndValidVersion() {
        login(Set.of("goods:view","goods:edit","goods:bom:edit"),session);
        UUID root=editableGoods("master-scope-root"), unrelated=editableGoods("master-unrelated");
        var snapshot=edits.snapshot(unrelated);
        BomEditRequest request=draft(List.of(updateGoods(unrelated,snapshot.goods().version(),
                Map.of("model",mapper.valueToTree("must-not-write")))),root,unrelated);
        String before=masterState(unrelated);
        assertThrows(ApiException.class,()->edits.preview(root,request));
        assertEquals(before,masterState(unrelated));
    }

    @Test void masterPatchRejectsUnknownFieldsMissingVersionsStructuredValuesAndDuplicateTargets() {
        login(Set.of("goods:view","goods:edit","goods:bom:edit"),session);
        UUID root=editableGoods("master-invalid-root"), shared=editableGoods("master-invalid-shared"); edge(root,shared);
        long version=edits.snapshot(shared).goods().version();
        String before=masterState(shared);
        for(String field:List.of("code","stockQty","price","categoryId","colorId","version")) {
            BomEditRequest request=draft(List.of(updateGoods(shared,version,Map.of(field,mapper.valueToTree("unexpected")))),root,shared);
            assertThrows(ApiException.class,()->edits.preview(root,request),field);
        }
        BomEditRequest missing=draft(List.of(updateGoods(shared,null,Map.of("model",mapper.valueToTree("missing-version")))),root,shared);
        assertThrows(ApiException.class,()->edits.preview(root,missing));
        BomEditRequest structured=draft(List.of(updateGoods(shared,version,Map.of("spec",mapper.valueToTree(Map.of("nested","bad"))))),root,shared);
        assertThrows(ApiException.class,()->edits.preview(root,structured));
        var patch=updateGoods(shared,version,Map.of("model",mapper.valueToTree("duplicate")));
        assertThrows(ApiException.class,()->edits.preview(root,draft(List.of(patch,patch),root,shared)));
        assertEquals(before,masterState(shared));
    }

    @Test void viewOnlyOwnershipGrantNeverMakesTheMasterCellsWritable() {
        login(Set.of("goods:view","goods:edit","goods:bom:edit"),session);
        UUID root=editableGoods("master-owner-root"), shared=editableGoods("master-owner-shared"); edge(root,shared);
        UUID owner=UUID.randomUUID();
        UUID department=db.queryForObject("SELECT department_id FROM employees WHERE id=?",UUID.class,employee);
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')",
                owner,"BOM-OWNER-"+owner,"另一个货品负责人",department);
        db.update("UPDATE goods SET owner_employee_id=? WHERE id=?",owner,shared);
        db.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(?,'goods',?)",actor,owner);
        ReflectionTestUtils.setField(goodsService,"goodsOwnerScopeEnabled",true);
        try {
            var snapshot=edits.snapshot(shared);
            assertFalse(snapshot.goods().componentGoodsWritable());
            var request=draft(List.of(updateGoods(shared,snapshot.goods().version(),Map.of("model",mapper.valueToTree("read-only-owner")))),root,shared);
            String before=masterState(shared);
            assertThrows(ApiException.class,()->edits.preview(root,request));
            assertEquals(before,masterState(shared));
        } finally { ReflectionTestUtils.setField(goodsService,"goodsOwnerScopeEnabled",false); }
    }

    private UUID editableGoods(String tag) {
        UUID id=goods(tag),category=UUID.randomUUID();
        db.update("INSERT INTO material_categories(id,code,name) VALUES(?,?,?)",category,"BMC-"+category,"组装单元格测试分类");
        db.update("UPDATE goods SET category_id=? WHERE id=?",category,id);
        return id;
    }
    private BomEditRequest.Operation updateGoods(UUID goods,Long version,Map<String,JsonNode> changes) {
        return new BomEditRequest.Operation(UPDATE_GOODS,goods,null,null,null,null,null,version,changes);
    }
    private String masterState(UUID goods) {
        return db.queryForObject("SELECT to_jsonb(g)::text FROM goods g WHERE id=?",String.class,goods);
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

    @Test void componentReplacementKeepsRelationIdentityAndUsesNewDefaultPriceOnlyAfterCommit() {
        UUID root=goods("replace-root"), other=goods("replace-other"), old=goods("replace-old"), next=goods("replace-new");
        db.update("UPDATE goods SET price=5.5 WHERE id=?",next);
        UUID changed=edge(root,old), retained=edge(other,old);
        db.update("UPDATE goods_bom_items SET qty=3,price=99,total=297 WHERE id=?",changed);
        bom.setAudited(root,changed,true,actor);
        BomEditRequest request=draft(List.of(update(root,changed,next,"3")),root);
        String before=canonicalState();
        long historyBefore=count("goods_operation_history");
        route(root,"preview");
        var preview=edits.preview(root,request);
        assertEquals(before,canonicalState(),"preview cannot replace the canonical component");
        assertEquals(historyBefore,count("goods_operation_history"));

        route(root,"commit");
        edits.commit(root,confirmed(request,preview));

        var view=bom.list(root).getFirst();
        assertEquals(changed,view.getId());
        assertEquals(next,view.getComponentGoodsId());
        assertEquals(0,new BigDecimal("3").compareTo(view.getQty()));
        assertNull(view.getAuditedAt());
        assertNull(view.getPrice(),"a component picker cannot grant private-price access");
        assertEquals(0,new BigDecimal("5.5").compareTo(db.queryForObject(
                "SELECT price FROM goods_bom_items WHERE id=?",BigDecimal.class,changed)));
        assertEquals(0,new BigDecimal("16.5").compareTo(db.queryForObject(
                "SELECT total FROM goods_bom_items WHERE id=?",BigDecimal.class,changed)));
        assertEquals(old,db.queryForObject("SELECT component_goods_id FROM goods_bom_items WHERE id=?",UUID.class,retained));
        assertEquals(historyBefore+1,count("goods_operation_history"));
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
