package com.uten.imp.businesschain;

import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.GoodsBomService;
import com.uten.imp.features.master.goods.GoodsIssueMethodService;
import com.uten.imp.features.master.goods.GoodsPeriodicBomPreparationService;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomItemView;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.AffectedBomRow;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodBatchRequest;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodBatchResult;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodItem;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodPreview;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationBatchRequest;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationBatchResult;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationRow;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationRowInput;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationView;
import com.uten.imp.features.production.mrp.GeneratePlanningPackageRequest;
import com.uten.imp.features.production.mrp.PlanningPreviewResult;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueLine;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialRequisitionService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialSettingsService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-131 §5.1 第 1、2 步 (包 S6): 基础资料里的发料方式与分摊方式切换、BOM 期间边按克填、上线准备。
 *
 * <p>全部走真实服务与真实库 (V740 的守卫、延迟断言与 BOM 接管触发器), 按真实账号切换: 基础资料维护人
 * (货品编辑 + BOM 编辑)、BOM 维护人 (BOM 新增 + 编辑)、内料仓设置人 (上线准备列表)、仓库发料人。
 *
 * <p>覆盖: 预览列出受影响的 BOM 行与没清账的工单; 先改货品再转换 BOM 行, 转换出来的行满足期间边形状;
 * 按包按批的行拒绝; 改回按工单领料与改分摊方式要内料仓用完、期间结算; 认料随切换作废; 每袋净重预填整包装量;
 * 上线准备批量写期间边与认料、货品资料单重换算成克; 克与千克换算、异常单重确认、20% 提醒、第二种料确认。
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
class GoodsIssueMethodSwitchPostgresTest {

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired GoodsIssueMethodService issueMethods;
    @Autowired GoodsPeriodicBomPreparationService preparation;
    @Autowired GoodsBomService bom;
    @Autowired WorkshopMaterialChoicePort choices;
    @Autowired WorkshopMaterialSettingsService settings;
    @Autowired WorkshopMaterialRequisitionService requisitions;
    @Autowired StockDocService stock;
    @Autowired ProductionPlanService plans;
    @Autowired ProductionPlanningPackageService planningPackages;
    FullChainEndToEndTest fixture;

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    /** 一套夹具: 千克 (重量单位)、克、基础资料维护人、BOM 维护人。 */
    private record Shop(FullChainEndToEndTest.World world, String tag, UUID kg, UUID gram,
                        UUID masterUser, UUID bomUser) {}

    // =============================================================================================
    // 改为整批领料: 预览、按包按批拒绝、先改货品再转换 BOM 行、幂等
    // =============================================================================================

