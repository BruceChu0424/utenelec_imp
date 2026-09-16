package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class WarehouseTransitionTargetsContractTest {

    @Test
    void advertisedTargetsExactlyMatchTheAuthoritativeTransitionTopology() {
        assertThat(SalesShipmentService.allowedWarehouseTransitionTargets(
                SalesShipment.WORK_PENDING_PICK))
                .containsExactly(SalesShipment.WORK_SHIPPED);
        assertThatCode(() -> SalesShipmentService.validateWarehouseTransition(
                SalesShipment.WORK_PENDING_PICK,
                SalesShipment.WORK_SHIPPED,
                null)).doesNotThrowAnyException();

        for (String terminal : List.of(
                SalesShipment.WORK_SHIPPED,
                SalesShipment.WORK_LEGACY_PENDING,
                SalesShipment.WORK_CANCELLED,
                SalesShipment.WORK_REVERSED)) {
            assertThat(SalesShipmentService.allowedWarehouseTransitionTargets(terminal))
                    .isEmpty();
        }
    }

    /**
     * V582 删除的三个中间态必须 fail-closed 拒绝，而不是静默兼容：老前端、
     * 老脚本和重放的请求都可能还带着它们，一旦被当成合法目标就会跳过
     * 可发量、来源承诺与财务放行的整套校验。
     */
    @Test
    void retiredIntermediateTargetsAreRejectedByCommandValidation() {
        for (String retired : List.of("PICKING", "PICKED", "EXCEPTION")) {
            assertThatThrownBy(() -> SalesShipmentService.validateWarehouseTransition(
                    SalesShipment.WORK_PENDING_PICK, retired, "已核对实物"))
                    .isInstanceOf(ApiException.class)
                    .extracting(error -> ((ApiException) error).getCode())
                    .isEqualTo(ErrorCode.VALIDATION_FAILED);
            assertThat(SalesShipmentService.allowedWarehouseTransitionTargets(retired))
                    .isEmpty();
        }
    }

    @Test
    void confirmingOutboundTwiceFailsClosed() {
        assertThatThrownBy(() -> SalesShipmentService.validateWarehouseTransition(
                SalesShipment.WORK_SHIPPED,
                SalesShipment.WORK_SHIPPED,
                null))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode())
                .isEqualTo(ErrorCode.CONFLICT);
    }
}
