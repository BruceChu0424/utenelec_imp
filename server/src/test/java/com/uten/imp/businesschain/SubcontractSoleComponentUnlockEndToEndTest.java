package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundPlanLine;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-101 + ADR-103 委外「只有一个叶子子件」形态(路线 B)的真库全链: 下单前的锁 → 批准派活
 * → 分批发料。ADR-085 §五点名的那条用例在仓库里搜不到, 这一段至今没有任何端到端覆盖, 本轮补上。
 *
 * <p>覆盖用户口径 (ADR-103): 子件仓里一件都没有时连委外订货单都建不了 (建单/送审/批准同一把锁);
 * 子件入库了不管多少都解锁; 只能发这么多就先发这么多, 界面要直接看得到可发数量; 发完第一批不会
 * 被系统自己开的第二张草稿顶回去; 后续到货由库存内核 (StockService 每笔入库) 自动叫醒, 不靠任何
 * 入库单据记得去调。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractSoleComponentUnlockEndToEndTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractOrderService orders;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired SubcontractMaterialIssueService materialIssues;
    @Autowired SubcontractMaterialPlanService materialPlans;
    @Autowired StockDocService stockDocs;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService analysisCommands;
    @Autowired FulfillmentWorkbenchQueryService workbench;
    @Autowired com.uten.imp.features.production.analysis.PreplanAnalysisStockPegService stockPegs;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    @Autowired com.uten.imp.features.production.execution.ProductionDrawRequestService productionDraws;
    @Autowired com.uten.imp.features.production.execution.ProductionExecutionSegmentService productionSegments;
    @Autowired com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService materialSettlements;

    FullChainEndToEndTest fixture;

    @BeforeEach
    void setup() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        org.springframework.security.core.context.SecurityContextHolder.clearContext();
    }

    @Test
    void childStockLocksOrderingThenUnlocksWarehouseWorkAndIssuesInBatchesWithAServerSideIssuableQuantity() {
        var w = fixture.seedWorld("sc-sole-component");
        fixture.loginAs(w.superAdminUserId());
        // 委外件 goodsE 挂唯一一条 PER_UNIT 叶子边到采购件 goodsD：每 1 个 goodsE 吃 1 个 goodsD。
        // goodsD 自己没有 BOM，所以命中 fn_subcontract_sole_component_goods。
        db.update("""
                INSERT INTO goods_bom_items(id, goods_id, component_goods_id, qty, sort_order,
                    control_stage, consumption_basis, basis_output_qty, allow_partial_package, hard_gate)
                VALUES (?, ?, ?, 1, 1, 'START', 'PER_UNIT', 1, TRUE, TRUE)
                """, UUID.randomUUID(), w.goodsE(), w.goodsD());
        assertTrue(Boolean.TRUE.equals(db.queryForObject(
                "SELECT fn_subcontract_sole_component_goods(?)", Boolean.class, w.goodsE())),
                "夹具必须命中「只有一个叶子子件」判据，否则测的是别的形态");

        // ① ADR-103 路线 B 的锁: 子件仓里一件都没有, 连委外订货单都建不了, 文案要说清
        //    哪张委外件在等哪颗子件、什么时候会自动解锁。
        ApiException locked = assertThrows(ApiException.class,
                () -> orders.create(orderRequest(w, "10")),
                "子件一件都没有时不得建委外订货单 (ADR-103 建单/送审/批准同一把锁)");
        assertEquals(ErrorCode.CONFLICT, locked.getCode());
        assertTrue(locked.getMessage().contains("仓里还一件都没有"), locked.getMessage());
        assertTrue(locked.getMessage().contains("入库后任务中心会自动解锁"), locked.getMessage());
        assertEquals(0, db.queryForObject(
                "SELECT COUNT(*) FROM subcontract_order_items WHERE goods_id=?",
                Integer.class, w.goodsE()), "被锁的建单不能留下半张单");

        // ② 子件到货 6 个(少于订货量)。按用户口径「不管数量多少就解锁」: 这时才能订 10 个委外件,
        //    允许损耗 10%; 送审、批准同样放行。(此刻还没有委外计划, 入库内核的叫醒是空跑。)
        receiveChildStock(w, "6");
        UUID orderId = orders.create(orderRequest(w, "10")).getId();
        UUID orderItemId = db.queryForObject(
                "SELECT id FROM subcontract_order_items WHERE order_id=?", UUID.class, orderId);
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        financeApproval.submit("SUBCONTRACT", orderId);
        fixture.loginAs(reviewer);
        fixture.approvePendingFinance("SUBCONTRACT", orderId);
        fixture.loginAs(w.superAdminUserId());

        // ③ 批准落的是「发子件」的计划行：货品是子件、父件仍是委外件。
        UUID planItemId = db.queryForObject("""
                SELECT id FROM subcontract_material_plan_items
                WHERE order_item_id=? AND is_deleted=FALSE
                """, UUID.class, orderItemId);
        assertEquals("COMPONENT_OUTBOUND", db.queryForObject(
                "SELECT flow_mode FROM subcontract_material_plan_items WHERE id=?", String.class, planItemId));
        assertEquals(w.goodsD(), db.queryForObject(
                "SELECT goods_id FROM subcontract_material_plan_items WHERE id=?", UUID.class, planItemId));
        assertEquals(w.goodsE(), db.queryForObject(
                "SELECT parent_goods_id FROM subcontract_material_plan_items WHERE id=?", UUID.class, planItemId));

        // ④ ADR-101: 批准时子件已有 6 个, 系统按此刻可动用量给仓库开一张发得出去的草稿——
        //    量按仓里现货截断, 不是整笔计划量 10。
        assertEquals(1, draftCount(planItemId), "子件有货时批准就该自动出现一张能发得出去的草稿");
        UUID firstDraft = draftId(planItemId);
        assertEquals(0, new BigDecimal("6").compareTo(draftQty(firstDraft)),
                "草稿量必须按该仓此刻的可动用量截断，不是整笔计划量");
        OutboundPlanLine unlocked = outboundLine(planItemId);
        assertEquals(w.warehouseId(), unlocked.stockWarehouseId(),
                "服务端要替仓库指出这批料在哪个仓");
        // 草稿一建就把这 6 个预留掉了，所以「还空着的可动用量」与「还能再填多少」都是 0。
        // 仓库在界面上看到的「仓内可动用」是这个数加回本草稿自己占的量。
        assertEquals(0, BigDecimal.ZERO.compareTo(unlocked.stockAvailableQty()));
        assertEquals(0, BigDecimal.ZERO.compareTo(unlocked.issuableQty()));

        // ⑤ 先发这 6 个。审核之后系统会为剩余 4 个续生草稿——子件还没到，占不上库存，
        //    此前这一步会抛 409 把刚审核的这 6 个一起回滚，分批发料根本走不通。
        materialIssues.approve(firstDraft);
        assertEquals(0, new BigDecimal("6").compareTo(db.queryForObject(
                "SELECT issued_qty FROM subcontract_material_plan_items WHERE id=?",
                BigDecimal.class, planItemId)), "第一批 6 个必须真的发出去");
        assertEquals(0, draftCount(planItemId),
                "剩余 4 个还没有料，不该再开一张发不出去的草稿");

        // ⑥ 子件再到 4 个 → 再解锁一次，把剩下的发完。ADR-103: 这里**不手工叫醒**——
        //    其它入库单审核走 StockService 的入库分支, 库存内核在同一事务里自动叫醒。
        receiveChildStock(w, "4");
        UUID secondDraft = draftId(planItemId);
        assertNotNull(secondDraft, "后续到货必须由库存内核自动再解锁一批, 不靠入库单据记得去调");
        assertEquals(0, new BigDecimal("4").compareTo(draftQty(secondDraft)));
        materialIssues.approve(secondDraft);
        assertEquals(0, new BigDecimal("10").compareTo(db.queryForObject(
                "SELECT issued_qty FROM subcontract_material_plan_items WHERE id=?",
                BigDecimal.class, planItemId)), "两批合计必须等于订货量折算的子件量");
        assertEquals(0, draftCount(planItemId), "发完之后不再留未审草稿");

        // ⑦ 发出去的是子件、供应商处台账记的也是子件；委外件自己一件都没动过库存。
        assertEquals(0, new BigDecimal("10").compareTo(db.queryForObject("""
                SELECT COALESCE(SUM(at_supplier_qty),0) FROM subcontract_material_issue_items
                WHERE order_item_id=? AND is_deleted=FALSE
                """, BigDecimal.class, orderItemId)));
        assertEquals(0, BigDecimal.ZERO.compareTo(onHand(w.goodsE(), w.warehouseId())),
                "委外件要等加工回厂并质检入库才会有库存");
        assertEquals(0, BigDecimal.ZERO.compareTo(onHand(w.goodsD(), w.warehouseId())),
                "子件已经全部发给委外商");
    }

    // ===================== 夹具 =====================

    @Test
    void purchaseOwnedByExactChildUnlocksItsParentAndTransfersCustodyWithoutMakingStockPublic() {
        verifyExactChildCustody(false,false,BigDecimal.ONE);
    }

    @Test
    void laterPurchaseBatchKeepsExactOwnershipBeforeAutomaticallyWakingTheWaitingSubcontract() {
        verifyExactChildCustody(true,false,BigDecimal.ONE);
    }

    @Test
    void parentPublicSurplusRetainsItsExactChildResponsibilityBeyondTheSalesBoundAllocation() {
        verifyExactChildCustody(false,true,BigDecimal.ONE);
    }

    @Test
    void exactHandoffUsesFrozenComponentUnitsWhenTheBomConsumesTwoPerTarget() {
        verifyExactChildCustody(false,false,new BigDecimal("2"));
    }

    @Test
    void soleManufacturedChildWithItsOwnBomUnlocksAfterQualifiedFinishedInbound() {
        var w=fixture.seedWorld("sc-manufactured-direct-child");
        fixture.loginAs(w.superAdminUserId());
        UUID raw=UUID.randomUUID(),workshop=UUID.randomUUID(),worker=UUID.randomUUID();
        fixture.insertGoods(raw,"SC-RAW-"+raw,"自制子件原材料","采购",w.unitId(),w.unitLegacy());
        fixture.insertBom(w.goodsE(),w.goodsD(),"1");
        fixture.insertBom(w.goodsD(),raw,"1");
        db.update("UPDATE goods SET default_supplier_id=? WHERE id IN (?,?,?)",w.supplierId(),w.goodsE(),w.goodsD(),raw);
        assertTrue(Boolean.TRUE.equals(db.queryForObject("SELECT fn_subcontract_sole_component_goods(?)",Boolean.class,w.goodsE())),
                "唯一直属子件即使自身有BOM仍应直接发子件；不要求先做出委外父件");
        var original=componentAnalysis(w,"manufactured");
        UUID applicationItem=notifyComponent(w,original);
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM preplan_subcontract_make_tasks WHERE analysis_id=?",Integer.class,original.analysisId()));
        var request=orderRequest(w,"10");request.getItems().getFirst().setApplicationItemId(applicationItem);
        assertThrows(ApiException.class,()->orders.create(request),"子件的原材料不等于已完工子件");
        var view=analyses.detail(original.analysisId());
        var child=view.flatMaterials().stream().filter(row->row.goodsId().equals(w.goodsD())).findFirst().orElseThrow();
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"sc-make-routes-"+view.analysisId(),
                List.of(new RouteDecision(child.materialLineId(),child.actionGroupKey(),"MAKE",null))));
        var rawMaterial=view.flatMaterials().stream().filter(row->row.goodsId().equals(raw)&&row.actionable()).findFirst().orElseThrow();
        view=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"sc-raw-route-"+view.analysisId(),
                List.of(new RouteDecision(rawMaterial.materialLineId(),rawMaterial.actionGroupKey(),"BUY",null))));
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,raw,"10");
        UUID production=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'",UUID.class);
        db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",workshop,"SC-WORK-"+workshop,"委外子件车间",production);
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",worker,"SC-EMP-"+worker,"自制子件负责人",workshop);
        view=analyses.detail(view.analysisId());
        var plan=analysisCommands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                "sc-make-child-"+view.analysisId(),w.warehouseId(),BusinessTime.today(),null,true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(child.materialLineId(),null,new BigDecimal("10"),
                        BusinessTime.today(),null,workshop,null,worker,null,null)))).plans().getFirst();
        assertEquals(0,componentAvailable(applicationItem).signum(),"已排产但未实收入库仍不能发出子件");
        finishMadeComponent(w,plan);
        assertEquals(0,new BigDecimal("10").compareTo(componentAvailable(applicationItem)));
        assertEquals(0,onHand(w.goodsE(),w.warehouseId()).signum());
        UUID order=orders.create(request).getId();
        financeApproval.submit("SUBCONTRACT",order);
        fixture.loginAs(ReflectionTestUtils.invokeMethod(fixture,"createApprover",w));
        fixture.approvePendingFinance("SUBCONTRACT",order);
        fixture.loginAs(w.superAdminUserId());
        UUID planItem=db.queryForObject("SELECT pi.id FROM subcontract_material_plan_items pi JOIN subcontract_material_plans p ON p.id=pi.plan_id WHERE p.order_id=?",UUID.class,order);
        materialIssues.approve(draftId(planItem));
        assertEquals(0,onHand(w.goodsD(),w.warehouseId()).signum());
        assertEquals(0,onHand(w.goodsE(),w.warehouseId()).signum());
        assertTrue(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM subcontract_component_stock_handoffs handoff
                JOIN preplan_stock_entitlement_events origin ON origin.id=handoff.source_entitlement_event_id
                WHERE handoff.plan_item_id=? AND origin.event_type='ORIGIN_MAKE')
                """,Boolean.class,planItem));
    }

    private void finishMadeComponent(FullChainEndToEndTest.World w,GeneratedPlan plan) {
        UUID segment=plan.segmentIds().getFirst();
        productionSegments.confirmRoute(plan.planId(),segment,new com.uten.imp.features.production.execution.SegmentRouteConfirmRequest(
                segmentVersion(segment),"sc-child-route-"+segment,"FULL_KIT"));
        var documents=db.queryForList("SELECT document_id FROM production_planning_package_documents WHERE execution_segment_id=? AND document_type='DRAW'",UUID.class,segment);
        if(!documents.isEmpty()) {
            var items=List.of(new com.uten.imp.features.production.execution.ProductionDrawRequest.Item(segment,segmentVersion(segment)));
            var preview=productionDraws.preview(new com.uten.imp.features.production.execution.ProductionDrawRequest.PreviewRequest(items));
            productionDraws.submit(new com.uten.imp.features.production.execution.ProductionDrawRequest.SubmitRequest(items,"sc-child-draw-"+segment,preview.fingerprint()));
            var issue=new com.uten.imp.features.stock.dto.StockDocIssueBatchRequest();
            issue.setIdempotencyKey("sc-child-issue-"+segment);issue.setDocIds(documents);stockDocs.issueFullBatch(issue);
        }
        productionSegments.start(plan.planId(),segment,new com.uten.imp.features.production.execution.SegmentTransitionRequest(segmentVersion(segment),"sc-child-start-"+segment));
        var usage=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        usage.setExecutionSegmentId(segment);usage.setIdempotencyKey("sc-child-consumed-"+segment);usage.setReason("子件原料全部用于本批合格产出");
        usage.setLines(db.queryForList("SELECT id,required_qty FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",segment).stream().map(demand->{
            var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();
            line.setDemandId((UUID)demand.get("id"));line.setQtyBase((BigDecimal)demand.get("required_qty"));line.setSettlementType("CONSUMED");return line;
        }).toList());
        if(!usage.getLines().isEmpty())materialSettlements.post(plan.planId(),usage,w.superAdminUserId());
        UUID planItem=db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,segment);
        UUID report=fixture.reportAndApproveExecutionSegment(w,planItem,null,w.goodsD(),segment,null,"10",false,"0",null,null);
        fixture.confirmFinishedInboundFully(fixture.finishedInDocForReport(report));
        fixture.loginAs(w.superAdminUserId());
    }

    private long segmentVersion(UUID id) {
        return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,id);
    }

    @Test
    void mergedApplicationPartialOrderKeepsEachProductsOwnChildShare() {
        var w=fixture.seedWorld("sc-merged-products-owned");
        fixture.loginAs(w.superAdminUserId());
        fixture.insertBom(w.goodsE(),w.goodsD(),"1");
        db.update("UPDATE goods SET default_supplier_id=? WHERE id IN (?,?)",w.supplierId(),w.goodsD(),w.goodsE());
        var sources=new java.util.ArrayList<PreviewItem>();
        for(int index=0;index<2;index++) {
            UUID product=UUID.randomUUID();
            fixture.insertGoods(product,"SC-MERGED-"+product,"共用委外件产品"+index,"自制",w.unitId(),w.unitLegacy());
            fixture.insertBom(product,w.goodsE(),"1");
            UUID sales=ReflectionTestUtils.invokeMethod(fixture,"createApprovedOrder",w,product,"10","100");
            UUID salesItem=ReflectionTestUtils.invokeMethod(fixture,"orderItemId",sales);
            sources.add(new PreviewItem("SALES_ORDER_ITEM",salesItem,null,null,null,null,null,BusinessTime.today(),new BigDecimal("10")));
        }
        fixture.loginAs(w.superAdminUserId());
        var analysis=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"sc-merged-"+w.goodsE(),sources));
        var parents=analysis.flatMaterials().stream().filter(row->row.goodsId().equals(w.goodsE())).toList();
        var routed=analyses.saveRoutes(analysis.analysisId(),new RouteRequest(analysis.version(),analysis.fingerprint(),"sc-merged-routes-"+analysis.analysisId(),
                parents.stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),"SUBCONTRACT",null)).toList()));
        analysisCommands.notifySupply(analysis.analysisId(),new NotifyRequest(routed.version(),routed.fingerprint(),"sc-merged-notify-"+analysis.analysisId(),
                "SUBCONTRACT",parents.stream().map(MaterialView::materialLineId).toList(),List.of(),null));
        var applicationItems=db.queryForList("""
                SELECT DISTINCT allocation.external_item_id FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id=allocation.action_id
                WHERE action.analysis_id=? AND action.route='SUBCONTRACT' AND action.status<>'CANCELLED'
                """,UUID.class,analysis.analysisId());
        assertEquals(2,applicationItems.size());
        for(int index=0;index<2;index++) {
            var buyView=analyses.detail(analysis.analysisId());
            var buy=buyView.flatMaterials().stream().filter(row->row.goodsId().equals(w.goodsD())&&row.actionable()).findFirst().orElseThrow();
            buyView=analyses.saveRoutes(buyView.analysisId(),new RouteRequest(buyView.version(),buyView.fingerprint(),
                    "sc-merged-buy-route-"+analysis.analysisId()+"-"+index,List.of(new RouteDecision(buy.materialLineId(),buy.actionGroupKey(),"BUY",null))));
            analysisCommands.notifySupply(buyView.analysisId(),new NotifyRequest(buyView.version(),buyView.fingerprint(),
                    "sc-merged-buy-"+analysis.analysisId()+"-"+index,"BUY",List.of(buy.materialLineId()),List.of(),null));
            UUID purchase=ReflectionTestUtils.invokeMethod(fixture,"approveExistingAnalysisPurchase",w,analysis.analysisId(),w.goodsD());
            ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",w,purchase,w.goodsD(),new BigDecimal("10"),"root-sc-merged-owned-"+index);
            fixture.loginAs(w.superAdminUserId());
        }
        fixture.loginAs(w.superAdminUserId());
        var request=orderRequest(w,"15");request.getItems().getFirst().setApplicationItemIds(applicationItems);
        UUID order=orders.create(request).getId();
        financeApproval.submit("SUBCONTRACT",order);
        fixture.loginAs(ReflectionTestUtils.invokeMethod(fixture,"createApprover",w));
        fixture.approvePendingFinance("SUBCONTRACT",order);
        fixture.loginAs(w.superAdminUserId());
        var portions=db.queryForList("""
                SELECT handoff.parent_material_id,handoff.child_material_id,SUM(handoff.qty) AS qty
                FROM subcontract_component_stock_handoffs handoff
                JOIN subcontract_material_plan_items plan_item ON plan_item.id=handoff.plan_item_id
                JOIN subcontract_order_items item ON item.id=plan_item.order_item_id
                WHERE item.order_id=? GROUP BY handoff.parent_material_id,handoff.child_material_id
                """,order);
        assertEquals(2,portions.size(),"合并后的15件委外必须保留真实来源FIFO的10+5子件归属");
        assertEquals(List.of(new BigDecimal("5.0000"),new BigDecimal("10.0000")),
                portions.stream().map(portion->((BigDecimal)portion.get("qty")).setScale(4)).sorted().toList());
        assertEquals(0,new BigDecimal("5").compareTo(applicationItems.stream().map(this::componentAvailable).reduce(BigDecimal.ZERO,BigDecimal::add)),"另5件仍留在其产品原权益中");
        UUID mergedPlanItem=db.queryForObject("SELECT plan_item.id FROM subcontract_material_plan_items plan_item JOIN subcontract_order_items item ON item.id=plan_item.order_item_id WHERE item.order_id=?",
                UUID.class,order);
        materialIssues.approve(draftId(mergedPlanItem));
        var afterIssue=refreshComponentAnalysis(w,analysis.analysisId());
        var children=afterIssue.flatMaterials().stream().filter(row->row.goodsId().equals(w.goodsD())).toList();
        assertEquals(2,children.size());
        assertEquals(List.of(BigDecimal.ZERO.setScale(4),new BigDecimal("5.0000")),
                children.stream().map(child->child.requiredQty().setScale(4)).sorted().toList(),
                "15件按实际来源抵扣10+5，不能把整笔15件重复扣给每个产品");
    }

    private void verifyExactChildCustody(boolean batched,boolean surplus,BigDecimal bomQty) {
        String totalQty=surplus ? "12" : "10";
        String componentQty=new BigDecimal(totalQty).multiply(bomQty).toPlainString();
        String firstQty=batched ? "6" : componentQty;
        var w = fixture.seedWorld("sc-exact-owned-child-"+batched+"-"+surplus+"-"+bomQty);
        fixture.loginAs(w.superAdminUserId());
        fixture.insertBom(w.goodsE(), w.goodsD(), bomQty.toPlainString());
        db.update("UPDATE goods SET default_supplier_id=? WHERE id IN (?,?)",w.supplierId(),w.goodsD(),w.goodsE());
        var original = componentAnalysis(w,"original");
        UUID applicationItem = notifyComponent(w,original,surplus ? new BigDecimal(totalQty) : null);
        UUID application = db.queryForObject("SELECT application_id FROM subcontract_application_items WHERE id=?",UUID.class,applicationItem);
        UUID purchase = ReflectionTestUtils.invokeMethod(fixture,"approvePurchaseForAnalysis",w,
                analyses.detail(original.analysisId()),w.goodsD());
        UUID receipt = ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",w,purchase,w.goodsD(),
                new BigDecimal(firstQty),"root-sc-exact-owned-"+batched+"-"+surplus+"-"+bomQty);
        fixture.loginAs(w.superAdminUserId());
        assertNotNull(receipt);
        assertEquals(0,db.queryForObject("SELECT available_qty FROM v_stock_available WHERE goods_id=? AND warehouse_id=?",
                BigDecimal.class,w.goodsD(),w.warehouseId()).signum(),"计划专属料必须仍然被锁住");
        assertEquals(0,new BigDecimal(firstQty).compareTo(componentAvailable(applicationItem)));
        var task=workbench.query("SUBCONTRACT","WAITING_ORDER",null,null,null,null,1,100)
                .items().stream().filter(row->application.equals(row.actionDocId())).findFirst().orElseThrow();
        assertTrue(task.canCreateOrder(),"本单子件已采购质检入库，任务中心必须解锁");
        assertEquals(0,new BigDecimal(firstQty).compareTo(task.componentAvailableQty()));

        var other=componentAnalysis(w,"other");
        UUID otherApplicationItem=notifyComponent(w,other);
        assertEquals(0,componentAvailable(otherApplicationItem).signum(),"同货号其它产品需求不能抢本单专属到货");
        var request=orderRequest(w,totalQty);
        request.getItems().getFirst().setApplicationItemId(applicationItem);
        UUID order=orders.create(request).getId();
        financeApproval.submit("SUBCONTRACT",order);
        fixture.loginAs(ReflectionTestUtils.invokeMethod(fixture,"createApprover",w));
        fixture.approvePendingFinance("SUBCONTRACT",order);
        fixture.loginAs(w.superAdminUserId());
        UUID planItem=db.queryForObject("SELECT pi.id FROM subcontract_material_plan_items pi JOIN subcontract_material_plans p ON p.id=pi.plan_id WHERE p.order_id=?",UUID.class,order);
        UUID draft=draftId(planItem);
        assertNotNull(draft);
        assertEquals(0,new BigDecimal(firstQty).compareTo(draftQty(draft)));
        assertEquals(0,new BigDecimal(firstQty).compareTo(db.queryForObject(
                "SELECT SUM(qty) FROM subcontract_component_stock_handoffs WHERE plan_item_id=?",BigDecimal.class,planItem)));
        SubcontractComponentHandoffGuardAssertions.verify(db, db.queryForObject(
                "SELECT id FROM subcontract_component_stock_handoffs WHERE plan_item_id=? ORDER BY created_at,id LIMIT 1",
                UUID.class, planItem));
        if (!surplus && bomQty.compareTo(BigDecimal.ONE)==0) {
            assertComponentProjection(w,original.analysisId(),"10",firstQty,firstQty,"draft");
            var otherChild=refreshComponentAnalysis(w,other.analysisId()).flatMaterials().stream()
                    .filter(row->row.goodsId().equals(w.goodsD())).findFirst().orElseThrow();
            assertEquals(0,otherChild.exactPeggedQty().signum(),"另一产品的同货号子件不能继承本单草稿权益");
            assertEquals(0,otherChild.allocatedAvailableQty().signum(),"委外草稿权益不能进入其它用途的通用库存池");
        }
        assertOriginalReceiptCannotBeReversed(receipt,w.goodsD(),w.warehouseId(),planItem);
        assertEquals(0,componentAvailable(otherApplicationItem).signum());
        materialIssues.approve(draft);
        assertOriginalReceiptCannotBeReversed(receipt,w.goodsD(),w.warehouseId(),planItem);
        assertEquals(0,onHand(w.goodsD(),w.warehouseId()).signum());
        assertEquals(0,onHand(w.goodsE(),w.warehouseId()).signum());
        if(batched) {
            ReflectionTestUtils.invokeMethod(fixture,"receiveAndPassPurchase",w,purchase,w.goodsD(),
                    new BigDecimal("4"),"root-sc-exact-owned-second");
            fixture.loginAs(w.superAdminUserId());
            draft=draftId(planItem);
            assertNotNull(draft,"后续采购入库应在归属权益登记后自动补出仓草稿");
            assertEquals(0,new BigDecimal("4").compareTo(draftQty(draft)));
            assertEquals(0,componentAvailable(otherApplicationItem).signum());
            materialIssues.approve(draft);
        }
        assertEquals(0,new BigDecimal(componentQty).compareTo(db.queryForObject("""
                SELECT SUM(reservation.consumed_qty) FROM subcontract_component_stock_handoffs handoff
                JOIN stock_reservations reservation ON reservation.id=handoff.target_reservation_id
                WHERE handoff.plan_item_id=?
                """,BigDecimal.class,planItem)));
        if (!surplus && bomQty.compareTo(BigDecimal.ONE)==0)
            assertComponentProjection(w,original.analysisId(),"0","0","0","issued");
        materialIssues.reverse(draft);
        BigDecimal restoredQty=new BigDecimal(batched ? "4" : componentQty);
        assertEquals(0,restoredQty.compareTo(onHand(w.goodsD(),w.warehouseId())));
        assertEquals(0,restoredQty.compareTo(componentAvailable(applicationItem)),
                "红冲实物出仓后恢复同一产品下原子件权益");
        if (!surplus && bomQty.compareTo(BigDecimal.ONE)==0)
            assertComponentProjection(w,original.analysisId(),restoredQty.toPlainString(),restoredQty.toPlainString(),
                    restoredQty.toPlainString(),"reversed");
        assertEquals(0,componentAvailable(otherApplicationItem).signum());
        UUID plan=db.queryForObject("SELECT plan_id FROM subcontract_material_plan_items WHERE id=?",UUID.class,planItem);
        UUID replacement=materialPlans.regenerateDraft(plan);
        assertNotNull(replacement);
        materialIssues.delete(replacement);
        assertEquals(0,restoredQty.compareTo(componentAvailable(applicationItem)),
                "删除未审草稿仍恢复原权益，不能放进公共库存");
        if (!surplus && bomQty.compareTo(BigDecimal.ONE)==0)
            assertComponentProjection(w,original.analysisId(),restoredQty.toPlainString(),restoredQty.toPlainString(),
                    restoredQty.toPlainString(),"draft-deleted");
        assertEquals(0,componentAvailable(otherApplicationItem).signum());
    }

    private AnalysisView refreshComponentAnalysis(FullChainEndToEndTest.World w,UUID analysisId) {
        var current=analyses.detail(analysisId);
        var parent=current.flatMaterials().stream().filter(row->row.goodsId().equals(w.goodsE())).findFirst().orElseThrow();
        return analyses.saveRoutes(analysisId,new RouteRequest(current.version(),current.fingerprint(),
                "sc-custody-projection-"+UUID.randomUUID(),
                List.of(new RouteDecision(parent.materialLineId(),parent.actionGroupKey(),"SUBCONTRACT",null))));
    }

    private void assertComponentProjection(FullChainEndToEndTest.World w,UUID analysisId,
                                          String required,String owned,String allocated,String stage) {
        var child=refreshComponentAnalysis(w,analysisId).flatMaterials().stream()
                .filter(row->row.goodsId().equals(w.goodsD())).findFirst().orElseThrow();
        assertEquals(0,new BigDecimal(required).compareTo(child.requiredQty()),stage+": 实际出仓后扣除子层需求, 红冲后恢复");
        assertEquals(0,new BigDecimal(owned).compareTo(child.exactPeggedQty()),stage+": 草稿交接仍显示本节点专属库存");
        assertEquals(0,new BigDecimal(allocated).compareTo(child.allocatedAvailableQty()),stage+": 专属子件覆盖不丢失");
        assertEquals(0,child.netShortageQty().signum(),stage+": 已采购入库/已给委外的子件不能重新建议采购");
    }

    private AnalysisView componentAnalysis(FullChainEndToEndTest.World w,String key) {
        UUID product=UUID.randomUUID();
        fixture.insertGoods(product,"SC-OWN-"+product,"委外归属产品"+key,"自制",w.unitId(),w.unitLegacy());
        fixture.insertBom(product,w.goodsE(),"1");
        UUID sales=ReflectionTestUtils.invokeMethod(fixture,"createApprovedOrder",w,product,"10","100");
        fixture.loginAs(w.superAdminUserId());
        UUID salesItem=ReflectionTestUtils.invokeMethod(fixture,"orderItemId",sales);
        return analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),"sc-owned-preview-"+sales,
                List.of(new PreviewItem("SALES_ORDER_ITEM",salesItem,null,null,null,null,null,
                        BusinessTime.today(),new BigDecimal("10")))));
    }

    private UUID notifyComponent(FullChainEndToEndTest.World w,AnalysisView view) {
        return notifyComponent(w,view,null);
    }

    private UUID notifyComponent(FullChainEndToEndTest.World w,AnalysisView view,BigDecimal outputQty) {
        var parent=view.flatMaterials().stream().filter(row->row.goodsId().equals(w.goodsE())).findFirst().orElseThrow();
        var routed=analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),
                "sc-owned-route-"+view.analysisId(),List.of(new RouteDecision(parent.materialLineId(),parent.actionGroupKey(),"SUBCONTRACT",null))));
        analysisCommands.notifySupply(view.analysisId(),new NotifyRequest(routed.version(),routed.fingerprint(),
                "sc-owned-notify-"+view.analysisId(),"SUBCONTRACT",List.of(parent.materialLineId()),List.of(),
                outputQty==null ? null : List.of(new SupplyQuantityInput(null,parent.materialLineId(),outputQty,BigDecimal.ZERO))));
        return db.queryForObject("""
                SELECT DISTINCT allocation.external_item_id FROM preplan_supply_action_allocations allocation
                JOIN preplan_supply_actions action ON action.id=allocation.action_id
                WHERE action.analysis_id=? AND action.route='SUBCONTRACT' AND action.status<>'CANCELLED'
                """,UUID.class,view.analysisId());
    }

    private BigDecimal componentAvailable(UUID applicationItem) {
        return db.queryForObject("SELECT COALESCE(SUM(available_qty),0) FROM fn_subcontract_component_available_stock(?,NULL::uuid)",BigDecimal.class,applicationItem);
    }

    private void assertOriginalReceiptCannotBeReversed(UUID receipt,UUID goods,UUID warehouse,UUID planItem) {
        BigDecimal before=onHand(goods,warehouse);
        int bridges=db.queryForObject("SELECT COUNT(*) FROM subcontract_component_stock_handoffs WHERE plan_item_id=?",Integer.class,planItem);
        ApiException failure=assertThrows(ApiException.class,()->new org.springframework.transaction.support.TransactionTemplate(transactionManager)
                .executeWithoutResult(status->stockPegs.releaseForReceipt("PURCHASE",receipt)));
        assertEquals(ErrorCode.CONFLICT,failure.getCode());
        assertEquals(0,before.compareTo(onHand(goods,warehouse)));
        assertEquals(bridges,db.queryForObject("SELECT COUNT(*) FROM subcontract_component_stock_handoffs WHERE plan_item_id=?",Integer.class,planItem));
    }

    private OrderSaveRequest orderRequest(FullChainEndToEndTest.World w, String qty) {
        var request = new OrderSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setDeliverDate(BusinessTime.today().plusDays(3));
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId"));
        var line = new OrderItemLine();
        line.setGoodsId(w.goodsE());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("10"));
        line.setAmountOriginal(line.getQty().multiply(line.getPrice()));
        line.setAmountLocal(line.getAmountOriginal());
        line.setAllowedLossPct(new BigDecimal("10"));
        request.setItems(List.of(line));
        return request;
    }

    /** 子件按普通采购件入库(期初/其它入库)，模拟「采购件到货了」。 */
    private void receiveChildStock(FullChainEndToEndTest.World w, String qty) {
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setBillDate(LocalDate.of(2026, 1, 1));
        request.setWarehouseId(w.warehouseId());
        request.setRemark("委外子件到货 " + qty);
        var line = new StockDocItemLine();
        line.setGoodsId(w.goodsD());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal("10"));
        line.setAmountOriginal(line.getQty().multiply(line.getPrice()));
        line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));
        var doc = stockDocs.create(request);
        stockDocs.approve(doc.getId());
    }

    private OutboundPlanLine outboundLine(UUID planItemId) {
        UUID planId = db.queryForObject(
                "SELECT plan_id FROM subcontract_material_plan_items WHERE id=?", UUID.class, planItemId);
        return materialPlans.taskDetail(planId).lines().stream()
                .filter(line -> planItemId.equals(line.planItemId()))
                .findFirst().orElseThrow();
    }

    private int draftCount(UUID planItemId) {
        Integer count = db.queryForObject("""
                SELECT COUNT(*) FROM subcontract_material_issue_items item
                JOIN subcontract_material_issues issue ON issue.id=item.issue_id
                WHERE item.plan_item_id=? AND issue.status=0 AND issue.is_deleted=FALSE
                """, Integer.class, planItemId);
        return count == null ? 0 : count;
    }

    private UUID draftId(UUID planItemId) {
        return db.query("""
                SELECT issue.id FROM subcontract_material_issue_items item
                JOIN subcontract_material_issues issue ON issue.id=item.issue_id
                WHERE item.plan_item_id=? AND issue.status=0 AND issue.is_deleted=FALSE
                ORDER BY issue.created_at DESC LIMIT 1
                """, rs -> rs.next() ? rs.getObject(1, UUID.class) : null, planItemId);
    }

    private BigDecimal draftQty(UUID issueId) {
        return db.queryForObject(
                "SELECT COALESCE(SUM(qty),0) FROM subcontract_material_issue_items WHERE issue_id=?",
                BigDecimal.class, issueId);
    }

    private BigDecimal onHand(UUID goodsId, UUID warehouseId) {
        BigDecimal qty = db.queryForObject("""
                SELECT COALESCE(SUM(qty),0) FROM stock_balances
                WHERE goods_id=? AND warehouse_id=?
                """, BigDecimal.class, goodsId, warehouseId);
        return qty == null ? BigDecimal.ZERO : qty;
    }
}
