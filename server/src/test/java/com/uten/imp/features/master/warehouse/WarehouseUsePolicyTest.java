package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.WarehouseUse;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-146 选仓规则唯一判定点: 用途 x 仓库类别(良品仓/不良品仓/车间内料仓/主仓/停用仓)的允许与拒绝矩阵,
 * 以及给人看的原因文案(不带代号, 括号半角)。
 */
class WarehouseUsePolicyTest {

    private static final WarehouseUsePolicy.Facts GOOD =
            new WarehouseUsePolicy.Facts("包材仓库", true, false, false, false, true, true);
    private static final WarehouseUsePolicy.Facts DEFECTIVE =
            new WarehouseUsePolicy.Facts("成品不良品仓", true, false, true, false, true, true);
    private static final WarehouseUsePolicy.Facts LINE_SIDE =
            new WarehouseUsePolicy.Facts("注塑车间内料仓", true, true, false, false, true, true);
    private static final WarehouseUsePolicy.Facts MAIN =
            new WarehouseUsePolicy.Facts("仓库(14年版)", true, false, false, true, true, true);
    private static final WarehouseUsePolicy.Facts DISABLED =
            new WarehouseUsePolicy.Facts("五金仓库", true, false, false, false, true, false);
    private static final WarehouseUsePolicy.Facts BROKEN_CHAIN =
            new WarehouseUsePolicy.Facts("孤儿仓", true, false, false, false, false, true);
    private static final WarehouseUsePolicy.Facts UNACCOUNTABLE =
            new WarehouseUsePolicy.Facts("样品柜", false, false, false, false, true, true);

    @ParameterizedTest
    @EnumSource(WarehouseUse.class)
    void goodLeafServesEveryUseExceptTheTwoDefectiveChannelEnds(WarehouseUse use) {
        String violation = WarehouseUsePolicy.violation(GOOD, "仓库", use, true);
        if (use == WarehouseUse.DEFECTIVE_IN || use == WarehouseUse.DEFECTIVE_OUT) {
            assertThat(violation).contains("「包材仓库」是良品仓");
        } else {
            assertThat(violation).isNull();
        }
    }

    @ParameterizedTest
    @EnumSource(WarehouseUse.class)
    void defectiveLeafOnlyServesChannelsDisposalTransferAndCount(WarehouseUse use) {
        String violation = WarehouseUsePolicy.violation(DEFECTIVE, "仓库", use, true);
        if (use == WarehouseUse.GOOD_IN || use == WarehouseUse.GOOD_OUT) {
            assertThat(violation).contains("「成品不良品仓」是不良品仓").contains("请选择良品仓");
        } else {
            assertThat(violation).isNull();
        }
    }

    @Test
    void messagesTellWhatToDoInsteadInPlainWords() {
        assertThat(WarehouseUsePolicy.violation(DEFECTIVE, "入库仓库", WarehouseUse.GOOD_IN, true))
                .isEqualTo("入库仓库「成品不良品仓」是不良品仓, 正常货品不能入库, 请选择良品仓; "
                        + "判为不良的货请用「转不良品仓」");
        assertThat(WarehouseUsePolicy.violation(DEFECTIVE, "发出仓库", WarehouseUse.GOOD_OUT, true))
                .isEqualTo("发出仓库「成品不良品仓」是不良品仓, 不能从这里领用或发货, 请选择良品仓");
        assertThat(WarehouseUsePolicy.violation(GOOD, "调入仓", WarehouseUse.DEFECTIVE_IN, true))
                .isEqualTo("调入仓「包材仓库」是良品仓, 转不良品仓只能转入不良品仓");
        assertThat(WarehouseUsePolicy.violation(GOOD, "调出仓", WarehouseUse.DEFECTIVE_OUT, true))
                .isEqualTo("调出仓「包材仓库」是良品仓, 不良复判转回只能从不良品仓转出");
        for (WarehouseUse use : WarehouseUse.values()) {
            for (var facts : new WarehouseUsePolicy.Facts[] {GOOD, DEFECTIVE, LINE_SIDE, MAIN, DISABLED}) {
                String message = WarehouseUsePolicy.violation(facts, "仓库", use, true);
                if (message == null) continue;
                assertThat(message).doesNotContain("（", "）", "WarehouseUse", "is_defective", use.name());
            }
        }
    }

    @ParameterizedTest
    @EnumSource(WarehouseUse.class)
    void structuralRulesApplyToEveryUse(WarehouseUse use) {
        assertThat(WarehouseUsePolicy.violation(MAIN, "仓库", use, true)).contains("具体子仓库");
        assertThat(WarehouseUsePolicy.violation(LINE_SIDE, "仓库", use, true)).contains("必须选择正常仓库");
        assertThat(WarehouseUsePolicy.violation(DISABLED, "仓库", use, true)).contains("停用");
        assertThat(WarehouseUsePolicy.violation(BROKEN_CHAIN, "仓库", use, true)).contains("不完整");
        assertThat(WarehouseUsePolicy.violation(UNACCOUNTABLE, "仓库", use, true)).contains("不参与库存记账");
        assertThat(WarehouseUsePolicy.violation(null, "仓库", use, true)).contains("不存在");
    }

    @Test
    void keepingTheOriginalWarehouseSkipsActivityChecksButNeverTheMainOrTheWarehouseUse() {
        assertThat(WarehouseUsePolicy.violation(DISABLED, "仓库", WarehouseUse.GOOD_IN, false)).isNull();
        assertThat(WarehouseUsePolicy.violation(LINE_SIDE, "仓库", WarehouseUse.GOOD_IN, false)).isNull();
        assertThat(WarehouseUsePolicy.violation(null, "仓库", WarehouseUse.GOOD_IN, false)).isNull();
        assertThat(WarehouseUsePolicy.violation(MAIN, "仓库", WarehouseUse.GOOD_IN, false)).contains("具体子仓库");
        assertThat(WarehouseUsePolicy.violation(DEFECTIVE, "仓库", WarehouseUse.GOOD_IN, false))
                .contains("是不良品仓");
    }

    @Test
    void useCapabilitiesMatchTheDocumentedMatrix() {
        assertThat(WarehouseUse.GOOD_IN.acceptsDefective()).isFalse();
        assertThat(WarehouseUse.GOOD_OUT.acceptsDefective()).isFalse();
        assertThat(WarehouseUse.DEFECTIVE_IN.acceptsGood()).isFalse();
        assertThat(WarehouseUse.DEFECTIVE_OUT.acceptsGood()).isFalse();
        for (WarehouseUse use : new WarehouseUse[] {WarehouseUse.DISPOSAL_OUT, WarehouseUse.TRANSFER, WarehouseUse.COUNT}) {
            assertThat(use.acceptsGood()).isTrue();
            assertThat(use.acceptsDefective()).isTrue();
        }
    }
}
