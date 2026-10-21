package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.analysis.MaterialAnalysisController;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;

/** Real migrated PostgreSQL: soft allocations change; physical stock and history do not. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false"})
class MaterialAnalysisBorrowEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired MaterialAnalysisController controller;
    FullChainEndToEndTest fixture;

    @BeforeEach void prepare() { fixture = new FullChainEndToEndTest(); beans.autowireBean(fixture); }
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void borrowAndRevokeReplayPreservePhysicalStockAndOriginalProductDemand() {
        var scenario = scenario();
        var request = borrow(scenario, "borrow-create-" + UUID.randomUUID(), "4");
        var moved = controller.createBorrow(scenario.view.analysisId(), request);
        assertAllocation(moved, scenario.from, "6");
        assertAllocation(moved, scenario.to, "4");
        assertPhysicalFacts(scenario);
        var replay = controller.createBorrow(scenario.view.analysisId(), request);
        assertAllocation(replay, scenario.to, "4");
        assertEquals(1, count("SELECT count(*) FROM production_material_analysis_borrows WHERE analysis_id=?", scenario.view.analysisId()));
        assertThrows(ApiException.class, () -> controller.createBorrow(scenario.view.analysisId(), borrow(scenario, request.idempotencyKey(), "3")));
        assertThrows(ApiException.class, () -> controller.createBorrow(scenario.view.analysisId(), borrow(scenario, "borrow-stale-" + UUID.randomUUID(), "1")));

        UUID borrowId = db.queryForObject("SELECT id FROM production_material_analysis_borrows WHERE analysis_id=?", UUID.class, scenario.view.analysisId());
        var cancel = new CancelRequest(moved.version(), moved.fingerprint(), "borrow-revoke-" + UUID.randomUUID(), "恢复原分析软分配");
        var restored = controller.revokeBorrow(scenario.view.analysisId(), borrowId, cancel);
        assertAllocation(restored, scenario.from, "10");
        assertAllocation(restored, scenario.to, "0");
        controller.revokeBorrow(scenario.view.analysisId(), borrowId, cancel);
        assertEquals("REVOKED", db.queryForObject("SELECT status FROM production_material_analysis_borrows WHERE id=?", String.class, borrowId));
        assertEquals(1, count("SELECT count(*) FROM production_material_analysis_commands WHERE analysis_id=? AND operation='BORROW_REVOKE'", scenario.view.analysisId()));
        assertPhysicalFacts(scenario);
    }

    @Test void missingActionPermissionAndAnAlreadyOrderedEndpointDoNotCreateBorrowFacts() {
        var scenario = scenario();
        var actor = (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var reader = new AuthUser(actor.getId(), actor.getEmployeeId(), actor.getUsername(), Set.of("production_material_analysis:view"), false, true, false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(reader, null, reader.getAuthorities()));
        assertThrows(AccessDeniedException.class, () -> controller.createBorrow(scenario.view.analysisId(), borrow(scenario, "borrow-denied-" + UUID.randomUUID(), "1")));
        fixture.loginAs(scenario.world.superAdminUserId());
        commands.notifySupply(scenario.view.analysisId(), new NotifyRequest(scenario.view.version(), scenario.view.fingerprint(),
                "borrow-supply-" + UUID.randomUUID(), "BUY", List.of(scenario.to), List.of(), null));
        var current = analyses.detail(scenario.view.analysisId());
        assertThrows(ApiException.class, () -> controller.createBorrow(current.analysisId(), new BorrowRequest(current.version(), current.fingerprint(),
                "borrow-ordered-" + UUID.randomUUID(), scenario.from, scenario.to, BigDecimal.ONE, "已办理的目标不能借用")));
        assertEquals(0, count("SELECT count(*) FROM production_material_analysis_borrows WHERE analysis_id=?", scenario.view.analysisId()));
        assertPhysicalFacts(scenario);
    }

    @Test void simultaneousBorrowCommandsWithOneSnapshotCommitOnlyOneAllocation() throws Exception {
        var scenario = scenario();
        var actor = (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var ready = new java.util.concurrent.CountDownLatch(2);
        var start = new java.util.concurrent.CountDownLatch(1);
        try (var executor = java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var results = new java.util.ArrayList<java.util.concurrent.Future<String>>();
            for (int index = 0; index < 2; index++) {
                var request = borrow(scenario, "borrow-race-" + UUID.randomUUID(), "4");
                results.add(executor.submit(() -> {
                    SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
                    try {
                        ready.countDown();
                        assertTrue(start.await(10, java.util.concurrent.TimeUnit.SECONDS));
                        try {
                            controller.createBorrow(scenario.view.analysisId(), request);
                            return "OK";
                        } catch (ApiException conflict) {
                            assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT, conflict.getCode());
                            return "STALE";
                        }
                    } finally { SecurityContextHolder.clearContext(); }
                }));
            }
            assertTrue(ready.await(10, java.util.concurrent.TimeUnit.SECONDS));
            start.countDown();
            var states = new java.util.ArrayList<String>();
            for (var result : results) states.add(result.get(90, java.util.concurrent.TimeUnit.SECONDS));
            assertEquals(1, states.stream().filter("OK"::equals).count());
            assertEquals(1, states.stream().filter("STALE"::equals).count());
        }
        assertEquals(1, count("SELECT count(*) FROM production_material_analysis_borrows WHERE analysis_id=?", scenario.view.analysisId()));
        var current = analyses.detail(scenario.view.analysisId());
        assertAllocation(current, scenario.from, "6");
        assertAllocation(current, scenario.to, "4");
        assertPhysicalFacts(scenario);
    }

    private Scenario scenario() {
        var world = fixture.seedWorld("borrow-audit-" + UUID.randomUUID().toString().substring(0, 8));
        fixture.loginAs(world.superAdminUserId());
        UUID first = UUID.randomUUID(), second = UUID.randomUUID(), material = UUID.randomUUID();
        fixture.insertGoods(first, "BR-P1-" + first, "先分配产品", "自制", world.unitId(), world.unitLegacy());
        fixture.insertGoods(second, "BR-P2-" + second, "后分配产品", "自制", world.unitId(), world.unitLegacy());
        fixture.insertGoods(material, "BR-M-" + material, "共用物料", "采购", world.unitId(), world.unitLegacy());
        fixture.insertBom(first, material, "1"); fixture.insertBom(second, material, "1");
        db.update("UPDATE goods SET default_supplier_id=? WHERE id=?", world.supplierId(), material);
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,color_id,qty) VALUES(?,?,NULL,10)", world.warehouseId(), material);
        var view = analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(), "borrow-preview-" + first,
                List.of(new PreviewItem("OTHER", null, first, null, world.unitId(), "first-" + first, "现货调拨原需求", BusinessTime.today(), BigDecimal.TEN),
                        new PreviewItem("OTHER", null, second, null, world.unitId(), "second-" + second, "现货调拨目标需求", BusinessTime.today(), BigDecimal.TEN))));
        var rows = view.flatMaterials().stream().filter(row -> row.goodsId().equals(material)).toList();
        UUID from = rows.stream().filter(row -> row.allocatedAvailableQty().compareTo(BigDecimal.TEN) == 0).findFirst().orElseThrow().materialLineId();
        UUID to = rows.stream().filter(row -> !row.materialLineId().equals(from)).findFirst().orElseThrow().materialLineId();
        return new Scenario(world, view, material, from, to);
    }
    private BorrowRequest borrow(Scenario s, String key, String qty) {
        return new BorrowRequest(s.view.version(), s.view.fingerprint(), key, s.from, s.to, new BigDecimal(qty), "优先安排接受产品");
    }
    private void assertPhysicalFacts(Scenario s) {
        amount("10", db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE goods_id=?", BigDecimal.class, s.material));
        assertEquals(0, count("SELECT count(*) FROM stock_reservations WHERE goods_id=? AND NOT is_deleted", s.material));
        assertEquals(0, count("SELECT count(*) FROM stock_movements WHERE goods_id=?", s.material));
        for (var product : analyses.detail(s.view.analysisId()).products()) amount("10", product.requestedQty());
    }
    private static void assertAllocation(AnalysisView view, UUID material, String expected) {
        amount(expected, view.flatMaterials().stream().filter(row -> row.materialLineId().equals(material)).findFirst().orElseThrow().allocatedAvailableQty());
    }
    private static void amount(String expected, BigDecimal actual) { assertNotNull(actual); assertEquals(0, new BigDecimal(expected).compareTo(actual), "expected " + expected + ", got " + actual); }
    private int count(String sql, UUID id) { return db.queryForObject(sql, Integer.class, id); }
    private record Scenario(FullChainEndToEndTest.World world, AnalysisView view, UUID material, UUID from, UUID to) {}
}
