package com.uten.imp.businesschain;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.mrp.MrpRow;
import com.uten.imp.features.production.mrp.MrpService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.production.schedule.dto.ScheduleOrderLine;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;
import java.util.stream.Collectors;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-131 §3.5 与 §6 第 14-17 条: 整批领料的料 (组件发料方式 PERIODIC 的 BOM 行, 期间边) 由车间内料仓
 * 按期盘点计耗, 物料分析、MRP、计划导入、委外单一子件判定与履约足迹都不读它。
 *
 * <p>在全链夹具的真实库上走服务层: 期间边与按单边并存时, 按单部分的结果与没有期间边时一样;
 * 颗粒在仓库里有现货也不会被物料分析占用, 也不会进入任何足迹的库存锁维度。
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
class PeriodicEdgeReadersPostgresTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactions;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MrpService mrp;
    @Autowired ProductionPlanService plans;
    @Autowired ProductionScheduleService schedule;
    @Autowired ProductionMutationFootprintPort footprints;

    FullChainEndToEndTest fixture;
    FullChainEndToEndTest.World world;
    /** 整批领料的颗粒: 质量单位, 发料方式 PERIODIC, 自己的料 (OWN)。 */
    UUID granule;

    @BeforeEach
    void seed() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        // 夹具 BOM: A -> {B x2, E x1}; B -> {C x3, D x5}。B/C 自制, D 采购, E 委外。
        world = fixture.seedWorld("periodic-" + UUID.randomUUID());
        fixture.loginAs(world.superAdminUserId());
        granule = periodicGranule();
    }

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    /** 物料分析快照不含期间边、不预留、不让料; 委外单一子件判定不受期间边影响; 足迹不含颗粒库存键。 */
    @Test
    void materialAnalysisAndFootprintsNeverSeeGranules() {
        periodicEdge(world.goodsB(), "0.0125");
        periodicEdge(world.goodsC(), "0.01");
        // 委外件 E: 一条按单子件 D + 一条期间边, 仍是「只有一个直属子件」
        fixture.insertBom(world.goodsE(), world.goodsD(), "1");
        periodicEdge(world.goodsE(), "0.002");
        db.update("INSERT INTO stock_balances(warehouse_id, goods_id, color_id, qty) VALUES (?, ?, NULL, 500)",
                world.warehouseId(), granule);
        assertTrue(bool("SELECT fn_goods_has_periodic_bom(?)", world.goodsC()));
        assertFalse(bool("SELECT fn_goods_has_order_bom(?)", world.goodsC()), "C 只有期间边, 没有按单 BOM");

        UUID order = fixture.createApprovedOrder(world, world.goodsA(), "10", "100");
        UUID item = orderItem(order);
        AnalysisView view = analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(),
                "periodic-analysis-" + order, List.of(new PreviewItem("SALES_ORDER_ITEM", item, null, null, null,
                        null, null, BusinessTime.today().plusDays(10), new BigDecimal("10")))));

        assertTrue(view.flatMaterials().stream().anyMatch(row -> world.goodsD().equals(row.goodsId())),
                "按单的料照常进物料分析");
        assertTrue(view.flatMaterials().stream().noneMatch(row -> granule.equals(row.goodsId())),
                "整批领料的颗粒不进物料分析快照");
        assertEquals(0, count("SELECT count(*) FROM production_material_analysis_materials WHERE analysis_id=? AND goods_id=?",
                view.analysisId(), granule), "分析里没有颗粒行, 也就无从让料");
        assertEquals(0, count("SELECT count(*) FROM stock_reservations WHERE goods_id=?", granule),
                "仓库里的颗粒现货不被预留");
        MaterialView subcontract = view.flatMaterials().stream()
                .filter(row -> world.goodsE().equals(row.goodsId())).findFirst().orElseThrow();
        assertEquals("COMPONENT_OUTBOUND", subcontract.subcontractOutboundForm(),
                "期间边不算直属子件, 委外件仍直接发唯一的按单子件");
        assertTrue(bool("SELECT fn_subcontract_sole_component_goods(?)", world.goodsE()));

        FulfillmentMutationLockPlan analysisFootprint =
                inTransaction(() -> footprints.forAnalyses(List.of(view.analysisId())));
        assertTrue(analysisFootprint.inventoryDimensions().contains(new InventoryDimension(world.goodsD(), null)));
        assertNoGranuleKey(analysisFootprint);
        FulfillmentMutationLockPlan previewFootprint = inTransaction(() -> footprints.forPreview(
                List.of(item), List.of(), List.of(), List.of(world.warehouseId()), List.of()));
        assertTrue(previewFootprint.inventoryDimensions().contains(new InventoryDimension(world.goodsD(), null)));
        assertNoGranuleKey(previewFootprint);
    }

    /** MRP 不展开期间边; 只有期间边的产品仍能确认下达; 计划导入把期间边列为不算需求。 */
    @Test
    void mrpAndPlanImportTreatPeriodicEdgesAsWorkshopSupplied() {
        periodicEdge(world.goodsA(), "0.02");
        periodicEdge(world.goodsB(), "0.0125");
        periodicEdge(world.goodsC(), "0.01");

        UUID planA = draftPlan(world.goodsA(), "10");
        List<MrpRow> rows = mrp.preview(planA);
        assertEquals(Set.of(world.goodsB(), world.goodsC(), world.goodsD(), world.goodsE()),
                rows.stream().map(MrpRow::goodsId).collect(Collectors.toSet()), "颗粒不进毛需求");
        assertEquals(0, new BigDecimal("100").compareTo(row(rows, world.goodsD()).gross()), "B x20 -> D x100 不变");
        assertTrue(row(rows, world.goodsB()).selfMade());
        assertFalse(row(rows, world.goodsC()).selfMade(), "只有期间边的零件仍是叶子件");
        // 颗粒标成自制也不算一层: A -> B -> C 两层
        assertEquals(2, mrp.makeTreeDepth(planA));

        UUID planC = draftPlan(world.goodsC(), "5");
        assertTrue(mrp.planGoodsHasBom(planC), "只有期间边的产品也要确认下达, 下达为零料段");
        assertTrue(mrp.preview(planC).isEmpty(), "期间边不产生物料需求");

        UUID order = fixture.createApprovedOrder(world, world.goodsA(), "10", "100");
        ScheduleOrderLine line = schedule.orderLines(order).getFirst();
        ScheduleOrderLine.BomComponent granuleRow = component(line, granule);
        assertEquals(0, granuleRow.needQty().signum(), "车间内料仓供料, 不算需求");
        assertFalse(granuleRow.selfMade());
        ScheduleOrderLine.BomComponent subAssembly = component(line, world.goodsB());
        assertTrue(subAssembly.needQty().signum() > 0);
        assertTrue(subAssembly.selfMade(), "B 有按单 BOM");
    }

    // -----------------------------------------------------------------

    private UUID periodicGranule() {
        UUID kg = UUID.randomUUID();
        UUID id = UUID.randomUUID();
        String tag = id.toString().substring(0, 8);
        db.update("INSERT INTO units(id, code, name, status) VALUES (?, ?, '千克', '使用')", kg, "KG-" + tag);
        db.update("""
                INSERT INTO unit_measurement_profiles(unit_id, measurement_dimension, mass_unit_code, provenance)
                    VALUES (?, 'MASS', 'KG', 'MANUAL_GOVERNANCE')""", kg);
        // 颗粒标成自制: 验证 MRP 自制层数也不把它算一层
        db.update("""
                INSERT INTO goods(id, code, name, source_type, status, unit_id, price, code_sequence,
                                  issue_method, periodic_cost_basis)
                VALUES (?, ?, ?, '自制', '使用', ?, 10, (SELECT coalesce(max(code_sequence), 0) + 1 FROM goods),
                        'PERIODIC', 'OWN')""", id, "PP-" + tag, "颗粒-" + tag, kg);
        return id;
    }

    /** 期间边: 只填单个重量 (公斤/件), 形状按 V740 守卫。 */
    private void periodicEdge(UUID product, String kilogramsPerPiece) {
        db.update("""
                INSERT INTO goods_bom_items(goods_id, component_goods_id, qty, hard_gate, control_stage,
                                            consumption_basis, basis_output_qty)
                VALUES (?, ?, ?, FALSE, 'START', 'PER_UNIT', 1)""",
                product, granule, new BigDecimal(kilogramsPerPiece));
    }

    /** 与夹具的旧式计划草稿同一写法: 从已审销售明细带入一行。 */
    private UUID draftPlan(UUID goodsId, String qty) {
        UUID order = fixture.createApprovedOrder(world, goodsId, qty, "100");
        Map<String, Object> source = db.queryForMap("""
                SELECT i.id, i.color_id, i.unit_id, COALESCE(i.unit_rate, 1) AS unit_rate,
                       o.bill_no, COALESCE(i.qty, 0) AS order_qty
                FROM sales_order_items i JOIN sales_orders o ON o.id = i.order_id
                WHERE i.order_id = ?""", order);
        PlanItemLine line = new PlanItemLine();
        line.setProductNo("PERIODIC-" + UUID.randomUUID());
        line.setGoodsId(goodsId);
        line.setColorId((UUID) source.get("color_id"));
        line.setUnitId((UUID) source.get("unit_id"));
        line.setUnitRate((BigDecimal) source.get("unit_rate"));
        line.setSalesOrderItemId((UUID) source.get("id"));
        line.setSalesOrderNo((String) source.get("bill_no"));
        line.setOqty((BigDecimal) source.get("order_qty"));
        line.setQty(new BigDecimal(qty));
        PlanSaveRequest request = new PlanSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setItems(List.of(line));
        return plans.create(request).getId();
    }

    private UUID orderItem(UUID order) {
        return db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?", UUID.class, order);
    }

    private void assertNoGranuleKey(FulfillmentMutationLockPlan plan) {
        assertTrue(plan.inventoryDimensions().stream().noneMatch(key -> granule.equals(key.goodsId())),
                () -> "足迹不能锁颗粒的库存维度: " + plan.inventoryDimensions());
    }

    private <T> T inTransaction(Supplier<T> work) {
        return new TransactionTemplate(transactions).execute(status -> work.get());
    }

    private static MrpRow row(List<MrpRow> rows, UUID goodsId) {
        return rows.stream().filter(row -> goodsId.equals(row.goodsId())).findFirst().orElseThrow();
    }

    private static ScheduleOrderLine.BomComponent component(ScheduleOrderLine line, UUID goodsId) {
        return line.bom().stream().filter(component -> goodsId.equals(component.goodsId())).findFirst().orElseThrow();
    }

    private int count(String sql, Object... args) {
        Integer value = db.queryForObject(sql, Integer.class, args);
        return value == null ? 0 : value;
    }

    private boolean bool(String sql, Object... args) {
        return Boolean.TRUE.equals(db.queryForObject(sql, Boolean.class, args));
    }
}
