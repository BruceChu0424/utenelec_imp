package com.uten.imp.ops;

import com.uten.imp.migration.MigrationRehearsalSupport;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 工作台「系统测试 · 清空业务数据」三处事实的同步锁：
 * <ol>
 *   <li>ops/reset_business_data.sql（psql 停机版）的全量 CLEAR/PRESERVE 分类；</li>
 *   <li>迁移函数 business_data_reset()（应用内运行的孪生；V464 为最新整函数重发版，
 *       V462 为历史首版）的同一份分类。V474 起经运行时补丁插入
 *       {@link #RUNTIME_RESET_EXTENSIONS} 登记的扩展行（已应用的 V464 字节不可改）；</li>
 *   <li>BusinessDataResetService 只做编排（绑定 actor + 调函数），不内联清空 SQL。</li>
 * </ol>
 * 迁移新增表后必须同步两份清单，否则本测试失败关闭；运行时未知表同样拒绝执行。
 */
class BusinessDataResetSqlContractTest {

    private static final Pattern POLICY_ROW = Pattern.compile(
            "\\('([a-z][a-z0-9_]*)'\\s*,\\s*'(CLEAR|PRESERVE)'\\)");

    /**
     * V474 起经「读取已安装函数定义 + 失败关闭锚点替换」插入孪生函数的扩展行。
     * 表名 -> 引入迁移版本号；新增扩展时同步登记，并保持 ops 脚本与补丁锚点一致。
     */
    private static final Map<String, Integer> RUNTIME_RESET_EXTENSIONS = Map.ofEntries(
            Map.entry("preplan_public_supply_events", 474),
            Map.entry("preplan_root_output_events", 478),
            Map.entry("sales_order_qty_change_logs", 484),
            Map.entry("procurement_order_qty_change_logs", 486),
            Map.entry("sales_order_revision_logs", 492),
            Map.entry("preplan_subcontract_make_batch_reversals", 496),
            Map.entry("stock_value_pools", 504),
            Map.entry("stock_value_events", 504),
            Map.entry("stock_value_nodes", 504),
            Map.entry("stock_value_edges", 504),
            Map.entry("stock_value_jobs", 504),
            Map.entry("stock_value_tasks", 504),
            Map.entry("stock_value_node_revisions", 504),
            Map.entry("stock_value_postings", 504),
            Map.entry("procurement_order_source_revisions", 504),
            Map.entry("procurement_order_source_revision_allocations", 504),
            Map.entry("procurement_order_source_revision_peg_changes", 504),
            Map.entry("stock_value_openings", 506),
            Map.entry("stock_value_legacy_balance_cases", 506),
            Map.entry("stock_value_legacy_balance_case_events", 506),
            Map.entry("sales_shipment_submission_events", 519),
            Map.entry("production_material_movement_links", 514),
            Map.entry("production_material_return_requests", 560),
            Map.entry("production_material_return_request_items", 560),
            Map.entry("production_material_return_request_cancellations", 560),
            Map.entry("production_execution_segment_splits", 561),
            Map.entry("preplan_reallocation_make_supplements", 568),
            Map.entry("preplan_future_supply_transfers", 569),
            Map.entry("preplan_future_supply_transfer_cancellations", 569),
            Map.entry("stock_value_acquisition_sources", 517),
            Map.entry("stock_value_position_transfers", 517),
            Map.entry("stock_value_production_cost_dirty", 517),
            Map.entry("stock_value_production_cost_inputs", 517),
            Map.entry("stock_value_production_cost_objects", 517),
            Map.entry("stock_value_production_cost_outputs", 517),
            Map.entry("stock_value_production_cost_revisions", 517),
            Map.entry("stock_value_production_cost_shares", 517),
            Map.entry("stock_value_production_cost_tasks", 517),
            Map.entry("procurement_iqc_consideration_reversals", 518),
            Map.entry("procurement_iqc_consideration_review_approvals", 518),
            Map.entry("procurement_iqc_credit_case_allocations", 518),
            Map.entry("procurement_iqc_credit_documents", 518),
            Map.entry("procurement_iqc_credit_slices", 518),
            Map.entry("procurement_iqc_funding_settlements", 518),
            Map.entry("procurement_iqc_funding_slices", 518),
            Map.entry("procurement_iqc_quality_consideration_parts", 518),
            Map.entry("procurement_iqc_stock_consideration_parts", 518),
            Map.entry("procurement_receipt_consideration_parts", 518),
            Map.entry("subcontract_receipt_material_consumptions", 522),
            Map.entry("production_fqc_inspection_sheets", 547),
            Map.entry("production_fqc_inspection_sheet_items", 547),
            Map.entry("production_finished_arrival_registration_reversals", 548),
            // V583/V584 建表时漏登记，V586 统一补进清库策略（四张都是纯业务事实）。
            Map.entry("production_daily_report_material_usages", 586),
            Map.entry("production_workshop_direct_transfer_items", 586),
            Map.entry("production_workshop_direct_transfer_reversals", 586),
            Map.entry("production_workshop_direct_transfers", 586),
            Map.entry("expense_claim_events", 608),
            Map.entry("expense_claim_invoices", 608),
            Map.entry("production_daily_report_target_events", 614),
            Map.entry("production_daily_report_material_release_events", 614),
            Map.entry("production_workshop_direct_source_allocations", 615),
            Map.entry("production_workshop_direct_source_events", 615),
            Map.entry("production_workshop_direct_legacy_anomalies", 615),
            Map.entry("production_material_return_receiving_confirmations", 618),
            Map.entry("production_workshop_material_return_slices", 619),
            Map.entry("production_workshop_material_custody_preparations", 619),
            Map.entry("production_workshop_material_custody_moves", 619),
            Map.entry("production_workshop_material_custody_reversals", 619),
            Map.entry("production_workshop_material_custody_handoffs", 619),
            Map.entry("production_workshop_custody_handoff_reversals", 619),
            Map.entry("production_workshop_custody_reverse_preparations", 619),
            Map.entry("production_workshop_return_preplan_events", 619));

    /**
     * V579 起 PRESERVE 语义的运行时扩展(基础资料子表随主档保留)。
     * 同样走「读取已安装函数定义 + 锚点替换插入」补丁；与 CLEAR 扩展分开登记，
     * ops 脚本与 V579 补丁锚点保持一致。
     */
    private static final Map<String, Integer> PRESERVE_RESET_EXTENSIONS = Map.of(
            "legacy_subcontract_order_import_sources", 624,
            "legacy_finance_import_sources", 626,
            "legacy_procurement_receipt_import_sources", 627,
            "expense_claim_settings", 617,
            "party_activity_records", 579,
            "party_addresses", 579,
            "party_contact_methods", 579);

    /**
     * V590 起整表废弃并从清空策略移除的表（「读取已安装定义 + 锚点替换删除」
     * 补丁）。新增删除时同步登记，并保持 ops 脚本与 V590 补丁锚点一致。
     */
    private static final Map<String, Integer> REMOVED_RESET_TABLES = Map.of(
            "production_goods_workshop_preferences", 590);

    private String opsScript;
    private String migrationSql;
    private String serviceSource;
    private String extensionSql;

    @BeforeEach
    void loadSources() throws IOException {
        opsScript = read(Path.of("ops", "reset_business_data.sql"),
                Path.of("server", "ops", "reset_business_data.sql"));
        migrationSql = read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V464__reset_twin_order_item_sources.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V464__reset_twin_order_item_sources.sql"));
        extensionSql = read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V474__preplan_public_supply_and_inbound_allocation.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V474__preplan_public_supply_and_inbound_allocation.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V478__analysis_root_supply_fulfillment.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V478__analysis_root_supply_fulfillment.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V484__sales_qty_change_reset_extension.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V484__sales_qty_change_reset_extension.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V486__procurement_qty_change_and_preparation_retirement.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V486__procurement_qty_change_and_preparation_retirement.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V492__sales_order_commercial_revisions.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V492__sales_order_commercial_revisions.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V496__subcontract_make_notification_reversals.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V496__subcontract_make_notification_reversals.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V504__inventory_and_procurement_revision_reset_policy.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V504__inventory_and_procurement_revision_reset_policy.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration", "V514__production_material_exact_movement_links.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration", "V514__production_material_exact_movement_links.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration", "V517__inventory_value_custody_positions.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration", "V517__inventory_value_custody_positions.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration", "V518__procurement_iqc_replacement_consideration.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration", "V518__procurement_iqc_replacement_consideration.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration", "V519__financial_actual_amounts_and_book_allocations.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration", "V519__financial_actual_amounts_and_book_allocations.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration", "V522__subcontract_own_material_cost_sources.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration", "V522__subcontract_own_material_cost_sources.sql"));
        serviceSource = read(
                Path.of("src", "main", "java", "com", "uten", "imp", "features", "admin",
                        "systemtest", "BusinessDataResetService.java"),
                Path.of("server", "src", "main", "java", "com", "uten", "imp", "features",
                        "admin", "systemtest", "BusinessDataResetService.java"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V506__inventory_value_openings_and_legacy_cases.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V506__inventory_value_openings_and_legacy_cases.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V547__production_fqc_inspection_sheets.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V547__production_fqc_inspection_sheets.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V548__production_finished_arrival_registration_reversal.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V548__production_finished_arrival_registration_reversal.sql"));
        for (String migration : java.util.List.of("V560__production_material_return_requests.sql", "V561__production_execution_batch_splits.sql", "V568__preplan_reallocation_make_supplements.sql", "V569__preplan_future_supply_transfers.sql")) {
            extensionSql += read(Path.of("src", "main", "resources", "db", "migration", migration),
                    Path.of("server", "src", "main", "resources", "db", "migration", migration));
        }
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V579__party_contact_address_activity.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V579__party_contact_address_activity.sql"));
        // V586 补登记 V583 报工实耗表与 V584 车间直送三张表（建表迁移漏了这一步，
        // 清库函数 fail-closed 会直接拒绝执行，com.uten.imp.ops.** 整包红）。
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V586__reset_policy_daily_report_usage_and_direct_transfer.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V586__reset_policy_daily_report_usage_and_direct_transfer.sql"));
        extensionSql += read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V590__goods_owning_workshop_consolidation.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V590__goods_owning_workshop_consolidation.sql"));
        for (String migration : List.of("V608__expense_claim_fullchain.sql",
                "V614__daily_report_finalization_provenance.sql",
                "V615__workshop_direct_source_allocation.sql",
                "V617__expense_claim_evidence_and_settings.sql",
                "V618__production_material_return_receiving_warehouse.sql",
                "V619__workshop_material_normal_warehouse_custody.sql",
                "V624__legacy_subcontract_settlement_provenance.sql",
                "V626__legacy_finance_source_provenance.sql",
                "V627__legacy_receipt_consideration_provenance.sql")) {
            extensionSql += read(Path.of("src/main/resources/db/migration",migration),
                    Path.of("server/src/main/resources/db/migration",migration));
        }
    }

    @Test
    void appTwinFunctionClassifiesExactlyTheOpsScriptTables() {
        Map<String, String> opsPolicy = policy(opsScript);
        Map<String, String> twinPolicy = policy(migrationSql);

        assertThat(opsPolicy).hasSize(
                320 + RUNTIME_RESET_EXTENSIONS.size() + PRESERVE_RESET_EXTENSIONS.size()
                        - REMOVED_RESET_TABLES.size());
        assertThat(opsPolicy.values().stream().filter("CLEAR"::equals).count())
                .isEqualTo(224 + RUNTIME_RESET_EXTENSIONS.size());
        assertThat(opsPolicy.values().stream().filter("PRESERVE"::equals).count())
                .isEqualTo(96 + PRESERVE_RESET_EXTENSIONS.size()
                        - REMOVED_RESET_TABLES.size());

        // V464 基础清单逐表一致：任何一侧漂移（新增/删除/改分类）都失败关闭。
        // V590 起废弃表从两侧同时移除（twin 基线文件按历史字节保留，比较前扣除）。
        Map<String, String> opsBase = new LinkedHashMap<>(opsPolicy);
        RUNTIME_RESET_EXTENSIONS.keySet().forEach(opsBase::remove);
        PRESERVE_RESET_EXTENSIONS.keySet().forEach(opsBase::remove);
        Map<String, String> twinExpected = new LinkedHashMap<>(twinPolicy);
        REMOVED_RESET_TABLES.keySet().forEach(twinExpected::remove);
        assertThat(twinExpected).isEqualTo(opsBase);
        // 扩展行必须全部 CLEAR：追加式运行时事件账随系统测试一并清空。
        RUNTIME_RESET_EXTENSIONS.keySet().forEach(table ->
                assertThat(opsPolicy.get(table))
                        .as(table + " runtime reset extension must be CLEAR")
                        .isEqualTo("CLEAR"));
        // 废弃表必须真的不在两侧策略里。
        REMOVED_RESET_TABLES.keySet().forEach(table ->
                assertThat(opsPolicy).as(table + " was retired by V590").doesNotContainKey(table));
    }

    @Test
    void rootSupplyForwardFixAcceptsV479WithoutAddingAnotherBusinessTable() {
        assertThat(opsScript)
                .contains("(478, 440)")
                .contains("(479, 441)")
                .contains("(480, 442)")
                .contains("(481, 443)")
                .contains("(482, 444)")
                // V483 审计窄修 + V484 运行时清空扩展：均不新增表（444→446）。
                .contains("(483, 445)")
                .contains("(484, 446)")
                // V485 进行中工作台单趟聚合：不新增表（446→447）。
                .contains("(485, 447)")
                .contains("(486, 448)")
                // V488 偏好表补列、V489/V490 换函数、V491 报工门控：均不新增表。
                .contains("(487, 449)")
                .contains("(488, 450)")
                .contains("(489, 451)")
                .contains("(490, 452)")
                .contains("(491, 453)")
                .contains("V484/446、V485/447、V486/448、V487/449、V488/450")
                .contains("(492, 454)")
                .contains("(493, 455)")
                .contains("(494, 456)")
                .contains("(495, 457)")
                .contains("(496, 458)")
                .contains("(497, 459)")
                .contains("(498, 460)")
                .contains("(499, 461)")
                .contains("(500, 462)")
                .contains("(501, 463)")
                .contains("(502, 464)")
                .contains("(503, 465)")
                .contains("(504, 466)")
                .contains("(505, 467)")
                .contains("(506, 468)")
                .contains("(507, 469)")
                .contains("(508, 470)")
                .contains("(527, 486)")
                .contains("(528, 487)")
                .contains("(529, 488)")
                .contains("(530, 489)")
                .contains("(531, 490)")
                .contains("(532, 491)")
                .contains("(533, 492)")
                .contains("(534, 493)")
                .contains("(535, 494)")
                .contains("(536, 495)")
                .contains("(537, 496)")
                .contains("(538, 497)")
                .contains("(539, 498)")
                .contains("(540, 499)")
                .contains("(541, 500)")
                .contains("(545, 503)")
                .contains("(547, 505)")
                .contains("(548, 506)")
                .contains("(549, 507)")
                .contains("(550, 508)")
                .contains("(551, 509)")
                // V552 只加权限码与默认授权，不新增业务表；但迁移头一动，
                // 清库脚本的 fail-closed 白名单就必须跟着动，否则脚本拒跑。
                .contains("(555, 513)")
                .contains("(556, 514)")
                .contains("(557, 515)")
                .contains("(558, 516)")
                .contains("(559, 517)")
                .contains("(560, 518)")
                .contains("(561, 519)")
                .contains("(562, 520)")
                .contains("(569, 527)")
                .contains("(570, 528)")
                .contains("(571, 529)")
                .contains("(572, 530)")
                // V573 放宽原因 CHECK、V574 跨路线在途调入与两条索引、
                // V575 货品起订量与订货倍数：三者都不新增业务表（530→533）。
                .contains("(573, 531)")
                .contains("(574, 532)")
                .contains("(575, 533)")
                // V577 下达车间超量的公共备货产出分账：只给计划关联行加一列 +
                // 改一个触发器，不新增业务表（533→534）。V576 由并行分支占用。
                .contains("(577, 534)")
                .contains("(578, 535)")
                .contains("(579, 536)")
                // V580 只放宽计划关联行对账(公共备货单可不带销售来源)，不加表。
                // V581 只扩委外发料计划行的 flow_mode 白名单与四个既有守卫，不加表。
                .contains("(581, 538)")
                // V582 只收窄销售出货仓库作业状态取值并重建触发器/索引/视图，不加表。
                .contains("(582, 539)")
                // V583 报工同页登记实际用料：新增 1 张表(539→540)。
                .contains("(583, 540)")
                // V584 车间直送：新增 3 张表(540→541)+ 线边仓/去向/检验种类三个列。
                .contains("(584, 541)")
                // V585 只加报工行接收需求列 + 一个审核权限码，不加表。
                .contains("(585, 542)")
                // V586 只补清库策略登记，不新增业务表；版本对的第二个数是迁移
                // 文件条数，本迁移本身让它 542→543。
                .contains("(586, 543)")
                .contains("(587, 544)")
                .contains("(588, 545)")
                .contains("(589, 546)")
                // V590 货品归属收敛：偏好表废弃删除（PRESERVE 96→95），条数 546→547。
                .contains("(590, 547)")
                // V591 存量归属回填：只 UPDATE 不加表（547→548）。
                .contains("(591, 548)")
                // V592 客户默认销售条款：clients 只加两列不加表（548→549）。
                .contains("(592, 549)")
                // V593 采购/委外链主档默认值：只加列不加表（549→550）。
                .contains("(593, 550)")
                // V594 日报审核补链放行：只替换只增不改守卫函数体，不加表（550→551）。
                .contains("(594, 551)")
                // V595 车间直送 v2：只加列/改函数/改视图列/加索引，不加表（551→552）。
                .contains("(595, 552)")
                // V598 货品来源按路线确认历史回填：只 UPDATE 一列不加表 (552->553)。
                // V596 到货先入库后质检：只加列/事件动作/批次来源/权限码，不加表(552→553)。
                .contains("(596, 553)")
                // V597 产成品先入库后质检：只加列/守卫/权限码，不加表(553→554)。
                .contains("(597, 554)")
                .contains("(598, 555)")
                .contains("(599, 556)")
                .contains("(600, 557)")
                // V601 通知已读回填 / V602 路线记忆索引：不加表（557→559）。
                .contains("(601, 558)")
                .contains("(602, 559)")
                // V603 访客黑名单三列：不加表（559→560）；V604 未发布跳号。
                .contains("(603, 560)")
                // V605 直送资格收紧 / V606 路线自动识别：只换函数+回填，不加表（560→562）。
                .contains("(605, 561)")
                .contains("(606, 562)")
                .contains("V507/469、V508/470及V511至V630完整目录");
        assertThat(RUNTIME_RESET_EXTENSIONS)
                .containsEntry("preplan_root_output_events", 478)
                .containsEntry("sales_order_qty_change_logs", 484);
    }

    @Test
    void runtimeResetExtensionsPatchTheTwinFunctionFailClosed() {
        // V474 的补丁构件：读取已安装定义、锚点替换插入、锚点缺失即失败关闭。
        assertThat(extensionSql)
                .contains("pg_get_functiondef('business_data_reset()'::regprocedure)")
                .contains("RAISE EXCEPTION 'V474 cannot extend business_data_reset policy safely'")
                .contains("(''preplan_supply_actions'', ''CLEAR'')");
        for (String table : RUNTIME_RESET_EXTENSIONS.keySet()) {
            assertThat(extensionSql)
                    .as(table + " must be inserted by the runtime reset patch")
                    .contains("'" + table + "'");
        }
        // V579：PRESERVE 语义扩展同样走补丁(基础资料子表随主档保留)。
        assertThat(extensionSql)
                .contains("RAISE EXCEPTION 'V579 cannot extend business_data_reset policy safely'")
                .contains("(''party_contact_methods'', ''PRESERVE'')");
        // V590：整表废弃走「读已安装定义 + 锚点替换删除」补丁；锚点单行无换行，
        // 不受迁移文件 CRLF/LF 差异影响（V588 教训）。
        assertThat(extensionSql)
                .contains("RAISE EXCEPTION 'V590 cannot drop retired preference policy row from business_data_reset'")
                .contains("(''production_goods_workshop_preferences'', ''PRESERVE''),");
    }

    @Test
    void appTwinKeepsOpsFailClosedChecksAndAddsKickAll() {
        // 与 ops 版同款失败关闭构件
        assertThat(migrationSql)
                .contains("存在未分类 public 表")
                .contains("表分类重复/重叠")
                .contains("保留表仍引用待清业务表，禁止清空")
                .contains("EXECUTE 'TRUNCATE TABLE ' || clear_tables || ' RESTART IDENTITY'")
                .contains("清空校验失败")
                .contains("保留校验失败")
                .contains("物化视图清空校验失败")
                .contains("账户金额归零校验失败")
                .contains("遗留期初归零校验失败")
                .contains("货品安全库存/成本预算归零校验失败")
                .contains("USING ERRCODE = 'UT900'")
                .contains("REFRESH MATERIALIZED VIEW purchase_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW production_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW stock_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW finance_ar_ap_mv")
                .contains("REFRESH MATERIALIZED VIEW sales_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW subcontract_monthly_mv")
                .contains("UPDATE accounts")
                .contains("balance_current = 0")
                .contains("UPDATE payment_styles")
                .contains("init_balance = 0")
                .doesNotContain("DISABLE TRIGGER");

        // 应用内孪生独有的收尾：全员强制重新登录（epoch + 1 / 断续期）
        assertThat(migrationSql)
                .contains("UPDATE authorization_state")
                .contains("epoch = epoch + 1")
                .contains("TRUNCATE TABLE refresh_tokens RESTART IDENTITY");

        // 摘要出参：服务层据此回显
        assertThat(migrationSql)
                .contains("cleared_table_count INT")
                .contains("cleared_rows BIGINT")
                .contains("preserved_table_count INT")
                .contains("authorization_epoch_after BIGINT");
    }

    @Test
    void serviceOrchestratesOnlyAndBindsActorParameters() {
        // 服务层只编排：调用函数、绑定 actor（? 参数）、设置事务级超时；
        // 清空 SQL 全部在迁移函数里（安全写入门不允许 Java 内联此类 SQL）。
        assertThat(serviceSource)
                .contains("FROM business_data_reset()")
                .contains("SELECT set_config('app.actor_id', ?, true)")
                .contains("SET LOCAL lock_timeout = '15s'")
                .contains("SET LOCAL statement_timeout = '30min'")
                .doesNotContain("TRUNCATE TABLE")
                .doesNotContain("DO $$");
        // 编排门禁与排水
        assertThat(serviceSource)
                .contains("featureGate.requireEnabled()")
                .contains("drainGate.beginDrain")
                .contains("drainGate.endReset()");
    }

    /**
     * <b>迁移头一动，清库脚本的 fail-closed 白名单就必须跟着动。</b>
     *
     * <p>这条耦合被踩过不止一次（2026-09-11 加 V552 时 CI 后端整条挂掉：
     * {@code 仅允许 ...及V511至V551完整目录，当前 V552/510}）。上面那串
     * {@code .contains("(NNN, MMM)")} 断言只能证明「写了什么」，证明不了
     * 「有没有漏写最新那条」——所以这里**从迁移目录算出真实的迁移头**再比对，
     * 漏了就当场报出该补哪一行，不用等跑到真实库才发现。
     *
     * <p>注意版本对是 (Flyway 版本号, 已应用迁移条数)，两者因跳号（如 V544 未发布）
     * 并不相等；条数只能由目录里实际存在的 .sql 个数数出来。
     */
    @Test
    void resetScriptAllowlistCoversTheCurrentMigrationHead() throws IOException {
        Path migrations = resolve(
                Path.of("src", "main", "resources", "db", "migration"),
                Path.of("server", "src", "main", "resources", "db", "migration"));
        int head = 0;
        int count = 0;
        try (var files = Files.list(migrations)) {
            for (Path file : files.toList()) {
                Matcher matcher = MIGRATION_FILE.matcher(file.getFileName().toString());
                if (!matcher.matches()) continue;
                count++;
                head = Math.max(head, Integer.parseInt(matcher.group(1)));
            }
        }
        assertThat(head).as("迁移目录里没找到任何 V*.sql").isGreaterThan(0);

        String expected = "(" + head + ", " + count + ")";
        assertThat(opsScript)
                .as("""
                        ops/reset_business_data.sql 的迁移头白名单没有覆盖当前迁移头。
                        请在版本对列表末尾补上 %s，并把异常文案里的上界改成 V%d。
                        （新增迁移就必须同步这张表，否则整个清库脚本 fail-closed 拒跑。）"""
                        .formatted(expected, head))
                .contains(expected);
        assertThat(opsScript)
                .as("异常文案里的上界也要同步到 V%d".formatted(head))
                .contains("及V511至V" + head + "完整目录");

        // 同一条耦合的第三处：迁移演练 / 引导兼容性用例把迁移头钉成两个常量。
        // 2026-09-11 就是漏了它，CI 后端又挂一轮（expected 509 but was 510）。
        String rehearsal = read(
                Path.of("src", "test", "java", "com", "uten", "imp", "migration",
                        "MigrationRehearsalSupport.java"),
                Path.of("server", "src", "test", "java", "com", "uten", "imp", "migration",
                        "MigrationRehearsalSupport.java"));
        // 2026-09-16 起 MigrationRehearsalSupport 从 classpath db/migration 目录自动推导这两个常量
        //（目录是唯一事实源）；旧式手写常量仍被接受，但必须与目录头一致。
        if (rehearsal.contains("CURRENT_HEAD_VERSION = Integer.toString(head)")) {
            assertThat(rehearsal)
                    .as("MigrationRehearsalSupport 自动推导迁移头时条数也必须来自目录")
                    .contains("CURRENT_MIGRATION_COUNT = count");
        } else {
            assertThat(rehearsal)
                    .as("MigrationRehearsalSupport 的迁移头常量没跟上："
                            + "请改成 CURRENT_HEAD_VERSION = \"%d\"; CURRENT_MIGRATION_COUNT = %d;"
                                    .formatted(head, count))
                    .contains("CURRENT_HEAD_VERSION = \"" + head + "\"")
                    .contains("CURRENT_MIGRATION_COUNT = " + count);
        }

        // 连带项：PreplanFutureTransferForwardMigrationPostgresTest 断言「从 V569
        // 升到目录头只跑 V569 之后的迁移」，它的条数常量同样要随新迁移 +1。
        // 第四处：迁移总览文档的「当前正式目录」。
        // LegacyMigrationSafetyContractTest 会拿上面那两个常量去比对这一行，
        // 所以文档漏改一样让 CI 后端整轮挂——2026-09-12 又栽了一次。
        // 那条断言在另一个测试类里，但**这里是新增迁移时唯一该看的清单**，
        // 因此把它一并纳入，宁可重复也别再漏。
        String migrationReadme = read(
                Path.of("..", "docs", "数据迁移", "README.md"),
                Path.of("docs", "数据迁移", "README.md"));
        assertThat(migrationReadme)
                .as("docs/数据迁移/README.md 的「当前正式目录」没跟上："
                        + "请改成 **当前正式目录：V%d/%d …**（并补一句新迁移做了什么）"
                                .formatted(head, count))
                .contains("当前正式目录：V" + head + "/" + count);
    }

    /**
     * <b>白名单全量对账（2026-09-18 起）：每一个版本对的条数都必须能从迁移目录数出来。</b>
     *
     * <p>上面的 {@code resetScriptAllowlistCoversTheCurrentMigrationHead} 只证明「最后一对
     * 覆盖当前头」，证明不了中间任何一对没写错（手抄条数打错一位照样绿，直到某次
     * 真实清库在旧目录上 fail-closed 拒跑）。版本对的第二个数 = 目录里版本号
     * {@code <= 该版本} 的 .sql 个数（跳号版本天然数不进去），完全可从目录推导——
     * 所以这里逐对重算：写错任何一对、漏写中间任何一对、顺序错乱，全部当场报出
     * 该改成什么，不再等真实库。
     */
    @Test
    void everyAllowlistPairIsRecountedFromTheMigrationDirectory() {
        int whitelistStart = opsScript.indexOf(
                "(applied_max_version, applied_migration_count) NOT IN (");
        assertThat(whitelistStart)
                .as("ops/reset_business_data.sql 里找不到迁移头 fail-closed 白名单锚点")
                .isGreaterThanOrEqualTo(0);
        int whitelistEnd = opsScript.indexOf(") THEN", whitelistStart);
        assertThat(whitelistEnd).isGreaterThan(whitelistStart);
        String whitelist = opsScript.substring(whitelistStart, whitelistEnd);

        Matcher pair = Pattern.compile("\\((\\d{1,4}),\\s*(\\d{1,4})\\)").matcher(whitelist);
        int previousVersion = 0;
        int pairCount = 0;
        while (pair.find()) {
            pairCount++;
            int version = Integer.parseInt(pair.group(1));
            int claimedCount = Integer.parseInt(pair.group(2));
            assertThat(version)
                    .as("白名单版本对必须严格递增，第 %d 对是 (%d, %d)"
                            .formatted(pairCount, version, claimedCount))
                    .isGreaterThan(previousVersion);
            int recounted = MigrationRehearsalSupport.migrationFileCountUpTo(version);
            assertThat(claimedCount)
                    .as("""
                            白名单第 %d 对 (%d, %d) 的条数与迁移目录不符：目录里版本号 \
                            <= %d 的 .sql 实际有 %d 个。要么这对手抄错了，要么目录有\
                            增删没同步白名单。"""
                            .formatted(pairCount, version, claimedCount, version, recounted))
                    .isEqualTo(recounted);
            previousVersion = version;
        }
        assertThat(pairCount)
                .as("白名单一个版本对都没解析到——锚点窗口或格式变了，先修本测试")
                .isGreaterThan(100);
        assertThat(previousVersion)
                .as("白名单最后一对的版本必须是当前迁移头 %s"
                        .formatted(MigrationRehearsalSupport.CURRENT_HEAD_VERSION))
                .isEqualTo(Integer.parseInt(MigrationRehearsalSupport.CURRENT_HEAD_VERSION));
    }

    private static Path resolve(Path direct, Path fallback) {
        return Files.exists(direct) ? direct : fallback;
    }

    private static String read(Path direct, Path fallback) throws IOException {
        return Files.readString(resolve(direct, fallback), StandardCharsets.UTF_8);
    }

    /** {@code V552__xxx.sql} → 捕获版本号；R__/U__ 等非版本迁移不计。 */
    private static final Pattern MIGRATION_FILE =
            Pattern.compile("^V([0-9]+)__.*\\.sql$");

    static Map<String, String> policy(String sql) {
        Map<String, String> result = new LinkedHashMap<>();
        Matcher matcher = POLICY_ROW.matcher(sql);
        while (matcher.find()) {
            String previous = result.put(matcher.group(1), matcher.group(2));
            assertThat(previous)
                    .as("duplicate policy row for " + matcher.group(1))
                    .isNull();
        }
        return result;
    }
}
