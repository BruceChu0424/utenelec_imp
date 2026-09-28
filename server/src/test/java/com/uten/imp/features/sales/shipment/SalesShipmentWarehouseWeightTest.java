package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 销售出库实称重量(ADR-135 §3.7): 仓库确认出库时逐行填的千克数只进库存重量账(MEASURED)与出库事件证据,
 * 按重量计的行丢弃, 出库后登记 SHIPMENT 称重核对观测(往来方 = 客户)。
 */
class SalesShipmentWarehouseWeightTest {

    @Test
    void lineWeightIsNonNegativeFourDecimalKilogramsAndZeroMeansNotWeighed() {
        assertThat(SalesShipmentService.normalizedLineWeightKg(null)).isNull();
        assertThat(SalesShipmentService.normalizedLineWeightKg(new BigDecimal("0.0000"))).isNull();
        assertThat(SalesShipmentService.normalizedLineWeightKg(new BigDecimal("12.5000")))
                .isEqualByComparingTo("12.5")
                .hasToString("12.5");
        // 负标度(1E+1)转成普通小数, 出库事件 JSON 里是 10 而不是 1E+1。
        assertThat(SalesShipmentService.normalizedLineWeightKg(new BigDecimal("1E+1")))
                .hasToString("10");
        for (String invalid : List.of("-0.0001", "1.00001", "100000000000000")) {
            assertThatThrownBy(() -> SalesShipmentService.normalizedLineWeightKg(new BigDecimal(invalid)))
                    .isInstanceOfSatisfying(ApiException.class, error -> {
                        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                        assertThat(error.getMessage()).contains("千克");
                    });
        }
    }

    @Test
    void confirmedOutboundPostsMeasuredWeightAndRecordsShipmentCheck() throws Exception {
        String source = Files.readString(Path.of(
                        "src/main/java/com/uten/imp/features/sales/shipment/SalesShipmentService.java"),
                StandardCharsets.UTF_8);
        int approve = source.indexOf("private ShipmentDetail approveLocked(");
        int ar = source.indexOf("立应收", approve);
        assertThat(approve).isGreaterThanOrEqualTo(0);
        assertThat(source.substring(approve, ar))
                .contains("applyMovement(s, it, StockService.DIR_OUT, now, null, lineWeights.get(it.getId()))")
                .contains("recordShipmentObservation(s, it, posted, now);");
        // 只有按实称记账的流水才登记观测; 按重量计的行在建表时已丢弃。
        assertThat(source)
                .contains("posted.weightSource() != WeightSource.MEASURED")
                .contains("SourceKind.SHIPMENT")
                .contains("\"CLIENT\"")
                .contains("line_profile.mass_unit_code IS NOT NULL")
                .contains("weightObservations.reverseBySourceItem(");
    }
}