    @Test
    void switchToPeriodicConvertsBomRowsAfterTheGoodsAndRejectsPackageRows() {
        Shop shop = shop("to-periodic");
        UUID granule = goods(shop, "颗粒PP", shop.kg(), "采购", "ORDER", null, new BigDecimal("25"));
        UUID p1 = product(shop, "注塑件一", null, null);
        UUID p2 = product(shop, "注塑件二", null, null);
        UUID p3 = product(shop, "注塑件三", null, null);
        UUID row1 = bomRow(p1, granule, "0.0125", "START", "PER_UNIT", "1", true);
        UUID row2 = bomRow(p2, granule, "12.5", "START", "PER_UNIT", "1000", true);
        UUID row3 = bomRow(p3, granule, "25", "START", "PER_PACKAGE", "1", true);

        fixture.loginAs(shop.masterUser());
        IssueMethodPreview preview = issueMethods.preview(granule, "PERIODIC", null);
        assertEquals("ORDER", preview.currentIssueMethod());
        assertEquals("OWN", preview.targetCostBasis(), "改为整批领料默认按主料");
        assertTrue(preview.massUnit());
        money("25", preview.suggestedBulkPackageQty(), "每袋净重预填整包装量");
        assertEquals("CONVERT", action(preview, row1).action());
        AffectedBomRow converted = action(preview, row2);
        assertEquals("CONVERT", converted.action());
        money("12.5", converted.unitWeightGrams(), "每 1000 件 12.5 千克折成每件 12.5 克");
        assertEquals("BLOCKED", action(preview, row3).action(), "按包装计量的行要先人工改");
        assertFalse(preview.canSwitch());
        assertTrue(preview.blockers().stream().anyMatch(text -> text.contains("按包装")), preview.blockers()::toString);

        long version = version(granule);
        ApiException blocked = assertThrows(ApiException.class, () -> issueMethods.batch(new IssueMethodBatchRequest(
                List.of(new IssueMethodItem(granule, version, "PERIODIC", "OWN", null, null)), key("blocked"))));
        assertEquals(ErrorCode.CONFLICT, blocked.getCode());
        assertEquals("ORDER", str("SELECT issue_method FROM goods WHERE id = ?", granule), "整批不改");

        // 员工先在 BOM 里把按包装的行改成按每件, 再切换。
        db.update("UPDATE goods_bom_items SET consumption_basis = 'PER_UNIT', qty = 0.02 WHERE id = ?", row3);
        assertTrue(issueMethods.preview(granule, "PERIODIC", null).canSwitch());
        IssueMethodBatchRequest request = new IssueMethodBatchRequest(
                List.of(new IssueMethodItem(granule, version, "PERIODIC", "OWN", null, true)), key("switch"));
        IssueMethodBatchResult result = issueMethods.batch(request);
        assertEquals(1, result.items().size());
        assertEquals(3, result.items().getFirst().bomRowsConverted());
        money("25", result.items().getFirst().bulkPackageQty(), "没填每袋净重时取整包装量");

        Map<String, Object> goods = db.queryForMap("""
                SELECT issue_method, periodic_cost_basis, bulk_package_qty, is_recycled_material, version
                FROM goods WHERE id = ?""", granule);
        assertEquals("PERIODIC", goods.get("issue_method"));
        assertEquals("OWN", goods.get("periodic_cost_basis"));
        money("25", (BigDecimal) goods.get("bulk_package_qty"), "每袋净重");
        assertEquals(Boolean.TRUE, goods.get("is_recycled_material"));
        assertEquals(version + 1, ((Number) goods.get("version")).longValue());
        for (UUID row : List.of(row1, row2, row3)) {
            assertEquals("START|PER_UNIT|1|false", str("""
                    SELECT concat_ws('|', control_stage, consumption_basis, basis_output_qty::int, hard_gate::text)
                    FROM goods_bom_items WHERE id = ?""", row), "转换出来的行是期间边形状");
        }
        money("0.0125", decimal("SELECT qty FROM goods_bom_items WHERE id = ?", row2), "按每件折算");
        assertTrue(bool("SELECT fn_goods_has_periodic_bom(?)", p1));
        assertFalse(bool("SELECT fn_goods_has_order_bom(?)", p1), "只剩期间边");

        // 同号同内容重放: 返回原结果, 不再改; 同号不同内容拒绝。
        IssueMethodBatchResult replay = issueMethods.batch(request);
        assertEquals(result.items().getFirst().bomRowsConverted(), replay.items().getFirst().bomRowsConverted());
        assertEquals(version + 1, version(granule), "重放不重复写");
        assertEquals(1, count("SELECT count(*) FROM workshop_material_commands WHERE idempotency_key = ?",
                request.idempotencyKey()));
        ApiException reused = assertThrows(ApiException.class, () -> issueMethods.batch(new IssueMethodBatchRequest(
                List.of(new IssueMethodItem(granule, version + 1, "PERIODIC", "OWN", null, false)),
                request.idempotencyKey())));
        assertTrue(reused.getMessage().contains("同一请求号"), reused.getMessage());

        // 期间边形状在数据库守卫下也不能改回按包装。
        assertThrows(RuntimeException.class, () -> db.update(
                "UPDATE goods_bom_items SET consumption_basis = 'PER_PACKAGE' WHERE id = ?", row1));
    }

