package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MaterialStockOption;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.access.prepost.PreAuthorize;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.HashSet;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** 用真实叶仓函数与 PostgreSQL 验证申请候选，无全 Spring 启动或业务库写入。 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopMaterialRequestCandidatesPostgresTest {
    private static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private final UUID workshop = UUID.randomUUID(), bin = UUID.randomUUID(), otherBin = UUID.randomUUID();
    private final UUID kg = UUID.randomUUID(), grams = UUID.randomUUID(), countUnit = UUID.randomUUID();
    private final UUID leaf = UUID.randomUUID(), secondLeaf = UUID.randomUUID();
    private WorkshopMaterialScope scope;
    private WorkshopMaterialBinSupport bins;
    private WorkshopMaterialPositionQueryService service;

    @BeforeAll static void start() {
        PG.start();
        var source = new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        db = new JdbcTemplate(source);
        named = new NamedParameterJdbcTemplate(source);
    }

    @AfterAll static void stop() { PG.stop(); }

    @BeforeEach void seed() throws Exception {
        db.execute("""
                DROP SCHEMA public CASCADE; CREATE SCHEMA public;
                CREATE TABLE units(id uuid PRIMARY KEY, name text, status text DEFAULT '使用', is_deleted boolean DEFAULT false);
                CREATE TABLE unit_measurement_profiles(unit_id uuid PRIMARY KEY, measurement_dimension text);
                CREATE TABLE colors(id uuid PRIMARY KEY, name text, status text DEFAULT '使用', is_deleted boolean DEFAULT false);
                CREATE TABLE warehouses(id uuid PRIMARY KEY, name text, parent_id uuid, status text DEFAULT '使用',
                    is_deleted boolean DEFAULT false, is_line_side boolean DEFAULT false, is_accountable boolean DEFAULT true);
                CREATE TABLE goods(id uuid PRIMARY KEY, code text, name text, color_id uuid, unit_id uuid,
                    status text DEFAULT '使用', is_deleted boolean DEFAULT false, issue_method text DEFAULT 'ORDER',
                    bulk_package_qty numeric, periodic_cost_basis text, owning_warehouse_id uuid, min_qty numeric DEFAULT 0);
                CREATE TABLE stock_balances(warehouse_id uuid, goods_id uuid, color_id uuid, qty numeric);
                CREATE TABLE stock_reservations(warehouse_id uuid, goods_id uuid, color_id uuid, qty numeric,
                    consumed_qty numeric DEFAULT 0, released_qty numeric DEFAULT 0,
                    is_deleted boolean DEFAULT false, status integer DEFAULT 0);
                CREATE TABLE v_workshop_material_bin_ledger(bin_warehouse_id uuid, goods_id uuid, color_id uuid);
                """);
        try (var resource = getClass().getResourceAsStream("/db/migration/V613__operational_warehouse_leaf_identity.sql")) {
            String migration = new String(resource.readAllBytes(), StandardCharsets.UTF_8);
            db.execute(migration.substring(0, migration.indexOf("DO $migration$")));
        }
        db.update("INSERT INTO units(id,name) VALUES (?, 'kg'), (?, 'g'), (?, '个')", kg, grams, countUnit);
        db.update("INSERT INTO unit_measurement_profiles VALUES (?, 'MASS'), (?, 'MASS'), (?, 'COUNT')", kg, grams, countUnit);
        warehouse(leaf, "颗粒仓", null, false);
        warehouse(secondLeaf, "辅料仓", null, false);
        warehouse(bin, "本车间内料仓", leaf, true);
        warehouse(otherBin, "别的车间内料仓", secondLeaf, true);
        scope = mock(WorkshopMaterialScope.class);
        bins = mock(WorkshopMaterialBinSupport.class);
        when(bins.settings(workshop)).thenReturn(new WorkshopMaterialBinSupport.Settings(workshop,
                "注塑车间", true, bin, LocalDate.of(2026, 9, 30), 1));
        service = new WorkshopMaterialPositionQueryService(named, bins, scope,
                mock(WorkshopMaterialPermissions.class), mock(WorkshopMaterialPeriodViews.class));
    }

    @Test void zeroPeriodicMaterialsStillOffersOrderMassMaterialsWithTheirActualUnitsAndChangesNothing() {
        UUID pp = goods("PP", "PP 颗粒", kg, "ORDER");
        UUID pigment = goods("PIGMENT", "色粉", grams, "ORDER");
        var result = service.requestMaterials(workshop, null, null, 1, 50);
        assertThat(result.getTotal()).isEqualTo(2);
        assertThat(result.getItems()).extracting(MaterialStockOption::unitName).containsExactlyInAnyOrder("kg", "g");
        assertThat(result.getItems()).extracting(MaterialStockOption::goodsId).containsExactlyInAnyOrder(pp, pigment);
        assertThat(result.getItems()).allSatisfy(row -> {
            assertThat(row.costBasis()).isNull();
            assertThat(row.warehouseAvailableQty()).isZero();
        });
        assertThat(db.queryForObject("SELECT count(*) FROM goods WHERE issue_method = 'ORDER'", Integer.class)).isEqualTo(2);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_balances", Integer.class)).isZero();
        assertThat(service.materials(workshop)).isEmpty();
    }

    @Test void eligibilityRequiresUsableGoodsAndMassUnitsButDoesNotInventAProfile() {
        UUID valid = goods("VALID", "正常颗粒", kg, "PERIODIC");
        goods("COUNT", "螺丝", countUnit, "ORDER");
        UUID disabled = goods("DISABLED", "禁用颗粒", kg, "ORDER");
        UUID deleted = goods("DELETED", "删除颗粒", kg, "ORDER");
        UUID unitDisabled = goods("BAD-UNIT", "禁用单位料", grams, "ORDER");
        db.update("UPDATE goods SET status='禁用' WHERE id=?", disabled);
        db.update("UPDATE goods SET is_deleted=true WHERE id=?", deleted);
        db.update("UPDATE units SET status='禁用' WHERE id=?", grams);
        var result = service.requestMaterials(workshop, null, null, 1, 50);
        assertThat(result.getItems()).extracting(MaterialStockOption::goodsId).containsExactly(valid);
        assertThat(service.requestMaterials(workshop, null, List.of(unitDisabled), 1, 50).getTotal()).isZero();
    }

    @Test void ownHistoryAndNormalWarehouseColorsAreMergedWithoutLeakingOtherBins() {
        UUID material = goods("PP", "聚丙烯", kg, "ORDER");
        UUID black = color("黑"), local = color("本仓旧色"), foreign = color("别仓私有色");
        db.update("UPDATE goods SET min_qty=2, owning_warehouse_id=? WHERE id=?", otherBin, material);
        balance(leaf, material, black, "20"); balance(secondLeaf, material, black, "30");
        balance(bin, material, black, "10000"); balance(otherBin, material, foreign, "20000");
        db.update("INSERT INTO stock_reservations(warehouse_id,goods_id,color_id,qty) VALUES (?,?,?,6), (NULL,?,?,3)",
                leaf, material, black, material, black);
        db.update("INSERT INTO v_workshop_material_bin_ledger VALUES (?,?,?), (?,?,?)",
                bin, material, local, otherBin, material, foreign);
        var result = service.requestMaterials(workshop, null, List.of(material), 1, 50);
        assertThat(result.getTotal()).isEqualTo(3); // 默认无色、正常仓有货色、本仓历史色。
        assertThat(result.getItems().getFirst().colorId()).isEqualTo(local);
        assertThat(result.getItems()).extracting(MaterialStockOption::colorId).doesNotContain(foreign);
        var stock = result.getItems().stream().filter(row -> black.equals(row.colorId())).findFirst().orElseThrow();
        assertThat(stock.warehouseAvailableQty()).isEqualByComparingTo("39");
        assertThat(stock.defaultLeafWarehouseId()).isNull();
        assertThat(stock.defaultLeafWarehouseName()).isNull();
        assertThat(stock.leafWarehouses()).extracting(WorkshopMaterialDtos.LeafStockView::warehouseId)
                .containsExactlyInAnyOrder(leaf, secondLeaf);
    }

    @Test void missingGoodsUnitOrColorStatusDoesNotOfferRowsThatCannotBeRequested() {
        UUID valid = goods("VALID", "有效颗粒", kg, "ORDER");
        UUID unstated = goods("NULL-GOODS", "未定状态颗粒", kg, "ORDER");
        db.update("UPDATE goods SET status=NULL WHERE id=?", unstated);
        UUID unstatedUnit = UUID.randomUUID();
        db.update("INSERT INTO units(id,name,status) VALUES (?, '未定状态重量单位', NULL)", unstatedUnit);
        db.update("INSERT INTO unit_measurement_profiles VALUES (?, 'MASS')", unstatedUnit);
        goods("NULL-UNIT", "单位状态未定颗粒", unstatedUnit, "ORDER");
        UUID unstatedColor = color("状态未定色");
        db.update("UPDATE colors SET status=NULL WHERE id=?", unstatedColor);
        balance(leaf, valid, unstatedColor, "10");
        var result = service.requestMaterials(workshop, null, null, 1, 50);
        assertThat(result.getTotal()).isEqualTo(1);
        assertThat(result.getItems()).extracting(MaterialStockOption::goodsId).containsExactly(valid);
        assertThat(result.getItems().getFirst().colorId()).isNull();
    }

    @Test void pagingBeyondFiveHundredNeverDropsCandidatesAndHistoryStillComesFirst() {
        db.update("""
                INSERT INTO goods(id,code,name,unit_id)
                SELECT gen_random_uuid(), 'SAME-CODE', '颗粒-' || value, ? FROM generate_series(1, 507) value
                """, kg);
        UUID familiar = goods("ZZZ", "常用颗粒", kg, "ORDER");
        db.update("INSERT INTO v_workshop_material_bin_ledger VALUES (?,?,NULL)", bin, familiar);
        var seen = new HashSet<UUID>();
        for (int page = 1; page <= 6; page++) {
            var result = service.requestMaterials(workshop, null, null, page, 1000);
            assertThat(result.getSize()).isEqualTo(100);
            assertThat(result.getPage()).isEqualTo(page);
            assertThat(result.getTotal()).isEqualTo(508);
            assertThat(result.getTotalPages()).isEqualTo(6);
            if (page == 1) assertThat(result.getItems().getFirst().goodsId()).isEqualTo(familiar);
            for (var row : result.getItems()) assertThat(seen.add(row.goodsId())).isTrue();
        }
        assertThat(seen).hasSize(508);
        var beyond = service.requestMaterials(workshop, null, null, 7, 100);
        assertThat(beyond.getItems()).isEmpty();
        assertThat(beyond.getTotal()).isEqualTo(508);
    }

    @Test void exactGoodsIdsAndLiteralKeywordFiltersHaveCorrectTotals() {
        UUID requested = goods("PP-1", "100%_纯料", kg, "ORDER");
        goods("PP-2", "10000纯料", kg, "ORDER");
        UUID black = color("黑色"); balance(leaf, requested, black, "10");
        var exact = service.requestMaterials(workshop, null, List.of(requested), 1, 50);
        assertThat(exact.getTotal()).isEqualTo(2);
        assertThat(exact.getItems()).extracting(MaterialStockOption::goodsId).containsOnly(requested);
        var literal = service.requestMaterials(workshop, " %_ ", null, 1, 50);
        assertThat(literal.getTotal()).isEqualTo(2);
        assertThat(service.requestMaterials(workshop, "黑色", List.of(requested), 1, 50).getTotal()).isEqualTo(1);
        assertThat(service.requestMaterials(workshop, null, List.of(UUID.randomUUID()), 1, 50).getItems()).isEmpty();
    }

    @Test void invalidDefaultWarehousesAndDisabledColorsAreNotAdvertised() {
        UUID material = goods("PP", "颗粒", kg, "ORDER");
        UUID disabled = color("停用色");
        db.update("UPDATE colors SET status='禁用' WHERE id=?", disabled);
        balance(leaf, material, disabled, "50");
        db.update("UPDATE goods SET owning_warehouse_id=? WHERE id=?", leaf, material);
        var emptyLeaf = service.requestMaterials(workshop, null, null, 1, 50).getItems().getFirst();
        assertThat(emptyLeaf.colorId()).isNull();
        assertThat(emptyLeaf.defaultLeafWarehouseId()).isEqualTo(leaf);
        assertThat(emptyLeaf.leafWarehouses()).hasSize(1);
        assertThat(emptyLeaf.leafWarehouses().getFirst().availableQty()).isZero();
        warehouse(UUID.randomUUID(), "普通子仓", leaf, false);
        assertThat(service.requestMaterials(workshop, null, null, 1, 50).getItems().getFirst().defaultLeafWarehouseId()).isNull();
    }

    @Test void sharedMaterialsRemainPeriodicOnlyWhileRequestIncludesBothModes() {
        UUID ordered = goods("ORDER", "按单颗粒", kg, "ORDER");
        UUID periodic = goods("PERIODIC", "整批颗粒", kg, "PERIODIC");
        assertThat(service.materials(workshop)).extracting(MaterialStockOption::goodsId).containsExactly(periodic);
        assertThat(service.requestMaterials(workshop, null, null, 1, 50).getItems())
                .extracting(MaterialStockOption::goodsId).containsExactlyInAnyOrder(ordered, periodic);
    }

    @Test void workshopScopeIsCheckedBeforeReadingCandidatesAndControllerRequiresView() throws Exception {
        doThrow(new ApiException(ErrorCode.FORBIDDEN, "不是可见车间")).when(scope).requireWorkshop(workshop);
        assertThatThrownBy(() -> service.requestMaterials(workshop, null, null, 1, 50)).isInstanceOf(ApiException.class);
        verifyNoInteractions(bins);
        var method = WorkshopMaterialPositionController.class.getMethod("requestMaterials", UUID.class,
                String.class, List.class, int.class, int.class);
        assertThat(method.getAnnotation(PreAuthorize.class).value()).contains("workshop_material:view");
    }

    private UUID goods(String code, String name, UUID unit, String method) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO goods(id,code,name,unit_id,issue_method,periodic_cost_basis) VALUES (?,?,?,?,?,?)",
                id, code, name, unit, method, "PERIODIC".equals(method) ? "OWN" : null);
        return id;
    }
    private UUID color(String name) {
        UUID id = UUID.randomUUID(); db.update("INSERT INTO colors(id,name) VALUES (?,?)", id, name); return id;
    }
    private void warehouse(UUID id, String name, UUID parent, boolean lineSide) {
        db.update("INSERT INTO warehouses(id,name,parent_id,is_line_side) VALUES (?,?,?,?)", id, name, parent, lineSide);
    }
    private void balance(UUID warehouse, UUID goods, UUID color, String qty) {
        db.update("INSERT INTO stock_balances VALUES (?,?,?,?)", warehouse, goods, color, new BigDecimal(qty));
    }
}
