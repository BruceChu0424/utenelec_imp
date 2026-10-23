package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.draw.SubcontractDrawCommandService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.*;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_issue.SubcontractSelectedOutboundService;
import com.uten.imp.features.subcontract.material_issue.SubcontractSelectedOutboundContracts.*;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.*;
import java.util.concurrent.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.concurrency.verify-nested-footprint=true",
        "uten.workshop-material.auto-close.enabled=false","uten.inventory.value-work.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractSelectedOutboundEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractSelectedOutboundService commands;
    @Autowired SubcontractMaterialIssueService issues;
    @Autowired SubcontractDrawCommandService draws;
    @Autowired PlatformTransactionManager transactions;
    SubcontractStepDrawEndToEndTest h;
    @BeforeEach void setup(){h=new SubcontractStepDrawEndToEndTest();beans.autowireBean(h);h.setup();}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void issuingAThenBRetainsBRowAndReservationExactlyAndReplaysTheOriginalASlice() {
        var s=scenario();String beforeB=item(s.bItem()),beforeReserve=reservations(s.source(),s.b());
        Request request=request(s,s.aItem(),"6");
        Result a=commands.execute(s.source(),request);
        assertThat(a.executionIssueId()).isNotEqualTo(s.source());
        assertThat(a.itemIds()).containsExactly(s.aItem());
        UUID executionA=db.queryForObject("SELECT execution_item_id FROM subcontract_selected_outbound_items WHERE source_item_id=?",UUID.class,s.aItem());
        assertThat(executionA).isNotEqualTo(s.aItem());
        assertThat(db.queryForObject("SELECT issue_id FROM subcontract_material_issue_items WHERE id=?",UUID.class,s.aItem())).isEqualTo(s.source());
        assertThat(db.queryForObject("SELECT parent_id FROM business_record_identities WHERE source_table='subcontract_material_issue_items' AND source_id=?",String.class,s.aItem().toString())).isEqualTo(s.source().toString());
        assertThat(db.queryForObject("SELECT is_deleted AND warehouse_split_at IS NOT NULL AND warehouse_dropped_at IS NULL FROM subcontract_material_issue_items WHERE id=?",Boolean.class,s.aItem())).isTrue();
        assertThrows(RuntimeException.class,()->db.update("UPDATE subcontract_material_issue_items SET issue_id=? WHERE id=?",a.executionIssueId(),s.aItem()));
        assertThrows(RuntimeException.class,()->db.update("UPDATE subcontract_selected_outbound_items SET execution_item_id=source_item_id WHERE source_item_id=?",s.aItem()));
        assertThat(item(s.bItem())).isEqualTo(beforeB);
        assertThat(reservations(s.source(),s.b())).isEqualTo(beforeReserve);
        assertThat(issues.detail(s.source()).getStatus()).isZero();
        amount("4",onHand(s,s.a()));amount("20",onHand(s,s.b()));
        amount("6",issued(s,s.a()));amount("0",issued(s,s.b()));
        assertThat(commands.execute(s.source(),request)).isEqualTo(a);
        assertThat(commands.receipt(s.source(),request.idempotencyKey())).isEqualTo(a);
        assertThat(reservations(s.source(),s.b())).isEqualTo(beforeReserve);
        Result b=commands.execute(s.source(),request(s,s.bItem(),"20"));
        assertThat(b.executionIssueId()).isEqualTo(s.source());
        assertThat(b.itemIds()).containsExactly(s.bItem());
        amount("6",issued(s,s.a()));amount("20",issued(s,s.b()));
        amount("4",onHand(s,s.a()));amount("0",onHand(s,s.b()));
        assertThat(commands.execute(s.source(),request)).isEqualTo(a);
        assertThat(movements(s.aItem())).isEqualTo(1);
        assertThat(count("SELECT count(*) FROM subcontract_selected_outbound_commands WHERE source_issue_id=?",s.source())).isEqualTo(2);
        amount("26",db.queryForObject("SELECT sum(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=? AND NOT is_deleted",BigDecimal.class,s.orderItem()));
    }

    @Test void reversingTheExecutionRestoresOnlyAAndNeverReleasesOrConsumesB() {
        var s=scenario();String beforeB=item(s.bItem()),beforeReserve=reservations(s.source(),s.b());
        var request=request(s,s.aItem(),"10");var result=commands.execute(s.source(),request);
        issues.reverse(result.executionIssueId());
        assertThat(item(s.bItem())).isEqualTo(beforeB);
        assertThat(reservations(s.source(),s.b())).isEqualTo(beforeReserve);
        amount("10",onHand(s,s.a()));amount("20",onHand(s,s.b()));
        amount("0",issued(s,s.a()));amount("0",issued(s,s.b()));
        assertThat(commands.execute(s.source(),request)).isEqualTo(result);
        assertThat(movements(s.aItem())).isEqualTo(2);
        assertThat(issues.detail(result.executionIssueId()).getStatus()).isEqualTo((short)-1);
        assertThat(db.queryForObject("SELECT is_deleted FROM subcontract_material_issue_items WHERE id=?",Boolean.class,s.aItem())).isTrue();
        assertThrows(ApiException.class,()->commands.execute(s.source(),new Request("retired-source-"+UUID.randomUUID(),
                commands.review(s.source()).fingerprint(),List.of(s.aItem()),request.document())));
    }

    @Test void exactEntitlementHandoffsMoveOnlyTheSelectedMaterialAndReverseWithoutTouchingB() {
        var s=scenario(true);
        assertThat(count("SELECT count(*) FROM subcontract_component_stock_handoffs handoff JOIN subcontract_material_plan_items plan ON plan.id=handoff.plan_item_id WHERE plan.order_item_id=?",s.orderItem())).isEqualTo(2);
        String beforeB=item(s.bItem()),beforeReserve=reservations(s.source(),s.b());
        String beforeBBridge=db.queryForObject("""
                SELECT jsonb_agg(to_jsonb(handoff) ORDER BY handoff.id)::text FROM subcontract_component_stock_handoffs handoff
                JOIN subcontract_material_plan_items plan ON plan.id=handoff.plan_item_id WHERE plan.order_item_id=? AND plan.goods_id=?
                """,String.class,s.orderItem(),s.b());
        var result=commands.execute(s.source(),request(s,s.aItem(),"6"));
        amount("6",issued(s,s.a()));amount("0",issued(s,s.b()));
        assertThat(item(s.bItem())).isEqualTo(beforeB);assertThat(reservations(s.source(),s.b())).isEqualTo(beforeReserve);
        issues.reverse(result.executionIssueId());
        amount("0",issued(s,s.a()));amount("0",issued(s,s.b()));
        assertThat(item(s.bItem())).isEqualTo(beforeB);assertThat(reservations(s.source(),s.b())).isEqualTo(beforeReserve);
        assertThat(db.queryForObject("""
                SELECT jsonb_agg(to_jsonb(handoff) ORDER BY handoff.id)::text FROM subcontract_component_stock_handoffs handoff
                JOIN subcontract_material_plan_items plan ON plan.id=handoff.plan_item_id WHERE plan.order_item_id=? AND plan.goods_id=?
                """,String.class,s.orderItem(),s.b())).isEqualTo(beforeBBridge);
        amount("10",onHand(s,s.a()));amount("20",onHand(s,s.b()));
    }

    @Test void identicalSkuRowsStillFollowTheirOriginalPlanAndReservationIdentity() {
        String tag="sc-selected-same-sku-"+UUID.randomUUID();var w=h.fixture.seedWorld(tag);h.fixture.loginAs(w.superAdminUserId());
        call("grantAuthorities",w.superAdminUserId(),new String[]{"subcontract_order:view","subcontract_order:draw","subcontract:view:all"});
        UUID parent=call("goods",w,tag,"P","委外"),material=call("goods",w,tag,"A","采购");
        h.fixture.insertBom(parent,material,"1");call("otherIn",w,w.warehouseId(),material,null,"20","10");
        com.uten.imp.features.subcontract.order.dto.OrderSaveRequest body=call("orderRequest",w,parent,"10",BusinessTime.today().plusDays(5),null);
        var second=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();second.setLineNo(2);second.setGoodsId(parent);
        second.setUnitId(w.unitId());second.setUnitRate(BigDecimal.ONE);second.setQty(BigDecimal.TEN);second.setPrice(new BigDecimal("50"));
        body.setItems(List.of(body.getItems().getFirst(),second));
        UUID order=h.orders.create(body).getId();call("approveSubcontract",w,order);
        List<UUID> orderItems=db.queryForList("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted ORDER BY id",UUID.class,order);
        UUID source=draws.submit(new DrawSubmitRequest(orderItems.stream().map(id->new DrawItemRequest(id,null)).toList(),"same-sku-draw-"+order)).issueIds().getFirst();
        var rows=issues.detail(source).getItems();assertThat(rows).hasSize(2);
        UUID a=rows.getFirst().getId(),b=rows.get(1).getId(),bPlan=rows.get(1).getPlanItemId();
        String beforeB=item(b),beforeReservation=db.queryForObject("SELECT jsonb_agg(to_jsonb(r) ORDER BY id)::text FROM stock_reservations r WHERE source_doc_id=? AND owner_id=?",String.class,source,bPlan);
        var s=new Scenario(w,source,rows.getFirst().getOrderItemId(),material,material,a,b);
        var result=commands.execute(source,request(s,a,"10"));
        assertThat(item(b)).isEqualTo(beforeB);
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(r) ORDER BY id)::text FROM stock_reservations r WHERE source_doc_id=? AND owner_id=?",String.class,source,bPlan)).isEqualTo(beforeReservation);
        amount("10",onHand(s,material));
        issues.reverse(result.executionIssueId());
        amount("20",onHand(s,material));
        assertThat(item(b)).isEqualTo(beforeB);
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(r) ORDER BY id)::text FROM stock_reservations r WHERE source_doc_id=? AND owner_id=?",String.class,source,bPlan)).isEqualTo(beforeReservation);
    }

    @Test void missingDuplicateForeignAndStaleSelectionNeverExpandsOrWritesAnything() {
        var s=scenario();String beforeA=item(s.aItem()),beforeB=item(s.bItem()),beforeReserve=allReservations(s.source());
        var valid=request(s,s.aItem(),"10");
        for(List<UUID> ids:Arrays.asList(null,List.<UUID>of(),List.of(s.aItem(),s.aItem()),List.of(UUID.randomUUID()))) {
            assertThrows(ApiException.class,()->commands.execute(s.source(),new Request("bad-scope-"+UUID.randomUUID(),valid.fingerprint(),ids,valid.document())));
        }
        assertThrows(ApiException.class,()->commands.execute(s.source(),new Request(valid.idempotencyKey(),valid.fingerprint(),List.of(s.bItem()),valid.document())));
        assertThrows(ApiException.class,()->commands.execute(s.source(),new Request("omitted-selected-"+UUID.randomUUID(),valid.fingerprint(),List.of(s.aItem(),s.bItem()),valid.document())));
        var zero=request(s,s.aItem(),"0");
        assertThrows(ApiException.class,()->commands.execute(s.source(),zero));
        assertThat(item(s.aItem())).isEqualTo(beforeA);assertThat(item(s.bItem())).isEqualTo(beforeB);
        assertThat(allReservations(s.source())).isEqualTo(beforeReserve);
        assertThat(count("SELECT count(*) FROM subcontract_selected_outbound_commands WHERE source_issue_id=?",s.source())).isZero();
        db.update("UPDATE subcontract_material_issues SET remark='changed after review' WHERE id=?",s.source());
        assertThat(assertThrows(ApiException.class,()->commands.execute(s.source(),valid)).getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(allReservations(s.source())).isEqualTo(beforeReserve);
    }

    @Test void failedReserveAndLaterTransactionFailureRollBackTheTransferAndEveryReservation() {
        var s=scenario();String beforeA=item(s.aItem()),beforeB=item(s.bItem()),beforeReserve=allReservations(s.source());
        var bad=request(s,s.aItem(),"10");UUID empty=call("warehouse","empty-selected-"+UUID.randomUUID());bad.document().setWarehouseId(empty);
        assertThrows(RuntimeException.class,()->commands.execute(s.source(),bad));
        assertThat(item(s.aItem())).isEqualTo(beforeA);assertThat(item(s.bItem())).isEqualTo(beforeB);
        assertThat(allReservations(s.source())).isEqualTo(beforeReserve);
        var request=request(s,s.aItem(),"10");
        new TransactionTemplate(transactions).executeWithoutResult(status->{commands.execute(s.source(),request);status.setRollbackOnly();});
        assertThat(item(s.aItem())).isEqualTo(beforeA);assertThat(item(s.bItem())).isEqualTo(beforeB);
        assertThat(allReservations(s.source())).isEqualTo(beforeReserve);
        assertThat(commands.receipt(s.source(),request.idempotencyKey())).isNull();
        amount("10",onHand(s,s.a()));amount("20",onHand(s,s.b()));
    }

    @Test void receiptsBelongToTheOriginalActorAndDoNotPreserveARevokedReadGrant() {
        var s=scenario();var request=request(s,s.aItem(),"10");
        UUID executor=h.fixture.createUserWithPerms(s.world(),"selected-executor-"+UUID.randomUUID(),
                "subcontract_material_issue:view","subcontract_material_issue:edit","subcontract_material_issue:approve",
                "subcontract_outbound:view","subcontract_outbound:execute");
        h.fixture.loginAs(executor);var result=commands.execute(s.source(),request);
        assertThat(commands.execute(s.source(),request)).isEqualTo(result);
        h.fixture.loginAs(s.world().superAdminUserId());
        assertThat(commands.receipt(s.source(),request.idempotencyKey())).isNull();
        db.update("UPDATE user_permission_overrides SET effect='revoke' WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='subcontract_outbound:view')",executor);
        h.fixture.loginAs(executor);
        assertThrows(org.springframework.security.access.AccessDeniedException.class,()->commands.receipt(s.source(),request.idempotencyKey()));
        assertThrows(org.springframework.security.access.AccessDeniedException.class,()->commands.execute(s.source(),request));
        assertThat(movements(s.aItem())).isEqualTo(1);
    }

    @Test void executionForksPlatformFieldsWithoutReparentingOrExposingTheOriginalPrivateValues() {
        var s=scenario();var fields=beans.getBean(com.uten.imp.common.platformcolumns.PlatformColumnService.class);
        String scope="subcontract_material_issue_item";
        var note=fields.create(scope,new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CreateDefinition("split note "+UUID.randomUUID(),"TEXT",false,null));
        var price=fields.create(scope,new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CreateDefinition("split private "+UUID.randomUUID(),"NUMBER",true,null));
        var cells=List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(note.id(),"original selected note"),
                new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(price.id(),"123.40"));
        fields.write(scope,s.aItem(),new com.uten.imp.common.platformcolumns.PlatformColumnContracts.Write(0,cells));
        var stale=request(s,s.aItem(),"6");
        fields.write(scope,s.aItem(),new com.uten.imp.common.platformcolumns.PlatformColumnContracts.Write(1,cells));
        assertThat(assertThrows(ApiException.class,()->commands.execute(s.source(),stale)).getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(count("SELECT count(*) FROM subcontract_selected_outbound_commands WHERE source_issue_id=?",s.source())).isZero();
        fields.write(scope,s.bItem(),new com.uten.imp.common.platformcolumns.PlatformColumnContracts.Write(0,
                List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(note.id(),"untouched B"))));
        String beforeA=fieldRow(s.aItem()),beforeB=fieldRow(s.bItem());var request=request(s,s.aItem(),"6");
        UUID executor=h.fixture.createUserWithPerms(s.world(),"selected-fields-"+UUID.randomUUID(),
                "subcontract_material_issue:view","subcontract_material_issue:edit","subcontract_material_issue:approve",
                "subcontract_outbound:view","subcontract_outbound:execute");
        h.fixture.loginAs(executor);commands.execute(s.source(),request);
        UUID actual=db.queryForObject("SELECT execution_item_id FROM subcontract_selected_outbound_items WHERE source_item_id=?",UUID.class,s.aItem());
        assertThat(actual).isNotEqualTo(s.aItem());assertThat(fieldRow(s.aItem())).isEqualTo(beforeA);assertThat(fieldRow(s.bItem())).isEqualTo(beforeB);
        assertThat(db.queryForObject("SELECT cells::text FROM platform_record_fields WHERE scope=? AND record_id=?",String.class,scope,actual))
                .isEqualTo(db.queryForObject("SELECT cells::text FROM platform_record_fields WHERE scope=? AND record_id=?",String.class,scope,s.aItem()));
        assertThat(db.queryForObject("SELECT version FROM platform_record_fields WHERE scope=? AND record_id=?",Long.class,scope,actual)).isEqualTo(1);
        var publicView=fields.read(scope,new com.uten.imp.common.platformcolumns.PlatformColumnContracts.BatchRead(List.of(actual),List.of(note.id(),price.id()))).getFirst();
        assertThat(publicView.cells().stream().filter(cell->cell.columnId().equals(price.id())).findFirst().orElseThrow().masked()).isTrue();
    }

    @Test @Timeout(120) void concurrentSameKeyCommitsOneSliceAndCompetingKeysCannotMoveTheSameLineTwice() throws Exception {
        var s=scenario();var request=request(s,s.aItem(),"10");String beforeReserve=reservations(s.source(),s.b());
        try(var executor=Executors.newFixedThreadPool(2)) {
            var start=new CountDownLatch(1);
            Callable<Result> run=()->{h.fixture.loginAs(s.world().superAdminUserId());try{start.await();return commands.execute(s.source(),request);}finally{SecurityContextHolder.clearContext();}};
            var first=executor.submit(run);var second=executor.submit(run);start.countDown();
            assertThat(first.get(90,TimeUnit.SECONDS)).isEqualTo(second.get(90,TimeUnit.SECONDS));
        }
        assertThat(reservations(s.source(),s.b())).isEqualTo(beforeReserve);
        assertThat(movements(s.aItem())).isEqualTo(1);
        h.fixture.loginAs(s.world().superAdminUserId());
        var differentKey=new Request("competing-"+UUID.randomUUID(),request.fingerprint(),request.itemIds(),request.document());
        assertThat(assertThrows(ApiException.class,()->commands.execute(s.source(),differentKey)).getCode()).isEqualTo(ErrorCode.CONFLICT);
        var changedBody=request.document();changedBody.setRemark("changed replay payload");
        assertThat(assertThrows(ApiException.class,()->commands.execute(s.source(),request)).getCode()).isEqualTo(ErrorCode.CONFLICT);
    }

    @Test @Timeout(120) void concurrentDisjointSelectionsRequireAFreshReviewOfTheRemainingOriginalLine() throws Exception {
        var s=scenario();var a=request(s,s.aItem(),"10");var b=request(s,s.bItem(),"20");
        String beforeA=item(s.aItem()),beforeB=item(s.bItem());
        try(var executor=Executors.newFixedThreadPool(2)) {
            var start=new CountDownLatch(1);
            var futures=new ArrayList<Future<Object>>();
            for(var request:List.of(a,b)) futures.add(executor.submit(()->{
                h.fixture.loginAs(s.world().superAdminUserId());
                try{start.await();return commands.execute(s.source(),request);}catch(ApiException failure){return failure;}finally{SecurityContextHolder.clearContext();}
            }));
            start.countDown();List<Object> outcomes=new ArrayList<>();
            for(var future:futures)outcomes.add(future.get(90,TimeUnit.SECONDS));
            assertThat(outcomes.stream().filter(Result.class::isInstance)).hasSize(1);
            assertThat(outcomes.stream().filter(ApiException.class::isInstance).map(ApiException.class::cast).map(ApiException::getCode)).containsExactly(ErrorCode.CONFLICT);
        }
        h.fixture.loginAs(s.world().superAdminUserId());
        UUID remaining=issues.detail(s.source()).getItems().getFirst().getId();
        assertThat(item(remaining)).isEqualTo(remaining.equals(s.aItem())?beforeA:beforeB);
        commands.execute(s.source(),request(s,remaining,remaining.equals(s.aItem())?"10":"20"));
        amount("10",issued(s,s.a()));amount("20",issued(s,s.b()));
        amount("0",onHand(s,s.a()));amount("0",onHand(s,s.b()));
        assertThat(movements(s.aItem())).isEqualTo(1);
        assertThat(movements(s.bItem())).isEqualTo(1);
    }

    record Scenario(FullChainEndToEndTest.World world,UUID source,UUID orderItem,UUID a,UUID b,UUID aItem,UUID bItem){}
    private Scenario scenario(){return scenario(false);}
    private Scenario scenario(boolean exact){return scenario(exact,world->{});}
    Scenario scenario(boolean exact,java.util.function.Consumer<FullChainEndToEndTest.World> beforeDraw){
        String tag="sc-selected-"+UUID.randomUUID();var w=h.fixture.seedWorld(tag);h.fixture.loginAs(w.superAdminUserId());
        call("grantAuthorities",w.superAdminUserId(),new String[]{"subcontract_order:view","subcontract_order:draw","subcontract:view:all"});
        beforeDraw.accept(w);
        UUID parent=call("goods",w,tag,"P","委外"),a=call("goods",w,tag,"A","采购"),b=call("goods",w,tag,"B","采购");
        h.fixture.insertBom(parent,a,"1");h.fixture.insertBom(parent,b,"2");
        if(!exact){call("otherIn",w,w.warehouseId(),a,null,"10","10");call("otherIn",w,w.warehouseId(),b,null,"20","5");}
        UUID order;
        if(exact) {
            UUID sales=ReflectionTestUtils.invokeMethod(h.fixture,"createApprovedOrder",w,parent,"10","100");
            UUID salesItem=ReflectionTestUtils.invokeMethod(h.fixture,"orderItemId",sales);
            var analysis=h.analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"selected-exact-"+sales,
                    List.of(new PreviewItem("SALES_ORDER_ITEM",salesItem,null,null,null,null,null,BusinessTime.today().plusDays(5),BigDecimal.TEN))));
            for(UUID material:List.of(a,b)) {
                var fresh=h.analyses.detail(analysis.analysisId());
                var row=fresh.flatMaterials().stream().filter(value->value.goodsId().equals(material)).findFirst().orElseThrow();
                var buyRoutes=h.analyses.saveRoutes(analysis.analysisId(),new RouteRequest(fresh.version(),fresh.fingerprint(),
                        "selected-exact-buy-route-"+material,List.of(new RouteDecision(row.materialLineId(),row.actionGroupKey(),"BUY",null))));
                h.analysisCommands.notifySupply(analysis.analysisId(),new NotifyRequest(buyRoutes.version(),buyRoutes.fingerprint(),
                        "selected-exact-buy-"+material,"BUY",List.of(row.materialLineId()),List.of(),null));
                UUID purchaseItem=ReflectionTestUtils.invokeMethod(h.fixture,"approveExistingAnalysisPurchase",w,analysis.analysisId(),material);
                String quantity=material.equals(a)?"10":"20";
                UUID receipt=ReflectionTestUtils.invokeMethod(h.fixture,"receiveIntoQuarantine",w,material,purchaseItem,quantity,"NORMAL");
                ReflectionTestUtils.invokeMethod(h.fixture,"passAndStockPurchase",w,receipt,quantity);
            }
            analysis=h.analyses.detail(analysis.analysisId());
            var target=analysis.flatMaterials().stream().filter(row->row.goodsId().equals(parent)&&row.actionable()).findFirst().orElseThrow();
            var routed=h.analyses.saveRoutes(analysis.analysisId(),new RouteRequest(analysis.version(),analysis.fingerprint(),
                    "selected-exact-route-"+sales,List.of(new RouteDecision(target.materialLineId(),target.actionGroupKey(),"SUBCONTRACT",null))));
            h.analysisCommands.notifySupply(analysis.analysisId(),new NotifyRequest(routed.version(),routed.fingerprint(),
                    "selected-exact-notify-"+sales,"SUBCONTRACT",List.of(target.materialLineId()),List.of(),null));
            UUID application=db.queryForObject("""
                    SELECT item.id FROM preplan_supply_actions action JOIN subcontract_application_items item ON item.application_id=action.external_document_id
                    WHERE action.analysis_id=? AND action.route='SUBCONTRACT' AND item.goods_id=? AND NOT item.is_deleted
                    """,UUID.class,analysis.analysisId(),parent);
            com.uten.imp.features.subcontract.order.dto.OrderSaveRequest body=call("orderRequest",w,parent,"10",BusinessTime.today().plusDays(5),null);
            body.getItems().getFirst().setApplicationItemId(application);
            order=h.orders.create(body).getId();
        } else order=call("subcontractOrder",w,parent,"10",BusinessTime.today().plusDays(5),null);
        call("approveSubcontract",w,order);
        UUID orderItem=call("itemOf",order);
        UUID source=draws.submit(new DrawSubmitRequest(List.of(new DrawItemRequest(orderItem,null)),"draw-selected-"+orderItem)).issueIds().getFirst();
        UUID aItem=db.queryForObject("SELECT id FROM subcontract_material_issue_items WHERE issue_id=? AND goods_id=? AND NOT is_deleted",UUID.class,source,a);
        UUID bItem=db.queryForObject("SELECT id FROM subcontract_material_issue_items WHERE issue_id=? AND goods_id=? AND NOT is_deleted",UUID.class,source,b);
        return new Scenario(w,source,orderItem,a,b,aItem,bItem);
    }
    Request request(Scenario s,UUID selected,String qty){
        var review=commands.review(s.source());var document=review.document();
        var original=document.getItems().stream().filter(item->selected.equals(item.getId())).findFirst().orElseThrow();
        var line=new MaterialIssueItemLine();line.setId(original.getId());line.setPlanItemId(original.getPlanItemId());
        line.setOrderItemId(original.getOrderItemId());line.setGoodsId(original.getGoodsId());line.setColorId(original.getColorId());
        line.setUnitId(original.getUnitId());line.setUnitRate(original.getUnitRate());line.setQty(new BigDecimal(qty));
        var body=new MaterialIssueSaveRequest();body.setBillDate(document.getBillDate());body.setWarehouseId(document.getWarehouseId());
        body.setSupplierId(document.getSupplierId());body.setWorkerId(document.getWorkerId());body.setItems(List.of(line));
        return new Request("selected-outbound-"+UUID.randomUUID(),review.fingerprint(),List.of(selected),body);
    }
    private String item(UUID id){return db.queryForObject("SELECT to_jsonb(item)::text FROM subcontract_material_issue_items item WHERE id=?",String.class,id);}
    private String reservations(UUID source,UUID goods){return db.queryForObject("SELECT jsonb_agg(to_jsonb(r) ORDER BY id)::text FROM stock_reservations r WHERE source_doc_id=? AND goods_id=?",String.class,source,goods);}
    private String allReservations(UUID source){return db.queryForObject("SELECT jsonb_agg(to_jsonb(r) ORDER BY id)::text FROM stock_reservations r WHERE source_doc_id=?",String.class,source);}
    private String fieldRow(UUID id){return db.queryForObject("SELECT to_jsonb(f)::text FROM platform_record_fields f WHERE scope='subcontract_material_issue_item' AND record_id=?",String.class,id);}
    private BigDecimal onHand(Scenario s,UUID goods){return db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",BigDecimal.class,goods,s.world().warehouseId());}
    private BigDecimal issued(Scenario s,UUID goods){return db.queryForObject("SELECT sum(issued_qty) FROM subcontract_material_plan_items WHERE order_item_id=? AND goods_id=? AND NOT is_deleted",BigDecimal.class,s.orderItem(),goods);}
    private int count(String sql,Object...args){return db.queryForObject(sql,Integer.class,args);}
    private int movements(UUID original){return count("SELECT count(*) FROM stock_movements WHERE source_item_id IN (SELECT execution_item_id FROM subcontract_selected_outbound_items WHERE source_item_id=?)",original);}
    private void amount(String expected,BigDecimal actual){assertThat(actual).isEqualByComparingTo(expected);}
    @SuppressWarnings("unchecked") private <T>T call(String method,Object...args){return (T)ReflectionTestUtils.invokeMethod(h,method,args);}
}