    @Test
    void unclearedOrderDemandIsListedWithItsPlanAndBlocksTheSwitch() {
        Shop shop = shop("uncleared");
        FullChainEndToEndTest.World world = shop.world();
        // 夹具 BOM: B -> {C x3 (自制), D x5 (采购)}; 给 B 下达一张工单, D 就有了按工单领料的需求。
        fixture.loginAs(world.superAdminUserId());
        UUID plan = approvedPlan(world, world.goodsB(), "10");
        PlanningPreviewResult planningPreview = planningPackages.preview(plan, world.warehouseId());
        GeneratePlanningPackageRequest confirm = new GeneratePlanningPackageRequest();
        confirm.setWarehouseId(world.warehouseId());
        confirm.setIdempotencyKey("s6-uncleared-" + plan);
        confirm.setPreviewFingerprint(planningPreview.fingerprint());
        confirm.setGeneratePurchaseRequest(true);
        planningPackages.confirm(plan, confirm);
        assertTrue(count("""
                SELECT count(*) FROM production_material_demands
                WHERE goods_id = ? AND is_deleted = FALSE AND status NOT IN ('RELEASED', 'REVERSED')""",
                world.goodsD()) > 0, "D 有按工单领料的需求");

        fixture.loginAs(shop.masterUser());
        IssueMethodPreview preview = issueMethods.preview(world.goodsD(), "PERIODIC", "OWN");
        assertFalse(preview.canSwitch());
        String planNo = str("SELECT bill_no FROM production_plans WHERE id = ?", plan);
        assertTrue(preview.unclearedDemands().stream().anyMatch(demand -> planNo.equals(demand.planNo())),
                () -> "没清账的工单逐条列出: " + preview.unclearedDemands());
        assertTrue(preview.unclearedDemands().stream().allMatch(demand -> demand.note() != null
                && !demand.note().isBlank()), "每条写明差什么");
        assertTrue(preview.blockers().stream().anyMatch(text -> text.contains("没有清账")), preview.blockers()::toString);
        assertFalse(preview.massUnit(), "夹具的 D 按个记账");
        assertTrue(preview.blockers().stream().anyMatch(text -> text.contains("重量单位")), preview.blockers()::toString);

        long version = version(world.goodsD());
        ApiException blocked = assertThrows(ApiException.class, () -> issueMethods.batch(new IssueMethodBatchRequest(
                List.of(new IssueMethodItem(world.goodsD(), version, "PERIODIC", "OWN", null, null)),
                key("uncleared"))));
        assertEquals(ErrorCode.CONFLICT, blocked.getCode());
        assertNotNull(blocked.getFieldErrors());
        assertTrue(blocked.getFieldErrors().size() >= 2, blocked.getFieldErrors()::toString);
        assertEquals("ORDER", str("SELECT issue_method FROM goods WHERE id = ?", world.goodsD()));
    }

    // =============================================================================================
    // 改回按工单领料、改分摊方式: 内料仓要用完、期间要结算; 认料作废; 辅料不写进 BOM
    // =============================================================================================

