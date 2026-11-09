package com.uten.imp.features.subcontract.kit;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 「物料」列逐种备料计数的行级汇总口径(ADR-156 2026-11-09 修订: 下单前也显示到齐情况)。
 * 需要与「齐套情况」弹窗同源: 需要按明细累加, 可用 = Σ专属剩余 + 公共剩余——同种物料的
 * 公共池是共享的, 整行只计一次, 不能按明细重复加。
 */
class SubcontractKitServiceKindCountsTest {

    private static SubcontractKitService.ApplicationKitKindFact fact(
            UUID item, UUID goods, String needed, String exactFree, String publicFree) {
        return new SubcontractKitService.ApplicationKitKindFact(item, goods, null,
                new BigDecimal(needed), new BigDecimal(exactFree), new BigDecimal(publicFree));
    }

    @Test
    void publicPoolCountsOncePerKindAcrossTheRowItems() {
        UUID itemOne = UUID.randomUUID();
        UUID itemTwo = UUID.randomUUID();
        UUID shell = UUID.randomUUID();
        UUID screw = UUID.randomUUID();
        // 两条申请明细同用「外壳」: 各需要 6, 各有专属 2, 公共剩余 8 —— 可用 = 2+2+8 = 12 ≥ 12, 备齐。
        // 「螺丝」需要 10, 专属 0, 公共 3 —— 缺。
        var counts = SubcontractKitService.applicationKitKindCounts(List.of(
                fact(itemOne, shell, "6", "2", "8"),
                fact(itemTwo, shell, "6", "2", "8"),
                fact(itemOne, screw, "10", "0", "3")));
        assertThat(counts.kindCount()).isEqualTo(2);
        assertThat(counts.readyKindCount()).isEqualTo(1);
        assertThat(counts.shortKindCount()).isEqualTo(1);
    }

    @Test
    void doubleCountingThePublicPoolWouldFalselyMarkShortKindsReady() {
        UUID itemOne = UUID.randomUUID();
        UUID itemTwo = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        // 需要各 5(合计 10), 专属 0, 公共 8: 按明细重复加公共池会得 16 → 误判备齐;
        // 整行只计一次得 8 < 10 → 正确判缺。
        var counts = SubcontractKitService.applicationKitKindCounts(List.of(
                fact(itemOne, goods, "5", "0", "8"),
                fact(itemTwo, goods, "5", "0", "8")));
        assertThat(counts.kindCount()).isEqualTo(1);
        assertThat(counts.readyKindCount()).isZero();
        assertThat(counts.shortKindCount()).isEqualTo(1);
    }

    @Test
    void emptyMeansNoKinds() {
        var counts = SubcontractKitService.applicationKitKindCounts(List.of());
        assertThat(counts.kindCount()).isZero();
        assertThat(counts.readyKindCount()).isZero();
        assertThat(counts.shortKindCount()).isZero();
        assertThat(SubcontractKitService.applicationKitKindCounts(null).kindCount()).isZero();
    }
}
