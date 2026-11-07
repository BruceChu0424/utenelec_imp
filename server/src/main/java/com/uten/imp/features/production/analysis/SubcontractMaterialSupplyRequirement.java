package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.math.RoundingMode;

/** Baseline BOM preparation with any approved, source-specific subcontract supply commitment. */
record SubcontractMaterialSupplyRequirement(BigDecimal frozenOutputQty, BigDecimal frozenMaterialQty) {
    static final SubcontractMaterialSupplyRequirement NONE = new SubcontractMaterialSupplyRequirement(
            BigDecimal.ZERO, BigDecimal.ZERO);

    SubcontractMaterialSupplyRequirement {
        if (frozenOutputQty == null || frozenOutputQty.signum() < 0
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
        // The master allowance is a ceiling. Only a real approved order freezes extra supply.
        return frozen.add(MaterialConsumptionMath.required(remaining, bomQty,
                consumptionBasis, basisOutputQty, allowPartialPackage));
    }
}
