package com.uten.imp.features.finance.asset.domain;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CorporateAssetBookPolicyTest {

    @Test
    void corporateBookStartsInTheMonthAfterReadyForUse() {
        assertThat(CorporateAssetBookPolicy.deriveDepreciationStart(LocalDate.parse("2026-12-31")).toString())
                .isEqualTo("2027-01");
        assertThatCode(() -> CorporateAssetBookPolicy.requireDerivedStart(
                LocalDate.parse("2026-08-01"), "2026-09"))
                .doesNotThrowAnyException();
        assertThatThrownBy(() -> CorporateAssetBookPolicy.requireDerivedStart(
                LocalDate.parse("2026-08-01"), "2026-08"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("2026-09");
    }
}