    @Test
    void backToOrderAndCostBasisChangeNeedAnEmptyStoreAndSupersedeChoices() {
        Shop shop = shop("to-order");
        FullChainEndToEndTest.World world = shop.world();
        Object assignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment", "s6-order-" + shop.tag());
        UUID workshop = ReflectionTestUtils.invokeMethod(assignment, "workshopId");
        UUID worker = ReflectionTestUtils.invokeMethod(assignment, "workerId");
        UUID warehouseUser = fixture.createUserWithPerms(world, "s6-wh-" + shop.tag(), "notice:read",
                "workshop_material:view", "workshop_material:issue", "workshop_material:setup");
        db.update("INSERT INTO warehouse_keepers(warehouse_id, employee_id) SELECT ?, employee_id FROM users WHERE id = ?",
                world.warehouseId(), warehouseUser);

        // 颗粒甲: 已整批领料, 内料仓里有 40 千克、开着的一期里有发料。
        UUID used = goods(shop, "颗粒甲", shop.kg(), "采购", "PERIODIC", "OWN", null);
        otherIn(shop, world.warehouseId(), used, "100", "10");
        fixture.loginAs(warehouseUser);
        var enabled = settings.update(workshop, new SettingsRequest(null, 0L, true, world.warehouseId(), null, true, BusinessTime.today(),
                List.of(), key("enable")));
        UUID bin = enabled.binWarehouseId();
        requisitions.directIssue(new DirectIssueRequest(workshop, worker,
                List.of(new DirectIssueLine(used, null, null, new BigDecimal("40"), world.warehouseId())), null,
                key("issue")));
        money("40", decimal("SELECT qty FROM stock_balances WHERE warehouse_id = ? AND goods_id = ?", bin, used), "内料仓账面");

        fixture.loginAs(shop.masterUser());
        IssueMethodPreview toOrder = issueMethods.preview(used, "ORDER", null);
        assertFalse(toOrder.canSwitch());
        assertTrue(toOrder.binBalances().stream().anyMatch(balance -> bin.equals(balance.warehouseId())));
        assertFalse(toOrder.openPeriods().isEmpty(), "开着的一期里有这种料的发料");
        assertTrue(toOrder.blockers().stream().anyMatch(text -> text.contains("内料仓里还有")), toOrder.blockers()::toString);
        long usedVersion = version(used);
        ApiException orderBlocked = assertThrows(ApiException.class, () -> issueMethods.batch(new IssueMethodBatchRequest(
                List.of(new IssueMethodItem(used, usedVersion, "ORDER", null, null, null)), key("order-blocked"))));
        assertEquals(ErrorCode.CONFLICT, orderBlocked.getCode());
        IssueMethodPreview toShared = issueMethods.preview(used, "PERIODIC", "SHARED");
        assertFalse(toShared.canSwitch(), "分摊方式也要等内料仓用完、期间结算后再改");
        ApiException sharedBlocked = assertThrows(ApiException.class, () -> issueMethods.batch(new IssueMethodBatchRequest(
                List.of(new IssueMethodItem(used, usedVersion, "PERIODIC", "SHARED", null, null)), key("shared-blocked"))));
        assertEquals(ErrorCode.CONFLICT, sharedBlocked.getCode());
        assertEquals("PERIODIC|OWN", str("SELECT issue_method || '|' || periodic_cost_basis FROM goods WHERE id = ?", used));

        // 颗粒乙: 没进过内料仓; 一个产品的 BOM 里有它的单个重量, 另一个产品认了它。改回按工单领料可以。
        UUID idle = goods(shop, "颗粒乙", shop.kg(), "采购", "PERIODIC", "OWN", null);
        UUID edgeProduct = product(shop, "有单重的件", null, null);
        UUID choiceProduct = product(shop, "认料的件", null, null);
        UUID edge = bomRow(edgeProduct, idle, "0.01", "START", "PER_UNIT", "1", false);
        choices.choose(List.of(new WorkshopMaterialChoicePort.ProductChoice(choiceProduct,
                WorkshopMaterialChoicePort.KIND_MATERIAL, List.of(new WorkshopMaterialChoicePort.MaterialRef(idle, null)),
                false, null)), null, key("choose-idle"));
        IssueMethodPreview idlePreview = issueMethods.preview(idle, "ORDER", null);
        assertTrue(idlePreview.canSwitch(), idlePreview.blockers()::toString);
        assertEquals(1, idlePreview.activeChoices().size(), "认料列出来, 切换时作废");
        assertEquals("RESTORE", action(idlePreview, edge).action());
        IssueMethodBatchResult reverted = issueMethods.batch(new IssueMethodBatchRequest(
                List.of(new IssueMethodItem(idle, version(idle), "ORDER", null, null, null)), key("order")));
        assertEquals(1, reverted.items().getFirst().bomRowsRestored());
        assertEquals(1, reverted.items().getFirst().choicesSuperseded());
        assertEquals("ORDER|", str("SELECT issue_method || '|' || COALESCE(periodic_cost_basis, '') FROM goods WHERE id = ?", idle));
        assertEquals(Boolean.TRUE, db.queryForObject("SELECT hard_gate FROM goods_bom_items WHERE id = ?", Boolean.class, edge),
                "改回按工单领料, 恢复为开工前的齐套门槛");
        assertEquals("ISSUE_METHOD_SWITCH", str("""
                SELECT superseded_reason FROM goods_periodic_material_choices
                WHERE product_goods_id = ? AND material_goods_id = ?""", choiceProduct, idle));

        // 颗粒丙: 改成辅料 → BOM 里去掉 (辅料不写进 BOM), 认料作废。
        UUID colorant = goods(shop, "颗粒丙", shop.kg(), "采购", "PERIODIC", "OWN", null);
        UUID colorantProduct = product(shop, "用丙的件", null, null);
        UUID colorantEdge = bomRow(colorantProduct, colorant, "0.002", "START", "PER_UNIT", "1", false);
        IssueMethodPreview sharedPreview = issueMethods.preview(colorant, "PERIODIC", "SHARED");
        assertTrue(sharedPreview.canSwitch(), sharedPreview.blockers()::toString);
        assertEquals("REMOVE", action(sharedPreview, colorantEdge).action());
        IssueMethodBatchResult shared = issueMethods.batch(new IssueMethodBatchRequest(
                List.of(new IssueMethodItem(colorant, version(colorant), "PERIODIC", "SHARED", null, null)), key("shared")));
        assertEquals(1, shared.items().getFirst().bomRowsRemoved());
        assertEquals(Boolean.TRUE, db.queryForObject("SELECT is_deleted FROM goods_bom_items WHERE id = ?",
                Boolean.class, colorantEdge));
        assertEquals("PERIODIC|SHARED", str("SELECT issue_method || '|' || periodic_cost_basis FROM goods WHERE id = ?",
                colorant));
        // 辅料不能再写进 BOM。
        fixture.loginAs(shop.bomUser());
        BomItemSaveRequest again = new BomItemSaveRequest();
        again.setComponentGoodsId(colorant);
        again.setUnitWeightGrams(new BigDecimal("2"));
        ApiException sharedEdge = assertThrows(ApiException.class, () -> bom.create(colorantProduct, again));
        assertTrue(sharedEdge.getMessage().contains("辅料"), sharedEdge.getMessage());
    }

