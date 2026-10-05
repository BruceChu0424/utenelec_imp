package com.uten.imp.features.production.directtransfer;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * V736/ADR-127: every reason code of the single direct-transfer eligibility rule, on the
 * real migrated schema. Rows are seeded with triggers off (only the read functions and the
 * assert are under test here); the insert-time guard path is covered by the business-chain
 * end-to-end tests.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopDirectTargetReasonPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static SingleConnectionDataSource dataSource;
    private static JdbcTemplate jdbc;

    private static final UUID W1 = UUID.randomUUID(), W2 = UUID.randomUUID();
    private static final UUID CHILD = UUID.randomUUID(), OTHER = UUID.randomUUID(), TOP = UUID.randomUUID();
    private static final UUID LEAF = UUID.randomUUID(), SUBCONTRACTED = UUID.randomUUID();
    private static final UUID WAREHOUSE = UUID.randomUUID(), UNIT = UUID.randomUUID();
    private static int sequence;

    // Producing work orders.
    private static UUID source, sourcePlanItem, topSource, leafSource, subcontractSource, loneSubcontractSource;
    // Receiving demands of CHILD, one per reason.
    private static UUID later, earlier, otherWorkshop, subcontractDemand, buyDemand, unrelated, stopped,
            cancelledPackage, started, released, fulfilled, shareUsedUp, selfDemand, otherGoods, aggregateDemand;
    // Same-workshop, same-goods demands that are NOT linked to the producing work order (other analysis,
    // or no sub-plan link / peg): they must never be listed nor become the red reason.
    private static UUID unrelatedBuy, unrelatedSubcontract, subcontractUnrelated;
    private static List<UUID> topUnrelated, leafUnrelated;

    @BeforeAll
    static void seed() {
        POSTGRES.start();
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load().migrate();
        dataSource = new SingleConnectionDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword(), true);
        jdbc = new JdbcTemplate(dataSource);
        for (String table : List.of("departments", "goods", "production_plans", "production_planning_packages",
                "production_execution_segments", "production_material_demands", "subplan_links",
                "production_material_supply_pegs", "production_material_analyses",
                "production_material_analysis_items", "preplan_aggregate_batches", "warehouses", "workshop_bins")) {
            jdbc.execute("ALTER TABLE " + table + " DISABLE TRIGGER ALL");
        }
        jdbc.update("INSERT INTO departments(id,code,name,level) VALUES (?,'WS_T736_A','一车间','二级班组'),"
                + "(?,'WS_T736_B','二车间','二级班组')", W1, W2);
        // ADR-147 (V802): 直送只送已开通内料仓的车间; 两个车间都已开通 (没开通的情形见专门的用例)。
        for (UUID workshop : List.of(W1, W2)) {
            UUID bin = UUID.randomUUID();
            jdbc.update("""
                    INSERT INTO warehouses(id,code,name,status,is_accountable,is_line_side,workshop_department_id)
                    VALUES (?,?,?,'使用',TRUE,TRUE,?)""", bin, "LS-T736-" + bin.toString().substring(0, 6),
                    "内料仓-" + bin.toString().substring(0, 6), workshop);
            jdbc.update("INSERT INTO workshop_bins(workshop_department_id,bin_warehouse_id) VALUES (?,?)", workshop, bin);
        }
        goods(CHILD, "HVT001");
        goods(OTHER, "HVT999");
        goods(TOP, "HVTP01");
        goods(LEAF, "HVT002");
        goods(SUBCONTRACTED, "HVZJ12");

        UUID sourcePlan = plan(null, null);
        sourcePlanItem = UUID.randomUUID();
        source = segment(sourcePlan, sourcePlanItem, CHILD, W1, "IN_PROGRESS", false);
        selfDemand = demand(source, CHILD, "MAKE", "OPEN", "10", null);

        later = linkedReceiver(sourcePlan, W1, "WAITING", "MAKE", "OPEN", "100", LocalDate.of(2026, 10, 5));
        earlier = linkedReceiver(sourcePlan, W1, "READY", "MAKE", "OPEN", "50", LocalDate.of(2026, 10, 1));
        otherWorkshop = linkedReceiver(sourcePlan, W2, "WAITING", "MAKE", "OPEN", "10", null);
        subcontractDemand = linkedReceiver(sourcePlan, W1, "WAITING", "SUBCONTRACT", "OPEN", "10", null);
        buyDemand = linkedReceiver(sourcePlan, W1, "WAITING", "BUY", "OPEN", "10", null);
        stopped = linkedReceiver(sourcePlan, W1, "WAITING", "MAKE", "OPEN", "10", null);
        jdbc.update("UPDATE production_plans SET is_stopped=TRUE WHERE id=(SELECT plan_id FROM production_material_demands WHERE id=?)", stopped);
        cancelledPackage = linkedReceiver(sourcePlan, W1, "WAITING", "MAKE", "OPEN", "10", null);
        jdbc.update("UPDATE production_planning_packages SET status='CANCELLED' WHERE id=(SELECT package_id FROM production_material_demands WHERE id=?)", cancelledPackage);
        started = linkedReceiver(sourcePlan, W1, "IN_PROGRESS", "MAKE", "OPEN", "10", null);
        released = linkedReceiver(sourcePlan, W1, "WAITING", "MAKE", "RELEASED", "10", null);
        fulfilled = linkedReceiver(sourcePlan, W1, "WAITING", "MAKE", "FULFILLED", "10", null);
        shareUsedUp = linkedReceiver(sourcePlan, W1, "WAITING", "MAKE", "OPEN", "10", null);
        // A released peg from this source keeps the parent-child relation but leaves no share.
        jdbc.update("""
                INSERT INTO production_material_supply_pegs(demand_id,supply_type,supply_item_id,allocated_qty,
                    released_qty,status,idempotency_key) VALUES (?,'PRODUCTION_PLAN_ITEM',?,10,10,'RELEASED',?)
                """, shareUsedUp, sourcePlanItem, "peg-" + UUID.randomUUID());
        UUID unrelatedPlan = plan(null, null);
        unrelated = demand(segment(unrelatedPlan, UUID.randomUUID(), TOP, W1, "WAITING", false),
                CHILD, "MAKE", "OPEN", "10", null);
        otherGoods = demand(segment(plan(null, null), UUID.randomUUID(), TOP, W1, "WAITING", false),
                OTHER, "MAKE", "OPEN", "10", null);
        // Not linked to the source: a plain plan without sub-plan link or peg, and a plan of another analysis.
        UUID otherAnalysis = analysis();
        unrelatedBuy = unlinkedDemand(null, CHILD, "BUY");
        unrelatedSubcontract = unlinkedDemand(otherAnalysis, CHILD, "SUBCONTRACT");

        // A top-level product has no next process; a sub-plan whose parent has no work order yet waits.
        // Open same-workshop demands for the same goods from unrelated plans must not hide either reason.
        topSource = segment(plan(null, null), UUID.randomUUID(), TOP, W1, "IN_PROGRESS", false);
        topUnrelated = List.of(unlinkedDemand(otherAnalysis, TOP, "MAKE"),
                unlinkedDemand(otherAnalysis, TOP, "SUBCONTRACT"), unlinkedDemand(null, TOP, "BUY"));
        UUID leafPlan = plan(null, null);
        leafSource = segment(leafPlan, UUID.randomUUID(), LEAF, W1, "IN_PROGRESS", false);
        jdbc.update("INSERT INTO subplan_links(plan_id,subplan_id) VALUES (?,?)", plan(null, null), leafPlan);
        leafUnrelated = List.of(unlinkedDemand(otherAnalysis, LEAF, "MAKE"), unlinkedDemand(null, LEAF, "BUY"));

        // HV5ZJ012 shape: a shared (aggregate) batch confirmed as subcontract pre-make feeding a same-workshop parent.
        UUID analysis = analysis();
        subcontractSource = subcontractBatchSource(analysis);
        UUID parentItem = analysisItem(analysis, "OTHER", TOP, "1");
        // The parent's demand itself says MAKE: the producing-side marker alone must name the route.
        aggregateDemand = demand(segment(plan(analysis, parentItem), UUID.randomUUID(), TOP, W1, "WAITING", false),
                SUBCONTRACTED, "MAKE", "OPEN", "1000", null);
        // Another analysis' demand for the same subcontracted goods in the same workshop is not its parent.
        subcontractUnrelated = unlinkedDemand(otherAnalysis, SUBCONTRACTED, "MAKE");
        // A subcontract pre-make whose own analysis has no parent work order: only the same-goods demands of
        // other analyses exist in its workshop.
        loneSubcontractSource = subcontractBatchSource(analysis());
    }

    @AfterAll
    static void stop() {
        if (dataSource != null) dataSource.destroy();
        POSTGRES.stop();
    }

    @Test
    void structureCodesAreEvaluatedInOneFixedOrder() {
        assertThat(code(source, later)).isNull();
        assertThat(code(UUID.randomUUID(), later)).isEqualTo("SOURCE_INVALID");
        assertThat(code(source, UUID.randomUUID())).isEqualTo("TARGET_INVALID");
        assertThat(code(source, selfDemand)).isEqualTo("SELF");
        assertThat(code(source, otherGoods)).isEqualTo("GOODS_MISMATCH");
        assertThat(code(source, subcontractDemand)).isEqualTo("SUBCONTRACT_ROUTE");
        assertThat(code(subcontractSource, aggregateDemand)).isEqualTo("SUBCONTRACT_ROUTE");
        assertThat(code(source, buyDemand)).isEqualTo("BUY_ROUTE");
        assertThat(code(source, unrelated)).isEqualTo("NO_PARENT_RELATION");
        assertThat(code(source, otherWorkshop)).isEqualTo("DIFFERENT_WORKSHOP");
        // Routes are named only for demands linked to the source (same analysis / sub-plan link / live peg):
        // an unlinked subcontract or bought demand is simply not supplied by this work order.
        assertThat(code(source, unrelatedBuy)).isEqualTo("NO_PARENT_RELATION");
        assertThat(code(source, unrelatedSubcontract)).isEqualTo("NO_PARENT_RELATION");
        assertThat(code(subcontractSource, subcontractUnrelated)).isEqualTo("NO_PARENT_RELATION");
        assertThat(code(loneSubcontractSource, aggregateDemand)).isEqualTo("NO_PARENT_RELATION");
    }

    @Test
    void historicalWrappersKeepTheirMeaning() {
        assertThat(allows("fn_workshop_direct_relationship_allows", source, later)).isTrue();
        assertThat(allows("fn_workshop_direct_relationship_allows", source, otherWorkshop)).isFalse();
        // Historical responsibility ignores only the current workshop boundary.
        assertThat(allows("fn_workshop_direct_responsibility_allows", source, otherWorkshop)).isTrue();
        assertThat(allows("fn_workshop_direct_responsibility_allows", source, subcontractDemand)).isFalse();
        assertThat(allows("fn_workshop_direct_responsibility_allows", subcontractSource, aggregateDemand)).isFalse();
        assertThat(allows("fn_workshop_direct_responsibility_allows", source, unrelated)).isFalse();
        for (UUID notLinked : List.of(unrelatedBuy, unrelatedSubcontract)) {
            assertThat(allows("fn_workshop_direct_relationship_allows", source, notLinked)).isFalse();
            assertThat(allows("fn_workshop_direct_responsibility_allows", source, notLinked)).isFalse();
        }
        assertThat(allows("fn_workshop_direct_responsibility_allows", subcontractSource, subcontractUnrelated))
                .isFalse();
    }

    @Test
    void validateModeNamesStateAndQuantityReasons() {
        assertThat(single(source, stopped, null)).containsEntry("reason_code", "PLAN_NOT_ACTIVE")
                .containsEntry("receiver_open", false);
        assertThat((String) single(source, stopped, null).get("reason_text")).contains("已暂停");
        assertThat(single(source, cancelledPackage, null)).containsEntry("reason_code", "PACKAGE_NOT_CONFIRMED");
        assertThat(single(source, started, null)).containsEntry("reason_code", "RECEIVER_STATUS");
        assertThat((String) single(source, started, null).get("reason_text")).contains("已按齐套开工");
        assertThat(single(source, released, null)).containsEntry("reason_code", "DEMAND_CLOSED");
        // Quantity-only reasons keep the receiver open: saving routes the rest to the warehouse.
        assertThat(single(source, fulfilled, null)).containsEntry("reason_code", "DEMAND_ALREADY_COVERED")
                .containsEntry("receiver_open", true).containsEntry("eligible", false);
        assertThat(single(source, shareUsedUp, null)).containsEntry("reason_code", "SOURCE_SHARE_USED_UP")
                .containsEntry("receiver_open", true);
        var exceeded = single(source, earlier, new BigDecimal("60"));
        assertThat(exceeded).containsEntry("reason_code", "QTY_EXCEEDS_REMAINING").containsEntry("eligible", false);
        assertThat((String) exceeded.get("reason_text")).contains("60").contains("50");
        var fits = single(source, earlier, new BigDecimal("50"));
        assertThat(fits).containsEntry("eligible", true).containsEntry("receiver_open", true);
        assertThat(fits.get("reason_code")).isNull();
        assertThat((BigDecimal) fits.get("remaining_qty")).isEqualByComparingTo("50");
        assertThat((BigDecimal) fits.get("receiver_shortfall_qty")).isEqualByComparingTo("50");
        assertThat((String) single(source, otherWorkshop, null).get("reason_text"))
                .isEqualTo("上层工单 " + segmentCode(otherWorkshop) + " 在二车间，跨车间必须送入仓库");
        for (var row : List.of(single(source, stopped, null), single(source, otherWorkshop, null),
                single(subcontractSource, aggregateDemand, null))) {
            assertThat((String) row.get("reason_text")).doesNotContain("（").doesNotContain("）")
                    .doesNotContainPattern("[A-Z]{3,}_[A-Z]");
        }
    }

    @Test
    void listModeReturnsReceiversUrgentFirstWithTheirReasons() {
        var rows = jdbc.queryForList("SELECT * FROM fn_workshop_direct_targets(?) ORDER BY sort_order", source);
        assertThat(rows).filteredOn(row -> Boolean.TRUE.equals(row.get("eligible")))
                .extracting(row -> row.get("demand_id")).containsExactly(earlier, later);
        assertThat(rows).extracting(row -> row.get("demand_id"))
                .contains(otherWorkshop, subcontractDemand, buyDemand, stopped, cancelledPackage,
                        started, released, fulfilled, shareUsedUp)
                .doesNotContain(selfDemand, otherGoods, unrelated, unrelatedBuy, unrelatedSubcontract);
        // Only structural parents are listed: rows without a parent relation are not receivers at all.
        assertThat(rows).extracting(row -> row.get("reason_code")).doesNotContain("NO_PARENT_RELATION");
        assertThat(rows).allSatisfy(row -> assertThat(row.get("reason_rank")).isNotNull());

        var subcontract = jdbc.queryForList("SELECT * FROM fn_workshop_direct_targets(?)", subcontractSource);
        assertThat(subcontract).singleElement().satisfies(row -> {
            assertThat(row).containsEntry("demand_id", aggregateDemand).containsEntry("eligible", false)
                    .containsEntry("reason_code", "SUBCONTRACT_ROUTE");
            assertThat((String) row.get("reason_text"))
                    .isEqualTo("HVZJ12 是委外件：做好后先送入仓库，发外加工回来后，上层工单再从仓库领料");
        });

        assertThat(jdbc.queryForList("SELECT * FROM fn_workshop_direct_targets(?)", topSource)).singleElement()
                .satisfies(row -> assertThat(row).containsEntry("reason_code", "NOT_A_COMPONENT")
                        .containsEntry("eligible", false).containsEntry("demand_id", null));
        assertThat(jdbc.queryForList("SELECT * FROM fn_workshop_direct_targets(?)", leafSource)).singleElement()
                .satisfies(row -> assertThat(row).containsEntry("reason_code", "NO_RECEIVER_ISSUED_YET"));
        assertThat(jdbc.queryForList("SELECT * FROM fn_workshop_direct_targets(?)", UUID.randomUUID()))
                .singleElement().satisfies(row -> assertThat(row).containsEntry("reason_code", "SOURCE_INVALID"));
    }

    @Test
    void unrelatedSameGoodsOrdersNeverMaskTheTrueReason() {
        // 用户要红字「无法转到下一道工序：<原因>」说真正的原因: 同车间同货品、但属于别的物料分析或没有
        // 子计划/挂钩的工单，既不能挡住哨兵，也不能以委外/采购的名义变成原因或出现在不能收的上层里。
        for (UUID notLinked : topUnrelated) assertThat(code(topSource, notLinked)).isEqualTo("NO_PARENT_RELATION");
        for (UUID notLinked : leafUnrelated) assertThat(code(leafSource, notLinked)).isEqualTo("NO_PARENT_RELATION");
        assertThat(closestReason(topSource)).isEqualTo("NOT_A_COMPONENT");
        assertThat(closestReason(leafSource)).isEqualTo("NO_RECEIVER_ISSUED_YET");

        var listed = jdbc.queryForList("SELECT demand_id FROM fn_workshop_direct_targets(?)", UUID.class, source);
        assertThat(listed).doesNotContain(unrelated, unrelatedBuy, unrelatedSubcontract);
        assertThat(single(source, unrelatedSubcontract, null)).containsEntry("reason_code", "NO_PARENT_RELATION")
                .containsEntry("eligible", false).containsEntry("receiver_open", false);

        // A subcontract pre-make still says so: with its linked parent listed, and as the sentinel when the only
        // same-goods orders in its workshop belong to other analyses.
        assertThat(closestReason(subcontractSource)).isEqualTo("SUBCONTRACT_ROUTE");
        assertThat(jdbc.queryForList("SELECT demand_id FROM fn_workshop_direct_targets(?)", UUID.class,
                subcontractSource)).containsExactly(aggregateDemand);
        assertThat(jdbc.queryForList("SELECT * FROM fn_workshop_direct_targets(?)", loneSubcontractSource))
                .singleElement().satisfies(row -> {
                    assertThat(row).containsEntry("demand_id", null).containsEntry("eligible", false)
                            .containsEntry("reason_code", "SUBCONTRACT_ROUTE");
                    assertThat((String) row.get("reason_text"))
                            .isEqualTo("HVZJ12 是委外件：做好后先送入仓库，发外加工回来后，上层工单再从仓库领料");
                });
    }

    @Test
    void warehouseRouteReasonsShareTheSingleTextAndOnlyWarehousePiecesCarryThem() {
        // ADR-127 第二步：送入仓库的报工明细记原因码，文案仍只有 fn_workshop_direct_reason_text 一份。
        assertThat(text("USER_CHOSEN", null)).isEqualTo("报工时选择送入仓库");
        assertThat(text("RECEIVERS_FULL", null)).isEqualTo("能直送的上层工单都已分满，其余送入仓库");
        assertThat(text("PUBLIC_SHARE", null)).isEqualTo("计划内的公共备货部分，统一送入仓库");
        assertThat(text("ACTUAL_SURPLUS", null)).isEqualTo("超出计划的实际产量，统一送入仓库");
        // 详情回看时已没有当时的接收工单与车间：仍是一句完整的话。
        assertThat(text("DIFFERENT_WORKSHOP", null)).isEqualTo("上层工单在其它车间，跨车间必须送入仓库");
        assertThat(text("DEMAND_ALREADY_COVERED", "HVT001")).isEqualTo("上层工单的 HVT001 已经备齐 (仓库备料或其它直送)");
        assertThat(text("RECEIVER_STATUS", null)).isEqualTo("上层工单已开工或已结束，不再接收直送");
        assertThat(text("SUBCONTRACT_ROUTE", "HVZJ12"))
                .isEqualTo("HVZJ12 是委外件：做好后先送入仓库，发外加工回来后，上层工单再从仓库领料");
        // 数量超出时点名是哪个上层工单(一行分给多个工单时才知道是哪一条)。
        assertThat(single(source, earlier, null)).containsEntry("receiver_label", "上层工单 " + segmentCode(earlier));
        assertThat((String) single(source, earlier, new BigDecimal("60")).get("reason_text"))
                .startsWith("转给上层工单 " + segmentCode(earlier) + " 的本次基本数量 60 超过最多可送 50");
        String check = jdbc.queryForObject("""
                SELECT pg_get_constraintdef(oid) FROM pg_constraint
                WHERE conname='production_daily_report_items_output_route_reason_chk'""", String.class);
        assertThat(check).contains("WAREHOUSE").contains("USER_CHOSEN").contains("SUBCONTRACT_ROUTE")
                .contains("WORKSHOP_BIN_NOT_OPEN");
    }

    @Test
    void receivingWorkshopWithoutAnOpenedBinCannotReceiveAndSaysSo() {
        // ADR-147: 不再第一次直送时自动建仓; 收料车间没开通内料仓时上层工单都不能收, 原因说清楚怎么办,
        // 报工这部分送入仓库 (同一原因码记进送仓原因)。
        UUID bin = jdbc.queryForObject("SELECT bin_warehouse_id FROM workshop_bins WHERE workshop_department_id=?",
                UUID.class, W1);
        jdbc.update("DELETE FROM workshop_bins WHERE workshop_department_id=?", W1);
        try {
            var row = single(source, earlier, null);
            assertThat(row).containsEntry("reason_code", "WORKSHOP_BIN_NOT_OPEN").containsEntry("eligible", false)
                    .containsEntry("receiver_open", false);
            assertThat((String) row.get("reason_text"))
                    .isEqualTo("一车间还没开通内料仓，请仓库在「车间内料仓」开通后再直送，这次先送入仓库");
            var listed = jdbc.queryForList("SELECT * FROM fn_workshop_direct_targets(?)", source);
            assertThat(listed).noneSatisfy(target -> assertThat(target.get("eligible")).isEqualTo(true));
            assertThat(closestReason(source)).isEqualTo("WORKSHOP_BIN_NOT_OPEN");
            // 结构原因在前: 跨车间的上层仍说跨车间。
            assertThat(single(source, otherWorkshop, null)).containsEntry("reason_code", "DIFFERENT_WORKSHOP");
            assertThatThrownBy(() -> jdbc.queryForList("SELECT fn_assert_workshop_direct_target(?,?,?)",
                    source, earlier, new BigDecimal("10")))
                    .rootCause().isInstanceOfSatisfying(PSQLException.class, error ->
                            assertThat(error.getServerErrorMessage().getHint()).isEqualTo("WORKSHOP_BIN_NOT_OPEN"));
        } finally {
            jdbc.update("INSERT INTO workshop_bins(workshop_department_id,bin_warehouse_id) VALUES (?,?)", W1, bin);
        }
        assertThat(single(source, earlier, null)).containsEntry("eligible", true);
        // 报工详情回看时没有车间名: 仍是一句完整的话。
        assertThat(text("WORKSHOP_BIN_NOT_OPEN", null))
                .isEqualTo("收料车间还没开通内料仓，请仓库在「车间内料仓」开通后再直送，这次先送入仓库");
    }

    @Test
    void assertRaisesThePlainReasonWithTheCodeAsHint() {
        jdbc.queryForList("SELECT fn_assert_workshop_direct_target(?,?,?)", source, earlier, new BigDecimal("10"));
        assertThatThrownBy(() -> jdbc.queryForList("SELECT fn_assert_workshop_direct_target(?,?,?)",
                subcontractSource, aggregateDemand, BigDecimal.ONE))
                .rootCause().isInstanceOfSatisfying(PSQLException.class, error -> {
                    assertThat(error.getSQLState()).isEqualTo("23514");
                    assertThat(error.getServerErrorMessage().getMessage())
                            .isEqualTo("无法转到下一道工序：HVZJ12 是委外件：做好后先送入仓库，发外加工回来后，上层工单再从仓库领料");
                    assertThat(error.getServerErrorMessage().getHint()).isEqualTo("SUBCONTRACT_ROUTE");
                    assertThat(error.getServerErrorMessage().getConstraint()).isEqualTo("workshop_direct_target_guard");
                });
    }

    @Test
    void continuousSupplyEligibilityReusesTheSameRelation() {
        assertThat(allows("fn_demand_direct_supply_eligible", later)).isTrue();
        // V605 counted any same-workshop work order of the same goods; without a parent relation it no longer does.
        assertThat(allows("fn_demand_direct_supply_eligible", unrelated)).isFalse();
        assertThat(allows("fn_demand_direct_supply_eligible", subcontractDemand)).isFalse();
    }

    private static String code(UUID producing, UUID demand) {
        return jdbc.queryForObject("SELECT fn_workshop_direct_relation_code(?,?)", String.class, producing, demand);
    }

    /** The reason the candidates endpoint shows when nothing is eligible: the closest (lowest-rank) one. */
    private static String closestReason(UUID producing) {
        return jdbc.queryForObject("""
                SELECT reason_code FROM fn_workshop_direct_targets(?) WHERE NOT eligible
                ORDER BY reason_rank, sort_order LIMIT 1""", String.class, producing);
    }

    private static boolean allows(String function, Object... args) {
        String marks = String.join(",", java.util.Collections.nCopies(args.length, "?"));
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT " + function + "(" + marks + ")", Boolean.class, args));
    }

    private static Map<String, Object> single(UUID producing, UUID demand, BigDecimal qty) {
        return jdbc.queryForMap("SELECT * FROM fn_workshop_direct_targets(?,?,?)", producing, demand, qty);
    }

    private static String text(String code, String goods) {
        return jdbc.queryForObject("SELECT fn_workshop_direct_reason_text(?,NULL,?,NULL,NULL,NULL,NULL)",
                String.class, code, goods);
    }

    private static String segmentCode(UUID demand) {
        return jdbc.queryForObject("""
                SELECT segment.segment_code FROM production_material_demands demand
                JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id WHERE demand.id=?
                """, String.class, demand);
    }

    private static UUID linkedReceiver(UUID sourcePlan, UUID workshop, String segmentStatus, String route,
                                       String demandStatus, String qty, LocalDate needDate) {
        UUID receivingPlan = plan(null, null);
        jdbc.update("INSERT INTO subplan_links(plan_id,subplan_id) VALUES (?,?)", receivingPlan, sourcePlan);
        UUID receiving = segment(receivingPlan, UUID.randomUUID(), TOP, workshop, segmentStatus, false);
        return demand(receiving, CHILD, route, demandStatus, qty, needDate);
    }

    /** An open same-workshop demand for {@code goods} on a plan with no sub-plan link or peg to any source. */
    private static UUID unlinkedDemand(UUID analysis, UUID goods, String route) {
        return demand(segment(plan(analysis, null), UUID.randomUUID(), OTHER, W1, "WAITING", false),
                goods, route, "OPEN", "10", null);
    }

    /** A work order making SUBCONTRACTED from a shared batch confirmed as subcontract pre-make. */
    private static UUID subcontractBatchSource(UUID analysis) {
        UUID anchor = analysisItem(analysis, "AGGREGATE_MAKE", SUBCONTRACTED, "0");
        UUID aggregatePlan = plan(analysis, anchor);
        jdbc.update("""
                INSERT INTO preplan_aggregate_batches(analysis_id,action_id,anchor_analysis_item_id,plan_id,route,
                    compatibility_key,configuration_snapshot,created_by) VALUES (?,?,?,?,'SUBCONTRACT',?,'{}'::jsonb,?)
                """, analysis, UUID.randomUUID(), anchor, aggregatePlan, hex(), UUID.randomUUID());
        return segment(aggregatePlan, UUID.randomUUID(), SUBCONTRACTED, W1, "IN_PROGRESS", false);
    }

    private static UUID analysis() {
        UUID analysis = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_analyses(id,fingerprint,initial_idempotency_key,maker_id,
                    warehouse_id,participating_warehouse_ids) VALUES (?,?,?,?,?,ARRAY[?]::uuid[])
                """, analysis, hex(), "analysis-" + analysis, UUID.randomUUID(), WAREHOUSE, WAREHOUSE);
        return analysis;
    }

    private static UUID plan(UUID analysis, UUID analysisItem) {
        UUID plan = UUID.randomUUID();
        UUID pack = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_plans(id,bill_no,bill_date,status,material_analysis_id,material_analysis_item_id)
                VALUES (?,?,CURRENT_DATE,1,?,?)
                """, plan, "SC736" + (++sequence), analysis, analysisItem);
        jdbc.update("""
                INSERT INTO production_planning_packages(id,plan_id,warehouse_id,idempotency_key,request_hash,
                    preview_fingerprint,status) VALUES (?,?,?,?,?,?,'CONFIRMED')
                """, pack, plan, WAREHOUSE, "package-" + pack, hex(), hex());
        return plan;
    }

    private static UUID segment(UUID plan, UUID planItem, UUID goods, UUID workshop, String status, boolean continuous) {
        UUID segment = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_execution_segments(id,package_id,plan_id,source_plan_item_id,segment_no,
                    segment_code,client_segment_key,product_goods_id,product_unit_id,product_unit_rate,planned_qty,
                    status,bom_fingerprint,idempotency_key,workshop_department_id,continuous_supply)
                SELECT ?,package.id,?,?,1,?,?,?,?,1,100,?,?,?,?,? FROM production_planning_packages package
                WHERE package.plan_id=?
                """, segment, plan, planItem, "ZX736" + String.format("%05d", ++sequence), "key-" + segment,
                goods, UNIT, status, hex(), "segment-" + segment, workshop, continuous, plan);
        return segment;
    }

    private static UUID demand(UUID segment, UUID goods, String route, String status, String qty, LocalDate needDate) {
        UUID demand = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_demands(id,package_id,plan_id,warehouse_id,goods_id,unit_id,
                    required_qty,supply_route,status,idempotency_key,execution_segment_id,source_plan_item_id,
                    per_product_qty,need_date)
                SELECT ?,segment.package_id,segment.plan_id,?,?,?,?,?,?,?,segment.id,segment.source_plan_item_id,1,?
                FROM production_execution_segments segment WHERE segment.id=?
                """, demand, WAREHOUSE, goods, UNIT, new BigDecimal(qty), route, status, "demand-" + demand,
                needDate, segment);
        return demand;
    }

    private static UUID analysisItem(UUID analysis, String type, UUID goods, String qty) {
        UUID item = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,unit_id,
                    requested_qty,source_ref,source_reason) VALUES (?,?,?,?,?,?,?,'测试来源')
                """, item, analysis, type, goods, UNIT, new BigDecimal(qty), "T736-" + (++sequence));
        return item;
    }

    private static void goods(UUID id, String code) {
        jdbc.update("INSERT INTO goods(id,code,name,code_sequence,unit_id) VALUES (?,?,?,?,?)",
                id, code, "测试货品" + code, 736000 + (++sequence), UNIT);
    }

    private static String hex() {
        byte[] bytes = new byte[32];
        new java.security.SecureRandom().nextBytes(bytes);
        return HexFormat.of().formatHex(bytes);
    }
}
