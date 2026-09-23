package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V581 静态契约：委外「单一叶子子件」直接发料出仓（COMPONENT_OUTBOUND）。
 *
 * <p>锁定四件容易被后人改漏的事：①形态判据只有一个来源（DB 函数）；
 * ②五个既有守卫都按新流向扩展过；③两条 fail-closed 口子是焊死的；
 * ④V502 的一致性视图**刻意没有**被加进白名单（加进去每张单都会卡死）。
 */
class SubcontractComponentOutboundMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V581__subcontract_component_outbound.sql");

    private static String migration() throws Exception {
        return Files.readString(resolve(MIGRATION), StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }

    /** 测试可能从仓库根或 server/ 启动，两处都试一遍。 */
    private static Path resolve(Path relative) {
        return Files.exists(relative) ? relative : Path.of("server").resolve(relative);
    }

    @Test
    void formShapePredicateHasExactlyOneSourceOfTruth() throws Exception {
        String sql = migration();
        assertThat(sql)
                .contains("create or replace function fn_subcontract_sole_component_goods")
                // 判据四条：活动边恰好 1 条、PER_UNIT、真实投入阶段、子件无活动边
                .contains("consumption_basis = 'per_unit'")
                .contains("control_stage in ('start', 'assembly', 'finish')")
                .contains("coalesce(child.auto_created, false) = false")
                .contains("= 1");
        // 数量基准守卫必须调用同一个函数，而不是把判据再抄一遍。
        assertThat(sql).contains("fn_subcontract_sole_component_goods(oi.goods_id)");
    }

    @Test
    void forwardRuleUsesOneImmediateInputAndAllowsThatInputToHaveItsOwnManufacturingBom() throws Exception {
        String sql=Files.readString(resolve(Path.of("src/main/resources/db/migration/V646__subcontract_component_exact_stock_handoff.sql")),StandardCharsets.UTF_8);
        String predicate=sql.substring(sql.indexOf("CREATE OR REPLACE FUNCTION fn_subcontract_sole_component_goods"),sql.indexOf("COMMENT ON FUNCTION fn_subcontract_sole_component_goods"));
        assertThat(predicate).contains("edge.consumption_basis='PER_UNIT'","edge.control_stage IN ('START','ASSEMBLY','FINISH')","edge.qty>0", "sibling.goods_id=p_goods_id", ")=1");
        assertThat(predicate).doesNotContain("grand.component_goods_id", "grand.goods_id", "NOT EXISTS");
    }

    @Test
    void everyExistingGuardKnowsTheNewFlowMode() throws Exception {
        String sql = migration();
        assertThat(sql)
                // ① flow_mode 白名单
                .contains("'legacy_bom_component', 'direct_outbound', 'make_then_outbound', "
                        + "'prepared_outbound', 'component_outbound'")
                // ② 准备形态：与 DIRECT 同款（批准即待出仓、prepared=planned）
                .contains("flow_mode in ('direct_outbound', 'component_outbound')")
                // ③ BOM 快照：有子层 + 冻结目标件指纹
                .contains("(flow_mode = 'component_outbound' and bom_has_children_snapshot = true")
                // ④ 出仓分配断言
                .contains("fn_assert_subcontract_outbound_issue_allocation")
                // ⑤ 先出后进 / 消费守恒按冻结单耗折算
                .contains("fn_assert_subcontract_target_outbound_receipt")
                .contains("v_per_base");
    }

    @Test
    void twoFailClosedGatesAreWelded() throws Exception {
        String sql = migration();
        // 同一订货明细禁止混用「发子件」与「发目标件」——回厂按货色分组逐组扣满，
        // 混行两组都扣不够会把单据永久卡死。
        assertThat(sql)
                .contains("subcontract_component_outbound_exclusive_guard")
                // COMPONENT 行不支持损耗补量（V525 的补量算式只认 DIRECT）。
                .contains("subcontract_component_outbound_no_loss_replacement_chk");
    }

    @Test
    void quantityBasisViewIsDeliberatelyLeftOutOfTheWhitelist() throws Exception {
        String sql = migration();
        // v_subcontract_quantity_basis_issues 的判据 bom_unit_qty <> oi.unit_rate
        // 对 COMPONENT 恒为真：加进白名单等于把每张单都判成异常。本迁移只补注释。
        assertThat(sql).contains("comment on view v_subcontract_quantity_basis_issues");
        assertThat(sql).doesNotContain(
                "where pi.flow_mode in ('direct_outbound','make_then_outbound',"
                        + "'prepared_outbound','component_outbound')");
    }

    @Test
    void bomSnapshotRebuildKeepsTheV529Relaxation() throws Exception {
        String sql = migration();
        // V529 把 DIRECT 分支放开成 IS NOT NULL；V581 整条重建时必须保留，
        // 并在重建前断言库内确实是 V529 之后的形态。
        assertThat(sql)
                .contains("subcontract bom snapshot guard is not at the v529 shape before v581")
                .contains("(flow_mode = 'direct_outbound' and bom_has_children_snapshot is not null");
    }
}