    // =============================================================================================
    // BOM 期间边按克填; 上线准备
    // =============================================================================================

    @Test
    void periodicEdgeTakesGramsWithConfirmationsAndWarnings() {
        Shop shop = shop("grams");
        UUID granule = goods(shop, "颗粒丁", shop.kg(), "采购", "PERIODIC", "OWN", null);
        UUID second = goods(shop, "颗粒戊", shop.kg(), "采购", "PERIODIC", "OWN", null);
        UUID product = product(shop, "双料件", new BigDecimal("10"), shop.gram());
        fixture.loginAs(shop.bomUser());

        BomItemSaveRequest tiny = new BomItemSaveRequest();
        tiny.setComponentGoodsId(granule);
        tiny.setUnitWeightGrams(new BigDecimal("0.05"));
        ApiException confirm = assertThrows(ApiException.class, () -> bom.create(product, tiny));
        assertEquals(ErrorCode.VALIDATION_FAILED, confirm.getCode());
        assertEquals(List.of("confirmUnusualWeight"),
                confirm.getFieldErrors().stream().map(ApiError.FieldError::field).toList());

        BomItemSaveRequest normal = new BomItemSaveRequest();
        normal.setComponentGoodsId(granule);
        normal.setUnitWeightGrams(new BigDecimal("12.5"));
        normal.setControlStage("FINISH");
        normal.setHardGate(true);
        BomItemView created = bom.create(product, normal);
        assertEquals("PERIODIC", created.getComponentIssueMethod());
        money("12.5", created.getUnitWeightGrams(), "界面按克显示");
        money("0.0125", created.getQty(), "库里存千克");
        assertEquals("START", created.getControlStage(), "形状自动设成开工前");
        assertFalse(created.isHardGate(), "期间边不设齐套门槛");
        assertEquals(1, created.getWarnings().size(), "12.5 克与货品资料单重 10 克相差 25%");
        assertTrue(created.getWarnings().getFirst().contains("相差"), created.getWarnings()::toString);

        BomItemSaveRequest another = new BomItemSaveRequest();
        another.setComponentGoodsId(second);
        another.setUnitWeightGrams(new BigDecimal("3"));
        ApiException twoMaterials = assertThrows(ApiException.class, () -> bom.create(product, another));
        assertEquals(List.of("confirmSecondPeriodicMaterial"),
                twoMaterials.getFieldErrors().stream().map(ApiError.FieldError::field).toList());
        another.setConfirmSecondPeriodicMaterial(true);
        money("3", bom.create(product, another).getUnitWeightGrams(), "双料件确认后写入");

        BomItemSaveRequest packaged = new BomItemSaveRequest();
        packaged.setComponentGoodsId(granule);
        packaged.setUnitWeightGrams(new BigDecimal("13"));
        packaged.setConsumptionBasis("PER_PACKAGE");
        ApiException shape = assertThrows(ApiException.class, () -> bom.update(product, created.getId(), packaged));
        assertTrue(shape.getMessage().contains("单个重量"), shape.getMessage());

        // 按工单领料的组件不能按克填。
        UUID ordinary = goods(shop, "嵌件", shop.world().unitId(), "采购", "ORDER", null, null);
        BomItemSaveRequest insert = new BomItemSaveRequest();
        insert.setComponentGoodsId(ordinary);
        insert.setUnitWeightGrams(new BigDecimal("1"));
        assertThrows(ApiException.class, () -> bom.create(product, insert));
    }

