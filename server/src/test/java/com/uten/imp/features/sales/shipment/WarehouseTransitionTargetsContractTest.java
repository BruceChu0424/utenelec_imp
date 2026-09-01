package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class WarehouseTransitionTargetsContractTest {

    @Test
    void advertisedTargetsExactlyMatchTheAuthoritativeTransitionTopology() {
        Map<String, List<String>> expected = Map.of(
                SalesShipment.WORK_PENDING_PICK,
                List.of(SalesShipment.WORK_PICKING, SalesShipment.WORK_EXCEPTION),
                SalesShipment.WORK_PICKING,
                List.of(SalesShipment.WORK_PICKED, SalesShipment.WORK_EXCEPTION),
                SalesShipment.WORK_PICKED,
                List.of(SalesShipment.WORK_SHIPPED, SalesShipment.WORK_EXCEPTION),
                SalesShipment.WORK_EXCEPTION,
                List.of(SalesShipment.WORK_PENDING_PICK));

        expected.forEach((current, targets) -> {
            assertThat(SalesShipmentService.allowedWarehouseTransitionTargets(current))
                    .containsExactlyElementsOf(targets);
            for (String target : targets) {
                String reason = SetOfReasons.requiresReason(target) ? "已核对实物" : null;
                assertThatCode(() -> SalesShipmentService.validateWarehouseTransition(
                        current, target, reason)).doesNotThrowAnyException();
            }
        });
        assertThat(SalesShipmentService.allowedWarehouseTransitionTargets(
                SalesShipment.WORK_SHIPPED)).isEmpty();
        assertThat(SalesShipmentService.allowedWarehouseTransitionTargets(
                SalesShipment.WORK_LEGACY_PENDING)).isEmpty();
    }

    @Test
    void nonAdvertisedTargetIsRejectedByCommandValidation() {
        assertThatThrownBy(() -> SalesShipmentService.validateWarehouseTransition(
                SalesShipment.WORK_PENDING_PICK,
                SalesShipment.WORK_SHIPPED,
                null)).isInstanceOf(ApiException.class);
    }

    private static final class SetOfReasons {
        private SetOfReasons() {
        }

        private static boolean requiresReason(String target) {
            return SalesShipment.WORK_EXCEPTION.equals(target)
                    || SalesShipment.WORK_PENDING_PICK.equals(target);
        }
    }
}
