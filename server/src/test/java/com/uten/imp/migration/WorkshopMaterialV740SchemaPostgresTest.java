package com.uten.imp.migration;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * V740 车间整批领料与盘点计耗 (ADR-131) 的数据库层验收: 在真实迁移库上逐条验证新表守卫、提交时断言、
 * 锚点替换与数据迁移。
 *
 * <p>模板库先迁到 V738, 放入几个自动配置的线边仓 (验证 V740 改名), 再迁到头。之后在模板上关掉与本用例
 * 无关的旧业务触发器 (V740 自己的触发器保持开启), 每个用例克隆一份独立的库; 执行段、日报、需求等
 * 依赖长链路外键的夹具行在 replica 角色下直接写入, 被测动作一律在 origin 角色下走真实守卫。
 * 服务层与全链行为见各实现包的 PostgresTest 与 WorkshopMaterialFullChainEndToEndTest。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopMaterialV740SchemaPostgresTest {

    private static final PostgreSQLContainer<?> TEMPLATE =
            new PostgreSQLContainer<>("postgres:16-alpine").withDatabaseName("wm740_template");
    private static final AtomicInteger CLONES = new AtomicInteger();

    static final UUID ACTOR = id(0xA1);
    static final UUID OTHER_ACTOR = id(0xA2);
    static final UUID KG = id(0xB1);
    static final UUID PCS = id(0xB2);
    static final UUID MAIN_A = id(0xC1);
    static final UUID MAIN_B = id(0xC2);
    static final UUID LEAF = id(0xC3);
    static final UUID BIN = id(0xC4);
    static final UUID BIN_OTHER_MAIN = id(0xC5);
    static final UUID ASSEMBLY_BIN = id(0xC6);
    static final UUID NAME_CLASH = id(0xC7);
    static final UUID MANUAL_BIN = id(0xC8);
    static final UUID GRANULE = id(0xD1);
    static final UUID GRANULE_B = id(0xD2);
    static final UUID MASTERBATCH = id(0xD3);
    static final UUID INSERT_PART = id(0xD4);
    static final UUID P1 = id(0xE1);
    static final UUID P2 = id(0xE2);
    static final UUID P3 = id(0xE3);
    static final UUID P4 = id(0xE4);
    static final UUID P5 = id(0xE5);
    static final LocalDate GO_LIVE = LocalDate.of(2026, 9, 1);

    static UUID injection;
    static UUID assembly;
    static UUID esd;

    Connection db;
    private final AtomicInteger numbers = new AtomicInteger();

    record Issue(UUID requisition, UUID line, UUID document, UUID item, UUID binMovement, UUID posting) {
    }

    record Count(UUID count, UUID line, UUID posting) {
    }

    // -----------------------------------------------------------------
    // 模板库
    // -----------------------------------------------------------------

    @BeforeAll
    static void migrateWithLegacyLineSideWarehouses() throws Exception {
        TEMPLATE.start();
        flyway("738").migrate();
        try (Connection connection = template(); Statement statement = connection.createStatement()) {
            injection = department(connection, "WS_ZHUSU");
            assembly = department(connection, "WS_ZHUANG");
            esd = department(connection, "WS_ESD");
            statement.execute("SET session_replication_role = replica");
            try (PreparedStatement insert = connection.prepareStatement("""
                    INSERT INTO warehouses(id, code, name, remark, is_accountable, status, parent_id, is_line_side,
                                           workshop_department_id, auto_created, created_at)
                    VALUES (?, ?, ?, '线边仓', TRUE, '使用', ?, ?, ?, ?, now() - make_interval(days => ?))""")) {
                warehouse(insert, MAIN_A, "WM740A", "一号主仓", null, false, null, false, 30);
                warehouse(insert, MAIN_B, "WM740B", "二号主仓", null, false, null, false, 29);
                warehouse(insert, LEAF, "WM740L", "原料区", MAIN_A, false, null, false, 28);
                warehouse(insert, BIN, "WM740Z1", "注塑车间线边仓", MAIN_A, true, injection, true, 20);
                warehouse(insert, BIN_OTHER_MAIN, "WM740Z2", "注塑车间线边仓(二号主仓)", MAIN_B, true, injection, true, 10);
                warehouse(insert, ASSEMBLY_BIN, "WM740Q1", "装配车间线边仓", MAIN_A, true, assembly, true, 9);
                warehouse(insert, NAME_CLASH, "WM740Q2", "装配车间内料仓", MAIN_A, false, null, false, 8);
                warehouse(insert, MANUAL_BIN, "WM740E1", "ESD 手工料架", MAIN_A, true, esd, false, 7);
            }
        }
        // V740 改名按「车间 x 主仓」的老口径在多主仓数据上跑一遍 (lineSideRenamedOnlyDuplicatesSuffixed 核对)。
        flyway("740").migrate();
        // 之后的 V800 (ADR-145 单主仓) 与 V802 (ADR-147 一车间一个开通的内料仓) 要求存量先收敛:
        // 一号主仓定为 001、挂在二号主仓下的内料仓改挂到主仓下 (V800 只把普通仓改挂, 内料仓要人工处理)。
        try (Connection connection = template(); Statement statement = connection.createStatement()) {
            statement.execute("SET session_replication_role = replica");
            statement.execute("UPDATE warehouses SET code='001' WHERE id='" + MAIN_A + "'");
            statement.execute("UPDATE warehouses SET parent_id='" + MAIN_A + "' WHERE id='" + BIN_OTHER_MAIN + "'");
            statement.execute("SET session_replication_role = origin");
        }
        flyway(null).migrate();
        // V802 把从没用过的内料仓都软删了 (存量回填只保留有引用的); 本用例以注塑车间的 BIN 为已开通的内料仓,
        // 与开通命令同样在一个事务里: 恢复仓库行并写开通行 (提交时校验两者同生共死)。
        try (Connection connection = template()) {
            connection.setAutoCommit(false);
            try (PreparedStatement revive = connection.prepareStatement(
                    "UPDATE warehouses SET is_deleted=FALSE, deleted_at=NULL WHERE id=?");
                 PreparedStatement open = connection.prepareStatement(
                         "INSERT INTO workshop_bins(workshop_department_id, bin_warehouse_id) VALUES (?, ?)")) {
                revive.setObject(1, BIN);
                revive.executeUpdate();
                open.setObject(1, injection);
                open.setObject(2, BIN);
                open.executeUpdate();
            }
            connection.commit();
        }
        try (Connection connection = template(); Statement statement = connection.createStatement()) {
            // 与本用例无关的旧业务触发器在模板上关闭; V740 自己的触发器全部保持开启。
            for (String sql : List.of(
                    "ALTER TABLE production_execution_segments DISABLE TRIGGER USER",
                    "ALTER TABLE production_execution_segments ENABLE TRIGGER trg_workshop_material_start_gate",
                    "ALTER TABLE production_execution_segments ENABLE TRIGGER trg_workshop_material_start_gate_ins",
                    "ALTER TABLE production_execution_segments ENABLE TRIGGER trg_workshop_material_bind_on_start",
                    "ALTER TABLE production_execution_segments ENABLE TRIGGER trg_workshop_material_bind_on_start_ins",
                    "ALTER TABLE production_execution_segments ENABLE ALWAYS TRIGGER trg_guard_execution_segment_requirement_shape",
                    "ALTER TABLE production_execution_segments ENABLE TRIGGER trg_guard_execution_segment_requirement_shape_upd",
                    "ALTER TABLE production_material_demands DISABLE TRIGGER USER",
                    "ALTER TABLE production_material_demands ENABLE TRIGGER trg_guard_periodic_goods_demand",
                    "ALTER TABLE production_material_demands ENABLE TRIGGER trg_guard_periodic_goods_demand_upd",
                    "ALTER TABLE production_material_stock_events DISABLE TRIGGER USER",
                    "ALTER TABLE production_material_stock_postings DISABLE TRIGGER USER",
                    "ALTER TABLE production_material_settlement_events DISABLE TRIGGER USER",
                    "ALTER TABLE production_material_settlement_postings DISABLE TRIGGER USER",
                    "ALTER TABLE production_daily_reports DISABLE TRIGGER USER",
                    "ALTER TABLE production_daily_reports ENABLE TRIGGER trg_wm_report_date_lock_upd",
                    "ALTER TABLE production_daily_report_items DISABLE TRIGGER USER",
                    "ALTER TABLE production_daily_report_items ENABLE TRIGGER trg_wm_report_item_date_lock",
                    "ALTER TABLE production_daily_report_items ENABLE TRIGGER trg_wm_report_item_date_lock_upd",
                    "ALTER TABLE stock_documents DISABLE TRIGGER USER",
                    "ALTER TABLE stock_documents ENABLE TRIGGER trg_guard_wm_stock_document_reverse",
                    "ALTER TABLE stock_document_items DISABLE TRIGGER USER",
                    "ALTER TABLE stock_movements DISABLE TRIGGER USER",
                    "ALTER TABLE stock_movements ENABLE ALWAYS TRIGGER trg_workshop_direct_physical_provenance",
                    "ALTER TABLE stock_balances DISABLE TRIGGER USER",
                    "ALTER TABLE production_workshop_direct_transfer_items DISABLE TRIGGER USER",
                    "ALTER TABLE production_workshop_direct_transfer_items ENABLE TRIGGER trg_guard_periodic_goods_direct_transfer",
                    "ALTER TABLE stock_value_production_cost_inputs DISABLE TRIGGER USER",
                    "ALTER TABLE stock_value_production_cost_inputs ENABLE ALWAYS TRIGGER trg_periodic_material_cost_input",
                    "ALTER TABLE stock_value_production_cost_objects DISABLE TRIGGER USER",
                    "ALTER TABLE stock_value_production_cost_objects ENABLE ALWAYS TRIGGER trg_cost_business_refresh_source")) {
                statement.execute(sql);
            }
            statement.execute("SET session_replication_role = replica");
            statement.execute("""
                    INSERT INTO users(id, employee_id, login_account, password_hash) VALUES
                      ('%s', gen_random_uuid(), 'wm740_actor', 'x'), ('%s', gen_random_uuid(), 'wm740_other', 'x')
                    """.formatted(ACTOR, OTHER_ACTOR));
            statement.execute("""
                    INSERT INTO units(id, code, name) VALUES ('%s', 'WM740KG', '千克'), ('%s', 'WM740PCS', '个')
                    """.formatted(KG, PCS));
            // V743 删了 canonical_unit_id/to_canonical_factor 死列, MASS 档案改为登记
            // mass_unit_code(V743 的 G/KG/T/JIN/LB/OZ 口径)。
            statement.execute("""
                    INSERT INTO unit_measurement_profiles(unit_id, measurement_dimension, mass_unit_code, provenance)
                    VALUES ('%s', 'MASS', 'KG', 'MANUAL_GOVERNANCE')
                    """.formatted(KG));
            try (PreparedStatement insert = connection.prepareStatement("""
                    INSERT INTO goods(id, code, name, unit_id, code_sequence) VALUES (?, ?, ?, ?, ?)""")) {
                goods(insert, GRANULE, "WM740G1", "颗粒A", KG, 7400001);
                goods(insert, GRANULE_B, "WM740G2", "颗粒B", KG, 7400002);
                goods(insert, MASTERBATCH, "WM740S1", "色母", KG, 7400003);
                goods(insert, INSERT_PART, "WM740I1", "嵌件", PCS, 7400004);
                goods(insert, P1, "WM740P1", "注塑件一", PCS, 7400011);
                goods(insert, P2, "WM740P2", "注塑件二", PCS, 7400012);
                goods(insert, P3, "WM740P3", "注塑件三", PCS, 7400013);
                goods(insert, P4, "WM740P4", "嵌件注塑件", PCS, 7400014);
                goods(insert, P5, "WM740P5", "按个计的件", PCS, 7400015);
            }
            statement.execute("SET session_replication_role = origin");
        }
    }

    @AfterAll
    static void stop() {
        TEMPLATE.stop();
    }

    @BeforeEach
    void cloneCase() throws Exception {
        db = MigratedSchemaBaseline.cloneConnection(TEMPLATE, "wm740_case_" + CLONES.incrementAndGet());
        exec("SELECT set_config('app.actor_id', ?, false)", ACTOR.toString());
    }

    @AfterEach
    void closeCase() throws Exception {
        db.close();
    }

    // -----------------------------------------------------------------
    // 1-2 车间设置
    // -----------------------------------------------------------------

    @Test
    void settingsRejectForeignOrNonLineSideBin() throws Exception {
        // V802: 整批领料只能开在本车间已开通 (workshop_bins) 的内料仓上。
        rejected("还没开通内料仓", () -> insertSettings(injection, ASSEMBLY_BIN, true));
        rejected("还没开通内料仓", () -> insertSettings(injection, LEAF, true));
        rejected("整批领料只能在生产部下的车间开启",
                () -> insertSettings(uuid("SELECT id FROM departments WHERE code='DEPT_FIN'"), null, false));
        rejected("恰好有一个开着的期间", () -> insertSettings(injection, BIN, true));
        UUID period = enable();
        assertThat(str("SELECT status FROM workshop_material_periods WHERE id=?", period)).isEqualTo("OPEN");
        rejected("已被别人改过", () -> exec(
                "UPDATE workshop_material_settings SET go_live_date=? WHERE workshop_department_id=?",
                GO_LIVE.plusDays(1), injection));
        // V802: 一个车间只有一个开通的内料仓, 换成别的内料仓先被开通守卫拦下。
        rejected("还没开通内料仓", () -> exec(
                "UPDATE workshop_material_settings SET periodic_bin_warehouse_id=? WHERE workshop_department_id=?",
                BIN_OTHER_MAIN, injection));
    }

    @Test
    void settingsBinAndGoLiveImmutableAfterLedger() throws Exception {
        UUID first = enable();
        // 从未用过: 停用 (同事务删掉空的第 1 期) 后可以像第一次一样重新开启
        tx(() -> {
            exec("DELETE FROM workshop_material_periods WHERE id=?", first);
            disableSettings();
        });
        assertThat(count("SELECT count(*) FROM workshop_material_periods")).isZero();
        UUID period = UUID.randomUUID();
        tx(() -> {
            exec("""
                    UPDATE workshop_material_settings SET periodic_enabled=TRUE, disabled_by=NULL, disabled_at=NULL,
                        enabled_by=?, enabled_at=now(), row_version=row_version+1 WHERE workshop_department_id=?""",
                    ACTOR, injection);
            insertPeriod(period, 1, GO_LIVE);
        });
        periodic(GRANULE, "OWN");
        edge(P1, GRANULE, "0.0125");
        UUID segment = segment(P1);
        start(segment);
        rejected("不能停用", () -> {
            exec("DELETE FROM workshop_material_periods WHERE id=?", period);
            disableSettings();
        });
        tx(() -> issue(period, GRANULE, "500", GO_LIVE, false, true));
        rejected("内料仓和启用日期不能再改", () -> exec("""
                UPDATE workshop_material_settings SET go_live_date=?, row_version=row_version+1
                WHERE workshop_department_id=?""", GO_LIVE.plusDays(1), injection));
        rejected("还没开通内料仓", () -> exec("""
                UPDATE workshop_material_settings SET periodic_bin_warehouse_id=?, row_version=row_version+1
                WHERE workshop_department_id=?""", BIN_OTHER_MAIN, injection));
        rejected("不能停用", () -> disableSettings());
    }

    // -----------------------------------------------------------------
    // 3-6 货品、BOM 与认料
    // -----------------------------------------------------------------

    @Test
    void periodicGoodsRequireMassUnitAndServiceSwitch() throws Exception {
        rejected("整批领料的料基本单位必须是重量单位", () -> {
            switchFlag();
            exec("UPDATE goods SET issue_method='PERIODIC', periodic_cost_basis='OWN' WHERE id=?", P5);
        });
        rejected("请在基础资料的\"发料方式\"里切换",
                () -> exec("UPDATE goods SET issue_method='PERIODIC', periodic_cost_basis='OWN' WHERE id=?", GRANULE));

        // 已 FULFILLED 但已发 - 已退 != 实耗 + 损耗: 仍算没清账
        UUID segment = segment(P5);
        UUID demand = demand(segment, GRANULE, "FULFILLED");
        stockPosting(demand, "ISSUE", "100");
        settlement(demand, "CONSUMED", "80");
        rejected("还有按工单领出、没有清账的料", () -> switchTo(GRANULE, "PERIODIC", "OWN"));
        settlement(demand, "APPROVED_LOSS", "20");
        periodic(GRANULE, "OWN");

        // 改成辅料: 还有 BOM 期间边就拒绝
        edge(P1, GRANULE, "0.0125");
        rejected("分摊方式要等", () -> switchTo(GRANULE, "PERIODIC", "SHARED"));

        // 改回按工单领: 未结算期间里还有这种料的理论用量就拒绝 (没有库存、没有在做的工单与认料)
        periodic(GRANULE_B, "OWN");
        edge(P2, GRANULE_B, "0.01");
        UUID period = enable();
        UUID done = segment(P2);
        start(done);
        exec("UPDATE production_execution_segments SET status='COMPLETED' WHERE id=?", done);
        report(GO_LIVE.plusDays(2), 1, done, "100");
        rejected("处理完才能改回按工单领料", () -> switchTo(GRANULE_B, "ORDER", null));

        // 分摊方式: 内料仓里还有这种料 (有未结算期间的流水) 就拒绝
        tx(() -> issue(period, GRANULE_B, "50", GO_LIVE, false, true));
        rejected("分摊方式要等", () -> switchTo(GRANULE_B, "PERIODIC", "EXPENSE"));
    }

    @Test
    void periodicBomEdgeShapeAndSharedRejected() throws Exception {
        periodic(GRANULE, "OWN");
        periodic(MASTERBATCH, "SHARED");
        rejected("只填单个重量", () -> exec("""
                INSERT INTO goods_bom_items(goods_id, component_goods_id, qty, hard_gate, control_stage,
                                            consumption_basis, basis_output_qty)
                VALUES (?, ?, 0.0125, FALSE, 'START', 'PER_PACKAGE', 1)""", P1, GRANULE));
        rejected("只填单个重量", () -> exec("""
                INSERT INTO goods_bom_items(goods_id, component_goods_id, qty, hard_gate, control_stage,
                                            consumption_basis, basis_output_qty)
                VALUES (?, ?, 0.0125, TRUE, 'START', 'PER_UNIT', 1)""", P1, GRANULE));
        rejected("只填单个重量", () -> exec("""
                INSERT INTO goods_bom_items(goods_id, component_goods_id, qty, hard_gate, control_stage,
                                            consumption_basis, basis_output_qty)
                VALUES (?, ?, 0.0125, FALSE, 'START', 'PER_UNIT', 1000)""", P1, GRANULE));
        rejected("色母这类辅料不写进 BOM", () -> edge(P1, MASTERBATCH, "0.001"));
        UUID edge = edge(P1, GRANULE, "0.0125");
        rejected("只填单个重量", () -> exec("UPDATE goods_bom_items SET hard_gate=TRUE WHERE id=?", edge));
        assertThat(count("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted", P1)).isEqualTo(1);
    }

    @Test
    void bomTakeoverSupersedesChoices() throws Exception {
        periodic(GRANULE, "OWN");
        UUID choice = choose(P3, GRANULE, false);
        edge(P3, GRANULE, "0.02");
        assertThat(str("SELECT superseded_reason FROM goods_periodic_material_choices WHERE id=?", choice))
                .isEqualTo("BOM_TAKEOVER");
        assertThat(uuid("SELECT superseded_by FROM goods_periodic_material_choices WHERE id=?", choice)).isEqualTo(ACTOR);

        // 认料勾了"还要按工单领别的料", 产品还没有按单边: 先填嵌件再填塑料单重
        UUID alsoOrder = choose(P4, GRANULE, true);
        rejected("还要按工单领别的料", () -> edge(P4, GRANULE, "0.03"));
        orderEdge(P4, INSERT_PART);
        edge(P4, GRANULE, "0.03");
        assertThat(str("SELECT superseded_reason FROM goods_periodic_material_choices WHERE id=?", alsoOrder))
                .isEqualTo("BOM_TAKEOVER");
        assertThat(count("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted", P4)).isEqualTo(2);
    }

    @Test
    void choiceExclusivity() throws Exception {
        periodic(GRANULE, "OWN");
        periodic(GRANULE_B, "OWN");
        periodic(MASTERBATCH, "SHARED");
        choose(P1, GRANULE, false);
        rejected("已经认了内料仓的料", () -> chooseNone(P1));
        chooseNone(P2);
        rejected("不用内料仓的料", () -> choose(P2, GRANULE, false));
        rejected("按单个重量记到产品上的料", () -> choose(P3, MASTERBATCH, false));
        rejected("认料记录不能删除", () -> exec("DELETE FROM goods_periodic_material_choices WHERE product_goods_id=?", P1));
        rejected("认料记录不能修改", () -> exec(
                "UPDATE goods_periodic_material_choices SET also_order_materials=TRUE WHERE product_goods_id=?", P1));
        orderEdge(P4, INSERT_PART);
        rejected("不需要勾", () -> choose(P4, GRANULE, true));
        choose(P3, GRANULE, true);
        rejected("要选得一样", () -> choose(P3, GRANULE_B, false));
        choose(P3, GRANULE_B, true);
        assertThat(count("""
                SELECT count(*) FROM goods_periodic_material_choices
                WHERE product_goods_id=? AND superseded_at IS NULL""", P3)).isEqualTo(2);
    }

    // -----------------------------------------------------------------
    // 7-9 生产执行
    // -----------------------------------------------------------------

    @Test
    void periodicGoodsNeverDemandedOrDirectTransferred() throws Exception {
        periodic(GRANULE, "OWN");
        UUID segment = segment(P1);
        rejected("不能按工单领料", () -> exec("""
                INSERT INTO production_material_demands(package_id, plan_id, warehouse_id, goods_id, unit_id,
                    required_qty, supply_route, status, idempotency_key)
                VALUES (gen_random_uuid(), gen_random_uuid(), ?, ?, ?, 1, 'BUY', 'OPEN', 'wm740-demand-direct')""",
                LEAF, GRANULE, KG));
        UUID demand = demand(segment, INSERT_PART, "OPEN");
        rejected("不能按工单领料",
                () -> exec("UPDATE production_material_demands SET goods_id=? WHERE id=?", GRANULE, demand));

        UUID report = report(GO_LIVE, 1, segment, "10");
        UUID granuleLine = UUID.randomUUID();
        exec("""
                INSERT INTO production_daily_report_items(id, bill_no, bill_date, report_id, goods_id, unit_rate, qty)
                SELECT ?, bill_no, bill_date, id, ?, 1, 5 FROM production_daily_reports WHERE id=?""",
                granuleLine, GRANULE, report);
        rejected("不能走车间直送", () -> exec("""
                INSERT INTO production_workshop_direct_transfer_items(transfer_id, source_report_item_id,
                    to_execution_segment_id, to_demand_id, qty)
                VALUES (gen_random_uuid(), ?, ?, ?, 1)""", granuleLine, segment, demand));
    }

    @Test
    void zeroReasonPeriodicMaterialEvidence() throws Exception {
        periodic(GRANULE, "OWN");
        edge(P1, GRANULE, "0.0125");
        zeroSegment(P1, "PERIODIC_MATERIAL", null, null, null);
        edge(P2, GRANULE, "0.01");
        orderEdge(P2, INSERT_PART);
        rejected("zero-material evidence does not match", () -> zeroSegment(P2, "PERIODIC_MATERIAL", null, null, null));
        rejected("zero-material evidence does not match", () -> zeroSegment(P3, "PERIODIC_MATERIAL", null, null, null));
        // NO_PRODUCTION_HARD_GATE 不改: 期间边不是硬门槛, 证据仍成立
        zeroSegment(P1, "NO_PRODUCTION_HARD_GATE", null, null, null);
        // DIRECT_MAKE 的"没有 BOM"改为"没有按单 BOM": 补了颗粒单重的产品仍能插入原路线的拆批子段
        UUID analysis = UUID.randomUUID();
        UUID analysisItem = UUID.randomUUID();
        UUID plan = UUID.randomUUID();
        UUID planItem = UUID.randomUUID();
        replica(() -> {
            exec("""
                    INSERT INTO production_plans(id, bill_no, bill_date, material_analysis_id, material_analysis_item_id)
                    VALUES (?, 'SJ740', ?, ?, ?)""", plan, GO_LIVE, analysis, analysisItem);
            exec("""
                    INSERT INTO production_plan_items(id, bill_no, bill_date, plan_id, product_no, goods_id, unit_id,
                                                      allowed_overproduction_rate)
                    VALUES (?, 'SJ740', ?, ?, 'PN740', ?, ?, 0)""", planItem, GO_LIVE, plan, P1, PCS);
            exec("""
                    INSERT INTO production_material_analysis_items(id, analysis_id, source_type, goods_id, unit_id,
                                                                   source_ref, source_reason, requested_qty)
                    VALUES (?, ?, 'STOCK', ?, ?, 'WM740', '整批领料验收', 1)""", analysisItem, analysis, P1, PCS);
        });
        zeroSegment(P1, "DIRECT_MAKE", analysis, plan, planItem);
        rejected("zero-material evidence does not match", () -> zeroSegment(P2, "DIRECT_MAKE", analysis, plan, planItem));

        // 函数开头仍是 V710、V701 的早退, 没有新的早退
        String definition = str("SELECT pg_get_functiondef('fn_guard_execution_segment_requirement_shape()'::regprocedure)");
        String body = definition.substring(definition.indexOf("BEGIN\n"));
        assertThat(body).startsWith("BEGIN\n\n    IF TG_OP='UPDATE' AND OLD.material_discovery_required");
        int v710 = body.indexOf("OLD.material_discovery_required");
        int v701 = body.indexOf("proof.supplement_execution_segment_id=NEW.id");
        int v426 = body.indexOf("zero-material execution segment must start READY");
        assertThat(v710).isLessThan(v701);
        assertThat(v701).isLessThan(v426);
        assertThat(body.split("RETURN NEW;", -1)).hasSize(4);
        assertThat(body.indexOf("PERIODIC_MATERIAL")).isGreaterThan(v426);
        assertThat(body).contains("AND NOT fn_goods_has_order_bom(NEW.product_goods_id)");
    }

    @Test
    void startGateAndBind() throws Exception {
        periodic(GRANULE, "OWN");
        edge(P1, GRANULE, "0.0125");
        UUID bomSegment = segment(P1);
        assertThat(state(bomSegment)).isEqualTo("NEED_BIN");
        rejected("本车间还没有开启整批领料", () -> start(bomSegment));
        enable();
        start(bomSegment);
        assertThat(str("""
                SELECT origin || '|' || effective_from || '|' || design_qty_snapshot
                FROM production_execution_periodic_materials WHERE execution_segment_id=?""", bomSegment))
                .isEqualTo("BOM|" + GO_LIVE + "|0.01250");

        UUID choiceSegment = segment(P2);
        assertThat(state(choiceSegment)).isEqualTo("NEED_CHOICE");
        rejected("请先在开工确认表里认料", () -> start(choiceSegment));
        choose(P2, GRANULE, false);
        start(choiceSegment);
        UUID choiceRow = uuid("SELECT id FROM production_execution_periodic_materials WHERE execution_segment_id=?",
                choiceSegment);
        assertThat(str("SELECT origin || '|' || effective_from FROM production_execution_periodic_materials WHERE id=?",
                choiceRow)).isEqualTo("CHOICE|" + GO_LIVE);

        UUID child = UUID.randomUUID();
        replica(() -> exec("""
                INSERT INTO production_execution_segments(id, package_id, plan_id, source_plan_item_id, segment_no,
                    segment_code, client_segment_key, product_goods_id, product_unit_id, product_unit_rate, planned_qty,
                    status, workshop_department_id, bom_fingerprint, idempotency_key, source_segment_id,
                    split_root_segment_id, split_material_snapshot, split_start_qty)
                SELECT ?, package_id, plan_id, source_plan_item_id, segment_no + 100, segment_code || '-B',
                       client_segment_key || '-b', product_goods_id, product_unit_id, product_unit_rate, 10, 'READY',
                       workshop_department_id, bom_fingerprint, idempotency_key || '-b', id, id, '[{"split":1}]'::jsonb, 1
                FROM production_execution_segments WHERE id=?""", child, choiceSegment));
        start(child);
        assertThat(str("""
                SELECT origin || '|' || source_row_id FROM production_execution_periodic_materials
                WHERE execution_segment_id=?""", child)).isEqualTo("INHERITED|" + choiceRow);
        assertThat(str("SELECT fn_segment_bin_discovery_released(?)::text", child)).isEqualTo("true");

        // 段上有整批领料货品的未核清按单需求: 按工单做完为止, 不绑定, 直接建行也被拒
        UUID orderSegment = segment(P1);
        demand(orderSegment, GRANULE, "OPEN");
        assertThat(state(orderSegment)).isEqualTo("ORDER_ONLY");
        start(orderSegment);
        assertThat(count("SELECT count(*) FROM production_execution_periodic_materials WHERE execution_segment_id=?",
                orderSegment)).isZero();
        rejected("这张工单已经按工单领过颗粒", () -> exec("""
                INSERT INTO production_execution_periodic_materials(execution_segment_id, bin_warehouse_id,
                    material_goods_id, unit_id, origin, bom_item_id, design_qty_snapshot, effective_from)
                SELECT ?, ?, ?, ?, 'BOM', id, qty, ? FROM goods_bom_items WHERE goods_id=? AND component_goods_id=?""",
                orderSegment, BIN, GRANULE, KG, GO_LIVE, P1, GRANULE));
    }

    // -----------------------------------------------------------------
    // 10-12 内料仓进出
    // -----------------------------------------------------------------

    @Test
    void ledgerRejectsUnregisteredMovementAndBalanceMismatch() throws Exception {
        periodic(GRANULE, "OWN");
        UUID period = enable();
        rejected("Technical workshop stock requires exact", () -> {
            movement(UUID.randomUUID(), 7, "STOCK_DOC", UUID.randomUUID(), UUID.randomUUID(), GRANULE, BIN, 1, "100");
            balance(BIN, GRANULE, "100");
        });
        Issue issue = txIssue(period, GRANULE, "100", GO_LIVE, false, true);
        assertThat(count("SELECT count(*) FROM v_workshop_material_bin_ledger WHERE movement_id=?", issue.binMovement()))
                .isEqualTo(1);
        assertNum("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?", "100", BIN, GRANULE);
        rejected("合计与库存余额对不上", () -> issue(period, GRANULE, "30", GO_LIVE, false, false));
        rejected("必须对应本次登记、已审核的调拨单", () -> {
            Issue draft = issue(period, GRANULE, "10", GO_LIVE, false, true);
            exec("UPDATE stock_documents SET status=0 WHERE id=?", draft.document());
        });
    }

    @Test
    void ledgerPeriodRules() throws Exception {
        periodic(GRANULE, "OWN");
        periodic(GRANULE_B, "OWN");
        UUID first = enable();
        txIssue(first, GRANULE, "500", GO_LIVE, false, true);
        LocalDate cutOff = GO_LIVE.plusDays(14);
        UUID second = startCounting(first, cutOff);
        rejected("只能记进当前开着的那一期", () -> issue(first, GRANULE, "10", cutOff, false, true));
        // 截止日选"今天": 当天再发的料记进下一期, 业务日期照记真实日期
        Issue sameDay = txIssue(second, GRANULE, "20", cutOff, false, true);
        assertThat(str("SELECT period_id || '|' || business_date FROM v_workshop_material_bin_ledger WHERE source_row_id=?",
                sameDay.posting())).isEqualTo(second + "|" + cutOff);
        // 漏录补记进盘点中的那一期
        txIssue(first, GRANULE, "30", GO_LIVE.plusDays(3), true, true);
        Count counted = txSubmit(first, GRANULE, "0", "530", "200");
        // 补记进已盘点的那一期: 同事务不更正期间行就在提交时被拒
        rejected("领入、退回、其它耗用与进出记录对不上", () -> issue(first, GRANULE, "40", GO_LIVE.plusDays(4), true, true));
        tx(() -> {
            issue(first, GRANULE, "40", GO_LIVE.plusDays(4), true, true);
            exec("""
                    UPDATE workshop_material_period_lines SET transfer_in_qty=transfer_in_qty+40, row_version=row_version+1
                    WHERE id=?""", counted.line());
            countPosting(counted.line(), counted.count(), GRANULE, "CONSUME", "40", cutOff, "SUPPLEMENT", null);
        });
        assertNum("SELECT actual_qty FROM workshop_material_period_lines WHERE id=?", "370", counted.line());
        // 那一期没有盘到的料不能补记
        rejected("先更正盘点补上实盘数", () -> issue(first, GRANULE_B, "5", GO_LIVE.plusDays(4), true, true));
        // 已结算的期间不能补记
        tx(() -> closeRows(first, counted.line(), "UNALLOCATED_LOSS", "0", "370", null, List.of()));
        rejected("正在盘点或已盘点、还没结算", () -> issue(first, GRANULE, "1", GO_LIVE.plusDays(4), true, true));
    }

    @Test
    void workshopMaterialDocumentsCannotBeReversed() throws Exception {
        periodic(GRANULE, "OWN");
        UUID period = enable();
        Issue issue = txIssue(period, GRANULE, "100", GO_LIVE, false, true);
        rejected("不能红冲", () -> exec("UPDATE stock_documents SET status=-1 WHERE id=?", issue.document()));
        UUID ordinary = UUID.randomUUID();
        exec("""
                INSERT INTO stock_documents(id, doc_type, bill_no, bill_date, warehouse_id, status)
                VALUES (?, 'OTHER_OUT', 'QC740-ORDINARY', ?, ?, 1)""", ordinary, GO_LIVE, LEAF);
        exec("UPDATE stock_documents SET status=-1 WHERE id=?", ordinary);
    }

    // -----------------------------------------------------------------
    // 13-16 期间、盘点与结算
    // -----------------------------------------------------------------

    @Test
    void periodChainAssertions() throws Exception {
        UUID first = enable();
        rejected("内料仓的期间不连续或状态顺序不对", () -> {
            countingPeriod(first, GO_LIVE.plusDays(5));
            insertPeriod(UUID.randomUUID(), 2, GO_LIVE.plusDays(7));
        });
        rejected("内料仓的期间不连续或状态顺序不对", () -> {
            countingPeriod(first, GO_LIVE.plusDays(5));
            insertPeriod(UUID.randomUUID(), 2, GO_LIVE.plusDays(5));
        });
        rejected("内料仓的期间不连续或状态顺序不对", () -> insertPeriod(UUID.randomUUID(), 2, GO_LIVE.plusDays(1)));
        rejected("恰好有一个开着的期间", () -> countingPeriod(first, GO_LIVE.plusDays(5)));
        rejected("内料仓的期间不连续或状态顺序不对", () -> {
            countingPeriod(first, GO_LIVE.plusDays(5));
            exec("""
                    INSERT INTO workshop_material_periods(id, bin_warehouse_id, workshop_department_id, period_no,
                        start_date, end_date, status)
                    VALUES (gen_random_uuid(), ?, ?, 2, ?, ?, 'COUNTED')""",
                    BIN, injection, GO_LIVE.plusDays(6), GO_LIVE.plusDays(8));
            insertPeriod(UUID.randomUUID(), 3, GO_LIVE.plusDays(9));
        });
        rejected("期间状态不能这样变更", () -> exec("""
                UPDATE workshop_material_periods SET status='CLOSED', end_date=?, row_version=row_version+1
                WHERE id=?""", GO_LIVE.plusDays(5), first));
        UUID second = startCounting(first, GO_LIVE.plusDays(5));
        assertThat(str("SELECT status FROM workshop_material_periods WHERE id=?", second)).isEqualTo("OPEN");
    }

    @Test
    void countLineGeneratedQty() throws Exception {
        periodic(GRANULE, "OWN");
        UUID first = enable();
        UUID machine = UUID.randomUUID();
        UUID machineTwo = UUID.randomUUID();
        exec("""
                INSERT INTO workshop_machines(id, workshop_department_id, code, name, created_by)
                VALUES (?, ?, 'ZS-01', '一号注塑机', ?), (?, ?, 'ZS-02', '二号注塑机', ?)""",
                machine, injection, ACTOR, machineTwo, injection, ACTOR);
        UUID hopper = container(machine, "料斗", "50");
        UUID barrel = container(machine, "储料桶", "100");
        UUID hopperTwo = container(machineTwo, "料斗", "50");
        UUID barrelTwo = container(machineTwo, "储料桶", "100");
        startCounting(first, GO_LIVE.plusDays(6));
        UUID countId = UUID.randomUUID();
        exec("INSERT INTO workshop_material_counts(id, period_id, version, created_by) VALUES (?, ?, 1, ?)",
                countId, first, ACTOR);
        containerLine(countId, "full", machine, hopper, "50", "FULL", GRANULE, null);
        containerLine(countId, "half", machine, barrel, "100", "HALF", GRANULE, null);
        containerLine(countId, "empty", machineTwo, hopperTwo, "50", "EMPTY", null, null);
        containerLine(countId, "weighed", machineTwo, barrelTwo, "100", "WEIGHED", GRANULE, "12.3");
        exec("""
                INSERT INTO workshop_material_count_lines(count_id, client_line_key, line_kind, goods_id, unit_id,
                    bag_count, bag_net_qty, entered_by)
                VALUES (?, 'bags', 'FULL_BAGS', ?, ?, 4, 25, ?)""", countId, GRANULE, KG, ACTOR);
        exec("""
                INSERT INTO workshop_material_count_lines(count_id, client_line_key, line_kind, weigh_note, goods_id,
                    unit_id, weighed_qty, entered_by)
                VALUES (?, 'open-bag', 'WEIGHED', 'OPEN_BAG', ?, ?, 7.3, ?)""", countId, GRANULE, KG, ACTOR);
        assertThat(str("""
                SELECT string_agg(client_line_key || '=' || trim_scale(qty_base), ',' ORDER BY client_line_key)
                FROM workshop_material_count_lines WHERE count_id=?""", countId))
                .isEqualTo("bags=100,empty=0,full=50,half=50,open-bag=7.3,weighed=12.3");
        rejected("workshop_material_count_line_note_chk", () -> exec("""
                INSERT INTO workshop_material_count_lines(count_id, client_line_key, line_kind, weigh_note, goods_id,
                    unit_id, bag_count, bag_net_qty, entered_by)
                VALUES (?, 'bad', 'FULL_BAGS', 'OPEN_BAG', ?, ?, 1, 25, ?)""", countId, GRANULE, KG, ACTOR));
        rejected("已被别人改过", () -> exec(
                "UPDATE workshop_material_count_lines SET weighed_qty=8 WHERE count_id=? AND client_line_key='open-bag'",
                countId));
        exec("""
                UPDATE workshop_material_count_lines SET weighed_qty=8, row_version=row_version+1
                WHERE count_id=? AND client_line_key='open-bag'""", countId);
        rejected("盘点用过的机台或容器只能停用", () -> exec(
                "UPDATE workshop_machines SET is_deleted=TRUE, deleted_at=now() WHERE id=?", machine));
        exec("""
                UPDATE workshop_material_counts SET status='SUBMITTED', submitted_by=?, submitted_at=now(),
                    row_version=row_version+1 WHERE id=?""", ACTOR, countId);
        rejected("盘点单已提交", () -> exec("""
                UPDATE workshop_material_count_lines SET weighed_qty=9, row_version=row_version+1
                WHERE count_id=? AND client_line_key='open-bag'""", countId));
    }

    @Test
    void periodLineAndPostingAssertions() throws Exception {
        periodic(GRANULE, "OWN");
        UUID first = enable();
        txIssue(first, GRANULE, "500", GO_LIVE, false, true);
        LocalDate end = GO_LIVE.plusDays(9);
        startCounting(first, end);
        rejected("这一期的期初与上一期的期末对不上", () -> submit(first, GRANULE, "10", "500", "210"));
        rejected("这一期的领入、退回、其它耗用与进出记录对不上", () -> submit(first, GRANULE, "0", "400", "100"));
        rejected("盘点过账与这一期的实际用量对不上", () -> {
            Count bad = submitWithoutPosting(first, GRANULE, "0", "500", "200");
            countPosting(bad.line(), bad.count(), GRANULE, "CONSUME", "250", end, "SUBMIT", null);
        });
        // 第 1 版盘盈 20 (实盘 520), 更正为多用 10 (实盘 490): 冲回盘盈 20 + 耗用 10
        Count gained = txSubmit(first, GRANULE, "0", "500", "520");
        assertThat(str("SELECT kind FROM workshop_material_count_postings WHERE id=?", gained.posting())).isEqualTo("GAIN");
        rejected("盘点过账与这一期的实际用量对不上", () -> {
            UUID version2 = correctCount(first, gained, "490");
            countPosting(gained.line(), version2, GRANULE, "CONSUME", "30", end, "CORRECTION", null);
        });
        tx(() -> {
            UUID version2 = correctCount(first, gained, "490");
            countPosting(gained.line(), version2, GRANULE, "GAIN_REVERSE", "20", end, "CORRECTION", gained.posting());
            countPosting(gained.line(), version2, GRANULE, "CONSUME", "10", end, "CORRECTION", null);
        });
        assertNum("SELECT actual_qty FROM workshop_material_period_lines WHERE id=?", "10", gained.line());
        assertNum("SELECT fn_workshop_material_book_as_of(?, ?, NULL)", "490", first, GRANULE);
        assertNum("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?", "490", BIN, GRANULE);
    }

    @Test
    void closeAssertions() throws Exception {
        periodic(GRANULE, "OWN");
        edge(P1, GRANULE, "0.0125");
        edge(P2, GRANULE, "0.01");
        UUID first = enable();
        UUID one = segment(P1);
        UUID two = segment(P2);
        start(one);
        start(two);
        txIssue(first, GRANULE, "500", GO_LIVE, false, true);
        report(GO_LIVE.plusDays(2), 1, one, "20000");
        report(GO_LIVE.plusDays(2), 1, two, "8000");
        startCounting(first, GO_LIVE.plusDays(14));
        Count counted = txSubmit(first, GRANULE, "0", "500", "200");
        assertThat(count("SELECT count(*) FROM fn_workshop_material_close_blockers(?)", first)).isZero();

        rejected("结算的计入量、损失与分摊合计对不上", () -> closeRows(first, counted.line(), "ALLOCATED", "300", "0", "330",
                List.<Object[]>of(allocation(one, "250", "227", true), allocation(two, "80", "72.7273", false))));
        rejected("结算的计入量、损失与分摊合计对不上", () -> closeRows(first, counted.line(), "ALLOCATED", "300", "0", "330",
                List.<Object[]>of(allocation(one, "250", "227.2727", false), allocation(two, "80", "72.7273", false))));
        rejected("结算的计入量、损失与分摊合计对不上", () -> closeRows(first, counted.line(), "ALLOCATED", "300", "0", "330",
                List.<Object[]>of(allocation(one, "250", "227.2727", true), allocation(two, "80", "72.7273", true))));
        rejected("结算的理论明细与这一期的已审报工对不上", () -> closeRowsWithId(UUID.randomUUID(), first, counted.line(),
                "ALLOCATED", "300", "0", "330",
                List.<Object[]>of(allocation(one, "250", "227.2727", true), allocation(two, "80", "72.7273", false)), two));
        rejected("有已审报工不在任何一段用料时间内", () -> {
            UUID uncovered = segment(P2);
            replica(() -> exec("""
                    INSERT INTO production_execution_periodic_materials(execution_segment_id, bin_warehouse_id,
                        material_goods_id, unit_id, origin, bom_item_id, design_qty_snapshot, effective_from)
                    SELECT ?, ?, ?, ?, 'BOM', id, qty, ? FROM goods_bom_items WHERE goods_id=? AND component_goods_id=?""",
                    uncovered, BIN, GRANULE, KG, GO_LIVE.plusDays(5), P2, GRANULE));
            replica(() -> report(GO_LIVE.plusDays(3), 1, uncovered, "10"));
            closeRows(first, counted.line(), "ALLOCATED", "300", "0", "330",
                    List.<Object[]>of(allocation(one, "250", "227.2727", true), allocation(two, "80", "72.7273", false)));
        });
        UUID close = UUID.randomUUID();
        tx(() -> closeRowsWithId(close, first, counted.line(), "ALLOCATED", "300", "0", "330",
                List.<Object[]>of(allocation(one, "250", "227.2727", true), allocation(two, "80", "72.7273", false)), null));
        assertThat(str("SELECT status FROM workshop_material_periods WHERE id=?", first)).isEqualTo("CLOSED");
        assertThat(str("SELECT fn_workshop_material_closed_through(?)::text", BIN)).isEqualTo(GO_LIVE.plusDays(14).toString());
        assertNum("SELECT theory_qty FROM v_workshop_material_period_report WHERE period_id=?", "330", first);
        assertNum("SELECT sum(allocated_qty) FROM v_workshop_material_product_report WHERE period_id=?", "300", first);

        UUID allocationId = uuid("""
                SELECT allocation.id FROM workshop_material_close_allocations allocation
                JOIN workshop_material_close_materials material ON material.id=allocation.close_material_id
                WHERE material.close_id=? AND allocation.cost_scope_segment_id=?""", close, one);
        rejected("整批领料的成本投入必须来自有效结算", () -> replica(() -> exec("""
                INSERT INTO stock_value_production_cost_inputs(input_node_id, execution_segment_id, approved_posting_id,
                                                               input_kind)
                VALUES (gen_random_uuid(), ?, ?, 'PERIODIC_MATERIAL')""", one, allocationId)));
        rejected("车间内料仓的分摊只能作为整批领料的成本投入", () -> replica(() -> exec("""
                INSERT INTO stock_value_production_cost_inputs(input_node_id, execution_segment_id, approved_posting_id,
                                                               input_kind)
                VALUES (gen_random_uuid(), ?, ?, 'CONSUMED')""", one, allocationId)));
    }

    @Test
    void zeroTheoryWithoutAPeriodLineNeedsNoTheoryLine() throws Exception {
        periodic(GRANULE, "OWN");
        periodic(GRANULE_B, "OWN");
        edge(P1, GRANULE, "0.0125");
        edge(P2, GRANULE_B, "0.01");
        UUID first = enable();
        UUID one = segment(P1);
        UUID two = segment(P2);
        start(one);
        start(two);
        txIssue(first, GRANULE, "500", GO_LIVE, false, true);
        report(GO_LIVE.plusDays(2), 1, one, "20000");
        // 产量为 0 (例如返工补产): 这种料这一期没有进出, 也没盘到, 理论为 0
        report(GO_LIVE.plusDays(2), 1, two, "0");
        startCounting(first, GO_LIVE.plusDays(14));
        Count counted = txSubmit(first, GRANULE, "0", "500", "200");
        assertThat(count("SELECT count(*) FROM fn_workshop_material_close_blockers(?)", first)).isZero();
        assertThat(count("""
                SELECT count(*) FROM fn_workshop_material_period_theory(?, ?, ?)
                WHERE material_goods_id=? AND output_qty_base=0""", BIN, GO_LIVE, GO_LIVE.plusDays(14), GRANULE_B))
                .isEqualTo(1);
        // 零理论那一行没有可挂的料行: 不写理论明细也能结算
        tx(() -> closeRowsWithId(UUID.randomUUID(), first, counted.line(), "ALLOCATED", "300", "0", "250",
                List.<Object[]>of(allocation(one, "250", "300", true)), two));
        assertThat(str("SELECT status FROM workshop_material_periods WHERE id=?", first)).isEqualTo("CLOSED");
    }

    @Test
    void periodicEdgeReadersOnlyFollowOrderEdges() throws Exception {
        // V798(ADR-143): 委外可发外直属边只剩一个判据 fn_subcontract_draw_edges, 整批领料的料不发外。
        assertThat(str("SELECT pg_get_functiondef('fn_subcontract_draw_edges(uuid)'::regprocedure)"))
                .contains("component.issue_method <> 'PERIODIC'");
        assertThat(str("SELECT pg_get_functiondef('fn_preplan_future_source_private_capacity_qty(uuid)'::regprocedure)"))
                .contains("NOT fn_goods_has_order_bom(action.goods_id)")
                .doesNotContain("NOT EXISTS(SELECT 1 FROM goods_bom_items bom WHERE bom.goods_id=action.goods_id");
    }

    // -----------------------------------------------------------------
    // 17-19 报工截止、成本刷新来源、直送异常视图
    // -----------------------------------------------------------------

    @Test
    void reportDateLockTriggers() throws Exception {
        UUID segment = closedSinglePeriod();
        LocalDate closedDay = GO_LIVE.plusDays(3);
        rejected("已经结算", () -> {
            UUID header = reportHeader(closedDay, 0);
            reportItem(header, segment, "5");
        });
        UUID draft = UUID.randomUUID();
        replica(() -> {
            exec("INSERT INTO production_daily_reports(id, bill_no, bill_date, status) VALUES (?, 'RB740-D', ?, 0)",
                    draft, closedDay);
            reportItem(draft, segment, "5");
        });
        rejected("已经结算", () -> exec("UPDATE production_daily_reports SET status=1 WHERE id=?", draft));
        UUID approved = uuid("SELECT id FROM production_daily_reports WHERE status=1 AND bill_date=?", GO_LIVE.plusDays(2));
        rejected("已经结算", () -> exec("UPDATE production_daily_reports SET status=-1 WHERE id=?", approved));
        UUID later = report(GO_LIVE.plusDays(20), 0, segment, "5");
        rejected("已经结算", () -> exec("UPDATE production_daily_reports SET bill_date=? WHERE id=?", closedDay, later));
        exec("UPDATE production_daily_reports SET status=1 WHERE id=?", later);
        // 结算后才开工的段 (期间料行从已结算截止日次日开始), 报工日期落在已结算期间同样被锁
        UUID lateSegment = segment(P1);
        start(lateSegment);
        assertThat(str("SELECT effective_from::text FROM production_execution_periodic_materials WHERE execution_segment_id=?",
                lateSegment)).isEqualTo(GO_LIVE.plusDays(15).toString());
        rejected("已经结算", () -> {
            UUID header = reportHeader(GO_LIVE.plusDays(4), 0);
            reportItem(header, lateSegment, "5");
        });
        // 删除草稿不拦
        exec("UPDATE production_daily_reports SET is_deleted=TRUE, deleted_at=now() WHERE id=?", draft);
    }

    @Test
    void refreshSourceAcceptsCloseAndReversal() throws Exception {
        UUID segment = closedSinglePeriod();
        UUID close = uuid("SELECT id FROM workshop_material_period_closes WHERE status='ACTIVE'");
        replica(() -> exec("""
                INSERT INTO stock_value_production_cost_objects(execution_segment_id, product_pool_id)
                VALUES (?, gen_random_uuid())""", segment));
        rejected("cost refresh requires", () -> refreshObject(segment, close, OTHER_ACTOR));
        tx(() -> refreshObject(segment, close, ACTOR));
        UUID reversal = UUID.randomUUID();
        UUID period = uuid("SELECT period_id FROM workshop_material_period_closes WHERE id=?", close);
        tx(() -> {
            exec("""
                    UPDATE workshop_material_period_closes SET status='REVERSED', reversal_event_id=?, reversed_by=?,
                        reversed_at=now(), reverse_reason='更正盘点' WHERE id=?""", reversal, OTHER_ACTOR, close);
            exec("""
                    UPDATE workshop_material_close_allocations SET reversed_at=now()
                    WHERE close_material_id IN (SELECT id FROM workshop_material_close_materials WHERE close_id=?)""", close);
            exec("UPDATE workshop_material_periods SET status='COUNTED', row_version=row_version+1 WHERE id=?", period);
        });
        rejected("cost refresh requires", () -> refreshObject(segment, reversal, ACTOR));
        tx(() -> refreshObject(segment, reversal, OTHER_ACTOR));
        rejected("结算记录只能追加", () -> exec(
                "UPDATE workshop_material_period_closes SET trigger_kind='MANUAL' WHERE id=?", close));
    }

    @Test
    void anomalyViewKeepsColumnsAndLegacyAnomalies() throws Exception {
        assertThat(str("""
                SELECT string_agg(attname, ',' ORDER BY attnum) FROM pg_attribute
                WHERE attrelid='v_workshop_direct_stock_anomalies'::regclass AND attnum > 0""")).isEqualTo(
                "movement_id,warehouse_id,goods_id,color_id,source_doc_type,source_doc_id,source_item_id,"
                        + "movement_type,direction,qty");
        periodic(GRANULE, "OWN");
        UUID period = enable();
        Issue issue = txIssue(period, GRANULE, "100", GO_LIVE, false, true);
        assertThat(count("SELECT count(*) FROM v_workshop_direct_stock_anomalies WHERE movement_id=?",
                issue.binMovement())).isZero();
        db.setAutoCommit(false);
        try {
            UUID legacy = UUID.randomUUID();
            movement(legacy, 7, "STOCK_DOC", UUID.randomUUID(), UUID.randomUUID(), INSERT_PART, BIN, 1, "3");
            assertThat(count("SELECT count(*) FROM v_workshop_direct_stock_anomalies WHERE movement_id=?", legacy))
                    .isEqualTo(1);
        } finally {
            db.rollback();
            db.setAutoCommit(true);
        }
    }

    // -----------------------------------------------------------------
    // 20-22 改名、权限、编号
    // -----------------------------------------------------------------

    @Test
    void lineSideRenamedOnlyDuplicatesSuffixed() throws Exception {
        assertThat(str("SELECT name FROM warehouses WHERE id=?", BIN)).isEqualTo("注塑车间内料仓");
        assertThat(str("SELECT name FROM warehouses WHERE id=?", BIN_OTHER_MAIN)).isEqualTo("注塑车间内料仓 (二号主仓)");
        assertThat(str("SELECT name FROM warehouses WHERE id=?", ASSEMBLY_BIN)).isEqualTo("装配车间内料仓 (一号主仓)");
        assertThat(str("SELECT name || '|' || remark FROM warehouses WHERE id=?", MANUAL_BIN)).isEqualTo("ESD 手工料架|线边仓");
        assertThat(str("SELECT name FROM warehouses WHERE id=?", NAME_CLASH)).isEqualTo("装配车间内料仓");
        assertThat(str("SELECT remark FROM warehouses WHERE id=?", BIN)).startsWith("系统自动配置的车间内料仓");
        assertThat(str("SELECT description FROM permissions WHERE code='production_direct_transfer:approve'"))
                .contains("内料仓").doesNotContain("线边仓");
        for (String function : List.of("fn_guard_procurement_iqc_pre_stock_mutation()",
                "fn_guard_production_finished_arrival_registration()")) {
            assertThat(str("SELECT pg_get_functiondef(?::regprocedure)", function))
                    .contains("内料仓").doesNotContain("线边仓");
        }
    }

    @Test
    void permissionsAndGrants() throws Exception {
        assertThat(str("""
                SELECT string_agg(code || ':' || action_type || ':' || grant_policy::text, ',' ORDER BY sort_order)
                FROM permissions WHERE code LIKE 'workshop\\_material:%'""")).isEqualTo(String.join(",",
                "workshop_material:view:VIEW:{NORMAL}",
                "workshop_material:issue:EXECUTE:{NORMAL}",
                "workshop_material:request:CREATE:{NORMAL}",
                "workshop_material:count:EXECUTE:{INDIVIDUAL_ONLY}",
                "workshop_material:choose:EXECUTE:{NORMAL}",
                "workshop_material:setup:CONFIGURE:{BULK_EXCLUDED,NON_DELEGABLE}",
                "workshop_material:reopen:EXECUTE:{INDIVIDUAL_ONLY}"));
        assertThat(str("""
                SELECT string_agg(department.code || '>' || permission.code, ',' ORDER BY department.code, permission.code)
                FROM department_permissions grant_row
                JOIN departments department ON department.id=grant_row.department_id
                JOIN permissions permission ON permission.id=grant_row.permission_id
                WHERE permission.code LIKE 'workshop\\_material:%'""")).isEqualTo(String.join(",",
                "DEPT_FIN>workshop_material:view",
                "DEPT_PROD>workshop_material:choose",
                "DEPT_PROD>workshop_material:request", "DEPT_PROD>workshop_material:view",
                "SUB_PLAN>workshop_material:view",
                "SUB_WH>workshop_material:issue",
                "SUB_WH>workshop_material:setup", "SUB_WH>workshop_material:view"));
        assertThat(count("""
                SELECT count(*) FROM permissions permission
                WHERE permission.code LIKE 'workshop\\_material:%' AND 'NORMAL' = ANY(permission.grant_policy)
                  AND NOT EXISTS (SELECT 1 FROM permission_surface_permissions mapping
                                  WHERE mapping.permission_id=permission.id)""")).isZero();
        // The template migrates to HEAD: V812 retires the orphan workshop-material surface
        // and moves every permission to the actual workshop-tasks page, without adding grants.
        assertThat(str("""
                SELECT string_agg(surface_key, ',' ORDER BY surface_key) FROM permission_surfaces
                WHERE surface_key IN ('warehouse.workshop-material', 'warehouse.workshop-material-setup',
                                      'production.workshop-tasks', 'report.workshop-material') AND enabled"""))
                .isEqualTo("production.workshop-tasks,report.workshop-material,warehouse.workshop-material,warehouse.workshop-material-setup");
        assertThat(count("SELECT count(*) FROM permission_surfaces WHERE surface_key='production.workshop-material'"))
                .isZero();
        assertThat(str("""
                SELECT string_agg(permission.code, ',' ORDER BY permission.code)
                FROM permission_surface_permissions mapping
                JOIN permission_surfaces surface ON surface.id=mapping.surface_id
                JOIN permissions permission ON permission.id=mapping.permission_id
                WHERE surface.surface_key='production.workshop-tasks'
                  AND permission.code IN ('workshop_material:view', 'workshop_material:request',
                                          'workshop_material:count', 'workshop_material:choose', 'stock:count:submit')
                """))
                .isEqualTo("stock:count:submit,workshop_material:choose,workshop_material:count,workshop_material:request,workshop_material:view");
        assertThat(count("SELECT count(*) FROM manager_permission_delegations WHERE surface_key='production.workshop-material'"))
                .isZero();
        assertThat(str("SELECT high_risk::text FROM permissions WHERE code='workshop_material:reopen'")).isEqualTo("true");
        // The template migrates to HEAD: V767 keeps named user grants, but revokes department/manager grants.
        assertThat(str("SELECT baseline::text FROM permissions WHERE code='workshop_material:count'")).isEqualTo("false");
        assertThat(count("""
                SELECT count(*) FROM manager_permission_delegations granted
                JOIN permissions permission ON permission.id=granted.permission_id
                WHERE permission.code='workshop_material:count'""")).isZero();
        assertThat(str("SELECT action_type || ':' || grant_policy::text || ':' || baseline::text FROM permissions WHERE code='stock:count:submit'"))
                .isEqualTo("CREATE:{INDIVIDUAL_ONLY}:false");
        assertThat(count("""
                SELECT count(*) FROM (
                    SELECT permission_id FROM department_permissions
                    UNION ALL SELECT permission_id FROM manager_permission_delegations
                ) granted JOIN permissions permission ON permission.id=granted.permission_id
                WHERE permission.code='stock:count:submit'
                """)).isZero();

    }

    @Test
    void requisitionNumbersReservedGlobally() throws Exception {
        enable();
        UUID requisition = UUID.randomUUID();
        exec("""
                INSERT INTO workshop_material_requisitions(id, request_no, kind, origin, bin_warehouse_id,
                    workshop_department_id, requested_by)
                VALUES (?, 'ZL20260901000001', 'ISSUE', 'WORKSHOP_REQUEST', ?, ?, ?)""", requisition, BIN, injection, ACTOR);
        assertThat(count("SELECT count(*) FROM business_identifier_reservations WHERE normalized_identifier='ZL20260901000001'"))
                .isEqualTo(1);
        assertThat(count("""
                SELECT last_seq FROM business_document_sequences
                WHERE namespace_key='WORKSHOP_MATERIAL_ISSUE' AND sequence_date=DATE '2026-09-01'""")).isEqualTo(1);
        rejected("request_no is immutable", () -> exec("""
                UPDATE workshop_material_requisitions SET request_no='ZL20260901000002', row_version=row_version+1
                WHERE id=?""", requisition));
        rejected("kind is immutable", () -> exec(
                "UPDATE workshop_material_requisitions SET kind='RETURN', row_version=row_version+1 WHERE id=?", requisition));
        rejected("non-standard WORKSHOP_MATERIAL_ISSUE identifier", () -> requisition("ZX20260901000001", "ISSUE"));
        rejected("non-standard WORKSHOP_MATERIAL_ISSUE identifier", () -> requisition("ZT20260901000009", "ISSUE"));
        assertThatThrownBy(() -> requisition("ZL20260901000001", "ISSUE")).isInstanceOf(SQLException.class);
        requisition("ZT20260901000001", "RETURN");
        assertThat(count("""
                SELECT last_seq FROM business_document_sequences
                WHERE namespace_key='WORKSHOP_MATERIAL_RETURN' AND sequence_date=DATE '2026-09-01'""")).isEqualTo(1);
    }

    // -----------------------------------------------------------------
    // 夹具与工具
    // -----------------------------------------------------------------

    /** 一个已结算的期间: 产品一绑定颗粒 A, 9 月 3 日已审报工 100 件, 实际用量等于理论 1.25 千克。 */
    private UUID closedSinglePeriod() throws Exception {
        periodic(GRANULE, "OWN");
        edge(P1, GRANULE, "0.0125");
        UUID first = enable();
        UUID segment = segment(P1);
        start(segment);
        txIssue(first, GRANULE, "500", GO_LIVE, false, true);
        report(GO_LIVE.plusDays(2), 1, segment, "100");
        startCounting(first, GO_LIVE.plusDays(14));
        Count counted = txSubmit(first, GRANULE, "0", "500", "498.75");
        tx(() -> closeRows(first, counted.line(), "ALLOCATED", "1.25", "0", "1.25",
                List.<Object[]>of(allocation(segment, "1.25", "1.25", true))));
        return segment;
    }

    private void refreshObject(UUID segment, UUID event, UUID actor) throws SQLException {
        exec("""
                UPDATE stock_value_production_cost_objects SET business_refresh_event_id=?, business_refresh_actor_id=?,
                    business_refresh_pending=TRUE WHERE execution_segment_id=?""", event, actor, segment);
    }

    private static Object[] allocation(UUID scope, String basis, String allocated, boolean tail) {
        return new Object[]{scope, basis, allocated, tail};
    }

    private void closeRows(UUID period, UUID line, String outcome, String consumed, String loss, String theory,
                           List<Object[]> allocations) throws SQLException {
        closeRowsWithId(UUID.randomUUID(), period, line, outcome, consumed, loss, theory, allocations, null);
    }

    private void closeRowsWithId(UUID close, UUID period, UUID line, String outcome, String consumed, String loss,
                                 String theory, List<Object[]> allocations, UUID skipTheorySegment) throws SQLException {
        UUID material = UUID.randomUUID();
        exec("""
                INSERT INTO workshop_material_period_closes(id, period_id, close_no, trigger_kind, closed_by)
                VALUES (?, ?, (SELECT COALESCE(max(close_no), 0) + 1 FROM workshop_material_period_closes WHERE period_id=?),
                        'AFTER_COUNT', ?)""", close, period, period, ACTOR);
        exec("""
                INSERT INTO workshop_material_close_materials(id, close_id, period_line_id, cost_basis, theory_qty, outcome,
                    consumed_qty, loss_qty)
                VALUES (?, ?, ?, 'OWN', ?::numeric, ?, ?::numeric, ?::numeric)""",
                material, close, line, theory, outcome, consumed, loss);
        exec("""
                INSERT INTO workshop_material_close_theory_lines(close_id, close_material_id, report_item_id, report_id,
                    business_date, execution_segment_id, cost_scope_segment_id, product_goods_id, periodic_row_id,
                    output_qty_base, unit_weight, weight_source, theory_qty)
                SELECT ?, ?, theory.report_item_id, theory.report_id, theory.business_date, theory.execution_segment_id,
                       theory.cost_scope_segment_id, theory.product_goods_id, theory.periodic_row_id, theory.output_qty_base,
                       theory.unit_weight, theory.weight_source, theory.theory_qty
                FROM workshop_material_periods period
                CROSS JOIN LATERAL fn_workshop_material_period_theory(period.bin_warehouse_id, period.start_date,
                                                                      period.end_date) theory
                WHERE period.id=? AND theory.execution_segment_id IS DISTINCT FROM ?""",
                close, material, period, skipTheorySegment);
        for (Object[] allocation : allocations) {
            exec("""
                    INSERT INTO workshop_material_close_allocations(close_material_id, cost_scope_segment_id, basis_qty,
                        allocated_qty, is_tail)
                    VALUES (?, ?, ?::numeric, ?::numeric, ?)""", material, allocation[0], allocation[1], allocation[2],
                    allocation[3]);
        }
        exec("UPDATE workshop_material_periods SET status='CLOSED', row_version=row_version+1 WHERE id=?", period);
    }

    private UUID enable() throws Exception {
        UUID period = UUID.randomUUID();
        tx(() -> {
            insertSettings(injection, BIN, true);
            insertPeriod(period, 1, GO_LIVE);
        });
        return period;
    }

    private void insertSettings(UUID workshop, UUID bin, boolean enabled) throws SQLException {
        exec("""
                INSERT INTO workshop_material_settings(workshop_department_id, periodic_enabled, periodic_bin_warehouse_id,
                    go_live_date, enabled_by, enabled_at, created_by)
                VALUES (?, ?, ?, ?, ?, CASE WHEN ? THEN now() END, ?)""",
                workshop, enabled, bin, enabled ? GO_LIVE : null, enabled ? ACTOR : null, enabled, ACTOR);
    }

    private void disableSettings() throws SQLException {
        exec("""
                UPDATE workshop_material_settings SET periodic_enabled=FALSE, disabled_by=?, disabled_at=now(),
                    row_version=row_version+1 WHERE workshop_department_id=?""", ACTOR, injection);
    }

    private void insertPeriod(UUID period, int number, LocalDate start) throws SQLException {
        exec("""
                INSERT INTO workshop_material_periods(id, bin_warehouse_id, workshop_department_id, period_no, start_date,
                    created_by)
                VALUES (?, ?, ?, ?, ?, ?)""", period, BIN, injection, number, start, ACTOR);
    }

    private void countingPeriod(UUID period, LocalDate end) throws SQLException {
        exec("""
                UPDATE workshop_material_periods SET status='COUNTING', end_date=?, counting_started_by=?,
                    counting_started_at=now(), row_version=row_version+1 WHERE id=?""", end, ACTOR, period);
    }

    private UUID startCounting(UUID period, LocalDate end) throws Exception {
        UUID next = UUID.randomUUID();
        tx(() -> {
            countingPeriod(period, end);
            exec("""
                    INSERT INTO workshop_material_periods(id, bin_warehouse_id, workshop_department_id, period_no,
                        start_date, created_by)
                    SELECT ?, bin_warehouse_id, workshop_department_id, period_no + 1, ?, ?
                    FROM workshop_material_periods WHERE id=?""", next, end.plusDays(1), ACTOR, period);
        });
        return next;
    }

    private Count txSubmit(UUID period, UUID goods, String opening, String in, String closing) throws Exception {
        Count[] result = new Count[1];
        tx(() -> result[0] = submit(period, goods, opening, in, closing));
        return result[0];
    }

    private Count submit(UUID period, UUID goods, String opening, String in, String closing) throws SQLException {
        Count count = submitWithoutPosting(period, goods, opening, in, closing);
        BigDecimal actual = new BigDecimal(opening).add(new BigDecimal(in)).subtract(new BigDecimal(closing));
        LocalDate end = LocalDate.parse(str("SELECT end_date::text FROM workshop_material_periods WHERE id=?", period));
        UUID posting = null;
        if (actual.signum() > 0) {
            posting = countPosting(count.line(), count.count(), goods, "CONSUME", actual.toPlainString(), end, "SUBMIT", null);
        } else if (actual.signum() < 0) {
            posting = countPosting(count.line(), count.count(), goods, "GAIN", actual.negate().toPlainString(), end,
                    "SUBMIT", null);
        }
        return new Count(count.count(), count.line(), posting);
    }

    private Count submitWithoutPosting(UUID period, UUID goods, String opening, String in, String closing)
            throws SQLException {
        UUID count = UUID.randomUUID();
        UUID line = UUID.randomUUID();
        exec("INSERT INTO workshop_material_counts(id, period_id, version, created_by) VALUES (?, ?, 1, ?)",
                count, period, ACTOR);
        exec("""
                UPDATE workshop_material_counts SET status='SUBMITTED', submitted_by=?, submitted_at=now(),
                    row_version=row_version+1 WHERE id=?""", ACTOR, count);
        exec("""
                INSERT INTO workshop_material_period_lines(id, period_id, goods_id, unit_id, cost_basis, opening_qty,
                    transfer_in_qty, closing_qty)
                SELECT ?, ?, id, unit_id, periodic_cost_basis, ?::numeric, ?::numeric, ?::numeric FROM goods WHERE id=?""",
                line, period, opening, in, closing, goods);
        exec("UPDATE workshop_material_periods SET status='COUNTED', row_version=row_version+1 WHERE id=?", period);
        return new Count(count, line, null);
    }

    /** 更正盘点: 原版本作废、写新版本, 期间行改期末。返回新版本的盘点单。 */
    private UUID correctCount(UUID period, Count previous, String closing) throws SQLException {
        UUID version2 = UUID.randomUUID();
        exec("UPDATE workshop_material_counts SET status='SUPERSEDED', row_version=row_version+1 WHERE id=?",
                previous.count());
        exec("""
                INSERT INTO workshop_material_counts(id, period_id, version, created_by, correction_reason)
                VALUES (?, ?, 2, ?, '袋料少算了')""", version2, period, ACTOR);
        exec("""
                UPDATE workshop_material_counts SET status='SUBMITTED', submitted_by=?, submitted_at=now(),
                    row_version=row_version+1 WHERE id=?""", ACTOR, version2);
        exec("""
                UPDATE workshop_material_period_lines SET closing_qty=?::numeric, row_version=row_version+1
                WHERE id=?""", closing, previous.line());
        return version2;
    }

    private UUID countPosting(UUID line, UUID count, UUID goods, String kind, String qty, LocalDate end, String reason,
                              UUID reverses) throws SQLException {
        UUID posting = UUID.randomUUID();
        UUID movement = UUID.randomUUID();
        exec("""
                INSERT INTO workshop_material_count_postings(id, period_line_id, count_id, bin_warehouse_id, goods_id,
                    kind, reverses_posting_id, qty, business_date, reason, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?::numeric, ?, ?, ?)""",
                posting, line, count, BIN, goods, kind, reverses, qty, end, reason, ACTOR);
        int type = kind.startsWith("CONSUME") ? 21 : 22;
        int direction = kind.equals("CONSUME") || kind.equals("GAIN_REVERSE") ? -1 : 1;
        movement(movement, type, "WORKSHOP_MATERIAL_COUNT", count, line, goods, BIN, direction, qty);
        balance(BIN, goods, direction < 0 ? "-" + qty : qty);
        exec("UPDATE workshop_material_count_postings SET movement_id=? WHERE id=?", movement, posting);
        return posting;
    }

    private Issue txIssue(UUID period, UUID goods, String qty, LocalDate date, boolean supplement, boolean moveBalance)
            throws Exception {
        Issue[] result = new Issue[1];
        tx(() -> result[0] = issue(period, goods, qty, date, supplement, moveBalance));
        return result[0];
    }

    /** 仓库直接发料: 领料单 + 已审调拨单 (叶仓 -> 内料仓) + 两条流水 + 登记 + 调拨关联 (不提交)。 */
    private Issue issue(UUID period, UUID goods, String qty, LocalDate date, boolean supplement, boolean moveBalance)
            throws SQLException {
        UUID requisition = UUID.randomUUID();
        UUID line = UUID.randomUUID();
        UUID document = UUID.randomUUID();
        UUID item = UUID.randomUUID();
        UUID out = UUID.randomUUID();
        UUID in = UUID.randomUUID();
        UUID posting = UUID.randomUUID();
        int n = numbers.incrementAndGet();
        String requestNo = "ZL" + date.format(DateTimeFormatter.BASIC_ISO_DATE) + String.format("%06d", n);
        exec("""
                INSERT INTO workshop_material_requisitions(id, request_no, kind, origin, bin_warehouse_id,
                    workshop_department_id, requested_by)
                VALUES (?, ?, 'ISSUE', 'WORKSHOP_REQUEST', ?, ?, ?)""", requisition, requestNo, BIN, injection, ACTOR);
        exec("""
                INSERT INTO workshop_material_requisition_lines(id, requisition_id, line_no, goods_id, unit_id,
                    requested_qty, fulfilled_qty)
                VALUES (?, ?, 1, ?, ?, ?::numeric, 0)""", line, requisition, goods, KG, qty);
        exec("""
                INSERT INTO stock_documents(id, doc_type, bill_no, bill_date, warehouse_id, to_warehouse_id, status)
                VALUES (?, 'TRANSFER', ?, ?, ?, ?, 1)""", document, "DB740-" + n, date, LEAF, BIN);
        exec("""
                INSERT INTO stock_document_items(id, doc_id, bill_type, bill_no, bill_date, goods_id, unit_id, unit_rate,
                    qty, goods_snapshot_source)
                VALUES (?, ?, 'TRANSFER', ?, ?, ?, ?, 1, ?::numeric, 'MASTER_AT_SAVE')""",
                item, document, "DB740-" + n, date, goods, KG, qty);
        movement(out, 8, "STOCK_DOC", document, item, goods, LEAF, -1, qty);
        movement(in, 7, "STOCK_DOC", document, item, goods, BIN, 1, qty);
        if (moveBalance) {
            balance(BIN, goods, qty);
        }
        exec("""
                INSERT INTO workshop_material_stock_documents(stock_document_id, bin_warehouse_id, kind, requisition_id,
                    created_by)
                VALUES (?, ?, 'ISSUE', ?, ?)""", document, BIN, requisition, ACTOR);
        exec("""
                INSERT INTO workshop_material_requisition_postings(id, line_id, stock_document_item_id, leaf_warehouse_id,
                    bin_warehouse_id, goods_id, movement_id, qty, period_id, business_date, is_supplement,
                    supplement_reason, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?::numeric, ?, ?, ?, ?, ?)""",
                posting, line, item, LEAF, BIN, goods, in, qty, period, date, supplement,
                supplement ? "上一期漏录" : null, ACTOR);
        // Match the real stock gateway: only posted stock may advance fulfilled quantity.
        exec("UPDATE workshop_material_requisition_lines SET fulfilled_qty=?::numeric WHERE id=?", qty, line);
        exec("""
                UPDATE workshop_material_requisitions SET status='DONE', done_by=?, done_at=now(), row_version=row_version+1
                WHERE id=?""", ACTOR, requisition);
        return new Issue(requisition, line, document, item, in, posting);
    }

    private void requisition(String number, String kind) throws SQLException {
        exec("""
                INSERT INTO workshop_material_requisitions(request_no, kind, origin, bin_warehouse_id,
                    workshop_department_id, requested_by)
                VALUES (?, ?, 'WORKSHOP_REQUEST', ?, ?, ?)""", number, kind, BIN, injection, ACTOR);
    }

    private void movement(UUID id, int type, String sourceType, UUID document, UUID item, UUID goods, UUID warehouse,
                          int direction, String qty) throws SQLException {
        exec("""
                INSERT INTO stock_movements(id, transaction_date, movement_type, source_doc_type, source_doc_id,
                    source_item_id, goods_id, warehouse_id, direction, qty)
                VALUES (?, now(), ?, ?, ?, ?, ?, ?, ?, ?::numeric)""",
                id, type, sourceType, document, item, goods, warehouse, direction, qty);
    }

    private void balance(UUID warehouse, UUID goods, String delta) throws SQLException {
        exec("""
                INSERT INTO stock_balances(warehouse_id, goods_id, qty) VALUES (?, ?, ?::numeric)
                ON CONFLICT (warehouse_id, goods_id, color_id) DO UPDATE SET qty = stock_balances.qty + EXCLUDED.qty""",
                warehouse, goods, delta);
    }

    private UUID container(UUID machine, String name, String capacity) throws SQLException {
        UUID id = UUID.randomUUID();
        exec("""
                INSERT INTO workshop_machine_containers(id, machine_id, name, capacity_qty, created_by)
                VALUES (?, ?, ?, ?::numeric, ?)""", id, machine, name, capacity, ACTOR);
        return id;
    }

    private void containerLine(UUID count, String key, UUID machine, UUID container, String capacity, String level,
                               UUID goods, String weighed) throws SQLException {
        exec("""
                INSERT INTO workshop_material_count_lines(count_id, client_line_key, line_kind, goods_id, unit_id,
                    machine_id, container_id, capacity_qty_snapshot, fill_level, weighed_qty, entered_by)
                VALUES (?, ?, 'CONTAINER', ?, ?, ?, ?, ?::numeric, ?, ?::numeric, ?)""",
                count, key, goods, goods == null ? null : KG, machine, container, capacity, level, weighed, ACTOR);
    }

    private void switchFlag() throws SQLException {
        exec("SELECT set_config('app.workshop_material_issue_method_switch', 'on', true)");
    }

    private void switchTo(UUID goods, String method, String basis) throws SQLException {
        switchFlag();
        exec("UPDATE goods SET issue_method=?, periodic_cost_basis=? WHERE id=?", method, basis, goods);
    }

    private void periodic(UUID goods, String basis) throws Exception {
        tx(() -> switchTo(goods, "PERIODIC", basis));
    }

    private UUID edge(UUID product, UUID component, String qty) throws SQLException {
        UUID id = UUID.randomUUID();
        exec("""
                INSERT INTO goods_bom_items(id, goods_id, component_goods_id, qty, hard_gate, control_stage,
                                            consumption_basis, basis_output_qty)
                VALUES (?, ?, ?, ?::numeric, FALSE, 'START', 'PER_UNIT', 1)""", id, product, component, qty);
        return id;
    }

    private void orderEdge(UUID product, UUID component) throws SQLException {
        exec("""
                INSERT INTO goods_bom_items(goods_id, component_goods_id, qty, hard_gate, control_stage,
                                            consumption_basis, basis_output_qty)
                VALUES (?, ?, 1, TRUE, 'START', 'PER_UNIT', 1)""", product, component);
    }

    private UUID choose(UUID product, UUID material, boolean alsoOrder) throws SQLException {
        UUID id = UUID.randomUUID();
        exec("""
                INSERT INTO goods_periodic_material_choices(id, product_goods_id, kind, material_goods_id,
                                                            also_order_materials, chosen_by, chosen_workshop_department_id)
                VALUES (?, ?, 'MATERIAL', ?, ?, ?, ?)""", id, product, material, alsoOrder, ACTOR, injection);
        return id;
    }

    private void chooseNone(UUID product) throws SQLException {
        exec("""
                INSERT INTO goods_periodic_material_choices(product_goods_id, kind, chosen_by)
                VALUES (?, 'NONE', ?)""", product, ACTOR);
    }

    private UUID segment(UUID product) throws Exception {
        UUID id = UUID.randomUUID();
        int n = numbers.incrementAndGet();
        replica(() -> exec("""
                INSERT INTO production_execution_segments(id, package_id, plan_id, source_plan_item_id, segment_no,
                    segment_code, client_segment_key, product_goods_id, product_unit_id, product_unit_rate, planned_qty,
                    status, workshop_department_id, bom_fingerprint, idempotency_key)
                VALUES (?, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), ?, ?, ?, ?, ?, 1, 20000, 'READY', ?,
                        repeat('a', 64), ?)""",
                id, n, "ZX740-" + n, "segment-" + n, product, PCS, injection, "wm740-segment-" + n));
        return id;
    }

    private void zeroSegment(UUID product, String reason, UUID analysis, UUID plan, UUID planItem) throws Exception {
        int n = numbers.incrementAndGet();
        replica(() -> exec("""
                INSERT INTO production_execution_segments(package_id, plan_id, source_plan_item_id, segment_no,
                    segment_code, client_segment_key, product_goods_id, product_unit_id, product_unit_rate, planned_qty,
                    status, workshop_department_id, bom_fingerprint, idempotency_key, material_requirement_mode,
                    zero_material_reason, zero_material_analysis_id)
                VALUES (gen_random_uuid(), COALESCE(?, gen_random_uuid()), COALESCE(?, gen_random_uuid()), ?, ?, ?, ?, ?,
                        1, 100, 'READY', ?, repeat('a', 64), ?, 'ZERO_MATERIAL', ?, ?)""",
                plan, planItem, n, "ZX740-" + n, "segment-" + n, product, PCS, injection, "wm740-segment-" + n, reason,
                analysis));
    }

    private void start(UUID segment) throws SQLException {
        exec("UPDATE production_execution_segments SET status='IN_PROGRESS' WHERE id=?", segment);
    }

    private String state(UUID segment) throws SQLException {
        return str("SELECT fn_segment_bin_material_state(?)", segment);
    }

    private UUID demand(UUID segment, UUID goods, String status) throws Exception {
        UUID id = UUID.randomUUID();
        replica(() -> exec("""
                INSERT INTO production_material_demands(id, package_id, plan_id, warehouse_id, goods_id, unit_id,
                    required_qty, supply_route, status, idempotency_key, execution_segment_id, source_plan_item_id,
                    per_product_qty)
                VALUES (?, gen_random_uuid(), gen_random_uuid(), ?, ?, ?, 100, 'BUY', ?, ?, ?, gen_random_uuid(), 1)""",
                id, LEAF, goods, KG, status, "wm740-demand-" + id, segment));
        return id;
    }

    private void stockPosting(UUID demand, String type, String qty) throws Exception {
        UUID event = UUID.randomUUID();
        replica(() -> {
            exec("""
                    INSERT INTO production_material_stock_events(id, stock_document_id, event_type, idempotency_key,
                                                                 request_hash)
                    VALUES (?, gen_random_uuid(), ?, ?, repeat('b', 64))""", event, type, "wm740-stock-" + event);
            exec("""
                    INSERT INTO production_material_stock_postings(event_id, stock_document_item_id, demand_id,
                                                                   reservation_id, posting_type, qty_base)
                    VALUES (?, gen_random_uuid(), ?, gen_random_uuid(), ?, ?::numeric)""", event, demand, type, qty);
        });
    }

    private void settlement(UUID demand, String type, String qty) throws Exception {
        UUID event = UUID.randomUUID();
        replica(() -> {
            exec("""
                    INSERT INTO production_material_settlement_events(id, plan_id, event_type, idempotency_key, request_hash)
                    VALUES (?, gen_random_uuid(), 'POST', ?, repeat('c', 64))""", event, "wm740-settle-" + event);
            exec("""
                    INSERT INTO production_material_settlement_postings(event_id, demand_id, settlement_type, qty_base)
                    VALUES (?, ?, ?, ?::numeric)""", event, demand, type, qty);
        });
    }

    private UUID report(LocalDate date, int status, UUID segment, String qty) throws SQLException {
        UUID header = reportHeader(date, status);
        reportItem(header, segment, qty);
        return header;
    }

    private UUID reportHeader(LocalDate date, int status) throws SQLException {
        UUID id = UUID.randomUUID();
        exec("INSERT INTO production_daily_reports(id, bill_no, bill_date, status) VALUES (?, ?, ?, ?)",
                id, "RB740-" + numbers.incrementAndGet(), date, status);
        return id;
    }

    private void reportItem(UUID report, UUID segment, String qty) throws SQLException {
        exec("""
                INSERT INTO production_daily_report_items(bill_no, bill_date, report_id, goods_id, unit_rate, qty,
                                                          execution_segment_id)
                SELECT header.bill_no, header.bill_date, header.id, segment.product_goods_id, 1, ?::numeric, segment.id
                FROM production_daily_reports header, production_execution_segments segment
                WHERE header.id=? AND segment.id=?""", qty, report, segment);
    }

    // ---- JDBC helpers ----

    interface Work {
        void run() throws Exception;
    }

    private void tx(Work work) throws Exception {
        db.setAutoCommit(false);
        try {
            work.run();
            db.commit();
        } catch (Exception failure) {
            db.rollback();
            throw failure;
        } finally {
            db.setAutoCommit(true);
        }
    }

    private void replica(Work work) throws Exception {
        exec("SET session_replication_role = replica");
        work.run();
        exec("SET session_replication_role = origin");
    }

    private void rejected(String fragment, Work work) {
        assertThatThrownBy(() -> tx(work)).isInstanceOf(SQLException.class).hasMessageContaining(fragment);
        try {
            exec("SET session_replication_role = origin");
        } catch (SQLException failure) {
            throw new IllegalStateException(failure);
        }
    }

    private void exec(String sql, Object... args) throws SQLException {
        try (PreparedStatement statement = db.prepareStatement(sql)) {
            bind(statement, args);
            statement.execute();
        }
    }

    private String str(String sql, Object... args) throws SQLException {
        try (PreparedStatement statement = db.prepareStatement(sql)) {
            bind(statement, args);
            try (ResultSet rows = statement.executeQuery()) {
                return rows.next() ? rows.getString(1) : null;
            }
        }
    }

    private UUID uuid(String sql, Object... args) throws SQLException {
        String value = str(sql, args);
        return value == null ? null : UUID.fromString(value);
    }

    private long count(String sql, Object... args) throws SQLException {
        return Long.parseLong(str(sql, args));
    }

    private void assertNum(String sql, String expected, Object... args) throws SQLException {
        assertThat(new BigDecimal(str(sql, args))).isEqualByComparingTo(expected);
    }

    private static void bind(PreparedStatement statement, Object... args) throws SQLException {
        for (int i = 0; i < args.length; i++) {
            statement.setObject(i + 1, args[i]);
        }
    }

    private static UUID id(int n) {
        return UUID.fromString(String.format("00000000-0000-4740-8000-%012x", n));
    }

    private static Flyway flyway(String target) {
        var configuration = Flyway.configure()
                .dataSource(TEMPLATE.getJdbcUrl(), TEMPLATE.getUsername(), TEMPLATE.getPassword())
                .locations("classpath:db/migration");
        return (target == null ? configuration : configuration.target(target)).load();
    }

    private static Connection template() throws SQLException {
        return DriverManager.getConnection(TEMPLATE.getJdbcUrl(), TEMPLATE.getUsername(), TEMPLATE.getPassword());
    }

    private static UUID department(Connection connection, String code) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("SELECT id FROM departments WHERE code=?")) {
            statement.setString(1, code);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                return rows.getObject(1, UUID.class);
            }
        }
    }

    private static void warehouse(PreparedStatement insert, UUID id, String code, String name, UUID parent,
                                  boolean lineSide, UUID workshop, boolean auto, int daysAgo) throws SQLException {
        insert.setObject(1, id);
        insert.setString(2, code);
        insert.setString(3, name);
        insert.setObject(4, parent);
        insert.setBoolean(5, lineSide);
        insert.setObject(6, workshop);
        insert.setBoolean(7, auto);
        insert.setInt(8, daysAgo);
        insert.executeUpdate();
    }

    private static void goods(PreparedStatement insert, UUID id, String code, String name, UUID unit, long sequence)
            throws SQLException {
        insert.setObject(1, id);
        insert.setString(2, code);
        insert.setString(3, name);
        insert.setObject(4, unit);
        insert.setLong(5, sequence);
        insert.executeUpdate();
    }
}