    @Test
    void preparationListsFrequentProductsAndSavesEdgesAndChoicesAtOnce() {
        Shop shop = shop("prep");
        FullChainEndToEndTest.World world = shop.world();
        Object assignment = ReflectionTestUtils.invokeMethod(fixture, "productionAssignment", "s6-prep-" + shop.tag());
        UUID workshop = ReflectionTestUtils.invokeMethod(assignment, "workshopId");
        String granuleName = "颗粒PC-" + shop.tag();
        UUID granule = goods(shop, granuleName, shop.kg(), "采购", "PERIODIC", "OWN", null);
        UUID p1 = product(shop, "上线件一", new BigDecimal("12.5"), shop.gram());
        UUID p2 = product(shop, "上线件二", null, null);
        UUID p3 = product(shop, "上线件三", new BigDecimal("0.012"), shop.kg());
        db.update("UPDATE goods SET material = ? WHERE id = ?", granuleName, p3);
        db.update("UPDATE goods SET owning_workshop_department_id = ? WHERE id IN (?, ?, ?)", workshop, p1, p2, p3);
        UUID setupUser = fixture.createUserWithPerms(world, "s6-setup-" + shop.tag(), "goods:view",
                "workshop_material:view", "workshop_material:setup");

        fixture.loginAs(setupUser);
        PreparationView before = preparation.list(workshop);
        PreparationRow row3 = row(before, p3);
        assertEquals(granule, row3.materialGoodsId(), "老库材质与料名唯一命中, 预填");
        assertEquals(WorkshopMaterialChoicePort.PREFILL_LEGACY_MATERIAL_TEXT, row3.materialSource());
        assertEquals("PENDING", row3.status());
        money("12.5", row(before, p1).goodsWeightGrams(), "货品资料单重 (克)");
        money("12", row3.goodsWeightGrams(), "0.012 千克换成 12 克");
        assertTrue(before.materials().stream().anyMatch(option -> granule.equals(option.goodsId())
                && option.gramsConvertible()));

        fixture.loginAs(shop.bomUser());
        PreparationBatchRequest request = new PreparationBatchRequest(workshop, List.of(
                new PreparationRowInput(p1, null, granule, null, new BigDecimal("12.5"), null, null, null),
                new PreparationRowInput(p2, null, granule, null, null, null, null, null),
                new PreparationRowInput(p3, null, granule, null, new BigDecimal("20"), null, null,
                        WorkshopMaterialChoicePort.PREFILL_LEGACY_MATERIAL_TEXT)), key("prep"));
        PreparationBatchResult saved = preparation.save(request);
        assertEquals(2, saved.edgesCreated());
        assertEquals(0, saved.edgesUpdated());
        assertEquals(1, saved.choicesWritten());
        assertEquals(1, saved.warnings().size(), "20 克与货品资料单重 12 克相差 20% 以上");
        money("0.0125", decimal("SELECT qty FROM goods_bom_items WHERE goods_id = ? AND component_goods_id = ? AND NOT is_deleted",
                p1, granule), "克换成千克存");
        money("0.02", decimal("SELECT qty FROM goods_bom_items WHERE goods_id = ? AND component_goods_id = ? AND NOT is_deleted",
                p3, granule), "克换成千克存");
        assertEquals("START|PER_UNIT|false", str("""
                SELECT concat_ws('|', control_stage, consumption_basis, hard_gate::text) FROM goods_bom_items
                WHERE goods_id = ? AND component_goods_id = ? AND NOT is_deleted""", p1, granule));
        assertEquals(workshop, db.queryForObject("""
                SELECT chosen_workshop_department_id FROM goods_periodic_material_choices
                WHERE product_goods_id = ? AND material_goods_id = ? AND superseded_at IS NULL""", UUID.class, p2, granule),
                "只选了料的写认料, 记在这个车间名下");

        // 同号重放: 不重复写。
        PreparationBatchResult replay = preparation.save(request);
        assertEquals(saved.edgesCreated(), replay.edgesCreated());
        assertEquals(1, count("SELECT count(*) FROM goods_bom_items WHERE goods_id = ? AND NOT is_deleted", p1));

        fixture.loginAs(setupUser);
        PreparationView after = preparation.list(workshop);
        assertEquals("WEIGHED", row(after, p1).status());
        money("12.5", row(after, p1).unitWeightGrams(), "BOM 里的单个重量 (克)");
        assertEquals("CHOSEN", row(after, p2).status());
        assertEquals(3, after.chosenProducts());
        assertEquals(2, after.weighedProducts());

        // 千倍输错: 6000 克要确认; 确认后才写。
        fixture.loginAs(shop.bomUser());
        ApiException unusual = assertThrows(ApiException.class, () -> preparation.save(new PreparationBatchRequest(workshop,
                List.of(new PreparationRowInput(p1, null, granule, null, new BigDecimal("6000"), null, null, null)),
                key("unusual"))));
        assertEquals(ErrorCode.VALIDATION_FAILED, unusual.getCode());
        assertEquals("confirmUnusualWeight", unusual.getFieldErrors().getFirst().field());
        money("0.0125", decimal("SELECT qty FROM goods_bom_items WHERE goods_id = ? AND component_goods_id = ? AND NOT is_deleted",
                p1, granule), "没确认不写");
        PreparationBatchResult confirmed = preparation.save(new PreparationBatchRequest(workshop,
                List.of(new PreparationRowInput(p1, null, granule, null, new BigDecimal("6000"), true, null, null)),
                key("unusual-confirmed")));
        assertEquals(1, confirmed.edgesUpdated());
        money("6", decimal("SELECT qty FROM goods_bom_items WHERE goods_id = ? AND component_goods_id = ? AND NOT is_deleted",
                p1, granule), "确认后写入");
    }

