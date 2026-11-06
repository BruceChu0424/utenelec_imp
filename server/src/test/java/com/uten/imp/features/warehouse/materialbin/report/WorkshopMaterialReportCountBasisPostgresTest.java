package com.uten.imp.features.warehouse.materialbin.report;

import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPermissions;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialScope;
import com.uten.imp.features.warehouse.materialbin.WorkshopBinService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.time.LocalDate;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

/** 真实 PostgreSQL 查询回归；只搭建只读投影所需的表形状，不执行库存写命令或全链迁移。 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopMaterialReportCountBasisPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private final UUID bin = UUID.randomUUID(), workshop = UUID.randomUUID(), goods = UUID.randomUUID();
    private final UUID product = UUID.randomUUID(), color = UUID.randomUUID();
    private final UUID materialUnit = UUID.randomUUID();
    private final UUID first = UUID.randomUUID(), second = UUID.randomUUID();
    private final UUID firstCount = UUID.randomUUID(), secondCount = UUID.randomUUID();
    private WorkshopMaterialReportQueryService reports;
    private WorkshopMaterialPermissions permissions;
    private WorkshopMaterialScope scope;

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
        """);
        MigratedProjectionSchema.createCurrentColumns(db, "workshop_material_settings", "workshop_material_periods", "workshop_material_counts", "workshop_material_count_lines", "workshop_material_period_lines", "workshop_material_count_adjustment_postings", "goods", "colors", "units", "unit_measurement_profiles", "v_workshop_material_period_report");
        db.execute("""
            ALTER TABLE workshop_material_periods ADD PRIMARY KEY(id);
            ALTER TABLE workshop_material_counts ADD PRIMARY KEY(id);



            ALTER TABLE goods ADD PRIMARY KEY(id);
            ALTER TABLE colors ADD PRIMARY KEY(id);
            ALTER TABLE units ADD PRIMARY KEY(id);
            ALTER TABLE unit_measurement_profiles ADD PRIMARY KEY(unit_id);
            -- Constructor defaults below are supplied read-view outcomes, not production stored defaults.
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN start_date SET DEFAULT '2026-09-01';
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN end_date SET DEFAULT '2026-09-30';
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN period_status SET DEFAULT 'CLOSED';
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN period_line_id SET DEFAULT gen_random_uuid();
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN cost_basis SET DEFAULT 'OWN';
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN opening_qty SET DEFAULT 20;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN transfer_in_qty SET DEFAULT 100;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN return_qty SET DEFAULT 0;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN other_issue_qty SET DEFAULT 0;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN closing_qty SET DEFAULT 30;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN actual_qty SET DEFAULT 90;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN theory_qty SET DEFAULT 80;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN diff_qty SET DEFAULT 10;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN waste_rate SET DEFAULT 0.125;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN outcome SET DEFAULT 'ALLOCATED';
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN flags SET DEFAULT '{}';
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN consumed_qty SET DEFAULT 90;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN loss_qty SET DEFAULT 0;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN close_no SET DEFAULT 1;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN closed_at SET DEFAULT now();
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN current_value SET DEFAULT 180;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN value_at_close SET DEFAULT 180;
            ALTER TABLE v_workshop_material_period_report ALTER COLUMN adjustment_qty SET DEFAULT 0;
            CREATE TABLE product_reference(id uuid);
            CREATE VIEW v_workshop_material_product_report AS
                SELECT report.bin_warehouse_id, report.period_id, report.period_no, report.start_date, report.end_date,
                    report.period_line_id AS close_material_id, report.cost_basis, report.goods_id AS material_goods_id,
                    report.color_id AS material_color_id, report.unit_id AS material_unit_id,
                    product.id AS product_goods_id, 100::numeric AS output_qty,
                    report.theory_qty, report.actual_qty AS allocated_qty, report.current_value, true AS exclusive_period
                FROM v_workshop_material_period_report report CROSS JOIN product_reference product;
            CREATE VIEW v_workshop_material_waste_trend AS
                SELECT bin_warehouse_id, period_id, period_no, start_date, end_date, goods_id, color_id, waste_rate
                FROM v_workshop_material_period_report;
        """);
        MigratedProjectionSchema.createCurrentTables(db, "warehouses", "workshop_bins");
        // 使用当前权威换算函数，不在夹具中复制一套因子。
        try (var resource = getClass().getResourceAsStream("/db/migration/V743__warehouse_weight_ledger_and_learning.sql")) {
            String migration = new String(resource.readAllBytes(), StandardCharsets.UTF_8);
            int start = migration.indexOf("CREATE FUNCTION fn_weight_unit_kg_factor(");
            db.execute(migration.substring(start, migration.indexOf("$$;", start) + 3));
        }
        db.update("INSERT INTO workshop_material_settings(periodic_bin_warehouse_id,workshop_department_id) VALUES(?, ?)", bin, workshop);
        db.update("INSERT INTO workshop_bins(bin_warehouse_id,workshop_department_id) VALUES (?, ?)", bin, workshop);
        db.update("INSERT INTO warehouses(id) VALUES (?)", bin);
        db.update("INSERT INTO goods(id,code,name) VALUES(?, 'PP', '颗粒'), (?, 'P1', '外壳')", goods, product);
        db.update("INSERT INTO product_reference VALUES (?)", product);
        db.update("INSERT INTO colors(id,name) VALUES(?, '黑')", color);
        db.update("INSERT INTO units(id,name) VALUES(?, '车间称量单位')", materialUnit);
        db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code) VALUES(?, 'MASS', 'KG')", materialUnit);
        db.update("INSERT INTO workshop_material_periods(id,bin_warehouse_id,period_no) VALUES(?, ?, 1), (?, ?, 2)", first, bin, second, bin);
        count(firstCount, first, "SUBMITTED");
        count(secondCount, second, "SUBMITTED");
        line(firstCount, null, "CONTAINER", "HALF");
        line(firstCount, color, "WEIGHED", null);
        line(secondCount, null, "WEIGHED", null);
        line(secondCount, null, "FULL_BAGS", null);
        line(secondCount, color, "CONTAINER", "WEIGHED");
        report(first, 1, null); report(first, 1, color);
        report(second, 2, null); report(second, 2, color);
        permissions = mock(WorkshopMaterialPermissions.class);
        when(permissions.has("goods:cost:view")).thenReturn(true);
        scope = mock(WorkshopMaterialScope.class);
        reports = new WorkshopMaterialReportQueryService(named, scope, permissions, new WorkshopBinService(named));
    }

    @Test void openedBinIdentityDoesNotDependOnPeriodicSettingsAndHistoricalDataRemainsReadable() {
        db.update("DELETE FROM workshop_material_settings WHERE periodic_bin_warehouse_id = ?", bin);
        assertThat(reports.binUsage(bin, null, null)).hasSize(4);
        assertThat(reports.productUsage(bin, null, null)).hasSize(4);
        assertThat(reports.wasteTrend(bin, null)).hasSize(4);
        verify(scope, times(3)).requireWorkshop(workshop);
        assertThat(db.queryForObject("SELECT count(*) FROM workshop_material_settings", Integer.class)).isZero();
    }

    @Test void newlyOpenedBinWithNoPeriodicActivityReturnsAnEmptyReport() {
        UUID openedOnly = UUID.randomUUID(), openedWorkshop = UUID.randomUUID();
        db.update("INSERT INTO workshop_bins(bin_warehouse_id,workshop_department_id) VALUES (?, ?)", openedOnly, openedWorkshop);
        db.update("INSERT INTO warehouses(id) VALUES (?)", openedOnly);
        assertThat(reports.binUsage(openedOnly, null, null)).isEmpty();
        assertThat(reports.productUsage(openedOnly, null, null)).isEmpty();
        assertThat(reports.wasteTrend(openedOnly, null)).isEmpty();
        verify(scope, times(3)).requireWorkshop(openedWorkshop);
    }

    @Test void ordinaryDeletedAndOutOfScopeBinsRemainRejected() {
        UUID ordinary = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id) VALUES (?)", ordinary);
        assertThatThrownBy(() -> reports.binUsage(ordinary, null, null))
                .isInstanceOf(ApiException.class).hasMessageContaining("不是车间内料仓");
        db.update("UPDATE warehouses SET is_deleted = true WHERE id = ?", bin);
        assertThatThrownBy(() -> reports.binUsage(bin, null, null))
                .isInstanceOf(ApiException.class).hasMessageContaining("不是车间内料仓");
        verifyNoInteractions(scope);
        db.update("UPDATE warehouses SET is_deleted = false WHERE id = ?", bin);
        doThrow(new ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN, "只能查看和办理本车间的内料仓"))
                .when(scope).requireWorkshop(workshop);
        assertThatThrownBy(() -> reports.binUsage(bin, null, null))
                .isInstanceOf(ApiException.class).hasMessageContaining("本车间");
    }

    @Test void openingEstimateSurvivesAWeighedClosingAndIsSharedByAllThreeReports() {
        var row = reports.binUsage(bin, LocalDate.of(2026, 9, 1), null).stream()
                .filter(r -> r.periodNo() == 2 && r.colorId() == null).findFirst().orElseThrow();
        assertThat(row.openingCountBasis()).isEqualTo("ESTIMATED");
        assertThat(row.closingCountBasis()).isEqualTo("WEIGHED_AND_BAGS");
        assertThat(row.actualQty()).isEqualByComparingTo("90");
        var productRow = reports.productUsage(bin, null, null).stream()
                .filter(r -> r.periodNo() == 2 && r.materialColorId() == null).findFirst().orElseThrow();
        assertThat(productRow.exclusivePeriod()).isTrue();
        assertThat(productRow.openingCountBasis()).isEqualTo("ESTIMATED");
        assertThat(productRow.closingCountBasis()).isEqualTo(row.closingCountBasis());
        assertThat(productRow.actualPerUnit()).isEqualByComparingTo("0.9");
        var trend = reports.wasteTrend(bin, goods).stream()
                .filter(r -> r.periodNo() == 2 && r.colorId() == null).findFirst().orElseThrow();
        assertThat(trend.openingCountBasis()).isEqualTo("ESTIMATED");
        assertThat(trend.closingCountBasis()).isEqualTo(row.closingCountBasis());
        assertThat(trend.wasteRate()).isEqualByComparingTo("0.125");
        verify(scope, times(3)).requireWorkshop(workshop);
    }

    @Test void draftAndSupersededCorrectionsNeverReplaceSubmittedEvidence() {
        UUID draft = UUID.randomUUID(), old = UUID.randomUUID();
        count(draft, first, "DRAFT"); line(draft, null, "WEIGHED", null);
        count(old, first, "SUPERSEDED"); line(old, null, "WEIGHED", null);
        assertThat(secondOpening()).isEqualTo("ESTIMATED");
        db.update("UPDATE workshop_material_counts SET status = 'SUPERSEDED' WHERE id = ?", firstCount);
        db.update("UPDATE workshop_material_counts SET status = 'SUBMITTED' WHERE id = ?", draft);
        assertThat(secondOpening()).isEqualTo("WEIGHED");
    }

    @Test void colorAndWarehouseBoundariesDoNotLeakEstimates() {
        UUID otherBin = UUID.randomUUID(), period = UUID.randomUUID(), counted = UUID.randomUUID();
        db.update("INSERT INTO workshop_material_periods(id,bin_warehouse_id,period_no) VALUES(?, ?, 1)", period, otherBin);
        count(counted, period, "SUBMITTED"); line(counted, color, "CONTAINER", "FULL");
        var rows = reports.binUsage(bin, null, null);
        assertThat(rows).hasSize(4);
        var black = rows.stream().filter(r -> r.periodNo() == 2 && color.equals(r.colorId())).findFirst().orElseThrow();
        assertThat(black.openingCountBasis()).isEqualTo("WEIGHED");
        assertThat(black.closingCountBasis()).isEqualTo("WEIGHED");
        assertThat(rows.stream().filter(r -> r.periodNo() == 1).map(r -> r.openingCountBasis()))
                .containsOnly("EMPTY_START");
    }

    @Test void missingEvidenceRemainsUnknownAndBagCountsAreNotCalledWeighed() {
        db.update("DELETE FROM workshop_material_count_lines WHERE count_id = ? AND color_id IS NULL", secondCount);
        var missing = reports.binUsage(bin, null, null).stream()
                .filter(r -> r.periodNo() == 2 && r.colorId() == null).findFirst().orElseThrow();
        assertThat(missing.closingCountBasis()).isEqualTo("UNKNOWN");
        line(secondCount, null, "FULL_BAGS", null);
        var bags = reports.binUsage(bin, null, null).stream()
                .filter(r -> r.periodNo() == 2 && r.colorId() == null).findFirst().orElseThrow();
        assertThat(bags.closingCountBasis()).isEqualTo("BAG_COUNT");
    }

    @Test void emptyContainerStillCarriesItsHistoricalEstimateAndCostsRemainMasked() {
        db.update("UPDATE workshop_material_count_lines SET fill_level = 'EMPTY' WHERE count_id = ? AND color_id IS NULL",
                firstCount);
        when(permissions.has("goods:cost:view")).thenReturn(false);
        assertThat(secondOpening()).isEqualTo("ESTIMATED");
        assertThat(reports.binUsage(bin, null, null)).allSatisfy(row -> {
            assertThat(row.currentValue()).isNull(); assertThat(row.unitCost()).isNull();
            assertThat(row.valueAtClose()).isNull();
        });
        assertThat(reports.productUsage(bin, null, null)).allSatisfy(row -> {
            assertThat(row.currentValue()).isNull(); assertThat(row.getCurrentValueExact()).isNull();
            assertThat(row.unitMaterialCost()).isNull();
        });
    }

    @Test void newMaterialHasNoOpeningBalanceOnlyWhenThePreviousCountWasSubmitted() {
        db.update("DELETE FROM workshop_material_period_lines WHERE period_id = ? AND color_id IS NULL", first);
        db.update("DELETE FROM workshop_material_count_lines WHERE count_id = ? AND color_id IS NULL", firstCount);
        assertThat(secondOpening()).isEqualTo("NO_BALANCE");
        db.update("UPDATE workshop_material_counts SET status = 'DRAFT' WHERE id = ?", firstCount);
        assertThat(secondOpening()).isEqualTo("UNKNOWN");
    }

    @Test void materialUnitConversionUsesTheGovernedMassCodeAndNeverGuessesByItsName() {
        var kilograms = reports.productUsage(bin, null, null).getFirst();
        assertThat(kilograms.materialUnitName()).isEqualTo("车间称量单位");
        assertThat(kilograms.materialUnitKgFactor()).isEqualByComparingTo("1");
        db.update("UPDATE unit_measurement_profiles SET mass_unit_code = 'G'");
        var grams = reports.productUsage(bin, null, null).getFirst();
        assertThat(grams.materialUnitKgFactor()).isEqualByComparingTo("0.001");
        assertThat(grams.unitWeight()).isEqualByComparingTo(kilograms.unitWeight());
        db.update("UPDATE unit_measurement_profiles SET mass_unit_code = NULL");
        db.update("UPDATE units SET name = 'kg'");
        assertThat(reports.productUsage(bin, null, null).getFirst().materialUnitKgFactor()).isNull();
    }

    @Test void approvedOpeningIsASeparateSourceAndApprovedAdjustmentsAreNotTransferReceipts() {
        db.update("INSERT INTO workshop_material_count_adjustment_postings(period_id,goods_id,color_id,kind) VALUES(?,?,NULL,'OPENING')", first, goods);
        db.update("UPDATE v_workshop_material_period_report SET adjustment_qty=7 WHERE period_id=?", first);
        var row = reports.binUsage(bin, null, null).stream().filter(r -> r.periodNo()==1 && r.colorId()==null).findFirst().orElseThrow();
        assertThat(row.openingCountBasis()).isEqualTo("APPROVED_OPENING");
        assertThat(row.adjustmentQty()).isEqualByComparingTo("7");
        assertThat(row.transferInQty()).isEqualByComparingTo("100");
        assertThat(reports.productUsage(bin, null, null).stream().filter(r -> r.periodNo()==1 && r.materialColorId()==null)
                .findFirst().orElseThrow().openingCountBasis()).isEqualTo("APPROVED_OPENING");
    }

    private String secondOpening() {
        return reports.binUsage(bin, null, null).stream().filter(r -> r.periodNo() == 2 && r.colorId() == null)
                .findFirst().orElseThrow().openingCountBasis();
    }
    private void count(UUID id, UUID period, String status) {
        db.update("INSERT INTO workshop_material_counts(id,period_id,status) VALUES(?, ?, ?)", id, period, status);
    }
    private void line(UUID count, UUID lineColor, String kind, String fill) {
        db.update("INSERT INTO workshop_material_count_lines(count_id,goods_id,color_id,line_kind,fill_level) VALUES(?, ?, ?, ?, ?)", count, goods, lineColor, kind, fill);
    }
    private void report(UUID period, int no, UUID lineColor) {
        db.update("INSERT INTO workshop_material_period_lines(period_id, goods_id, color_id) VALUES (?, ?, ?)",
                period, goods, lineColor);
        db.update("""
                INSERT INTO v_workshop_material_period_report(bin_warehouse_id, period_id, period_no, goods_id, color_id, unit_id)
                VALUES (?, ?, ?, ?, ?, ?)
                """, bin, period, no, goods, lineColor, materialUnit);
    }
}
