package com.uten.imp.features.finance.asset.domain;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class AssetPostingPolicyTest {

    @Test
    void taxBookCannotPostToCorporateGeneralLedger() {
        assertThatThrownBy(() -> AssetPostingPolicy.requireCorporateGlBook("TAX"))
                .isInstanceOf(ApiException.class);
        assertThatCode(() -> AssetPostingPolicy.requireCorporateGlBook("CORPORATE"))
                .doesNotThrowAnyException();
    }

    @Test
    void makerCheckerAndDisposalCutoffAreFailClosed() {
        UUID maker = UUID.randomUUID();
        assertThatThrownBy(() -> AssetPostingPolicy.requireDifferentActor(maker, maker, "approve"))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> AssetPostingPolicy.requireDisposalMonthDepreciated(
                LocalDate.parse("2026-08-15"), "2026-07"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("disposal month");
        assertThatCode(() -> AssetPostingPolicy.requireDisposalMonthDepreciated(
                LocalDate.parse("2026-08-15"), "2026-08"))
                .doesNotThrowAnyException();
    }

    @Test
    void delayedActivationCannotBackfillAnEarlierStartPeriod() {
        assertThatThrownBy(() -> AssetPostingPolicy.requireStartNotBeforeActivationPeriod(
                "2026-08", "2026-09"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("activation GL period");
        assertThatCode(() -> AssetPostingPolicy.requireStartNotBeforeActivationPeriod(
                "2026-09", "2026-09"))
                .doesNotThrowAnyException();
    }
}
