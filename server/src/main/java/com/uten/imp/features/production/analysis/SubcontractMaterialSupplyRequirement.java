package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.math.RoundingMode;

/** Material preparation budget; finished output and the original BOM edge keep their own units. */
record SubcontractMaterialSupplyRequirement(BigDecimal lossPercent,
        BigDecimal frozenOutputQty, BigDecimal frozenMaterialQty) {
    static final SubcontractMaterialSupplyRequirement NONE = new SubcontractMaterialSupplyRequirement(
            BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO);

    SubcontractMaterialSupplyRequirement {
        if (lossPercent == null || lossPercent.signum() < 0 || lossPercent.compareTo(new BigDecimal("100")) > 0
                || frozenOutputQty == null || frozenOutputQty.signum() < 0
                || frozenMaterialQty == null || frozenMaterialQty.signum() < 0) {
            throw new IllegalArgumentException("Invalid subcontract material preparation basis");
        }
    }

    BigDecimal required(BigDecimal outputQty, BigDecimal bomQty, String consumptionBasis,
            BigDecimal basisOutputQty, boolean allowPartialPackage) {
        BigDecimal output = outputQty.max(BigDecimal.ZERO);
        BigDecimal frozenOutput = output.min(frozenOutputQty);
        BigDecimal frozen = frozenOutput.signum() == 0 ? BigDecimal.ZERO
                : frozenOutput.compareTo(frozenOutputQty) == 0 ? frozenMaterialQty
                : frozenMaterialQty.multiply(frozenOutput).divide(frozenOutputQty, 4, RoundingMode.CEILING);
        frozen=frozen.max(MaterialConsumptionMath.required(frozenOutput,bomQty,
                consumptionBasis,basisOutputQty,allowPartialPackage));
        BigDecimal remaining = output.subtract(frozenOutput);
        BigDecimal supplyUnitQty = bomQty.multiply(BigDecimal.ONE.add(lossPercent.movePointLeft(2)));
        return frozen.add(MaterialConsumptionMath.required(remaining, supplyUnitQty,
                consumptionBasis, basisOutputQty, allowPartialPackage));
    }
}