    // =============================================================================================
    // 夹具
    // =============================================================================================

    private Shop shop(String tag) {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        String unique = tag + "-" + UUID.randomUUID().toString().substring(0, 8);
        var world = fixture.seedWorld("s6-" + unique);
        fixture.loginAs(world.superAdminUserId());
        UUID kg = unit("千克", "KG-" + unique, true);
        UUID gram = unit("克", "G-" + unique, true);
        UUID masterUser = fixture.createUserWithPerms(world, "s6-master-" + unique, "goods:view", "goods:edit",
                "goods:bom:edit");
        UUID bomUser = fixture.createUserWithPerms(world, "s6-bom-" + unique, "goods:view", "goods:bom:create",
                "goods:bom:edit");
        return new Shop(world, unique, kg, gram, masterUser, bomUser);
    }

    private UUID unit(String name, String code, boolean mass) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO units(id, legacy_id, code, name, status) VALUES (?, ?, ?, ?, '使用')",
                id, 900_000_000 + ThreadLocalRandom.current().nextInt(90_000_000), code, name);
        if (mass) {
            db.update("""
                    INSERT INTO unit_measurement_profiles(unit_id, measurement_dimension, mass_unit_code, provenance)
                    VALUES (?, 'MASS', 'KG', 'MANUAL_GOVERNANCE')""", id);
        }
        return id;
    }

    private UUID goods(Shop shop, String name, UUID unit, String source, String method, String basis,
                       BigDecimal orderMultiple) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO goods(id, code, name, source_type, status, unit_id, price, code_sequence,
                                  issue_method, periodic_cost_basis, order_multiple_qty)
                VALUES (?, ?, ?, ?, '使用', ?, 10, (SELECT coalesce(max(code_sequence), 0) + 1 FROM goods), ?, ?, ?)""",
                id, "S6-" + id.toString().substring(0, 8), name + "-" + id.toString().substring(0, 4), source, unit,
                method, basis, orderMultiple);
        return id;
    }

    private UUID product(Shop shop, String name, BigDecimal weight, UUID weightUnit) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO goods(id, code, name, source_type, status, unit_id, price, code_sequence,
                                  m_weight, m_weight_unit_id)
                VALUES (?, ?, ?, '自制', '使用', ?, 100, (SELECT coalesce(max(code_sequence), 0) + 1 FROM goods), ?, ?)""",
                id, "S6P-" + id.toString().substring(0, 8), name + "-" + id.toString().substring(0, 4),
                shop.world().unitId(), weight, weightUnit);
        return id;
    }

    private UUID bomRow(UUID parent, UUID component, String qty, String stage, String basis, String basisQty,
                        boolean hardGate) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO goods_bom_items(id, goods_id, component_goods_id, qty, control_stage, consumption_basis,
                                            basis_output_qty, hard_gate)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                id, parent, component, new BigDecimal(qty), stage, basis, new BigDecimal(basisQty), hardGate);
        return id;
    }

    /** 与夹具的旧式计划草稿同一写法: 从已审销售明细带入一行, 再审核。 */
    private UUID approvedPlan(FullChainEndToEndTest.World world, UUID goodsId, String qty) {
        UUID order = fixture.createApprovedOrder(world, goodsId, qty, "100");
        Map<String, Object> source = db.queryForMap("""
                SELECT i.id, i.color_id, i.unit_id, COALESCE(i.unit_rate, 1) AS unit_rate,
                       o.bill_no, COALESCE(i.qty, 0) AS order_qty
                FROM sales_order_items i JOIN sales_orders o ON o.id = i.order_id
                WHERE i.order_id = ?""", order);
        PlanItemLine line = new PlanItemLine();
        line.setProductNo("S6-" + UUID.randomUUID());
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
        UUID plan = plans.create(request).getId();
        plans.approve(plan);
        return plan;
    }

    private void otherIn(Shop shop, UUID warehouse, UUID goods, String qty, String price) {
        fixture.loginAs(shop.world().superAdminUserId());
        var request = new StockDocSaveRequest();
        request.setDocType("OTHER_IN");
        request.setWarehouseId(warehouse);
        request.setBillDate(BusinessTime.today());
        var line = new StockDocItemLine();
        line.setGoodsId(goods);
        line.setUnitId(shop.kg());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(new BigDecimal(price));
        line.setAmountOriginal(new BigDecimal(qty).multiply(new BigDecimal(price)));
        line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));
        stock.approve(stock.create(request).getId());
    }

    private static AffectedBomRow action(IssueMethodPreview preview, UUID bomItemId) {
        return preview.bomRows().stream().filter(row -> bomItemId.equals(row.bomItemId())).findFirst()
                .orElseThrow(() -> new AssertionError("预览里没有这行 BOM: " + preview.bomRows()));
    }

    private static PreparationRow row(PreparationView view, UUID product) {
        return view.rows().stream().filter(row -> product.equals(row.productGoodsId())).findFirst()
                .orElseThrow(() -> new AssertionError("上线准备里没有这个产品: " + view.rows()));
    }

    private long version(UUID goods) {
        return db.queryForObject("SELECT version FROM goods WHERE id = ?", Long.class, goods);
    }

    private String str(String sql, Object... args) {
        return db.queryForObject(sql, String.class, args);
    }

    private BigDecimal decimal(String sql, Object... args) {
        return db.queryForObject(sql, BigDecimal.class, args);
    }

    private boolean bool(String sql, Object... args) {
        return Boolean.TRUE.equals(db.queryForObject(sql, Boolean.class, args));
    }

    private int count(String sql, Object... args) {
        Integer value = db.queryForObject(sql, Integer.class, args);
        return value == null ? 0 : value;
    }

    private static String key(String tag) {
        return "s6-" + tag + "-" + UUID.randomUUID();
    }

    private static void money(String expected, BigDecimal actual, String message) {
        assertNotNull(actual, message);
        assertEquals(0, new BigDecimal(expected).compareTo(actual), () -> message + ": expected " + expected
                + ", actual " + actual);
    }
}
