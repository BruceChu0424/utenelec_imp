package com.uten.imp.features.finance.asset.domain;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class AssetPostingFingerprintTest {

    @Test
    void orderAndDecimalScaleDoNotChangeTheFingerprint() {
        UUID first = UUID.fromString("00000000-0000-0000-0000-000000000001");
        UUID second = UUID.fromString("00000000-0000-0000-0000-000000000002");
        var a = input(first, new BigDecimal("10.00"));
        var b = input(second, new BigDecimal("20.0"));

        String left = AssetPostingFingerprint.calculate(
                "DEPRECIATION", "CORPORATE", AssetPeriod.parse("2026-08"), List.of(a, b));
        String right = AssetPostingFingerprint.calculate(
                "DEPRECIATION", "CORPORATE", AssetPeriod.parse("2026-08"),
                List.of(input(second, new BigDecimal("20.000")), input(first, new BigDecimal("10"))));

        assertThat(left).isEqualTo(right).hasSize(64);
    }

    @Test
    void anyAccountingInputChangeInvalidatesTheFingerprint() {
        UUID id = UUID.fromString("00000000-0000-0000-0000-000000000001");
        String before = AssetPostingFingerprint.calculate(
                "AMORTIZATION", "CORPORATE", AssetPeriod.parse("2026-08"),
                List.of(input(id, new BigDecimal("10"))));
        String after = AssetPostingFingerprint.calculate(
                "AMORTIZATION", "CORPORATE", AssetPeriod.parse("2026-08"),
                List.of(input(id, new BigDecimal("10.01"))));

        assertThat(before).isNotEqualTo(after);
    }

    private static AssetPostingFingerprint.Input input(UUID id, BigDecimal current) {
        return new AssetPostingFingerprint.Input(
                id,
                UUID.fromString("10000000-0000-0000-0000-000000000001"),
                new BigDecimal("100"),
                new BigDecimal("30"),
                current,
                UUID.fromString("20000000-0000-0000-0000-000000000001"),
                UUID.fromString("30000000-0000-0000-0000-000000000001"),
                UUID.fromString("40000000-0000-0000-0000-000000000001"),
                3L);
    }
}
