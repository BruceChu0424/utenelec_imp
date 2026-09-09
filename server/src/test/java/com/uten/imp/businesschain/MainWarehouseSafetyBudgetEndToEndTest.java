package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.*;

import static org.junit.jupiter.api.Assertions.*;

/** Actual analysis -> initial workshop issue -> physical DRAW, with one main-warehouse buffer. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MainWarehouseSafetyBudgetEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired StockDocService stock;
    @Autowired ProductionExecutionSegmentService execution;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    @Autowired com.uten.imp.security.TxSessionVars tx;
    @Autowired com.uten.imp.features.stock.valuation.InventoryValueWorkService inventoryValueWork;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare() { fixture = new FullChainEndToEndTest(); beans.autowireBean(fixture); }

    @Test void thirtyAndSeventyReserveEightyOnceThenIssueActualLeavesWithoutDoubleConsumption() {
        Case c = setup("main-safety-80", 1, "20");
        receive(c, c.a(), null, "30"); receive(c, c.b(), null, "70");
        Plan plan = issue(c, "80", "first");
        assertEquals("READY", status(plan));
        qty("80", reserved(plan));
        List<UUID> draws = draws(plan);
        assertEquals(2, draws.size());
        assertEquals(Set.of(c.a(), c.b()), Set.copyOf(db.queryForList(
                "SELECT warehouse_id FROM stock_documents WHERE id IN (?,?)", UUID.class, draws.get(0), draws.get(1))));
        assertCovered(plan, "80");
        for (UUID draw : draws) {
            com.uten.imp.features.stock.dto.StockDocIssueRequest request = ReflectionTestUtils.invokeMethod(
                    fixture, "drawIssueRequest", draw, "main-safety-draw-" + draw, null, BigDecimal.ZERO);
            stock.approveAndIssue(draw, request);
            stock.approveAndIssue(draw, request);
        }
        qty("20", balance(c, null));
        qty("80", db.queryForObject("""
                SELECT COALESCE(SUM(reservation.consumed_qty),0) FROM stock_reservations reservation
                JOIN production_material_demands demand ON demand.id=reservation.demand_id WHERE demand.plan_id=?
                """, BigDecimal.class, plan.plan()));
        for(int cycle=0;cycle<100 && inventoryValueWork.runBatch()>0;cycle++) { }
        qty("210",db.queryForObject("""
                SELECT COALESCE(SUM(node.owned_value_local),0) FROM stock_value_nodes node
                JOIN stock_value_pools pool ON pool.id=node.pool_id
                JOIN production_material_stock_postings posting ON posting.id=node.owner_id
                JOIN production_material_demands demand ON demand.id=posting.demand_id
                WHERE node.owner_kind='WIP' AND node.active AND pool.goods_id=? AND demand.plan_id=?
                """,BigDecimal.class,c.materials().getFirst(),plan.plan()));
        qty("60",db.queryForObject("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                BigDecimal.class,c.b(),c.materials().getFirst()));
        assertCovered(plan, "80");
        for(UUID draw:draws) {
            com.uten.imp.features.stock.dto.StockDocIssueRequest returned=ReflectionTestUtils.invokeMethod(
                    fixture,"drawIssueRequest",draw,"main-safety-return-"+draw,"核对原批次并退回原仓",BigDecimal.ZERO);
            stock.reverseIssue(draw,returned);
        }
        qty("100",balance(c,null));
        qty("270",db.queryForObject("SELECT SUM(amount_local) FROM stock_balances WHERE warehouse_id IN (?,?) AND goods_id=? AND color_id IS NULL",
                BigDecimal.class,c.a(),c.b(),c.materials().getFirst()));
        qty("80",reserved(plan));assertCovered(plan,"80");
    }

    @Test void seventyNineAvailableRejectsEightyWithoutAnyPartialReservationOrDraw() {
        Case c = setup("main-safety-79", 1, "20");
        Plan plan = issue(c, "80", "short"); // Establish one 80-unit workshop task before stock arrives.
        receive(c, c.a(), null, "30"); receive(c, c.b(), null, "69");
        assertEquals("WAITING", status(plan)); qty("0", reserved(plan)); assertTrue(draws(plan).isEmpty());
        var segment = execution.list(plan.plan()).getFirst();
        assertTrue(assertThrows(ApiException.class, () -> execution.recheckMaterial(plan.plan(), segment.id(),
                new SegmentTransitionRequest(segment.lockVersion(), "main-safety-short-" + plan.plan())))
                .getMessage().contains("缺 1"));
        qty("0", reserved(plan)); assertTrue(draws(plan).isEmpty()); qty("99", balance(c, null));
    }

    @Test void anotherColorAndAnotherMainWarehouseCannotFillThePublicGap() {
        Case c = setup("main-safety-boundaries", 1, "20");
        UUID otherMain = warehouse(null, "other-main");
        Plan plan = issue(c, "80", "boundaries");
        receive(c, c.a(), null, "30"); receive(c, c.b(), c.world().colorId(), "70");
        receive(c, otherMain, null, "100");
        assertEquals("WAITING", status(plan)); qty("0", reserved(plan));
        var unavailable = execution.list(plan.plan()).getFirst();
        assertTrue(assertThrows(ApiException.class, () -> execution.recheckMaterial(plan.plan(), unavailable.id(),
                new SegmentTransitionRequest(unavailable.lockVersion(), "main-safety-color-short-" + plan.plan())))
                .getMessage().contains("缺 70"));
        receive(c, c.b(), null, "70");
        var segment = execution.list(plan.plan()).getFirst();
        execution.recheckMaterial(plan.plan(), segment.id(), new SegmentTransitionRequest(
                segment.lockVersion(), "main-safety-boundary-recheck-" + plan.plan()));
        assertEquals("READY", status(plan)); qty("80", reserved(plan));
        assertEquals(0, db.queryForObject("""
                SELECT COUNT(*) FROM stock_reservations reservation JOIN production_material_demands demand ON demand.id=reservation.demand_id
                WHERE demand.plan_id=? AND (reservation.warehouse_id=? OR reservation.color_id IS NOT NULL)
                """, Integer.class, plan.plan(), otherMain));
    }

    @Test void concurrentWorkshopRechecksCannotSpendTheSameMainWarehouseBudgetTwice() throws Exception {
        Case c = setup("main-safety-concurrent", 1, "20");
        Plan first = issue(c, "80", "one"), second = issue(c, "80", "two");
        receive(c, c.a(), null, "30"); receive(c, c.b(), null, "70");
        var barrier = new CountDownLatch(1);
        ExecutorService pool = Executors.newFixedThreadPool(2);
        try {
            List<Future<Boolean>> outcomes = new ArrayList<>();
            for (Plan plan : List.of(first, second)) outcomes.add(pool.submit(() -> {
                fixture.loginAs(c.world().superAdminUserId());
                var segment = execution.list(plan.plan()).getFirst();
                barrier.await(10, TimeUnit.SECONDS);
                try {
                    execution.recheckMaterial(plan.plan(), segment.id(), new SegmentTransitionRequest(
                            segment.lockVersion(), "main-safety-race-" + plan.plan()));
                    return true;
                } catch (ApiException changedOrShort) { return false; }
            }));
            barrier.countDown();
            for (Future<Boolean> outcome : outcomes) outcome.get(30, TimeUnit.SECONDS);
        } finally { pool.shutdownNow(); }
        fixture.loginAs(c.world().superAdminUserId());
        assertEquals(1, List.of(first, second).stream().filter(plan -> "READY".equals(status(plan))).count());
        qty("80", reserved(first).add(reserved(second)));
        Plan waiting = "WAITING".equals(status(first)) ? first : second;
        qty("0", reserved(waiting)); assertTrue(draws(waiting).isEmpty());
    }

    @Test void zeroSafetyThreeMaterialsStillShowZeroGapAndCreateOnlyActualLeafDraws() {
        Case c = setup("main-safety-zero-three", 3, "0");
        receive(c, c.a(), null, "30"); receive(c, c.b(), null, "50");
        Plan plan = issue(c, "80", "three");
        assertEquals("READY", status(plan)); qty("240", reserved(plan)); assertEquals(2, draws(plan).size());
        for (UUID material : c.materials()) {
            var row = material(plan, material); qty("0", row.shortageQty()); qty("80", row.allocatedAvailableQty());
        }
    }

    @Test void databaseRejectsPhysicalOverdrawMainBufferOverdrawAndUnprovenQualifiedFlag() {
        Case c=setup("main-safety-db-guards",1,"20");Plan plan=issue(c,"100","guards");
        receive(c,c.a(),null,"30");receive(c,c.b(),null,"70");
        var transaction=new org.springframework.transaction.support.TransactionTemplate(transactionManager);
        for(String attack:List.of("physical","public-buffer","fake-qualified")) {
            RuntimeException failure=assertThrows(RuntimeException.class,()->transaction.executeWithoutResult(status->{
                tx.bind();
                rawReservation(plan,c.a(),attack.equals("physical")?"31":"30",attack.equals("fake-qualified"));
                if(attack.equals("public-buffer"))rawReservation(plan,c.b(),"51",false);
                db.execute("SET CONSTRAINTS trg_main_warehouse_public_stock_budget, trg_qualified_origin_target_coverage IMMEDIATE");
            }));
            Throwable cause=failure;while(cause.getCause()!=null)cause=cause.getCause();
            assertInstanceOf(java.sql.SQLException.class,cause);assertEquals("23514",((java.sql.SQLException)cause).getSQLState());
            String expected=switch(attack){case "physical"->"stock_reservations_production_capacity_guard";
                case "public-buffer"->"production_main_public_safety_guard";default->"qualified_origin_formal_coverage";};
            assertEquals(expected,((org.postgresql.util.PSQLException)cause).getServerErrorMessage().getConstraint());
            qty("0",reserved(plan));qty("100",balance(c,null));
        }
        transaction.executeWithoutResult(status->{
            tx.bind();rawReservation(plan,c.a(),"30",false);rawReservation(plan,c.b(),"50",false);
            // Verify this capacity guard in isolation, then roll back. A partial
            // reservation on a WAITING task must never be committed as a fixture.
            db.execute("SET CONSTRAINTS trg_main_warehouse_public_stock_budget IMMEDIATE");
            qty("80",reserved(plan));status.setRollbackOnly();
        });
        qty("0",reserved(plan));
    }

    private void rawReservation(Plan plan,UUID warehouse,String quantity,boolean requiresProof) {
        UUID material=plan.context().materials().getFirst();
        var demand=db.queryForMap("SELECT id,package_id FROM production_material_demands WHERE plan_id=? AND goods_id=?",plan.plan(),material);
        UUID balance=db.queryForObject("SELECT id FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",UUID.class,warehouse,material);
        UUID id=UUID.randomUUID();
        db.update("""
                INSERT INTO stock_reservations(id,goods_id,color_id,warehouse_id,qty,consumed_qty,released_qty,status,source,
                    source_doc_type,source_doc_id,owner_type,owner_id,purpose,demand_id,supply_type,supply_id,idempotency_key,
                    created_by,updated_by,requires_qualified_origin)
                VALUES(?,?,NULL,?,?,0,0,0,2,'PRODUCTION_PLANNING_PACKAGE',?,'PRODUCTION_MATERIAL_DEMAND',?,
                    'PRODUCTION_MATERIAL',?,'STOCK_BALANCE',?,?,?,?,?)
                """,id,material,warehouse,new BigDecimal(quantity),demand.get("package_id"),demand.get("id"),demand.get("id"),
                balance,"raw-safety-"+id,plan.context().world().superAdminUserId(),plan.context().world().superAdminUserId(),requiresProof);
    }

    private Case setup(String tag, int materialCount, String safety) {
        var world = fixture.seedWorld(tag); fixture.loginAs(world.superAdminUserId());
        UUID main = warehouse(null, "main");
        db.update("UPDATE warehouses SET parent_id=? WHERE id=?", main, world.warehouseId());
        UUID b = warehouse(main, "B"), product = UUID.randomUUID();
        fixture.insertGoods(product, "SAFE-P-" + product, "主仓齐套产品", "自制", world.unitId(), world.unitLegacy());
        List<UUID> materials = new ArrayList<>();
        for (int i=0;i<materialCount;i++) {
            UUID material = UUID.randomUUID(); materials.add(material);
            fixture.insertGoods(material, "SAFE-M-" + material, "主仓物料" + i, "采购", world.unitId(), world.unitLegacy());
            fixture.insertBom(product, material, "1");
            db.update("UPDATE goods SET min_qty=? WHERE id=?", new BigDecimal(safety), material);
        }
        UUID first=world.warehouseId().toString().compareTo(b.toString())<0?world.warehouseId():b;
        UUID second=first.equals(b)?world.warehouseId():b;
        return new Case(world, main, first, second, product, List.copyOf(materials));
    }

    private UUID warehouse(UUID parent, String label) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status,is_accountable,is_defective,parent_id) VALUES(?,?,?,'使用',true,false,?)",
                id, "SAFE-W-" + id, label, parent);
        return id;
    }

    private void receive(Case c, UUID warehouse, UUID color, String quantity) {
        fixture.loginAs(c.world().superAdminUserId());
        var request = new StockDocSaveRequest(); request.setDocType("OTHER_IN"); request.setBillDate(BusinessTime.today());
        request.setWarehouseId(warehouse); request.setRemark("已确认的测试初始库存，按实际子仓记账");
        List<StockDocItemLine> lines = new ArrayList<>();
        for (UUID material : c.materials()) {
            var line = new StockDocItemLine(); line.setGoodsId(material); line.setColorId(color);
            line.setUnitId(c.world().unitId()); line.setUnitRate(BigDecimal.ONE); line.setQty(new BigDecimal(quantity));
            line.setPrice(warehouse.equals(c.a()) ? new BigDecimal("2") : new BigDecimal("3"));
            line.setAmountOriginal(line.getQty().multiply(line.getPrice())); line.setAmountLocal(line.getAmountOriginal()); lines.add(line);
        }
        request.setItems(lines); stock.approve(stock.create(request).getId());
    }

    private Plan issue(Case c, String amount, String suffix) {
        fixture.loginAs(c.world().superAdminUserId());
        var view = analyses.preview(new PreviewRequest(null,null,null,c.main(),"safe-preview-"+c.product()+suffix,
                List.of(new PreviewItem("OTHER",null,c.product(),null,c.world().unitId(),"safe-source-"+c.product()+suffix,
                        "主仓数量验证",BusinessTime.today().plusDays(10),new BigDecimal(amount)))));
        var routes = view.flatMaterials().stream().filter(MaterialView::actionable)
                .map(row -> new RouteDecision(row.materialLineId(),row.actionGroupKey(),
                        row.goodsId().equals(c.product()) ? "MAKE" : "BUY",null)).toList();
        if (!routes.isEmpty()) view = analyses.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),
                "safe-route-"+c.product()+suffix,routes));
        UUID root = view.products().getFirst().analysisLineId();
        var issued = commands.issueWorkshopPlans(view.analysisId(),new IssueWorkshopPlansRequest(view.version(),view.fingerprint(),
                "safe-issue-"+c.product()+suffix,c.main(),BusinessTime.today(),BusinessTime.today().plusDays(10),true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(root,new BigDecimal(amount)))));
        return new Plan(c,view.analysisId(),issued.plans().getFirst().planId());
    }

    private MaterialView material(Plan plan, UUID material) { return analyses.detail(plan.analysis()).flatMaterials().stream().filter(row -> row.goodsId().equals(material)).findFirst().orElseThrow(); }
    private void assertCovered(Plan plan,String amount) { for(UUID id:plan.context().materials()) { var row=material(plan,id);qty("0",row.shortageQty());qty(amount,row.allocatedAvailableQty()); } }
    private String status(Plan plan) { return db.queryForObject("SELECT status FROM production_execution_segments WHERE plan_id=?",String.class,plan.plan()); }
    private List<UUID> draws(Plan plan) { return db.queryForList("SELECT draw_id FROM plan_draw_links WHERE plan_id=? AND NOT is_deleted ORDER BY draw_id",UUID.class,plan.plan()); }
    private BigDecimal reserved(Plan plan) { return db.queryForObject("SELECT COALESCE(SUM(r.qty-r.released_qty),0) FROM stock_reservations r JOIN production_material_demands d ON d.id=r.demand_id WHERE d.plan_id=? AND NOT r.is_deleted",BigDecimal.class,plan.plan()); }
    private BigDecimal balance(Case c, UUID color) { return db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id IN (?,?) AND goods_id=? AND color_id IS NOT DISTINCT FROM CAST(? AS uuid)",BigDecimal.class,c.a(),c.b(),c.materials().getFirst(),color); }
    private static void qty(String expected,BigDecimal actual) { assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+", actual "+actual); }
    private record Case(FullChainEndToEndTest.World world,UUID main,UUID a,UUID b,UUID product,List<UUID> materials) {}
    private record Plan(Case context,UUID analysis,UUID plan) {}
}
