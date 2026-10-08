package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.*;
import java.util.stream.Collectors;

import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.*;

/** Preparation ordering across original paths, exact shared targets and cancellation. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@Import(ProductionJdbcMeasurement.Configuration.class)
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class AggregateMaterialOrderingLifecycleEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    AggregateMaterialOrderEndToEndTest h;

    @BeforeEach void before(){
        h=new AggregateMaterialOrderEndToEndTest();
        beans.autowireBean(h);
        h.before();
    }
    @AfterEach void after(){ProductionJdbcMeasurement.end();h.after();}

    @Test void screenshotThreeProductsOfOneHundredKeepStableDetailFactsAcrossMeasuredReloads() throws Exception {
        var scenario=h.createThreeProductScreenshotCase("100");
        var c=scenario.data();
        List<GroupInput> later=scenario.laterRoutes().entrySet().stream().map(entry->h.input(c,entry.getKey(),
                entry.getValue(),entry.getKey().equals(scenario.tape())?"0.15":"300",false)).toList();
        h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.material(),"MAKE","400",true),
                h.input(c,scenario.bag(),"BUY","400",true))));
        for(GroupInput group:later)h.writer.submit(c.analysis(),h.command(c,List.of(group)));
        AnalysisView stable=h.analyses.detail(c.analysis());
        assertPhysical(c,"400","300","100");
        var mapper=beans.getBean(com.fasterxml.jackson.databind.ObjectMapper.class);
        var records=new ArrayList<Map<String,Object>>();
        for(int sample=1;sample<=3;sample++){
            ProductionJdbcMeasurement.Sample sql=ProductionJdbcMeasurement.begin();
            long start=System.nanoTime();
            AnalysisView current;
            try {current=h.analyses.detail(c.analysis());}
            finally {ProductionJdbcMeasurement.end();}
            double millis=(System.nanoTime()-start)/1_000_000.0;
            assertEquals(stable.version(),current.version());
            assertEquals(stable.fingerprint(),current.fingerprint());
            assertEquals(stable.flatMaterials().size(),current.flatMaterials().size());
            var hot=sql.nanosByFingerprint.entrySet().stream().sorted(Map.Entry.<String,Long>comparingByValue().reversed())
                    .limit(12).map(entry->Map.of("fingerprint",entry.getKey(),"label",sql.labelsByFingerprint.get(entry.getKey()),
                            "calls",sql.fingerprints.get(entry.getKey()),"millis",entry.getValue()/1_000_000.0)).toList();
            Map<String,Object> record=new LinkedHashMap<>();
            record.put("sample",sample);record.put("products",3);record.put("productQty",100);
            record.put("materialRows",current.flatMaterials().size());record.put("elapsedMillis",millis);
            record.put("sql",sql.result());record.put("hotSql",hot);records.add(record);
            assertTrue(sql.logicalStatements>0,"JDBC instrumentation must actually be active");
            System.out.println("MATERIAL-DETAIL-LIFECYCLE "+mapper.writeValueAsString(record));
        }
        var evidence=java.nio.file.Path.of(System.getProperty("uten.build.directory","target"),"material-ordering-detail-lifecycle.json");
        java.nio.file.Files.createDirectories(evidence.getParent());
        mapper.writerWithDefaultPrettyPrinter().writeValue(evidence.toFile(),records);
    }

    @ParameterizedTest @ValueSource(strings={"MAKE","BUY"})
    void threeHundredDemandWithFourHundredOrderedKeepsOriginalAppendAndRouteLock(String route){
        var c=h.create(true,false,"100",true,3,"1");
        h.setRoute(c,c.child(),"SUBCONTRACT");
        if("MAKE".equals(route))h.setRoute(c,c.material(),route);
        GroupInput leaves=h.input(c,c.material(),route,"400",true);
        h.writer.submit(c.analysis(),h.command(c,List.of(leaves)));
        h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE","300",false))));
        h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.child(),"SUBCONTRACT","300",false))));
        AnalysisView current=h.analyses.detail(c.analysis());
        List<MaterialView> originals=rows(current,leaves.materialLineIds());
        assertEquals(3,originals.size());
        amount("300",originals.stream().map(MaterialView::sourceRequiredQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        GroupInput reviewedOriginals=sourceInput(c,leaves.materialLineIds(),route,"0",false);
        var sourceTotals=h.preview.preview(c.analysis(),h.request(c,List.of(reviewedOriginals))).groups().getFirst();
        amount("300",sourceTotals.sourceRequiredQty());
        amount("400",sourceTotals.orderedQty());
        assertPhysical(c,"400","300","100");
        for(MaterialView original:originals){
            assertNotNull(original.aggregatePreparation());
            assertTrue(original.aggregatePreparation().actionable(),"The original path needs an append entry backed by its live order");
            amount("0",original.aggregatePreparation().planningUncoveredQty());
            assertFalse(effectiveActions(current,original).isEmpty(),"Whole-batch cancellation must resolve from every original path");
        }
        assertRouteChangeRejected(c,originals.getFirst(),"MAKE".equals(route)?"BUY":"MAKE");
        UUID source=leaves.materialLineIds().getFirst();
        GroupInput append=sourceInput(c,List.of(source),route,"1",true);
        var reviewed=h.preview.preview(c.analysis(),h.request(c,List.of(append)));
        assertNull(reviewed.groups().getFirst().blockedReason());
        var intent=h.command(c,List.of(append));
        assertFalse(h.writer.submit(c.analysis(),intent).replayed());
        assertTrue(h.writer.submit(c.analysis(),intent).replayed());
        assertPhysical(c,"401","300","101");
    }

    @ParameterizedTest @ValueSource(strings={"1","0.0001"})
    void nestedCanonicalOrderCanBeCancelledAndReorderedUsingOnlyOriginalIds(String leafUsage){
        var c=h.create(true,false,"1",true,3,leafUsage);
        List<UUID> originals=h.input(c,c.material(),"BUY","0",false).materialLineIds();
        h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE","3",false))));
        h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.child(),"MAKE","3",false))));
        String total=new BigDecimal(leafUsage).multiply(new BigDecimal("3")).toPlainString();
        GroupInput intent=sourceInput(c,originals,"BUY",total,false);
        var first=h.writer.submit(c.analysis(),h.command(c,List.of(intent))).batches().getFirst();
        UUID action=action(first);
        AnalysisView ordered=h.analyses.detail(c.analysis());
        for(MaterialView source:rows(ordered,originals)){
            assertEquals(Set.of(action),effectiveActions(ordered,source),"Only the leaf's real order may be offered for whole-batch cancellation");
            amount("0",source.aggregatePreparation().planningUncoveredQty());
            assertRouteChangeRejected(c,source,"MAKE");
        }
        var cancellation=cancelRequest(ordered,"nested-cancel-");
        h.writer.cancel(c.analysis(),action,cancellation);
        h.writer.cancel(c.analysis(),action,cancellation);
        AnalysisView restored=h.analyses.detail(c.analysis());
        for(MaterialView source:rows(restored,originals)){
            amount(leafUsage,source.aggregatePreparation().planningUncoveredQty());
            assertFalse(effectiveActions(restored,source).contains(action));
        }
        amount(total,rows(restored,originals).stream().map(row->row.aggregatePreparation().requiredQty()).reduce(BigDecimal.ZERO,BigDecimal::add));
        var second=h.writer.submit(c.analysis(),h.command(c,List.of(intent))).batches().getFirst();
        assertNotEquals(action,action(second));
        assertNotEquals(first.documentId(),second.documentId());
        assertEquals(1,h.count("SELECT count(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='CANCEL'",first.batchId()));
        assertPhysical(c,total,total,"0");
    }

    @Test void staleSnapshotsAndChangedIdempotentIntentCannotDuplicateOrCancelSupply(){
        var c=h.create(false,false,"1");
        GroupInput group=h.input(c,c.material(),"BUY","2",false);
        SubmitRequest first=h.command(c,List.of(group));
        SubmitRequest competitor=new SubmitRequest(first.version(),first.fingerprint(),"competitor-"+UUID.randomUUID(),
                first.warehouseId(),first.billDate(),first.deliveryDate(),first.approveNow(),first.groups(),first.previewFingerprint());
        var batch=h.writer.submit(c.analysis(),first).batches().getFirst();
        assertCode(ErrorCode.CONFLICT,()->h.writer.submit(c.analysis(),competitor));
        GroupInput changed=sourceInput(c,group.materialLineIds(),"BUY","3",false);
        SubmitRequest reused=new SubmitRequest(first.version(),first.fingerprint(),first.idempotencyKey(),
                first.warehouseId(),first.billDate(),first.deliveryDate(),first.approveNow(),List.of(changed),first.previewFingerprint());
        assertCode(ErrorCode.CONFLICT,()->h.writer.submit(c.analysis(),reused));
        assertCode(ErrorCode.CONFLICT,()->h.writer.cancel(c.analysis(),action(batch),
                new CancelRequest(first.version(),first.fingerprint(),"stale-cancel-"+UUID.randomUUID(),"旧页面不得撤回新事实")));
        assertPhysical(c,"2","2","0");
        assertEquals(1,h.count("SELECT count(*) FROM preplan_aggregate_batches WHERE analysis_id=?",c.analysis()));
    }

    @Test void oneOriginalPathRetainsEveryLiveTargetAfterPartialParentsSplitAcrossWorkshops(){
        var c=h.createWithChild("1");
        List<UUID> originalLeaves=h.input(c,c.material(),"BUY","0",false).materialLineIds();
        GroupInput parent=h.input(c,c.common(),"MAKE","1",false);
        var first=h.writer.submit(c.analysis(),h.command(c,List.of(parent))).batches().getFirst();
        Object other=ReflectionTestUtils.invokeMethod(h.fixture,"productionAssignment","lifecycle-split-"+UUID.randomUUID());
        UUID workshop=ReflectionTestUtils.invokeMethod(other,"workshopId");
        UUID worker=ReflectionTestUtils.invokeMethod(other,"workerId");
        GroupInput remaining=new GroupInput("other-workshop",parent.materialLineIds(),"MAKE",new BigDecimal("2"),false,
                workshop,worker,null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO);
        var second=h.writer.submit(c.analysis(),h.command(c,List.of(remaining))).batches().getFirst();
        assertNotEquals(first.batchId(),second.batchId());
        AnalysisView delegated=h.analyses.detail(c.analysis());
        for(MaterialView row:rows(delegated,originalLeaves)){
            assertEquals(2,row.aggregatePreparation().targetMaterialLineIds().size(),"Every partial parent target must survive projection");
            amount("2",row.aggregatePreparation().requiredQty());
        }
        GroupInput leaves=sourceInput(c,originalLeaves,"BUY","6",false);
        var ordered=h.writer.submit(c.analysis(),h.command(c,List.of(leaves))).batches().getFirst();
        UUID supplyAction=action(ordered);
        AnalysisView complete=h.analyses.detail(c.analysis());
        for(MaterialView row:rows(complete,originalLeaves)){
            assertEquals(Set.of(supplyAction),effectiveActions(complete,row));
            amount("0",row.aggregatePreparation().planningUncoveredQty());
            assertRouteChangeRejected(c,row,"MAKE");
        }
        assertPhysical(c,"6","6","0");
        h.writer.cancel(c.analysis(),supplyAction,cancelRequest(complete,"all-targets-cancel-"));
        AnalysisView cancelled=h.analyses.detail(c.analysis());
        for(MaterialView row:rows(cancelled,originalLeaves)){
            assertEquals(2,row.aggregatePreparation().targetMaterialLineIds().size());
            amount("2",row.aggregatePreparation().planningUncoveredQty());
        }
        assertEquals(2,h.count("SELECT count(*) FROM preplan_aggregate_batches batch JOIN preplan_supply_actions action ON action.id=batch.action_id WHERE batch.analysis_id=? AND batch.route='MAKE' AND action.status<>'CANCELLED'",c.analysis()));
    }

    @Test void partiallyDelegatedOriginalCannotChangeRouteWhileOnlyItsCanonicalTargetIsOrdered(){
        var c=h.createWithChild("10");
        List<UUID> originalLeaves=h.input(c,c.material(),"BUY","0",false).materialLineIds();
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE","15",false)))).batches().getFirst();
        AnalysisView partial=h.analyses.detail(c.analysis());
        List<UUID> canonical=partial.flatMaterials().stream().filter(row->row.analysisLineId().equals(parent.anchorAnalysisItemId())
                &&row.goodsId().equals(c.material())).map(MaterialView::materialLineId).toList();
        assertEquals(1,canonical.size());
        var child=h.writer.submit(c.analysis(),h.command(c,List.of(sourceInput(c,canonical,"BUY","30",false)))).batches().getFirst();
        AnalysisView current=h.analyses.detail(c.analysis());
        List<MaterialView> originals=rows(current,originalLeaves);
        amount("30",originals.stream().map(MaterialView::requiredQty).reduce(BigDecimal.ZERO,BigDecimal::add));
        List<MaterialView> partlyDelegated=originals.stream().filter(row->row.actionable()
                &&row.requiredQty().signum()>0&&row.planningUncoveredQty().signum()>0
                &&row.aggregateDelegatedQty().signum()>0).toList();
        assertFalse(partlyDelegated.isEmpty(),"Priority allocation must leave a real partial source with both remaining demand and an exact shared target");
        for(MaterialView original:partlyDelegated){
            assertTrue(original.actionable(),"Exercise the route writer, not the already-inactive row guard");
            assertTrue(original.requiredQty().signum()>0);
            assertTrue(original.planningUncoveredQty().signum()>0);
            assertTrue(original.downstreamReferences().isEmpty(),"Only the exact canonical child carries the order");
            assertEquals(Set.of(action(child)),effectiveActions(current,original));
            assertRouteChangeRejected(c,original,"MAKE");
        }
        assertPhysical(c,"30","30","0");
    }

    @Test void structuralRefreshCannotAutomaticallyRerouteAnOriginalWithAnOrderedCanonicalTarget(){
        var c=h.createWithChild("10");
        UUID lower=UUID.randomUUID();
        h.fixture.insertGoods(lower,"AUTO-LOWER-"+lower,"外购整件下层参考料","采购",c.world().unitId(),c.world().unitLegacy());
        h.fixture.insertBom(c.material(),lower,"1");
        refreshCurrentSources(c);
        List<UUID> originals=h.input(c,c.material(),"BUY","0",false).materialLineIds();
        var parent=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),"MAKE","15",false)))).batches().getFirst();
        AnalysisView partial=h.analyses.detail(c.analysis());
        List<UUID> canonical=partial.flatMaterials().stream().filter(row->row.analysisLineId().equals(parent.anchorAnalysisItemId())
                &&row.goodsId().equals(c.material())).map(MaterialView::materialLineId).toList();
        h.writer.submit(c.analysis(),h.command(c,List.of(sourceInput(c,canonical,"BUY","30",false))));
        h.db.update("UPDATE goods SET source_type='自制' WHERE id=?",c.material());
        AnalysisView sourceOnly=refreshCurrentSources(c);
        for(MaterialView row:rows(sourceOnly,originals))assertEquals("BUY",row.sourceConfirmed(),"Master source change alone keeps confirmation");
        Map<UUID,java.time.OffsetDateTime> confirmedAt=new HashMap<>();
        for(MaterialView row:sourceOnly.flatMaterials().stream().filter(value->value.goodsId().equals(c.material())).toList())
            confirmedAt.put(row.materialLineId(),h.db.queryForObject("SELECT route_confirmed_at FROM production_material_analysis_materials WHERE id=?",java.time.OffsetDateTime.class,row.materialLineId()));
        UUID edge=h.db.queryForObject("SELECT id FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",UUID.class,c.child(),c.material());
        var edit=new com.uten.imp.features.master.goods.dto.BomItemSaveRequest();
        edit.setComponentGoodsId(c.material());edit.setControlStage("ASSEMBLY");
        beans.getBean(com.uten.imp.features.master.goods.GoodsBomService.class).update(c.child(),edge,edit);
        AnalysisView refreshed=refreshCurrentSources(c);
        for(MaterialView row:refreshed.flatMaterials().stream().filter(value->value.goodsId().equals(c.material())).toList()){
            assertEquals("ASSEMBLY",row.controlStage());
            assertEquals("BUY",row.sourceConfirmed(),"Both exact canonical and original rows retain the actual issued route");
            assertTrue(row.routeConfirmed());
            assertEquals(confirmedAt.get(row.materialLineId()),h.db.queryForObject("SELECT route_confirmed_at FROM production_material_analysis_materials WHERE id=?",java.time.OffsetDateTime.class,row.materialLineId()));
        }
        assertEquals(0,refreshed.pendingAutoConfirmRouteCount(),"Read-side eligibility must not request the same unsafe confirmation again");
        assertPhysical(c,"30","30","0");
        for(UUID original:originals)h.db.update("UPDATE production_material_analysis_materials SET confirmed_route='MAKE',route_confirmed_by=?,route_confirmed_at=now(),route_reason='历史自动确认' WHERE id=? AND required_qty>0",c.world().superAdminUserId(),original);
        AnalysisView wrongOnly=refreshCurrentSources(c);
        for(MaterialView row:wrongOnly.flatMaterials().stream().filter(value->value.goodsId().equals(c.material())).toList()){
            assertEquals("BUY",row.sourceConfirmed(),"Wrong original routes must recover even when canonical confirmations remain present and structure is unchanged");
            assertTrue(row.routeConfirmed());
        }
        h.db.update("UPDATE production_material_analysis_materials SET confirmed_route=NULL,route_confirmed_by=NULL,route_confirmed_at=NULL,route_reason=NULL WHERE analysis_id=? AND goods_id=?",c.analysis(),c.material());
        for(UUID original:originals)h.db.update("UPDATE production_material_analysis_materials SET confirmed_route='MAKE',route_confirmed_by=?,route_confirmed_at=now(),route_reason='历史自动确认' WHERE id=? AND required_qty>0",c.world().superAdminUserId(),original);
        UUID receiver=h.fixture.createUserWithPerms(c.world(),"route-preserve-receiver-"+UUID.randomUUID(),"production_material_analysis:view");
        h.fixture.loginAs(receiver);
        Object serviceTarget=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(h.analyses);
        new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class))
                .executeWithoutResult(tx->ReflectionTestUtils.invokeMethod(serviceTarget,"refreshLocked",c.analysis()));
        h.fixture.loginAs(c.world().superAdminUserId());
        AnalysisView restored=h.analyses.detail(c.analysis());
        for(MaterialView row:restored.flatMaterials().stream().filter(value->value.goodsId().equals(c.material())).toList()){
            assertEquals("BUY",row.sourceConfirmed());assertTrue(row.routeConfirmed());
            assertEquals("依据已下达供给恢复，未重新选择供应方式",row.routeReason());
            assertEquals(receiver,h.db.queryForObject("SELECT route_confirmed_by FROM production_material_analysis_materials WHERE id=?",UUID.class,row.materialLineId()),"The restoration records its real triggering actor, never a guessed historical confirmer");
        }
        assertTrue(restored.flatMaterials().stream().filter(row->row.goodsId().equals(lower)).allMatch(row->row.requiredQty().signum()==0&&row.planningUncoveredQty().signum()==0),
                "Restoring an ordered BUY intermediate must suppress child responsibility in the same refresh");
        GroupInput append=sourceInput(c,originals,"BUY","1",false);
        var checked=h.preview.preview(c.analysis(),h.request(c,List.of(append)));
        assertNull(checked.groups().getFirst().blockedReason(),"A pinned historical route remains usable for the original remainder");
        h.writer.submit(c.analysis(),h.command(c,List.of(append)));
        assertPhysical(c,"31","31","0");
    }

    @Test void structuralRefreshWithoutIssuedSupplyStillAdoptsTheCurrentMasterRoute(){
        var c=h.createWithChild("1");
        h.db.update("UPDATE goods SET source_type='自制' WHERE id=?",c.material());
        UUID edge=h.db.queryForObject("SELECT id FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",UUID.class,c.child(),c.material());
        var edit=new com.uten.imp.features.master.goods.dto.BomItemSaveRequest();edit.setComponentGoodsId(c.material());edit.setControlStage("ASSEMBLY");
        beans.getBean(com.uten.imp.features.master.goods.GoodsBomService.class).update(c.child(),edge,edit);
        AnalysisView refreshed=refreshCurrentSources(c);
        assertTrue(refreshed.autoConfirmedRouteCount()>0);
        for(MaterialView row:refreshed.flatMaterials().stream().filter(value->value.goodsId().equals(c.material())).toList()){
            assertEquals("MAKE",row.sourceConfirmed());assertTrue(row.routeConfirmed());
        }
    }

    private AnalysisView refreshCurrentSources(AggregateMaterialOrderEndToEndTest.Case c){
        AnalysisView current=h.analyses.detail(c.analysis());
        List<PreviewItem> sources=current.products().stream().filter(row->row.salesOrderItemId()!=null)
                .map(row->new PreviewItem("SALES_ORDER_ITEM",row.salesOrderItemId(),null,null,null,null,null,row.deliveryDate(),row.requestedQty())).toList();
        return h.analyses.preview(new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest(
                c.analysis(),current.version(),current.fingerprint(),c.world().warehouseId(),"auto-alias-refresh-"+UUID.randomUUID(),sources));
    }

    @ParameterizedTest @ValueSource(strings={"MAKE","BUY"})
    void revokedRouteAuthorityCannotSubmitOrCancelTheSameActorsOrder(String route){
        var c=h.create(false,false,"1");
        if("MAKE".equals(route))h.setRoute(c,c.material(),route);
        SubmitRequest intent=h.command(c,List.of(h.input(c,c.material(),route,"6",false)));
        Authentication actor=SecurityContextHolder.getContext().getAuthentication();
        String permission="MAKE".equals(route)?"production_material_analysis:generate":"production_material_analysis:notify";
        withoutPermission(actor,permission);
        assertCode(ErrorCode.FORBIDDEN,()->h.writer.submit(c.analysis(),intent));
        assertEquals(0,h.count("SELECT count(*) FROM preplan_aggregate_batches WHERE analysis_id=?",c.analysis()));
        SecurityContextHolder.getContext().setAuthentication(actor);
        var batch=h.writer.submit(c.analysis(),intent).batches().getFirst();
        var cancellation=cancelRequest(h.analyses.detail(c.analysis()),"permission-cancel-");
        withoutPermission(actor,permission);
        assertCode(ErrorCode.FORBIDDEN,()->h.writer.submit(c.analysis(),intent));
        assertCode(ErrorCode.FORBIDDEN,()->h.writer.cancel(c.analysis(),action(batch),cancellation));
        assertPhysical(c,"6","6","0");
        SecurityContextHolder.getContext().setAuthentication(actor);
        h.writer.cancel(c.analysis(),action(batch),cancellation);
        withoutPermission(actor,permission);
        assertCode(ErrorCode.FORBIDDEN,()->h.writer.cancel(c.analysis(),action(batch),cancellation));
    }

    @Test void ordinaryPartialMakePlanAtOneTickAlsoLocksTheOriginalSupplyRoute(){
        var c=h.create(false,false,"1");
        h.setRoute(c,c.material(),"MAKE");
        AnalysisView initial=h.analyses.detail(c.analysis());
        MaterialView original=initial.flatMaterials().stream().filter(row->row.goodsId().equals(c.material())).findFirst().orElseThrow();
        h.ordinary.issueWorkshopPlans(c.analysis(),new IssueWorkshopPlansRequest(initial.version(),initial.fingerprint(),
                "ordinary-tick-"+UUID.randomUUID(),c.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(original.materialLineId(),null,new BigDecimal("0.0001"),
                        null,null,c.workshop(),null,c.worker(),null,null,false,BigDecimal.ZERO))));
        MaterialView current=rows(h.analyses.detail(c.analysis()),List.of(original.materialLineId())).getFirst();
        assertTrue(current.actionable());
        assertTrue(current.planningUncoveredQty().signum()>0);
        assertRouteChangeRejected(c,current,"BUY");
        amount("0.0001",h.db.queryForObject("""
                SELECT SUM(item.qty) FROM production_plan_items item JOIN production_plans plan ON plan.id=item.plan_id
                WHERE plan.material_analysis_id=? AND item.goods_id=? AND plan.status=1 AND NOT plan.is_deleted AND NOT item.is_deleted
                """,BigDecimal.class,c.analysis(),c.material()));
    }

    @Test void safetyOnlyPurchaseRetainsItsZeroAllocationReferencesAndWholeBatchCancellation(){
        var c=h.create(false,false,"1");
        h.db.update("UPDATE goods SET min_qty=4 WHERE id=?",c.material());
        List<UUID> originals=h.input(c,c.material(),"BUY","0",false).materialLineIds();
        GroupInput safety=new GroupInput("safety-only",originals,"BUY",BigDecimal.ZERO,false,
                null,null,null,null,null,null,null,new BigDecimal("4"));
        SubmitRequest intent=h.command(c,List.of(safety));
        var ordered=h.writer.submit(c.analysis(),intent);
        var batch=ordered.batches().getFirst();
        UUID action=action(batch);
        assertTrue(h.writer.submit(c.analysis(),intent).replayed());
        SupplyActionView supply=ordered.analysis().supplyActions().stream().filter(row->row.actionId().equals(action)).findFirst().orElseThrow();
        amount("0",supply.requestedQty());amount("0",supply.publicSurplusQty());
        amount("4",supply.safetyReplenishmentQty());amount("4",supply.totalRequestedQty());
        assertEquals(0,h.count("SELECT count(*) FROM preplan_supply_action_allocations WHERE action_id=?",action));
        amount("4",h.db.queryForObject("SELECT SUM(qty) FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,batch.documentId()));
        for(MaterialView source:rows(ordered.analysis(),originals)){
            var references=source.downstreamReferences().stream().filter(ref->ref.actionId().equals(action)).toList();
            assertEquals(1,references.size(),"A safety-only order still needs its exact cancellation and route-lock reference");
            amount("0",references.getFirst().allocatedQty());
            assertRouteChangeRejected(c,source,"MAKE");
        }
        var cancellation=cancelRequest(h.analyses.detail(c.analysis()),"safety-only-cancel-");
        h.writer.cancel(c.analysis(),action,cancellation);
        h.writer.cancel(c.analysis(),action,cancellation);
        assertEquals("CANCELLED",h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,action));
        assertEquals(1,h.count("SELECT count(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='CANCEL'",batch.batchId()));
        AnalysisView restored=h.analyses.detail(c.analysis());
        for(MaterialView source:rows(restored,originals)){
            assertFalse(effectiveActions(restored,source).contains(action));
            amount("2",source.planningUncoveredQty());
        }
    }

    @Test void cancellingAnActionFromAnotherAnalysisCannotTouchEitherOrder(){
        var first=h.create(false,false,"1");
        var firstActor=SecurityContextHolder.getContext().getAuthentication();
        var firstBatch=h.writer.submit(first.analysis(),h.command(first,List.of(h.input(first,first.material(),"BUY","6",false)))).batches().getFirst();
        var second=h.create(false,false,"1");
        var secondBatch=h.writer.submit(second.analysis(),h.command(second,List.of(h.input(second,second.material(),"BUY","6",false)))).batches().getFirst();
        String previousStatus=h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,action(secondBatch));
        var cancellation=cancelRequest(h.analyses.detail(second.analysis()),"wrong-analysis-");
        assertCode(ErrorCode.CONFLICT,()->h.writer.cancel(second.analysis(),action(firstBatch),cancellation));
        assertEquals(previousStatus,h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,action(secondBatch)));
        assertPhysical(second,"6","6","0");
        SecurityContextHolder.getContext().setAuthentication(firstActor);
        assertPhysical(first,"6","6","0");
    }

    @Test void simultaneousAppendAndWholeBatchCancelHaveOnlyOneWinner() throws Exception {
        var c=h.create(false,false,"1");
        var batch=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.material(),"BUY","6",false)))).batches().getFirst();
        UUID action=action(batch);
        SubmitRequest append=h.command(c,List.of(h.input(c,c.material(),"BUY","1",true)));
        CancelRequest cancel=cancelRequest(h.analyses.detail(c.analysis()),"racing-cancel-");
        Authentication actor=SecurityContextHolder.getContext().getAuthentication();
        var barrier=new java.util.concurrent.CyclicBarrier(2);
        java.util.function.Function<Boolean,Object> run=cancellation->{
            var context=SecurityContextHolder.createEmptyContext();context.setAuthentication(actor);
            SecurityContextHolder.setContext(context);
            try {
                barrier.await(30,java.util.concurrent.TimeUnit.SECONDS);
                if(cancellation)return h.writer.cancel(c.analysis(),action,cancel);
                return h.writer.submit(c.analysis(),append);
            } catch(ApiException rejected){return rejected;}
            catch(Exception failure){throw new RuntimeException(failure);}
            finally {SecurityContextHolder.clearContext();}
        };
        try(var workers=java.util.concurrent.Executors.newFixedThreadPool(2)){
            var appending=workers.submit(()->run.apply(false));
            var cancelling=workers.submit(()->run.apply(true));
            List<Object> results=List.of(appending.get(90,java.util.concurrent.TimeUnit.SECONDS),
                    cancelling.get(90,java.util.concurrent.TimeUnit.SECONDS));
            assertEquals(1,results.stream().filter(ApiException.class::isInstance).count());
            assertEquals(ErrorCode.CONFLICT,results.stream().filter(ApiException.class::isInstance)
                    .map(ApiException.class::cast).findFirst().orElseThrow().getCode());
            boolean cancelled=results.stream().anyMatch(AnalysisView.class::isInstance);
            assertPhysical(c,cancelled?"0":"7",cancelled?"0":"6",cancelled?"0":"1");
            assertEquals(cancelled?1:0,h.count("SELECT count(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='CANCEL'",batch.batchId()));
            assertEquals(cancelled?0:1,h.count("SELECT count(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='APPEND'",batch.batchId()));
        }
    }

    private GroupInput sourceInput(AggregateMaterialOrderEndToEndTest.Case c,List<UUID> ids,String route,String quantity,boolean extra){
        return new GroupInput("original-"+c.material(),ids,route,new BigDecimal(quantity),extra,
                "MAKE".equals(route)?c.workshop():null,"MAKE".equals(route)?c.worker():null,
                null,null,null,null,"MAKE".equals(route)?BigDecimal.ZERO:null,BigDecimal.ZERO);
    }

    private void assertRouteChangeRejected(AggregateMaterialOrderEndToEndTest.Case c,MaterialView row,String route){
        AnalysisView current=h.analyses.detail(c.analysis());
        ErrorCode expected=row.actionable()?ErrorCode.CONFLICT:ErrorCode.VALIDATION_FAILED;
        assertCode(expected,()->h.analyses.saveRoutes(c.analysis(),new RouteRequest(current.version(),current.fingerprint(),
                "ordered-route-"+UUID.randomUUID(),List.of(new RouteDecision(row.materialLineId(),row.actionGroupKey(),route,"已下单不能改路线")))));
        assertEquals(row.sourceConfirmed(),h.db.queryForObject("SELECT confirmed_route FROM production_material_analysis_materials WHERE id=?",String.class,row.materialLineId()));
    }

    private Set<UUID> effectiveActions(AnalysisView view,MaterialView source){
        Map<UUID,MaterialView> byId=view.flatMaterials().stream().collect(Collectors.toMap(MaterialView::materialLineId,row->row));
        Set<UUID> visited=new HashSet<>(),actions=new HashSet<>();
        ArrayDeque<UUID> pending=new ArrayDeque<>(List.of(source.materialLineId()));
        while(!pending.isEmpty()){
            UUID id=pending.removeFirst();
            if(!visited.add(id))continue;
            MaterialView row=Objects.requireNonNull(byId.get(id),"Missing exact material target "+id);
            row.downstreamReferences().stream().filter(reference->!"CANCELLED".equals(reference.status()))
                    .map(DownstreamReference::actionId).forEach(actions::add);
            if(row.aggregatePreparation()!=null)pending.addAll(row.aggregatePreparation().targetMaterialLineIds());
        }
        return actions;
    }

    private void assertPhysical(AggregateMaterialOrderEndToEndTest.Case c,String total,String privateQty,String publicQty){
        var amounts=h.db.queryForMap("""
                SELECT COALESCE(SUM(requested_qty),0) AS private_qty,
                       COALESCE(SUM(public_surplus_qty),0) AS public_qty,
                       COALESCE(SUM(requested_qty+public_surplus_qty),0) AS total_qty
                FROM preplan_supply_actions WHERE analysis_id=? AND goods_id=? AND status<>'CANCELLED'
                """,c.analysis(),c.material());
        amount(total,(BigDecimal)amounts.get("total_qty"));
        amount(privateQty,(BigDecimal)amounts.get("private_qty"));
        amount(publicQty,(BigDecimal)amounts.get("public_qty"));
        amount(privateQty,h.db.queryForObject("""
                SELECT COALESCE(SUM(allocation.allocated_qty),0) FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id=allocation.action_id
                WHERE action.analysis_id=? AND action.goods_id=? AND action.status<>'CANCELLED'
                """,BigDecimal.class,c.analysis(),c.material()));
    }

    private UUID action(BatchResult batch){return h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,batch.batchId());}
    private List<MaterialView> rows(AnalysisView view,List<UUID> ids){return view.flatMaterials().stream().filter(row->ids.contains(row.materialLineId())).toList();}
    private CancelRequest cancelRequest(AnalysisView current,String prefix){return new CancelRequest(current.version(),current.fingerprint(),prefix+UUID.randomUUID(),"验证整批撤回精确恢复来源");}
    private void assertCode(ErrorCode expected,org.junit.jupiter.api.function.Executable operation){
        ApiException failure=assertThrows(ApiException.class,operation);
        assertEquals(expected,failure.getCode(),failure.getMessage());
    }
    private void withoutPermission(Authentication authentication,String permission){
        AuthUser admin=(AuthUser)authentication.getPrincipal();
        Set<String> grants=new HashSet<>(admin.getPermissions());grants.remove(permission);
        AuthUser actor=new AuthUser(admin.getId(),admin.getEmployeeId(),admin.getUsername(),grants,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));
    }
}
