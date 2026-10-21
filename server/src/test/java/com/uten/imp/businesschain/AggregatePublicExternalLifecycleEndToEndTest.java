package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.GroupInput;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.BatchResult;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class AggregatePublicExternalLifecycleEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    AggregateMaterialOrderEndToEndTest h;
    @BeforeEach void before() { h=new AggregateMaterialOrderEndToEndTest(); beans.autowireBean(h); h.before(); }
    @AfterEach void after() { h.after(); }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void changedDeliveryCreatesALivePublicOnlyBatchWithoutInventingPrivateAllocations(String route) {
        var scenario=publicBatch(route,false);
        var c=scenario.c();var added=scenario.added();UUID action=scenario.action();
        assertNotEquals(scenario.first().batchId(),added.batchId());
        amount("0",h.db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,action));
        amount("2",h.db.queryForObject("SELECT public_surplus_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,action));
        assertEquals(0,h.count("SELECT count(*) FROM preplan_supply_action_allocations WHERE action_id=?",action));
        assertStatus(action,"CREATED");refresh(c);assertStatus(action,"CREATED");
        amount("2",h.db.queryForObject("SELECT available_to_claim_qty FROM v_preplan_public_surplus_source_state WHERE source_action_id=?",BigDecimal.class,action));
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void anExplicitOriginalSourceIntentAlsoPreservesItsZeroPrivatePublicBatch(String route) {
        var scenario=publicBatch(route,true);assertStatus(scenario.action(),"CREATED");refresh(scenario.c());assertStatus(scenario.action(),"CREATED");
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void purePublicAppendReusesTheSameLiveUnorderedBatch(String route) {
        var s=publicBatch(route,false);assertTrue(growable(s.action()));
        var input=h.input(s.c(),s.c().common(),route,"3",true);
        var group=new GroupInput(input.clientGroupKey(),input.materialLineIds(),route,input.qty(),true,
                null,null,null,null,BusinessTime.today().plusDays(11),null,null,BigDecimal.ZERO,
                Map.of(input.materialLineIds().getFirst(),new BigDecimal("3")));
        var request=h.command(s.c(),List.of(group));
        var result=h.writer.submit(s.c().analysis(),request);var appended=result.batches().getFirst();
        assertEquals(s.added().batchId(),appended.batchId());assertEquals(s.added().documentId(),appended.documentId());
        assertEquals(s.action(),action(appended));assertTrue(h.writer.submit(s.c().analysis(),request).replayed());
        assertStatus(s.action(),"CREATED");assertTrue(growable(s.action()));
        amount("0",h.db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,s.action()));
        amount("5",h.db.queryForObject("SELECT public_surplus_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,s.action()));
        assertEquals(0,h.count("SELECT count(*) FROM preplan_supply_action_allocations WHERE action_id=?",s.action()));
        assertEquals(1,h.count("SELECT count(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='CREATE'",appended.batchId()));
        assertEquals(1,h.count("SELECT count(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='APPEND'",appended.batchId()));
        String table=route.equals("BUY")?"purchase_request_items":"subcontract_application_items";
        amount("5",h.db.queryForObject("SELECT qty FROM "+table+" WHERE id=?",BigDecimal.class,publicItem(s.action())));
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void aSharedPublicClaimStillClosesTheInPlaceGrowthBoundary(String route) {
        var s=publicBatch(route,false);var target=newTarget(s,route);
        var material=target.flatMaterials().stream().filter(row->row.goodsId().equals(s.c().common())).findFirst().orElseThrow();
        h.ordinary.claimSharedFuture(target.analysisId(),new MaterialAnalysisContracts.ClaimSharedFutureRequest(
                target.version(),target.fingerprint(),"public-growth-claim-"+UUID.randomUUID(),List.of(material.actionGroupKey()),
                List.of(new MaterialAnalysisContracts.SharedFutureClaimQuantity(material.actionGroupKey(),BigDecimal.ONE,s.action())),true));
        assertTrue(h.db.queryForObject("SELECT fn_preplan_action_has_shared_claims(?)",Boolean.class,s.action()));
        assertFalse(growable(s.action()));
        amount("2",h.db.queryForObject("SELECT public_surplus_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,s.action()));
    }

    @org.junit.jupiter.api.Test void aPrivateFutureTransferStillClosesTheOriginalGrowthBoundary() {
        var s=publicBatch("BUY",false);UUID source=action(s.first());
        UUID item=h.db.queryForObject("SELECT external_item_id FROM preplan_supply_action_allocations WHERE action_id=?",UUID.class,source);
        approvePurchase(s,item,"5");var target=newTarget(s,"BUY");
        var material=target.flatMaterials().stream().filter(row->row.goodsId().equals(s.c().common())).findFirst().orElseThrow();
        var transfers=beans.getBean(com.uten.imp.features.production.analysis.PreplanFutureSupplyTransferService.class);
        UUID allocation=h.db.queryForObject("SELECT id FROM preplan_supply_action_allocations WHERE action_id=?",UUID.class,source);
        var candidate=transfers.sources(target.analysisId(),material.materialLineId()).stream()
                .filter(row->row.sourceAllocationId().equals(allocation)).findFirst().orElseThrow();
        transfers.create(target.analysisId(),new com.uten.imp.features.production.analysis.PreplanFutureSupplyTransfer.Create(
                candidate.sourceAllocationId(),material.materialLineId(),BigDecimal.ONE,candidate.sourceVersion(),candidate.sourceFingerprint(),
                candidate.targetVersion(),candidate.targetFingerprint(),true,"保留已转拨供给禁止就地增长","public-growth-transfer-"+UUID.randomUUID()));
        assertTrue(h.db.queryForObject("SELECT fn_preplan_action_has_future_transfer(?)",Boolean.class,source));
        assertFalse(growable(source));
    }

    @org.junit.jupiter.api.Test void aPurePublicSafetyBatchCannotBeAppendedInPlace() {
        var s=publicBatch("BUY",false,"3");assertFalse(growable(s.action()));
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void privateAndPublicAppendTransitionsKeepOneRealLineAndItsImmediateShapeGuard(String route) {
        var s=publicBatch(route,false);var c=s.c();
        var view=h.analyses.detail(c.analysis());
        h.writer.cancel(c.analysis(),action(s.first()),new MaterialAnalysisContracts.CancelRequest(
                view.version(),view.fingerprint(),"public-to-private-cancel-"+UUID.randomUUID(),"撤回原私有申请后按现行缺口追加"));
        assertTrue(growable(s.action()));
        var input=h.input(c,c.common(),route,"1",false);
        var group=new GroupInput(input.clientGroupKey(),input.materialLineIds(),route,BigDecimal.ONE,false,
                null,null,null,null,BusinessTime.today().plusDays(11),null,null,BigDecimal.ZERO,
                Map.of(input.materialLineIds().getFirst(),BigDecimal.ONE));
        var prepared=h.command(c,List.of(group));
        // Explicit full ordering is a supported UI choice; the default would adopt
        // the existing public stock instead and legitimately create no new batch.
        var request=new com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.SubmitRequest(
                prepared.version(),prepared.fingerprint(),prepared.idempotencyKey(),prepared.warehouseId(),prepared.billDate(),prepared.deliveryDate(),
                prepared.approveNow(),prepared.groups(),prepared.previewFingerprint(),true);
        var mixed=h.writer.submit(c.analysis(),request).batches().getFirst();
        assertEquals(s.added().batchId(),mixed.batchId());assertEquals(s.added().documentId(),mixed.documentId());
        assertTrue(h.writer.submit(c.analysis(),request).replayed());
        amount("1",h.db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,s.action()));
        amount("2",h.db.queryForObject("SELECT public_surplus_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,s.action()));
        assertEquals(publicItem(s.action()),h.db.queryForObject("SELECT external_item_id FROM preplan_supply_action_allocations WHERE action_id=?",UUID.class,s.action()));
        amount("1",h.db.queryForObject("SELECT sum(allocated_qty) FROM preplan_supply_action_allocations WHERE action_id=?",BigDecimal.class,s.action()));
        String table=route.equals("BUY")?"purchase_request_items":"subcontract_application_items";
        amount("3",h.db.queryForObject("SELECT qty FROM "+table+" WHERE id=?",BigDecimal.class,publicItem(s.action())));

        // The opposite transition starts with an ordinary private line and no public ID.
        var ordinary=h.createWithChild("5",1);h.setRoute(ordinary,ordinary.common(),route);
        var first=h.writer.submit(ordinary.analysis(),h.command(ordinary,List.of(h.input(ordinary,ordinary.common(),route,"5",false)))).batches().getFirst();
        UUID firstAction=action(first);assertEquals(null,publicItem(firstAction));
        var append=h.command(ordinary,List.of(h.input(ordinary,ordinary.common(),route,"1",true)));
        var extra=h.writer.submit(ordinary.analysis(),append).batches().getFirst();
        assertEquals(first.batchId(),extra.batchId());assertEquals(first.documentId(),extra.documentId());
        assertTrue(h.writer.submit(ordinary.analysis(),append).replayed());
        amount("5",h.db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,firstAction));
        amount("1",h.db.queryForObject("SELECT public_surplus_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,firstAction));
        assertEquals(publicItem(firstAction),h.db.queryForObject("SELECT external_item_id FROM preplan_supply_action_allocations WHERE action_id=?",UUID.class,firstAction));
        amount("6",h.db.queryForObject("SELECT qty FROM "+table+" WHERE id=?",BigDecimal.class,publicItem(firstAction)));
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void anExternalAppendCohortRollsEveryPhysicalLineAndEventBackAfterItsSecondWriteFails(String route) {
        Object cohort=ReflectionTestUtils.invokeMethod(h,"createIndependentCohort");
        AggregateMaterialOrderEndToEndTest.Case c=ReflectionTestUtils.invokeMethod(cohort,"c");
        List<UUID> outputs=ReflectionTestUtils.invokeMethod(cohort,"outputs");
        outputs.forEach(goods->h.setRoute(c,goods,route));
        h.writer.submit(c.analysis(),h.command(c,cohortInputs(c,outputs,route,"1",false,null)));
        var publicBatches=h.writer.submit(c.analysis(),h.command(c,cohortInputs(c,outputs,route,"2",true,BusinessTime.today().plusDays(11)))).batches();
        assertEquals(2,publicBatches.size());
        var request=h.command(c,cohortInputs(c,outputs,route,"1",true,BusinessTime.today().plusDays(11)));
        Map<UUID,String> before=new java.util.LinkedHashMap<>();
        publicBatches.forEach(batch->{UUID id=action(batch);assertTrue(growable(id));before.put(id,sourceSnapshot(new Scenario(c,batch,batch,id)));});
        long version=h.analyses.detail(c.analysis()).version();
        String suffix=UUID.randomUUID().toString().replace("-","");
        String probe="test_public_append_probe_"+suffix,trigger="zz_"+probe;
        String ids=before.keySet().stream().map(id->"'"+id+"'::uuid").collect(java.util.stream.Collectors.joining(","));
        assertTestDatabase();
        try {
            h.db.execute("CREATE FUNCTION "+probe+"() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE physical numeric; BEGIN "
                    +"IF NEW.route='BUY' THEN SELECT qty*COALESCE(unit_rate,1) INTO physical FROM purchase_request_items WHERE id=NEW.public_surplus_external_item_id; "
                    +"ELSE SELECT qty*COALESCE(unit_rate,1) INTO physical FROM subcontract_application_items WHERE id=NEW.public_surplus_external_item_id; END IF; "
                    +"IF physical=3 AND EXISTS(SELECT 1 FROM preplan_supply_actions other WHERE other.id IN ("+ids+") AND other.id<>NEW.id AND other.public_surplus_qty=3) THEN "
                    +"RAISE EXCEPTION 'TC_PUBLIC_APPEND_OBSERVED_BOTH_GROWN_LINES_THEN_ROLLED_BACK' USING ERRCODE='23514'; END IF; RETURN NEW; END $$");
            h.db.execute("CREATE TRIGGER "+trigger+" BEFORE UPDATE OF public_surplus_qty ON preplan_supply_actions FOR EACH ROW "
                    +"WHEN (NEW.id IN ("+ids+") AND NEW.public_surplus_qty>OLD.public_surplus_qty) EXECUTE FUNCTION "+probe+"()");
            RuntimeException rejected=assertThrows(RuntimeException.class,()->h.writer.submit(c.analysis(),request));
            assertTrue(org.springframework.core.NestedExceptionUtils.getMostSpecificCause(rejected).getMessage()
                    .contains("TC_PUBLIC_APPEND_OBSERVED_BOTH_GROWN_LINES_THEN_ROLLED_BACK"));
        } finally {
            h.db.execute("DROP TRIGGER IF EXISTS "+trigger+" ON preplan_supply_actions");
            h.db.execute("DROP FUNCTION IF EXISTS "+probe+"()");
            assertEquals(0,h.db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgname=?",Integer.class,trigger));
        }
        publicBatches.forEach(batch->{UUID id=action(batch);assertEquals(before.get(id),sourceSnapshot(new Scenario(c,batch,batch,id)));
            assertEquals(1,h.db.queryForObject("SELECT row_version FROM preplan_aggregate_batches WHERE id=?",Long.class,batch.batchId()));
            assertEquals(0,h.count("SELECT count(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='APPEND'",batch.batchId()));});
        assertEquals(version,h.analyses.detail(c.analysis()).version());
        assertEquals(0,h.db.queryForObject("SELECT count(*) FROM production_material_analysis_commands WHERE analysis_id=? AND operation='AGGREGATE_ORDER' AND idempotency_key=?",Integer.class,c.analysis(),request.idempotencyKey()));
        var appended=h.writer.submit(c.analysis(),request);assertTrue(h.writer.submit(c.analysis(),request).replayed());
        assertEquals(publicBatches.stream().map(BatchResult::batchId).collect(java.util.stream.Collectors.toSet()),
                appended.batches().stream().map(BatchResult::batchId).collect(java.util.stream.Collectors.toSet()));
        for(var batch:publicBatches) {
            amount("3",h.db.queryForObject("SELECT public_surplus_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,action(batch)));
            assertEquals(1,h.count("SELECT count(*) FROM preplan_aggregate_batch_events WHERE batch_id=? AND event_type='APPEND'",batch.batchId()));
        }
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void privateAndMixedBatchesKeepTheirOwnRequiredSourceProof(String route) {
        for(String qty:List.of("5","7")) {
            var c=h.createWithChild("5",1);h.setRoute(c,c.common(),route);
            var made=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),route,qty,qty.equals("7"))))).batches().getFirst();
            UUID action=action(made);assertStatus(action,"CREATED");refresh(c);assertStatus(action,"CREATED");
            amount("5",h.db.queryForObject("SELECT requested_qty FROM preplan_supply_actions WHERE id=?",BigDecimal.class,action));
        }
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void realSourceRemovalInvalidatesPublicOnlyAndNeverRevivesACancelledAction(String route) {
        var s=publicBatch(route,false);
        if(route.equals("BUY"))h.db.update("UPDATE purchase_requests SET is_stopped=true WHERE id=?",s.added().documentId());
        else corruptHistory("subcontract_applications","UPDATE subcontract_applications SET status=-1 WHERE id=?",s.added().documentId());
        assertFalse(growable(s.action()));refresh(s.c());assertCancelled(s.action());
        if(route.equals("BUY"))h.db.update("UPDATE purchase_requests SET is_stopped=false WHERE id=?",s.added().documentId());
        else {
            var rejected=assertThrows(org.springframework.dao.DataIntegrityViolationException.class,
                    ()->h.db.update("UPDATE subcontract_applications SET status=1 WHERE id=?",s.added().documentId()));
            assertEquals("23514",org.junit.jupiter.api.Assertions.assertInstanceOf(java.sql.SQLException.class,rejected.getMostSpecificCause()).getSQLState());
            assertEquals(-1,h.db.queryForObject("SELECT status FROM subcontract_applications WHERE id=?",Integer.class,s.added().documentId()));
        }
        refresh(s.c());assertCancelled(s.action());
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void anUnrelatedLiveParentCannotProveThePublicItemValid(String route) {
        var s=publicBatch(route,false);
        assertRejectedInvariant(s,()->h.db.update("UPDATE preplan_supply_actions SET external_document_id=? WHERE id=?",s.first().documentId(),s.action()));
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void deletingALivePublicItemIsRejectedWithoutChangingItsActionOrDocument(String route) {
        var s=publicBatch(route,false);
        UUID item=h.db.queryForObject("SELECT public_surplus_external_item_id FROM preplan_supply_actions WHERE id=?",UUID.class,s.action());
        if(route.equals("BUY"))assertRejectedInvariant(s,()->h.db.update("UPDATE purchase_request_items SET is_deleted=true WHERE id=?",item));
        else assertRejectedInvariant(s,()->h.db.update("UPDATE subcontract_application_items SET is_deleted=true WHERE id=?",item));
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void aMissingPublicSliceCannotBeHiddenByAValidPrivateSlice(String route) {
        var c=h.createWithChild("5",1);h.setRoute(c,c.common(),route);
        var made=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),route,"7",true)))).batches().getFirst();
        UUID action=action(made);
        assertRejectedInvariant(new Scenario(c,made,made,action),()->h.db.update("UPDATE preplan_supply_actions SET public_surplus_external_item_id=NULL WHERE id=?",action));
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void oneBrokenPrivateMemberCannotBeHiddenByTheOtherPrivateAndPublicMembers(String route) {
        var c=h.createWithChild("5",2);h.setRoute(c,c.common(),route);
        var made=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),route,"12",true)))).batches().getFirst();
        UUID action=action(made);
        assertEquals(2,h.count("SELECT count(*) FROM preplan_supply_action_allocations WHERE action_id=?",action));
        corruptHistory("preplan_supply_action_allocations","UPDATE preplan_supply_action_allocations SET external_item_id=NULL WHERE id=(SELECT id FROM preplan_supply_action_allocations WHERE action_id=? ORDER BY id LIMIT 1)",action);
        refresh(c);assertCancelled(action);
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void nonzeroPrivateDemandCannotLoseItsOnlyPrivateAllocation(String route) {
        var c=h.createWithChild("5",1);h.setRoute(c,c.common(),route);
        var made=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),route,"7",true)))).batches().getFirst();
        UUID action=action(made);
        String allocations=h.db.queryForObject("SELECT jsonb_agg(to_jsonb(allocation) ORDER BY id)::text FROM preplan_supply_action_allocations allocation WHERE action_id=?",String.class,action);
        assertRejectedInvariant(new Scenario(c,made,made,action),()->h.db.update("DELETE FROM preplan_supply_action_allocations WHERE action_id=?",action));
        assertEquals(allocations,h.db.queryForObject("SELECT jsonb_agg(to_jsonb(allocation) ORDER BY id)::text FROM preplan_supply_action_allocations allocation WHERE action_id=?",String.class,action));
        refresh(c);assertStatus(action,"CREATED");
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void aLivePublicItemFromAnotherDocumentCannotSupplyThisAction(String route) {
        var s=publicBatch(route,false);
        UUID unrelatedItem=h.db.queryForObject("SELECT external_item_id FROM preplan_supply_action_allocations WHERE action_id=? LIMIT 1",UUID.class,action(s.first()));
        assertRejectedInvariant(s,()->h.db.update("UPDATE preplan_supply_actions SET public_surplus_external_item_id=? WHERE id=?",unrelatedItem,s.action()));
    }

    @ParameterizedTest @ValueSource(strings={"BUY","SUBCONTRACT"})
    void aFullyOrderedPublicDocumentStaysValidAndCannotBeWithdrawn(String route) {
        var s=publicBatch(route,false);var w=s.c().world();
        UUID item=h.db.queryForObject("SELECT public_surplus_external_item_id FROM preplan_supply_actions WHERE id=?",UUID.class,s.action());
        if(route.equals("BUY")) {
            var purchasing=new PreplanPublicFutureReplenishmentEndToEndTest();beans.autowireBean(purchasing);
            ReflectionTestUtils.setField(purchasing,"fixture",h.fixture);
            ReflectionTestUtils.invokeMethod(purchasing,"approveOrder",w,item,s.c().common(),"2",BusinessTime.today().plusDays(11));
        } else {
            Object kit=ReflectionTestUtils.invokeMethod(h.fixture,"stageSubcontractKit",w,Map.of(s.c().common(),"2"));
            UUID order=ReflectionTestUtils.invokeMethod(h.fixture,"createSubcontractOrderFromApplication",w,s.c().common(),item,"2");
            ReflectionTestUtils.invokeMethod(h.fixture,"stageSubcontractKitUntilApproval",order,kit);
            var finance=(com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService)ReflectionTestUtils.getField(h.fixture,"financeApproval");
            UUID reviewer=ReflectionTestUtils.invokeMethod(h.fixture,"createApprover",w);
            finance.submit("SUBCONTRACT",order);h.fixture.loginAs(reviewer);
            ReflectionTestUtils.invokeMethod(h.fixture,"approvePendingFinance","SUBCONTRACT",order);
            h.fixture.loginAs(w.superAdminUserId());
        }
        refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");assertFalse(growable(s.action()));
        var current=h.analyses.detail(s.c().analysis());
        var rejected=assertThrows(com.uten.imp.common.web.ApiException.class,()->h.writer.cancel(s.c().analysis(),s.action(),
                new MaterialAnalysisContracts.CancelRequest(current.version(),current.fingerprint(),"ordered-public-cancel-"+UUID.randomUUID(),"已订货不得撤回")));
        assertEquals(409,rejected.getCode().getHttpStatus());assertStatus(s.action(),"IN_PROGRESS");
    }

    @org.junit.jupiter.api.Test
    void legacyFalseDoneWithNoQualifiedReceiptIsReconciledIdempotently() {
        var s=publicBatch("BUY",false);
        h.db.update("UPDATE preplan_supply_actions SET status='DONE' WHERE id=?",s.action());
        refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");
        refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");
    }

    @org.junit.jupiter.api.Test
    void publicPurchaseCompletesOnlyAfterFullStockInAndReceiptReversalReopensIt() {
        var s=publicBatch("BUY",false);UUID item=publicItem(s.action());
        UUID ordered=approvePurchase(s,item,"2");refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");
        receivePurchase(s,ordered,"1");refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");
        UUID second=receivePurchase(s,ordered,"1");refresh(s.c());assertStatus(s.action(),"DONE");
        h.db.update("UPDATE purchase_requests SET is_stopped=true WHERE id=?",s.added().documentId());
        refresh(s.c());assertStatus(s.action(),"DONE");refresh(s.c());assertStatus(s.action(),"DONE");
        h.db.update("UPDATE purchase_requests SET is_stopped=false WHERE id=?",s.added().documentId());
        beans.getBean(com.uten.imp.features.purchase.receipt.PurchaseReceiptService.class).reverse(second);
        refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void safetyAndPublicPurchaseKeepEverySliceOpenUntilQualifiedAndStocked(boolean withPrivate) {
        Scenario s;
        if(withPrivate) {
            var c=h.createWithChild("5",1);h.setRoute(c,c.common(),"BUY");
            h.db.update("UPDATE goods SET min_qty=3 WHERE id=?",c.common());
            var input=h.input(c,c.common(),"BUY","7",true);
            var group=new GroupInput(input.clientGroupKey(),input.materialLineIds(),"BUY",input.qty(),true,
                    null,null,null,null,null,null,null,new BigDecimal("3"));
            var made=h.writer.submit(c.analysis(),h.command(c,List.of(group))).batches().getFirst();
            s=new Scenario(c,made,made,action(made));
        } else s=publicBatch("BUY",false,"3");
        UUID safety=h.db.queryForObject("SELECT safety_external_item_id FROM preplan_supply_actions WHERE id=?",UUID.class,s.action());
        String regularQty=withPrivate?"7":"2";
        UUID regularOrder=withPrivate?approveMergedRegularPurchase(s,regularQty):approvePurchase(s,publicItem(s.action()),regularQty);
        UUID safetyOrder=approvePurchase(s,safety,"3");
        receivePurchase(s,safetyOrder,"3");refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");
        receivePurchase(s,regularOrder,withPrivate?"5":"1");refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");
        receivePurchase(s,regularOrder,withPrivate?"2":"1");refresh(s.c());assertStatus(s.action(),"DONE");
        refresh(s.c());assertStatus(s.action(),"DONE");
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void failedPublicSupplyWaitsForPendingStockAndSafetyFutureBeforeReleasing(boolean withSafety) {
        var s=publicBatch("BUY",false,withSafety?"3":"0");
        UUID regularOrder=approvePurchase(s,publicItem(s.action()),"2");
        UUID safetyOrder=withSafety?approvePurchase(s,h.db.queryForObject("SELECT safety_external_item_id FROM preplan_supply_actions WHERE id=?",UUID.class,s.action()),"3"):null;
        UUID receipt=pendingPurchase(s,regularOrder,"2");refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");
        UUID inspection=h.db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='PURCHASE' AND receipt_id=?",UUID.class,receipt);
        var inspections=beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.class);
        inspections.dispose("PURCHASE",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                "PASS",BigDecimal.ONE,"公共片部分合格待仓库入库","public-pass-"+UUID.randomUUID()));
        refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");
        inspections.dispose("PURCHASE",receipt,inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                "FAIL",BigDecimal.ONE,"公共片余量终态不合格","public-fail-"+UUID.randomUUID()));
        refresh(s.c());assertStatus(s.action(),"IN_PROGRESS");
        h.fixture.loginAs(ReflectionTestUtils.invokeMethod(h.fixture,"createIqcWarehouseConfirmer",s.c().world(),"public-lifecycle-stock-"+inspection));
        com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest confirmation=ReflectionTestUtils.invokeMethod(
                h.fixture,"latestIqcStockInRequest","PURCHASE",receipt,inspection,BigDecimal.ONE,"public-lifecycle-confirm-"+UUID.randomUUID(),"PUBLIC-L01");
        beans.getBean(com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService.class).confirm("PURCHASE",receipt,confirmation);
        h.fixture.loginAs(s.c().world().superAdminUserId());refresh(s.c());
        if(withSafety) { assertStatus(s.action(),"IN_PROGRESS");receivePurchase(s,safetyOrder,"3");refresh(s.c()); }
        assertCancelled(s.action());
    }

    @org.junit.jupiter.api.Test
    void mergedPhysicalOrderKeepsEachActionsRequestSourceFifoSeparate() {
        var s=publicBatch("BUY",false);var w=s.c().world();UUID privateAction=action(s.first());
        UUID privateItem=h.db.queryForObject("SELECT external_item_id FROM preplan_supply_action_allocations WHERE action_id=? LIMIT 1",UUID.class,privateAction);
        UUID publicItem=publicItem(s.action());assertNotEquals(privateItem,publicItem);
        var request=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(h.fixture,"activeSettlementMethodId"));
        request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line=ReflectionTestUtils.invokeMethod(h.fixture,"ma65OrderLine",w,privateItem,s.c().common(),"7");
        line.setRequestItemIds(List.of(privateItem,publicItem));request.setItems(List.of(line));
        beans.getBean(com.uten.imp.features.purchase.order.PurchaseOrderService.class).createBatch(request);
        UUID ordered=h.db.queryForObject("SELECT order_item_id FROM purchase_order_item_sources WHERE request_item_id=?",UUID.class,privateItem);
        assertEquals(2,h.count("SELECT count(*) FROM purchase_order_item_sources WHERE order_item_id=?",ordered));
        assertEquals(privateItem,h.db.queryForObject("SELECT request_item_id FROM purchase_order_item_sources WHERE order_item_id=? ORDER BY line_no,id LIMIT 1",UUID.class,ordered));
        UUID order=h.db.queryForObject("SELECT order_id FROM purchase_order_items WHERE id=?",UUID.class,ordered);
        var finance=beans.getBean(com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService.class);
        UUID reviewer=ReflectionTestUtils.invokeMethod(h.fixture,"createApprover",w);finance.submit("PURCHASE",order);
        h.fixture.loginAs(reviewer);ReflectionTestUtils.invokeMethod(h.fixture,"approvePendingFinance","PURCHASE",order);
        h.fixture.loginAs(w.superAdminUserId());refresh(s.c());
        assertStatus(privateAction,"IN_PROGRESS");assertStatus(s.action(),"IN_PROGRESS");
        receivePurchase(s,ordered,"2");refresh(s.c());
        assertStatus(privateAction,"IN_PROGRESS");assertStatus(s.action(),"IN_PROGRESS");
        receivePurchase(s,ordered,"3");refresh(s.c());
        assertStatus(privateAction,"DONE");assertStatus(s.action(),"IN_PROGRESS");
        receivePurchase(s,ordered,"2");refresh(s.c());
        assertStatus(privateAction,"DONE");assertStatus(s.action(),"DONE");
    }

    private Scenario publicBatch(String route,boolean explicitIntent) {
        return publicBatch(route,explicitIntent,"0");
    }
    private Scenario publicBatch(String route,boolean explicitIntent,String safety) {
        var c=h.createWithChild("5",1);
        h.setRoute(c,c.common(),route);
        var first=h.writer.submit(c.analysis(),h.command(c,List.of(h.input(c,c.common(),route,"5",false))))
                .batches().getFirst();
        if(!safety.equals("0"))h.db.update("UPDATE goods SET min_qty=3 WHERE id=?",c.common());
        var input=h.input(c,c.common(),route,"2",true);
        Map<UUID,BigDecimal> requested=explicitIntent?Map.of(input.materialLineIds().getFirst(),new BigDecimal("2")):Map.of();
        var changedDate=new GroupInput(input.clientGroupKey(),input.materialLineIds(),route,input.qty(),true,
                null,null,null,null,BusinessTime.today().plusDays(11),null,null,new BigDecimal(safety),requested);
        var request=h.command(c,List.of(changedDate));
        var added=h.writer.submit(c.analysis(),request).batches().getFirst();
        assertEquals(true,h.writer.submit(c.analysis(),request).replayed());
        assertStatus(action(added),"CREATED");
        return new Scenario(c,first,added,action(added));
    }
    private UUID action(BatchResult batch) { return h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,batch.batchId()); }
    private UUID publicItem(UUID action) { return h.db.queryForObject("SELECT public_surplus_external_item_id FROM preplan_supply_actions WHERE id=?",UUID.class,action); }
    private boolean growable(UUID action) { return h.db.queryForObject("SELECT fn_preplan_supply_action_growable(?)",Boolean.class,action); }
    private List<GroupInput> cohortInputs(AggregateMaterialOrderEndToEndTest.Case c,List<UUID> outputs,String route,
                                         String qty,boolean extra,java.time.LocalDate delivery) {
        return outputs.stream().map(goods->{var input=h.input(c,goods,route,qty,extra);
            return new GroupInput(input.clientGroupKey(),input.materialLineIds(),route,input.qty(),extra,
                    null,null,null,null,delivery,null,null,BigDecimal.ZERO);}).toList();
    }
    private void assertTestDatabase() {
        var container=(org.testcontainers.postgresql.PostgreSQLContainer)ReflectionTestUtils.getField(FullChainEndToEndTest.class,"POSTGRES");
        h.db.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection->{
            assertEquals(container.getJdbcUrl(),connection.getMetaData().getURL());return null;});
    }
    private MaterialAnalysisContracts.AnalysisView newTarget(Scenario s,String route) {
        var w=s.c().world();h.fixture.loginAs(w.superAdminUserId());UUID root=UUID.randomUUID();
        h.fixture.insertGoods(root,"PUBLIC-GROW-"+root,"公共供给增长边界接收产品","自制",w.unitId(),w.unitLegacy());
        h.fixture.insertBom(root,s.c().common(),"1");UUID order=h.fixture.createApprovedOrder(w,root,"1","100");
        UUID orderItem=h.db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        var target=h.analyses.preview(new MaterialAnalysisContracts.PreviewRequest(null,null,null,w.warehouseId(),
                "public-growth-target-"+UUID.randomUUID(),List.of(new MaterialAnalysisContracts.PreviewItem(
                "SALES_ORDER_ITEM",orderItem,null,null,null,null,null,BusinessTime.today().plusDays(10),BigDecimal.ONE))));
        var c=new AggregateMaterialOrderEndToEndTest.Case(w,target.analysisId(),s.c().common(),s.c().child(),s.c().material(),s.c().workshop(),s.c().worker());
        h.setRoute(c,c.common(),route);return h.analyses.detail(c.analysis());
    }
    private UUID approvePurchase(Scenario s,UUID item,String qty) {
        var purchasing=new PreplanPublicFutureReplenishmentEndToEndTest();beans.autowireBean(purchasing);
        ReflectionTestUtils.setField(purchasing,"fixture",h.fixture);
        return ReflectionTestUtils.invokeMethod(purchasing,"approveOrder",s.c().world(),item,s.c().common(),qty,BusinessTime.today().plusDays(11));
    }
    private UUID approveMergedRegularPurchase(Scenario s,String qty) {
        var w=s.c().world();h.fixture.loginAs(w.superAdminUserId());
        var regularSources=new java.util.LinkedHashSet<>(h.db.queryForList(
                "SELECT DISTINCT external_item_id FROM preplan_supply_action_allocations WHERE action_id=? AND external_item_id IS NOT NULL ORDER BY external_item_id",
                UUID.class,s.action()));
        regularSources.add(publicItem(s.action()));List<UUID> sources=List.copyOf(regularSources);
        var request=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(h.fixture,"activeSettlementMethodId"));
        request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        com.uten.imp.features.purchase.order.dto.OrderItemLine line=ReflectionTestUtils.invokeMethod(h.fixture,"ma65OrderLine",w,sources.getFirst(),s.c().common(),qty);
        line.setRequestItemIds(sources);line.setDeliverDate(BusinessTime.today().plusDays(11));request.setItems(List.of(line));
        beans.getBean(com.uten.imp.features.purchase.order.PurchaseOrderService.class).createBatch(request);
        UUID ordered=h.db.queryForObject("SELECT order_item_id FROM purchase_order_item_sources WHERE request_item_id=?",UUID.class,sources.getFirst());
        assertEquals(sources.size(),h.count("SELECT count(*) FROM purchase_order_item_sources WHERE order_item_id=?",ordered));
        amount(qty,h.db.queryForObject("SELECT sum(alloc_qty) FROM purchase_order_item_sources WHERE order_item_id=?",BigDecimal.class,ordered));
        UUID order=h.db.queryForObject("SELECT order_id FROM purchase_order_items WHERE id=?",UUID.class,ordered);
        var finance=beans.getBean(com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService.class);
        UUID reviewer=ReflectionTestUtils.invokeMethod(h.fixture,"createApprover",w);finance.submit("PURCHASE",order);
        h.fixture.loginAs(reviewer);ReflectionTestUtils.invokeMethod(h.fixture,"approvePendingFinance","PURCHASE",order);
        h.fixture.loginAs(w.superAdminUserId());return ordered;
    }
    private UUID receivePurchase(Scenario s,UUID ordered,String qty) {
        UUID receipt=ReflectionTestUtils.invokeMethod(h.fixture,"receiveAndPassPurchase",s.c().world(),ordered,s.c().common(),new BigDecimal(qty),"root-public-lifecycle-"+UUID.randomUUID());
        h.fixture.loginAs(s.c().world().superAdminUserId());return receipt;
    }
    private UUID pendingPurchase(Scenario s,UUID ordered,String qty) {
        var w=s.c().world();h.fixture.loginAs(w.superAdminUserId());
        var request=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today());request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(h.fixture,"purchaseOrderSettlementMethodOf",ordered));
        var item=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        item.setGoodsId(s.c().common());item.setOrderItemId(ordered);item.setUnitId(w.unitId());item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal(qty));item.setPrice(new BigDecimal("50"));request.setItems(List.of(item));
        var service=beans.getBean(com.uten.imp.features.purchase.receipt.PurchaseReceiptService.class);
        UUID receipt=service.create(request).getId();service.approve(receipt);return receipt;
    }
    private void assertStatus(UUID action,String expected) { assertEquals(expected,h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,action)); }
    private void assertCancelled(UUID action) { assertEquals("CANCELLED",h.db.queryForObject("SELECT status FROM preplan_supply_actions WHERE id=?",String.class,action)); }
    private void assertRejectedInvariant(Scenario s,Runnable invalidWrite) {
        String before=sourceSnapshot(s);
        var rejected=assertThrows(org.springframework.dao.DataIntegrityViolationException.class,invalidWrite::run);
        var sql=org.junit.jupiter.api.Assertions.assertInstanceOf(java.sql.SQLException.class,rejected.getMostSpecificCause());
        assertEquals("23514",sql.getSQLState());assertEquals(before,sourceSnapshot(s));
        assertStatus(s.action(),"CREATED");
    }
    private String sourceSnapshot(Scenario s) {
        String parent=s.added().route().equals("BUY")?"purchase_requests":"subcontract_applications";
        String items=s.added().route().equals("BUY")?"purchase_request_items":"subcontract_application_items";
        String foreign=s.added().route().equals("BUY")?"request_id":"application_id";
        return h.db.queryForObject("SELECT jsonb_build_array(to_jsonb(action),(SELECT to_jsonb(document) FROM "+parent+
                " document WHERE document.id=action.external_document_id),(SELECT jsonb_agg(to_jsonb(item) ORDER BY item.id) FROM "+items+
                " item WHERE item."+foreign+"=action.external_document_id))::text FROM preplan_supply_actions action WHERE action.id=?",String.class,s.action());
    }
    private void refresh(AggregateMaterialOrderEndToEndTest.Case c) {
        var view=h.analyses.detail(c.analysis());
        h.analyses.preview(new MaterialAnalysisContracts.PreviewRequest(c.analysis(),view.version(),view.fingerprint(),c.world().warehouseId(),
                "public-source-refresh-"+UUID.randomUUID(),view.products().stream().filter(source->"SALES_ORDER_ITEM".equals(source.sourceType()))
                .map(source->new MaterialAnalysisContracts.PreviewItem("SALES_ORDER_ITEM",source.salesOrderItemId(),null,null,null,null,null,source.deliveryDate(),source.requestedQty())).toList()));
    }
    /** Only this new Testcontainers database may model immutable, damaged historical facts. */
    private void corruptHistory(String table,String sql,Object... parameters) {
        assertEquals(true,java.util.Set.of("preplan_supply_actions","preplan_supply_action_allocations",
                "purchase_request_items","subcontract_application_items","subcontract_applications").contains(table));
        assertTestDatabase();
        var triggers=h.db.queryForList("""
                SELECT t.tgname FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
                WHERE t.tgrelid=CAST(? AS regclass) AND NOT t.tgisinternal AND p.proname IN
                  ('fn_guard_preplan_public_surplus_history','fn_guard_preplan_public_surplus_shape',
                   'fn_guard_preplan_supply_allocation_history','fn_guard_production_supply_source_header',
                   'fn_guard_production_supply_source_item') ORDER BY t.tgname
                """,String.class,table);
        try {
            new org.springframework.transaction.support.TransactionTemplate(beans.getBean(org.springframework.transaction.PlatformTransactionManager.class))
                    .executeWithoutResult(status->{
                        h.db.execute("SET CONSTRAINTS ALL IMMEDIATE");
                        for(String trigger:triggers)h.db.execute("ALTER TABLE "+table+" DISABLE TRIGGER \""+trigger+"\"");
                        try { h.db.update(sql,parameters); }
                        catch(RuntimeException failure) { status.setRollbackOnly();throw failure; }
                        finally {
                            // PostgreSQL rolls transactional trigger DDL back after a failed statement.
                            // Issuing ENABLE in an aborted transaction would mask its authoritative error.
                            if(!status.isRollbackOnly())for(String trigger:triggers)h.db.execute("ALTER TABLE "+table+" ENABLE TRIGGER \""+trigger+"\"");
                        }
                    });
        } finally {
            assertEquals(0,h.db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid=CAST(? AS regclass) AND NOT tgisinternal AND tgenabled='D'",Integer.class,table));
        }
    }
    private record Scenario(AggregateMaterialOrderEndToEndTest.Case c,BatchResult first,BatchResult added,UUID action) { }
}
