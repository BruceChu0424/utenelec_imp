package com.uten.imp.features.warehouse.materialbin.report;

import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPermissions;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialScope;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.LocalDate;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

/** 真实 PostgreSQL 查询回归；只搭建只读投影所需的表形状，不执行库存写命令或全链迁移。 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopMaterialReportCountBasisPostgresTest {
    private static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");
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
                CREATE TABLE workshop_material_settings(periodic_bin_warehouse_id uuid, workshop_department_id uuid);
                CREATE TABLE workshop_material_periods(id uuid PRIMARY KEY, bin_warehouse_id uuid, period_no int);
                CREATE TABLE workshop_material_counts(id uuid PRIMARY KEY, period_id uuid, status text);
                CREATE TABLE workshop_material_count_lines(count_id uuid, goods_id uuid, color_id uuid,
                    line_kind text, fill_level text);
                CREATE TABLE workshop_material_period_lines(id uuid DEFAULT gen_random_uuid(), period_id uuid,
                    goods_id uuid, color_id uuid);
                CREATE TABLE workshop_material_count_adjustment_postings(period_id uuid, goods_id uuid, color_id uuid, kind text);
                CREATE TABLE goods(id uuid PRIMARY KEY, code text, name text);
                CREATE TABLE colors(id uuid PRIMARY KEY, name text);
                CREATE TABLE units(id uuid PRIMARY KEY, name text);
                CREATE TABLE unit_measurement_profiles(unit_id uuid PRIMARY KEY, measurement_dimension text, mass_unit_code text);
                CREATE TABLE v_workshop_material_period_report(
                    bin_warehouse_id uuid, period_id uuid, period_no int, start_date date DEFAULT '2026-09-01',
                    end_date date DEFAULT '2026-09-30', period_status text DEFAULT 'CLOSED',
                    period_line_id uuid DEFAULT gen_random_uuid(), goods_id uuid, color_id uuid, unit_id uuid,
                    cost_basis text DEFAULT 'OWN', opening_qty numeric DEFAULT 20, transfer_in_qty numeric DEFAULT 100,
                    return_qty numeric DEFAULT 0, other_issue_qty numeric DEFAULT 0, closing_qty numeric DEFAULT 30,
                    actual_qty numeric DEFAULT 90, theory_qty numeric DEFAULT 80, allocation_basis_qty numeric,
                    diff_qty numeric DEFAULT 10, waste_rate numeric DEFAULT 0.125, outcome text DEFAULT 'ALLOCATED',
                    flags text[] DEFAULT '{}', consumed_qty numeric DEFAULT 90, loss_qty numeric DEFAULT 0,
                    close_no int DEFAULT 1, closed_at timestamptz DEFAULT now(), current_value numeric DEFAULT 180,
                    value_at_close numeric DEFAULT 180, adjustment_qty numeric DEFAULT 0);
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
        // 使用当前权威换算函数，不在夹具中复制一套因子。
        try (var resource = getClass().getResourceAsStream("/db/migration/V743__warehouse_weight_ledger_and_learning.sql")) {
            String migration = new String(resource.readAllBytes(), StandardCharsets.UTF_8);
            int start = migration.indexOf("CREATE FUNCTION fn_weight_unit_kg_factor(");
            db.execute(migration.substring(start, migration.indexOf("$$;", start) + 3));
        }
        db.update("INSERT INTO workshop_material_settings VALUES (?, ?)", bin, workshop);
        db.update("INSERT INTO goods VALUES (?, 'PP', '颗粒'), (?, 'P1', '外壳')", goods, product);
        db.update("INSERT INTO product_reference VALUES (?)", product);
        db.update("INSERT INTO colors VALUES (?, '黑')", color);
        db.update("INSERT INTO units VALUES (?, '车间称量单位')", materialUnit);
        db.update("INSERT INTO unit_measurement_profiles VALUES (?, 'MASS', 'KG')", materialUnit);
        db.update("INSERT INTO workshop_material_periods VALUES (?, ?, 1), (?, ?, 2)", first, bin, second, bin);
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
        reports = new WorkshopMaterialReportQueryService(named, scope, permissions);
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
        db.update("INSERT INTO workshop_material_periods VALUES (?, ?, 1)", period, otherBin);
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
        db.update("INSERT INTO workshop_material_count_adjustment_postings VALUES (?,?,NULL,'OPENING')", first, goods);
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
        db.update("INSERT INTO workshop_material_counts VALUES (?, ?, ?)", id, period, status);
    }
    private void line(UUID count, UUID lineColor, String kind, String fill) {
        db.update("INSERT INTO workshop_material_count_lines VALUES (?, ?, ?, ?, ?)", count, goods, lineColor, kind, fill);
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
