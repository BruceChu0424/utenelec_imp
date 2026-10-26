package com.uten.imp.businesschain;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService.ClosureRequest;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.subcontract.application.SubcontractApplicationService;
import com.uten.imp.features.subcontract.application.dto.ApplicationItemLine;
import com.uten.imp.features.subcontract.application.dto.ApplicationSaveRequest;
import com.uten.imp.features.subcontract.draw.SubcontractDrawCommandService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts;
import com.uten.imp.features.subcontract.draw.SubcontractDrawQueryService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService;
import com.uten.imp.features.subcontract.waste.SubcontractWasteService;
import com.uten.imp.features.subcontract.waste.dto.WasteItemLine;
import com.uten.imp.features.subcontract.waste.dto.WasteSaveRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Actual buyer, finance, warehouse and quality commands across the subcontract lifecycle. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@SpringBootTest(properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only", // gitleaks:allow shared synthetic fixture.
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow shared synthetic fixture.
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractOrderClosureLifecycleMatrixEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractApplicationService applications;
    @Autowired SubcontractOrderService orders;
    @Autowired com.uten.imp.features.subcontract.report.SubcontractReportService orderReports;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery approvalProjection;
    @Autowired ProcurementOrderClosureService closures;
    @Autowired TaskClaimService claims;
    @Autowired SubcontractDrawCommandService draws;
    @Autowired SubcontractDrawQueryService drawQueries;
    @Autowired SubcontractMaterialPlanService plans;
    @Autowired SubcontractMaterialIssueService issues;
    @Autowired SubcontractMaterialReturnService returns;
    @Autowired SubcontractWasteService wastes;
    @Autowired SubcontractShortDeliveryService shortDelivery;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired ProcurementArrivalControlService arrivalTasks;
    @Autowired ProcurementInspectionService inspections;
    @Autowired WarehouseTaskScopePort warehouseScopes;
    @Autowired BusinessOutboxProcessor outbox;
    @Autowired com.uten.imp.features.notice.outbox.BusinessOutboxScheduler outboxScheduler;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService planning;
    private FullChainEndToEndTest harness;

    private record Fixture(FullChainEndToEndTest.World world,UUID material,UUID buyer,UUID reviewer,
                           UUID warehouseUser,UUID qualityUser,UUID source,UUID order,UUID item,String billNo) {}
    private record Arrival(UUID receipt,UUID inspection,UUID shortCase) {}

    @BeforeEach void harness() {outboxScheduler.close();harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
    @AfterEach void logout() {SecurityContextHolder.clearContext();}

    @Test void anUnapprovedOrderHasNoMaterialPlanAndCannotBypassFinanceByClosingIt() {
        Fixture f=fixture(false);
        var preview=closures.preview("SUBCONTRACT",f.order());
        assertThat(preview.canSubmit()).isFalse();
        assertThatThrownBy(()->closures.submit("SUBCONTRACT",f.order(),new ClosureRequest("CLOSE","尚未生效",preview.fingerprint())))
                .isInstanceOf(ApiException.class);
        assertThat(count("SELECT COUNT(*) FROM subcontract_material_plans WHERE order_id=?",f.order())).isZero();
        assertThat(count("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_id=? AND request_type<>'ORDER'",f.order())).isZero();
        assertThat(number("SELECT ordered_qty FROM subcontract_application_items WHERE id=?",f.source())).isZero();
    }

    @ParameterizedTest @ValueSource(strings={"0","4","10"})
    void closureRetiresOnlyFutureWorkAtUnstartedPartlyIssuedAndFullyIssuedStages(String issued) {
        Fixture f=fixture(true);BigDecimal amount=new BigDecimal(issued);
        var beforeReport=orderReports.orderDetail(f.billNo(),null,null,null,null,null,java.util.Map.of(),1,50,null,null);
        assertThat(beforeReport.rows()).hasSize(1);
        assertThat(new BigDecimal(beforeReport.rows().getFirst().get("differenceQtyExact").toString())).isEqualByComparingTo("-10");
        if(amount.signum()>0) issue(f,amount);
        BigDecimal stockBefore=stock(f,f.material());
        BigDecimal custodyBefore=custody(f,"at_supplier_qty");
        BigDecimal plannedBefore=number("SELECT SUM(planned_qty) FROM subcontract_material_plan_items WHERE order_item_id=? AND NOT is_deleted",f.item());
        assertThat(inboundCount(f)).isEqualTo(amount.signum()>0?1:0);
        long financialBefore=count("SELECT COUNT(*) FROM ar_ap_ledger WHERE source_doc_id=?",f.order());

        approveClosure(f,"CLOSE");

        var afterReport=orderReports.export("ORDER/detail",java.util.Map.of("billNo",f.billNo()),null,null);
        assertThat(afterReport.rows()).hasSize(1);
        assertThat(afterReport.columns()).anyMatch(column->column.key().equals("differenceQty"));
        assertThat(new BigDecimal(afterReport.rows().getFirst().get("differenceQtyExact").toString())).isEqualByComparingTo("-10");

        assertEndedWork(f);
        assertThat(stock(f,f.material())).isEqualByComparingTo(stockBefore);
        assertThat(custody(f,"at_supplier_qty")).isEqualByComparingTo(custodyBefore);
        assertThat(number("SELECT SUM(planned_qty) FROM subcontract_material_plan_items WHERE order_item_id=? AND NOT is_deleted",f.item()))
                .isEqualByComparingTo(plannedBefore);
        assertThat(number("SELECT SUM(issued_qty) FROM subcontract_material_plan_items WHERE order_item_id=? AND NOT is_deleted",f.item())).isEqualByComparingTo(amount);
        assertThat(number("SELECT ordered_qty FROM subcontract_application_items WHERE id=?",f.source())).isZero();
        assertThat(number("SELECT fn_subcontract_application_open_qty(?)",f.source())).isEqualByComparingTo("10");
        assertThat(count("SELECT COUNT(*) FROM ar_ap_ledger WHERE source_doc_id=?",f.order())).isEqualTo(financialBefore);
        assertThat(count("SELECT COUNT(*) FROM subcontract_waste_items wi JOIN subcontract_material_issue_items ii ON ii.id=wi.material_issue_item_id WHERE ii.order_item_id=?",f.item())).isZero();
        if(amount.signum()>0) {
            materialReturn(f,BigDecimal.ONE);
            assertThat(custody(f,"returned_qty")).isEqualByComparingTo("1");
            assertThat(stock(f,f.material())).isEqualByComparingTo(stockBefore.add(BigDecimal.ONE));
            assertEndedWork(f);
        }
    }

    @Test void aRealWarehouseDraftBlocksClosureUntilBuyerWithdrawalReleasesEveryReservationAndCard() {
        Fixture f=fixture(true);
        harness.loginAs(f.buyer());
        UUID issue=harness.submitSubcontractDraw(f.item(),new BigDecimal("6"),"matrix-draft-"+f.item()).getFirst();
        drain();
        assertThat(warehouseDraftCount(f)).isEqualTo(1);
        assertThat(reservedFuture(f)).isEqualByComparingTo("6");
        assertThat(activeNotices("SUBCONTRACT_MATERIAL_ISSUE",issue)).isPositive();
        harness.loginAs(f.buyer());
        var blocked=closures.preview("SUBCONTRACT",f.order());
        assertThat(blocked.canSubmit()).isFalse();
        assertThat(blocked.blockReason()).contains("领料");
        assertThatThrownBy(()->closures.submit("SUBCONTRACT",f.order(),new ClosureRequest("CLOSE","先撤未发领料",blocked.fingerprint())))
                .isInstanceOf(ApiException.class);
        var withdrawn=draws.withdraw(new SubcontractDrawContracts.DrawWithdrawRequest(List.of(f.item())));
        assertThat(withdrawn.withdrawnIssueIds()).containsExactly(issue);
        drain();
        assertThat(warehouseDraftCount(f)).isZero();assertThat(reservedFuture(f)).isZero();
        assertThat(activeNotices("SUBCONTRACT_MATERIAL_ISSUE",issue)).isZero();
        assertThat(db.queryForObject("SELECT is_deleted FROM subcontract_material_issues WHERE id=?",Boolean.class,issue)).isTrue();

        approveClosure(f,"CLOSE");
        assertEndedWork(f);
        harness.loginAs(f.warehouseUser());
        assertThatThrownBy(()->issues.approve(issue)).isInstanceOf(ApiException.class);
        harness.loginAs(f.buyer());
        assertThat(stock(f,f.material())).isEqualByComparingTo("10");
        assertThat(custody(f,"at_supplier_qty")).isZero();
    }

    @Test void pendingAndPartialQualityRemainVisibleUntilQualityFinishesThenBuyerReleasesHeldStockWithoutInventingLoss() {
        Fixture f=fixture(true);issue(f,BigDecimal.TEN);Arrival a=arrival(f,"4");
        String physicalBefore=db.queryForObject("SELECT to_jsonb(ri)::text FROM subcontract_receipt_items ri WHERE receipt_id=?",String.class,a.receipt());
        String payableBefore=db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(ledger) ORDER BY ledger.id),'[]'::jsonb)::text FROM ar_ap_ledger ledger WHERE source_doc_id=?",String.class,a.receipt());
        harness.loginAs(f.buyer());
        assertThat(closures.preview("SUBCONTRACT",f.order()).canSubmit()).isFalse();
        pass(f,a,BigDecimal.ONE);
        assertThat(db.queryForObject("SELECT status FROM procurement_inspection_items WHERE id=?",String.class,a.inspection())).isEqualTo("PARTIAL");
        harness.loginAs(f.buyer());
        assertThat(closures.preview("SUBCONTRACT",f.order()).canSubmit()).isFalse();
        assertThat(stock(f,f.world().goodsE())).isZero();
        pass(f,a,null);
        assertThat(stock(f,f.world().goodsE())).isZero();
        assertThat(number("SELECT passed_base_qty FROM procurement_inspection_items WHERE id=?",a.inspection())).isEqualByComparingTo("4");
        drain();
        assertThat(activeNotices("SUBCONTRACT_SHORT_DELIVERY_CASE",a.shortCase())).isPositive();

        approveClosure(f,"CLOSE");
        assertEndedWork(f);
        assertThat(stock(f,f.world().goodsE())).isEqualByComparingTo("4");
        assertThat(number("SELECT warehouse_stocked_base_qty FROM procurement_inspection_items WHERE id=?",a.inspection())).isEqualByComparingTo("4");
        assertThat(db.queryForObject("SELECT status FROM subcontract_short_delivery_cases WHERE id=?",String.class,a.shortCase())).isEqualTo("CANCELED");
        assertThat(activeNotices("SUBCONTRACT_SHORT_DELIVERY_CASE",a.shortCase())).isZero();
        assertThat(db.queryForObject("SELECT to_jsonb(ri)::text FROM subcontract_receipt_items ri WHERE receipt_id=?",String.class,a.receipt())).isEqualTo(physicalBefore);
        assertThat(db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(ledger) ORDER BY ledger.id),'[]'::jsonb)::text FROM ar_ap_ledger ledger WHERE source_doc_id=?",String.class,a.receipt())).isEqualTo(payableBefore);
        assertThat(custody(f,"consumed_qty")).isEqualByComparingTo("4");
        assertThat(custody(f,"wasted_qty")).isZero();
        assertThat(number("SELECT ordered_qty FROM subcontract_application_items WHERE id=?",f.source())).isEqualByComparingTo("4");
    }

    @Test void buyerDirectTerminationCancelsWaitingForAnotherBatchWithoutConvertingTheMissingSixIntoAcceptedLoss() {
        Fixture f=fixture(true);issue(f,BigDecimal.TEN);Arrival a=arrival(f,"4");pass(f,a,null);
        harness.loginAs(f.buyer());
        var before=shortDelivery.detail(a.shortCase()).row();
        shortDelivery.decide(a.shortCase(),new DecisionRequest("WAIT_MORE",BusinessTime.today().plusDays(3),"先等下一批",before.version()));
        assertThat(shortDelivery.counts().waiting()).isEqualTo(1);
        assertThat(stock(f,f.world().goodsE())).isEqualByComparingTo("4");

        approveClosure(f,"CLOSE");
        assertEndedWork(f);
        harness.loginAs(f.buyer());
        assertThat(shortDelivery.counts().waiting()).isZero();
        assertThat(shortDelivery.counts().pending()).isZero();
        assertThat(number("SELECT fn_subcontract_settled_loss_qty(?)",f.item())).isZero();
        assertThat(custody(f,"wasted_qty")).isZero();
        assertThat(number("SELECT qty FROM subcontract_order_items WHERE id=?",f.item())).isEqualByComparingTo("10");
    }

    @Test void naturallyCompletedOrderWithAcceptedLossCannotAddAnotherCancellationOrReplacement() {
        Fixture f=fixture(true);issue(f,BigDecimal.TEN);Arrival a=arrival(f,"4");pass(f,a,null);
        harness.loginAs(f.buyer());
        var row=shortDelivery.detail(a.shortCase()).row();
        shortDelivery.decide(a.shortCase(),new DecisionRequest("ACCEPT_LOSS",null,"核对后接受实际短交，其余材料按真实损耗追责",row.version()));
        assertThat(number("SELECT fn_subcontract_settled_loss_qty(?)",f.item())).isEqualByComparingTo("6");
        String wasteBefore=wasteFacts(f);String liabilityBefore=lossCaseFacts(f);
        var preview=closures.preview("SUBCONTRACT",f.order());
        assertThat(preview.canSubmit()).isFalse();
        assertThat(preview.canReorder()).isFalse();
        assertThat(preview.items()).singleElement().satisfies(line->assertThat(line.remainingQty()).isZero());
        assertThatThrownBy(()->closures.submit("SUBCONTRACT",f.order(),new ClosureRequest("CLOSE_AND_REORDER","不能把已结损耗再订一次",preview.fingerprint())))
                .isInstanceOf(ApiException.class);

        assertThatThrownBy(()->closures.submit("SUBCONTRACT",f.order(),new ClosureRequest("CLOSE","没有余量不能再次取消",preview.fingerprint())))
                .isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT termination_case_id FROM subcontract_orders WHERE id=?",UUID.class,f.order())).isNull();
        assertThat(wasteFacts(f)).isEqualTo(wasteBefore);assertThat(lossCaseFacts(f)).isEqualTo(liabilityBefore);
        assertThat(db.queryForObject("SELECT status FROM subcontract_short_delivery_cases WHERE id=?",String.class,a.shortCase())).isEqualTo("ACCEPTED_LOSS");
        assertThat(number("SELECT fn_subcontract_settled_loss_qty(?)",f.item())).isEqualByComparingTo("6");
        assertThat(number("SELECT ordered_qty FROM subcontract_application_items WHERE id=?",f.source())).isEqualByComparingTo("10");
        assertThat(wasteFacts(f)).isEqualTo(wasteBefore);assertThat(lossCaseFacts(f)).isEqualTo(liabilityBefore);
        assertThat(number("SELECT fn_subcontract_settled_loss_qty(?)",f.item())).isEqualByComparingTo("6");
    }

    @ParameterizedTest @CsvSource({"2,0,CLOSE","0,1,CLOSE","2,1,CLOSE_AND_REORDER"})
    void existingMaterialReturnsAndActualLossRemainAtTheOldSupplierAndDoNotShrinkTheFinishedOrder(String returned,String wasted,String mode) {
        Fixture f=fixture(true);issue(f,BigDecimal.TEN);
        if(new BigDecimal(returned).signum()>0) materialReturn(f,new BigDecimal(returned));
        if(new BigDecimal(wasted).signum()>0) materialWaste(f,new BigDecimal(wasted));
        BigDecimal stockBefore=stock(f,f.material());String wasteBefore=wasteFacts(f),liabilityBefore=lossCaseFacts(f);

        FinanceApproval approval=approveClosure(f,mode);
        assertEndedWork(f);
        assertThat(stock(f,f.material())).isEqualByComparingTo(stockBefore);
        assertThat(custody(f,"at_supplier_qty")).isEqualByComparingTo("10");
        assertThat(custody(f,"returned_qty")).isEqualByComparingTo(returned);
        assertThat(custody(f,"wasted_qty")).isEqualByComparingTo(wasted);
        assertThat(wasteFacts(f)).isEqualTo(wasteBefore);assertThat(lossCaseFacts(f)).isEqualTo(liabilityBefore);
        assertThat(number("SELECT qty FROM subcontract_order_items WHERE id=?",f.item())).isEqualByComparingTo("10");
        if(mode.equals("CLOSE_AND_REORDER")) {
            UUID replacement=replacement(approval);
            assertThat(number("SELECT SUM(qty) FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",replacement)).isEqualByComparingTo("10");
            assertThat(count("SELECT COUNT(*) FROM subcontract_material_plans WHERE order_id=?",replacement)).isZero();
            assertThat(number("SELECT fn_subcontract_application_open_qty(?)",f.source())).isZero();
        }
        materialReturn(f,BigDecimal.ONE);
        assertThat(custody(f,"returned_qty")).isEqualByComparingTo(new BigDecimal(returned).add(BigDecimal.ONE));
        assertThat(custody(f,"wasted_qty")).isEqualByComparingTo(wasted);
        UUID independentWaste=materialWaste(f,BigDecimal.ONE);
        assertThat(custody(f,"wasted_qty")).isEqualByComparingTo(new BigDecimal(wasted).add(BigDecimal.ONE));
        assertThat(wastes.unapprovalEligibility(independentWaste).eligible()).isTrue();
        wastes.reverse(independentWaste);
        assertThat(custody(f,"wasted_qty")).isEqualByComparingTo(wasted);
        assertThat(number("SELECT qty FROM subcontract_order_items WHERE id=?",f.item())).isEqualByComparingTo("10");
        assertEndedWork(f);
    }

    @Test void realParentProductionDemandKeepsWaitingAndAReplacementNeedsFreshKitInsteadOfStealingTheOldSupplierMaterial() {
        Fixture base=fixture(false);
        orders.delete(base.order());
        harness.loginAs(base.world().superAdminUserId());
        UUID product=UUID.randomUUID();harness.insertGoods(product,"SCM-P-"+product,"终止委外联动成品","自制",base.world().unitId(),base.world().unitLegacy());
        harness.insertBom(product,base.world().goodsE(),"1");
        UUID sales=harness.createApprovedOrder(base.world(),product,"10","100");
        UUID salesItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,sales);
        var analysis=analyses.preview(new MaterialAnalysisContracts.PreviewRequest(null,null,null,base.world().warehouseId(),"matrix-analysis-"+sales,
                List.of(new MaterialAnalysisContracts.PreviewItem("SALES_ORDER_ITEM",salesItem,null,null,null,null,null,BusinessTime.today().plusDays(7),BigDecimal.TEN))));
        analyses.saveRoutes(analysis.analysisId(),new MaterialAnalysisContracts.RouteRequest(analysis.version(),analysis.fingerprint(),"matrix-routes-"+sales,
                analysis.flatMaterials().stream().filter(MaterialAnalysisContracts.MaterialView::actionable).map(m->new MaterialAnalysisContracts.RouteDecision(m.materialLineId(),m.actionGroupKey(),
                        m.goodsId().equals(base.world().goodsE())?"SUBCONTRACT":m.goodsId().equals(base.material())?"BUY":"MAKE",null)).toList()));
        var routed=analyses.detail(analysis.analysisId());
        UUID materialLine=routed.flatMaterials().stream().filter(m->m.goodsId().equals(base.world().goodsE())&&m.actionable()).findFirst().orElseThrow().materialLineId();
        planning.notifySupply(routed.analysisId(),new MaterialAnalysisContracts.NotifyRequest(routed.version(),routed.fingerprint(),"matrix-notify-"+sales,"SUBCONTRACT",List.of(materialLine),List.of(),null));
        UUID source=db.queryForObject("SELECT allocation.external_item_id FROM preplan_supply_action_allocations allocation JOIN preplan_supply_actions action ON action.id=allocation.action_id WHERE allocation.analysis_id=? AND action.route='SUBCONTRACT'",UUID.class,routed.analysisId());
        var beforePlan=analyses.detail(routed.analysisId());
        var root=beforePlan.products().stream().filter(p->p.goodsId().equals(product)).findFirst().orElseThrow();
        Object assignment=ReflectionTestUtils.invokeMethod(harness,"productionAssignment","matrix-assignment-"+sales);
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId"),worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        var generated=planning.issueWorkshopPlans(beforePlan.analysisId(),new MaterialAnalysisContracts.IssueWorkshopPlansRequest(beforePlan.version(),beforePlan.fingerprint(),"matrix-plan-"+sales,
                base.world().warehouseId(),BusinessTime.today(),BusinessTime.today().plusDays(7),true,List.of(new MaterialAnalysisContracts.IssueWorkshopPlansRequest.IssuePlanLine(
                null,root.analysisLineId(),BigDecimal.TEN,null,null,workshop,null,worker,null,null))));
        UUID plan=generated.plans().getFirst().planId();harness.confirmFullKitRoutes(plan);
        harness.loginAs(base.buyer());
        var request=orderRequest(base.world(),source);var order=orders.create(request);
        Fixture f=new Fixture(base.world(),base.material(),base.buyer(),base.reviewer(),base.warehouseUser(),base.qualityUser(),source,order.getId(),order.getItems().getFirst().getId(),order.getBillNo());
        approveInitial(f);issue(f,BigDecimal.TEN);
        UUID demand=db.queryForObject("SELECT id FROM production_material_demands WHERE plan_id=? AND goods_id=? AND NOT is_deleted",UUID.class,plan,base.world().goodsE());
        long demands=count("SELECT COUNT(*) FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",plan);
        // Modern analysis plans own supply through the original preplan action. Their formal package
        // deliberately creates neither another application nor the old plan-first generic pegs.
        assertThat(count("SELECT COUNT(*) FROM production_material_supply_pegs WHERE demand_id=? AND supply_type IN ('SUBCONTRACT_APPLICATION_ITEM','SUBCONTRACT_ORDER_ITEM')",demand)).isZero();
        assertThat(count("SELECT COUNT(*) FROM production_planning_package_documents mapping JOIN production_planning_packages package ON package.id=mapping.package_id WHERE package.plan_id=? AND mapping.document_type='SUBCONTRACT_APPLICATION'",plan)).isZero();
        assertThat(number("SELECT fn_procurement_order_source_remaining_qty('SUBCONTRACT',?,?)",f.item(),source)).isEqualByComparingTo("10");

        FinanceApproval closed=approveClosure(f,"CLOSE_AND_REORDER");
        assertEndedWork(f);
        assertThat(number("SELECT fn_procurement_order_source_remaining_qty('SUBCONTRACT',?,?)",f.item(),source)).isZero();
        assertThat(number("SELECT required_qty FROM production_material_demands WHERE id=?",demand)).isEqualByComparingTo("10");
        assertThat(count("SELECT COUNT(*) FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",plan)).isEqualTo(demands);
        assertThat(db.queryForList("SELECT status FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",String.class,plan)).containsOnly("WAITING");
        assertThat(count("SELECT COUNT(*) FROM stock_reservations WHERE demand_id=? AND status=0 AND NOT is_deleted",demand)).isZero();
        assertThat(number("SELECT SUM(allocated_qty-consumed_qty-released_qty) FROM production_material_supply_pegs WHERE demand_id=? AND supply_type='SUBCONTRACT_ORDER_ITEM' AND status<>'REVERSED'",demand)).isZero();
        assertThat(custody(f,"at_supplier_qty")).isEqualByComparingTo("10");
        assertThat(stock(f,f.material())).isZero();

        UUID replacement=replacement(closed),supplier=UUID.randomUUID();
        db.update("INSERT INTO suppliers(id,code,name,status,code_sequence) VALUES (?,?,?,'使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers))",supplier,"SCM-S-"+supplier,"重建单的新加工商");
        var replacementDetail=orders.detail(replacement);var newRequest=orderRequest(f.world(),source);
        newRequest.setSupplierId(supplier);newRequest.getItems().getFirst().setId(replacementDetail.getItems().getFirst().getId());
        assertThatThrownBy(()->orders.update(replacement,newRequest)).isInstanceOf(ApiException.class).hasMessageContaining("齐套");
        assertThat(count("SELECT COUNT(*) FROM subcontract_material_plans WHERE order_id=?",replacement)).isZero();
        assertThat(custody(f,"at_supplier_qty")).isEqualByComparingTo("10");
        harness.receiveSubcontractMaterial(f.world(),f.material(),"10");harness.loginAs(f.buyer());
        orders.update(replacement,newRequest);finance.submit("SUBCONTRACT",replacement);
        harness.loginAs(f.reviewer());harness.approvePendingFinance("SUBCONTRACT",replacement);harness.loginAs(f.buyer());
        assertThat(number("SELECT SUM(planned_qty) FROM subcontract_material_plan_items line JOIN subcontract_material_plans h ON h.id=line.plan_id WHERE h.order_id=? AND NOT line.is_deleted AND NOT h.is_deleted",replacement)).isEqualByComparingTo("10");
        assertThat(number("SELECT ordered_qty FROM subcontract_application_items WHERE id=?",source)).isEqualByComparingTo("10");
        assertThat(count("SELECT COUNT(*) FROM production_material_demands WHERE plan_id=? AND NOT is_deleted",plan)).isEqualTo(demands);
        assertThat(count("SELECT COUNT(*) FROM production_material_supply_pegs WHERE demand_id=? AND supply_type IN ('SUBCONTRACT_APPLICATION_ITEM','SUBCONTRACT_ORDER_ITEM')",demand)).isZero();
        UUID newItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,replacement);
        assertThat(number("SELECT fn_procurement_order_source_remaining_qty('SUBCONTRACT',?,?)",newItem,source)).isEqualByComparingTo("10");
        assertThat(number("SELECT fn_procurement_order_source_remaining_qty('SUBCONTRACT',?,?)",f.item(),source)).isZero();
        assertThat(count("SELECT COUNT(*) FROM production_planning_package_documents mapping JOIN production_planning_packages package ON package.id=mapping.package_id WHERE package.plan_id=? AND mapping.document_type='SUBCONTRACT_APPLICATION'",plan)).isZero();
        materialReturn(f,BigDecimal.ONE);
        assertThat(custody(f,"returned_qty")).isEqualByComparingTo("1");
        assertThat(count("SELECT COUNT(*) FROM subcontract_material_issue_items WHERE order_item_id IN (SELECT id FROM subcontract_order_items WHERE order_id=?) AND NOT is_deleted",replacement)).isZero();
        assertThat(db.queryForList("SELECT status FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",String.class,plan)).containsOnly("WAITING");
    }

    @Test void buyerWithoutFinanceManageAuthorityCanRetireALegacyReviewClaimWhenDirectlyClosing() {
        Fixture f=fixture(true);
        var preview=closures.preview("SUBCONTRACT",f.order());
        var legacy=LegacyProcurementClosureFixture.pending(db,preview,f.world(),"CLOSE");
        harness.loginAs(f.reviewer());
        assertThatThrownBy(()->claims.claim("PROCUREMENT_FINANCE_APPROVE",legacy.caseId().toString())).isInstanceOf(ApiException.class);
        assertThat(approvalProjection.canCurrentActorReviewPending("SUBCONTRACT",f.order())).isFalse();
        assertThat(approvalProjection.pendingOrderIds("SUBCONTRACT")).doesNotContain(f.order());
        UUID claimId=UUID.randomUUID();
        db.update("INSERT INTO task_claims(id,target_type,target_key,claimed_by,lease_until) SELECT ?,'PROCUREMENT_FINANCE_APPROVE',?,employee_id,now()+interval '30 minutes' FROM users WHERE id=?",
                claimId,legacy.caseId().toString(),f.reviewer());
        String billNo=f.billNo();
        assertThat(finance.tasks(1,50,"SUBCONTRACT",billNo,null,null,null,"PENDING").getItems()).isEmpty();
        assertThat(finance.tasks(1,50,"SUBCONTRACT",billNo,null,null,null,"CLOSURE_PENDING").getItems())
                .singleElement().satisfies(task->assertThat(task.allowedActions()).isEmpty());
        harness.loginAs(f.buyer());
        approvalProjection.requireMutable("SUBCONTRACT",f.order());
        var current=closures.preview("SUBCONTRACT",f.order());
        assertThat(current.canSubmit()).as(current.blockReason()).isTrue();
        var completed=closures.submit("SUBCONTRACT",f.order(),new ClosureRequest("CLOSE","Buyer rechecked the legacy request",current.fingerprint()));
        assertThat(completed.status()).isEqualTo("APPROVED");
        assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?",String.class,legacy.caseId())).isEqualTo("CANCELED");
        assertThat(count("SELECT COUNT(*) FROM task_claims WHERE id=? AND released_at IS NULL",claimId)).isZero();
        assertThat(db.queryForObject("SELECT release_reason FROM task_claims WHERE id=?",String.class,claimId)).isEqualTo("business_resolved");
        assertThat(count("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_id=? AND status='PENDING'",f.order())).isZero();
        drain();
        assertEndedWork(f);
    }

    private Fixture fixture(boolean approve) {
        var w=harness.seedWorld("matrix-sc-"+UUID.randomUUID());
        UUID material=harness.ensureSubcontractDirectMaterial(w,w.goodsE());harness.receiveSubcontractMaterial(w,material,"10");
        UUID buyer=harness.createUserWithPerms(w,"matrix-buyer-"+UUID.randomUUID(),"notice:read","goods:view","subcontract_application:view","subcontract_application:create",
                "subcontract_order:create","subcontract_order:edit","subcontract_order:delete","subcontract_order:view","subcontract_order:decompose","subcontract_order:draw","subcontract_order:submit_finance",
                "subcontract_short_delivery:decide","subcontract_material_return:create","subcontract_material_return:approve","subcontract_material_return:view",
                "subcontract_waste:create","subcontract_waste:approve","subcontract_waste:view","subcontract_waste:reverse");
        UUID reviewer=harness.createUserWithPerms(w,"matrix-finance-"+UUID.randomUUID(),"notice:read","finance_order_approval:view","finance_order_approval:approve","finance_order_approval:reject");
        UUID warehouse=harness.createUserWithPerms(w,"matrix-warehouse-"+UUID.randomUUID(),"notice:read","subcontract_outbound:view","subcontract_outbound:execute",
                "subcontract_material_issue:view","subcontract_material_issue:edit","subcontract_material_issue:approve","warehouse_inbound:view","warehouse_inbound:stock_in",
                "warehouse_iqc_stock_in:view","warehouse_iqc_stock_in:before_inspection","warehouse_iqc_stock_in:confirm");
        UUID quality=harness.createUserWithPerms(w,"matrix-quality-"+UUID.randomUUID(),"notice:read","procurement_inspection:view","procurement_inspection:handle");
        db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) SELECT ?,employee_id FROM users WHERE id=?",w.warehouseId(),warehouse);
        harness.loginAs(buyer);
        var application=new ApplicationSaveRequest();application.setBillDate(BusinessTime.today());application.setSupplierId(w.supplierId());application.setWarehouseId(w.warehouseId());
        var sourceLine=new ApplicationItemLine();sourceLine.setGoodsId(w.goodsE());sourceLine.setUnitId(w.unitId());sourceLine.setUnitRate(BigDecimal.ONE);sourceLine.setQty(BigDecimal.TEN);application.setItems(List.of(sourceLine));
        var source=applications.create(application);
        // Issued upstream input; this service has no public approval transition. Operational order/warehouse changes below use real commands.
        db.update("UPDATE subcontract_applications SET status=1 WHERE id=?",source.getId());
        UUID sourceId=source.getItems().getFirst().getId();var order=orders.create(orderRequest(w,sourceId));
        var f=new Fixture(w,material,buyer,reviewer,warehouse,quality,sourceId,order.getId(),order.getItems().getFirst().getId(),order.getBillNo());
        if(approve) approveInitial(f);
        return f;
    }
    private OrderSaveRequest orderRequest(FullChainEndToEndTest.World w,UUID source) {
        var request=new OrderSaveRequest();request.setBillDate(BusinessTime.today());request.setDeliverDate(BusinessTime.today().plusDays(7));request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
        var line=new OrderItemLine();line.setLineNo(1);line.setGoodsId(w.goodsE());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.TEN);
        line.setPrice(BigDecimal.TEN);line.setAllowedLossPct(BigDecimal.ZERO);line.setApplicationItemId(source);request.setItems(List.of(line));return request;
    }
    private void approveInitial(Fixture f) {
        harness.loginAs(f.buyer());finance.submit("SUBCONTRACT",f.order());
        harness.loginAs(f.reviewer());harness.approvePendingFinance("SUBCONTRACT",f.order());harness.loginAs(f.buyer());drain();
    }
    private void issue(Fixture f,BigDecimal quantity) {
        harness.loginAs(f.buyer());var draft=harness.submitSubcontractDraw(f.item(),quantity,"matrix-issue-"+UUID.randomUUID());
        harness.loginAs(f.warehouseUser());
        for (UUID id : draft) {
            issues.approve(id);
        }
        harness.loginAs(f.buyer());
        drain();
    }
    private Arrival arrival(Fixture f,String quantity) {
        harness.loginAs(f.warehouseUser());
        UUID receiver=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,f.warehouseUser());
        var result=arrivals.register(new WarehouseArrivalRegisterRequest("matrix-arrival-"+UUID.randomUUID(),"SUBCONTRACT",BusinessTime.today(),f.world().supplierId(),f.world().warehouseId(),null,receiver,null,
                List.of(new ArrivalLine(f.world().goodsE(),new BigDecimal(quantity),f.item(),null,f.world().unitId(),BigDecimal.ONE,null,null,null,"MATRIX-SHELF")),true,true));
        UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,result.receiptId());
        UUID shortCase=db.queryForObject("SELECT id FROM subcontract_short_delivery_cases WHERE order_item_id=? AND status IN ('PENDING_OWNER','WAITING_MORE')",UUID.class,f.item());
        harness.loginAs(f.buyer());return new Arrival(result.receiptId(),inspection,shortCase);
    }
    private void pass(Fixture f,Arrival a,BigDecimal quantity) {
        harness.loginAs(f.qualityUser());inspections.dispose("SUBCONTRACT",a.receipt(),a.inspection(),new InspectionDispositionRequest("PASS",quantity,"真实品质验收","matrix-pass-"+UUID.randomUUID()));harness.loginAs(f.buyer());
    }
    private FinanceApproval approveClosure(Fixture f,String mode) {
        harness.loginAs(f.buyer());var preview=closures.preview("SUBCONTRACT",f.order());assertThat(preview.canSubmit()).as(preview.blockReason()).isTrue();
        var pending=closures.submit("SUBCONTRACT",f.order(),new ClosureRequest(mode,"矩阵验证：加工商停止履约，保留实物和财务责任",preview.fingerprint()));
        assertThat(pending.status()).isEqualTo("APPROVED");
        assertThat(orders.detail(f.order()).getClosureRequest().executionMode()).isEqualTo("DIRECT");
        harness.loginAs(f.buyer());drain();return pending;
    }
    private void assertEndedWork(Fixture f) {
        harness.loginAs(f.buyer());assertThat(orders.detail(f.order()).getClosureRequest().status()).isEqualTo("APPROVED");
        assertThat(orders.detail(f.order()).isCanReverse()).isFalse();assertThat(orders.detail(f.order()).isClosed()).isTrue();
        assertThat(db.queryForList("SELECT status FROM subcontract_material_plans WHERE order_id=? AND NOT is_deleted",String.class,f.order())).containsOnly("CANCELED");
        assertThat(drawQueries.tasks(1,20,"","",f.order(),List.of()).page().getTotal()).isZero();
        assertThat(warehouseDraftCount(f)).isZero();assertThat(inboundCount(f)).isZero();assertThat(reservedFuture(f)).isZero();
        assertThat(activeNotices("SUBCONTRACT_ORDER_ITEM",f.item())).isZero();assertThat(activeNotices("PROCUREMENT_ORDER",f.order())).isZero();
        harness.loginAs(f.buyer());assertThatThrownBy(()->harness.submitSubcontractDraw(f.item(),BigDecimal.ONE,"matrix-terminal-"+UUID.randomUUID())).isInstanceOf(ApiException.class);
    }
    private void materialReturn(Fixture f,BigDecimal quantity) {
        harness.loginAs(f.buyer());UUID issue=db.queryForObject("SELECT i.id FROM subcontract_material_issue_items i JOIN subcontract_material_issues h ON h.id=i.issue_id WHERE i.order_item_id=? AND h.status=1 AND NOT i.is_deleted AND NOT h.is_deleted ORDER BY i.id LIMIT 1",UUID.class,f.item());
        var request=new MaterialReturnSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.world().supplierId());request.setWarehouseId(f.world().warehouseId());
        var line=new MaterialReturnItemLine();line.setGoodsId(f.material());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(quantity);
        line.setMaterialIssueItemId(issue);line.setOrderItemId(f.item());line.setParentGoodsId(f.world().goodsE());request.setItems(List.of(line));returns.approve(returns.create(request).getId());
    }
    private UUID materialWaste(Fixture f,BigDecimal quantity) {
        harness.loginAs(f.buyer());UUID issue=db.queryForObject("SELECT i.id FROM subcontract_material_issue_items i JOIN subcontract_material_issues h ON h.id=i.issue_id WHERE i.order_item_id=? AND h.status=1 AND NOT i.is_deleted AND NOT h.is_deleted ORDER BY i.id LIMIT 1",UUID.class,f.item());
        var request=new WasteSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.world().supplierId());request.setWarehouseId(f.world().warehouseId());
        var line=new WasteItemLine();line.setGoodsId(f.material());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(quantity);line.setStandardQty(BigDecimal.ZERO);
        line.setMaterialIssueItemId(issue);line.setCause("现场确认真实材料损耗，责任由财务另行判定");request.setItems(List.of(line));UUID id=wastes.create(request).getId();wastes.approve(id);return id;
    }
    private void drain() {
        var authentication=SecurityContextHolder.getContext().getAuthentication();
        try {int count=0;while(outbox.processNext()) {if(++count>3000) throw new AssertionError("业务事件没有收敛");}}
        finally {SecurityContextHolder.getContext().setAuthentication(authentication);}
    }
    private long warehouseDraftCount(Fixture f) {
        harness.loginAs(f.warehouseUser());long result=plans.tasks(1,20,f.billNo(),warehouseScopes.current(f.world().warehouseId())).getTotal();harness.loginAs(f.buyer());return result;
    }
    private long inboundCount(Fixture f) {
        harness.loginAs(f.warehouseUser());long result=arrivalTasks.expectations(1,20,"SUBCONTRACT",f.billNo(),f.world().supplierId(),warehouseScopes.current(f.world().warehouseId())).getTotal();harness.loginAs(f.buyer());return result;
    }
    private BigDecimal reservedFuture(Fixture f) {return number("SELECT COALESCE(SUM(r.qty-r.consumed_qty-r.released_qty),0) FROM stock_reservations r JOIN subcontract_material_plan_items pi ON pi.id=r.owner_id WHERE r.owner_type='SUBCONTRACT_OUTBOUND' AND pi.order_item_id=? AND NOT r.is_deleted",f.item());}
    private BigDecimal custody(Fixture f,String field) {return number("SELECT COALESCE(SUM(i."+field+"),0) FROM subcontract_material_issue_items i JOIN subcontract_material_issues h ON h.id=i.issue_id WHERE i.order_item_id=? AND h.status=1 AND NOT i.is_deleted AND NOT h.is_deleted",f.item());}
    private BigDecimal stock(Fixture f,UUID goods) {return number("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",f.world().warehouseId(),goods);}
    private long activeNotices(String kind,UUID id) {return count("SELECT COUNT(*) FROM notices WHERE aggregate_kind=? AND aggregate_id=? AND resolved_at IS NULL",kind,id);}
    private UUID replacement(FinanceApproval approval) {return db.queryForObject("SELECT replacement_order_id FROM procurement_order_approval_cases WHERE id=?",UUID.class,approval.caseId());}
    private String wasteFacts(Fixture f) {return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY w.id),'[]'::jsonb)::text FROM subcontract_waste_items w JOIN subcontract_material_issue_items i ON i.id=w.material_issue_item_id WHERE i.order_item_id=?",String.class,f.item());}
    private String lossCaseFacts(Fixture f) {return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.id),'[]'::jsonb)::text FROM subcontract_loss_cases c WHERE EXISTS(SELECT 1 FROM subcontract_loss_case_lines line WHERE line.case_id=c.id AND line.order_item_id=?)",String.class,f.item());}
    private long count(String sql,Object...parameters) {Long result=db.queryForObject(sql,Long.class,parameters);return result==null?0:result;}
    private BigDecimal number(String sql,Object...parameters) {BigDecimal result=db.queryForObject(sql,BigDecimal.class,parameters);return result==null?BigDecimal.ZERO:result;}
}
