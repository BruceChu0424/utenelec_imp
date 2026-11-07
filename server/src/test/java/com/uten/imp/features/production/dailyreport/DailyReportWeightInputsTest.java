package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

class DailyReportWeightInputsTest {
    @Test void measuredKilogramsUseTheConfiguredMasterWeightAndFrozenReportRate() {
        var basis = DailyReportWeightInputs.kgPerBaseUnit(new BigDecimal("125"), "G");
        assertEquals(new BigDecimal("0.125"), basis);
        assertNull(DailyReportWeightInputs.kgPerBaseUnit(new BigDecimal("125"), null));
        assertNull(DailyReportWeightInputs.kgPerBaseUnit(new BigDecimal("125"), "COUNT"));
        var line = weighed("0.125", "4.25", "10.625");
        line.setUnitRate(BigDecimal.valueOf(20));
        assertDoesNotThrow(() -> DailyReportWeightInputs.validate(line, basis));
        line.setQty(new BigDecimal("4.2"));
        assertThrows(ApiException.class, () -> DailyReportWeightInputs.validate(line, basis));
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class,
                () -> DailyReportWeightInputs.validate(line, new BigDecimal("0.126"))).getCode());
    }

    @Test void recurringQuotientRequiresExplicitLedgerPrecisionAndDoesNotChangeMeasuredWeight() {
        BigDecimal basis = new BigDecimal("0.03");
        var line = weighed("0.03", "33.33", "1");
        assertThrows(BusinessPrecisionRequiredException.class, () -> DailyReportWeightInputs.validate(line, basis));
        line.setWeightQuantityScale(2);
        line.setWeightQuantityRounding("DOWN");
        assertDoesNotThrow(() -> DailyReportWeightInputs.validate(line, basis));
        assertEquals(BigDecimal.ONE, line.getWeight());
        line.setWeight(new BigDecimal("1.00001"));
        assertThrows(ApiException.class, () -> DailyReportWeightInputs.validate(line, basis));
    }

    @Test void quantityEntryKeepsAnIndependentMeasurementWithoutComputingItFromTheBasis() {
        BigDecimal basis = new BigDecimal("0.125");
        var line = new DailyReportItemLine();
        line.setQty(BigDecimal.TEN);
        assertDoesNotThrow(() -> DailyReportWeightInputs.validate(line, null));
        line.setWeightEntryMode("QUANTITY");
        line.setUnitWeightKgExact(basis);
        assertDoesNotThrow(() -> DailyReportWeightInputs.validate(line, basis));
        assertNull(line.getWeight());
        line.setWeight(new BigDecimal("1.30"));
        assertDoesNotThrow(() -> DailyReportWeightInputs.validate(line, basis));
        assertEquals(new BigDecimal("1.30"), line.getWeight());
        line.setWeight(new BigDecimal("1.30001"));
        assertThrows(ApiException.class, () -> DailyReportWeightInputs.validate(line, basis));
        line.setWeight(new BigDecimal("1.30"));
        line.setWeightQuantityScale(4);
        line.setWeightQuantityRounding("DOWN");
        assertThrows(ApiException.class, () -> DailyReportWeightInputs.validate(line, basis));
    }

    @Test void manualWeightIsLocalToTheReportAndSupportsEitherQuantityOrWeighing() {
        var line = weighed("0.125", "4.25", "10.625");
        line.setUnitRate(new BigDecimal("20"));
        line.setUnitWeightSource("MANUAL");
        assertDoesNotThrow(() -> DailyReportWeightInputs.validate(line, new BigDecimal("0.126")));
        assertFalse(DailyReportWeightInputs.usesMasterBasis(line));
        line.setWeightEntryMode("QUANTITY");
        assertThrows(ApiException.class, () -> DailyReportWeightInputs.validate(line, null));
        line.setWeight(null);
        assertDoesNotThrow(() -> DailyReportWeightInputs.validate(line, null));
        assertNull(line.getWeight());
    }

    @Test void quantityAndMeasuredMassDeriveKgPerBaseUnitWithoutLosingAnyInput() {
        var line = weighed("0.125", "4.25", "10.625");
        line.setWeightEntryMode("UNIT");
        line.setUnitWeightSource("DERIVED");
        line.setUnitRate(new BigDecimal("20"));
        assertDoesNotThrow(() -> DailyReportWeightInputs.validate(line, null));
        assertEquals(new BigDecimal("10.625"), line.getWeight());
        line.setUnitWeightKgExact(new BigDecimal("0.13"));
        assertThrows(ApiException.class, () -> DailyReportWeightInputs.validate(line, null));
        line.setUnitWeightKgExact(new BigDecimal("0.125"));
        line.setWeight(null);
        assertThrows(ApiException.class, () -> DailyReportWeightInputs.validate(line, null));
    }

    @Test void recurringUnitWeightNeedsItsOwnExplicitPrecisionChoice() {
        var line = weighed("0.33333333", "3", "1");
        line.setWeightEntryMode("UNIT");
        line.setUnitWeightSource("DERIVED");
        assertThrows(BusinessPrecisionRequiredException.class, () -> DailyReportWeightInputs.validate(line, null));
        line.setWeightUnitScale(8);
        line.setWeightUnitRounding("DOWN");
        assertDoesNotThrow(() -> DailyReportWeightInputs.validate(line, null));
        line.setWeightQuantityScale(4);
        line.setWeightQuantityRounding("DOWN");
        assertThrows(ApiException.class, () -> DailyReportWeightInputs.validate(line, null));
        line.setWeightQuantityScale(null);
        line.setWeightQuantityRounding(null);
        line.setUnitWeightSource("MANUAL");
        assertThrows(ApiException.class, () -> DailyReportWeightInputs.validate(line, null));
    }

    @Test void onlyTheSameCompleteSavedSplitCanReuseItsFrozenFactorOnADraftEdit() {
        var input = weighed("0.125", "4", "0.5");
        input.setGoodsId(UUID.randomUUID());
        input.setUnitId(UUID.randomUUID());
        input.setPlanItemId(UUID.randomUUID());
        input.setExecutionSegmentId(UUID.randomUUID());
        UUID batch = UUID.randomUUID();
        var first = piece(input, batch, "1", "0.125");
        var remainder = piece(input, batch, "3", "0.375");
        input.setWeightSourceReportItemId(first.getId());
        var prior = List.of(first, remainder);
        var frozen = new DailyReportWeightInputs.FrozenDraftInputs(prior);
        assertTrue(frozen.canReuse(input));
        assertFalse(frozen.canReuse(input), "The same measured input cannot be cloned on update");
        assertFalse(new DailyReportWeightInputs.FrozenDraftInputs(List.of(first)).canReuse(input));
        input.setWeight(new BigDecimal("0.49"));
        assertFalse(new DailyReportWeightInputs.FrozenDraftInputs(prior).canReuse(input));
        input.setWeight(new BigDecimal("0.5"));
        input.setExecutionSegmentId(UUID.randomUUID());
        assertFalse(new DailyReportWeightInputs.FrozenDraftInputs(prior).canReuse(input));
    }

    private static ProductionDailyReportItem piece(DailyReportItemLine original, UUID batch, String qty, String kg) {
        var item = new ProductionDailyReportItem();
        item.setId(UUID.randomUUID());
        item.setOutputBatchId(batch);
        item.setOutputBatchQty(original.getQty());
        item.setGoodsId(original.getGoodsId());
        item.setUnitId(original.getUnitId());
        item.setPlanItemId(original.getPlanItemId());
        item.setExecutionSegmentId(original.getExecutionSegmentId());
        item.setUnitWeightKg(original.getUnitWeightKgExact());
        item.setWeightEntryMode(original.getWeightEntryMode());
        item.setQty(new BigDecimal(qty));
        item.setWeight(new BigDecimal(kg));
        return item;
    }

    private static DailyReportItemLine weighed(String basis, String quantity, String totalWeight) {
        var line = new DailyReportItemLine();
        line.setWeightEntryMode("WEIGHT");
        line.setUnitWeightKgExact(new BigDecimal(basis));
        line.setQty(new BigDecimal(quantity));
        line.setWeight(new BigDecimal(totalWeight));
        return line;
    }
}
