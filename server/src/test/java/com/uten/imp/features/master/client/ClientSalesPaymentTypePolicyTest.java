package com.uten.imp.features.master.client;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ClientSalesPaymentTypePolicyTest {

    @Test
    void unsetCreditFloorDefaultsToZeroAndValidPrecisionIsPreserved() {
        assertThat(ClientService.normalizeCreditFloor(null))
                .isEqualByComparingTo(BigDecimal.ZERO);
        assertThat(ClientService.normalizeCreditFloor(new BigDecimal("50000.0000")))
                .isEqualByComparingTo("50000.0000");
    }

    @Test
    void creditFloorRejectsNegativeOrUnrepresentableValues() {
        assertThatThrownBy(() -> ClientService.normalizeCreditFloor(new BigDecimal("-0.0001")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("铺底额必须为非负数");
        assertThatThrownBy(() -> ClientService.normalizeCreditFloor(new BigDecimal("0.00001")))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> ClientService.normalizeCreditFloor(
                new BigDecimal("100000000000000.0000")))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void legacyCreditRemainsAReadOnlyFloorSourceSnapshot() {
        Client legacy = new Client();
        legacy.setLegacyId(101);
        legacy.setCredit(new BigDecimal("50000.0000"));
        assertThatCode(() -> ClientService.requireLegacyCreditSnapshotUnchanged(
                legacy, new BigDecimal("50000")))
                .doesNotThrowAnyException();

        assertThatThrownBy(() -> ClientService.requireLegacyCreditSnapshotUnchanged(
                legacy, new BigDecimal("60000")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("只读快照");
        assertThatThrownBy(() -> ClientService.requireLegacyCreditSnapshotUnchanged(
                legacy, null))
                .isInstanceOf(ApiException.class);

        Client online = new Client();
        online.setCredit(new BigDecimal("1000"));
        assertThatCode(() -> ClientService.requireLegacyCreditSnapshotUnchanged(
                online, new BigDecimal("2000")))
                .doesNotThrowAnyException();
    }
}
