package com.uten.imp.features.measurement;

import java.util.Locale;
import java.util.UUID;

/** A goods may use different collection preferences in different operations. */
public record MeasurementProfileKey(UUID goodsId, String operationFamily) {

    public MeasurementProfileKey {
        if (goodsId == null) {
            throw new IllegalArgumentException("goodsId is required");
        }
        operationFamily = operationFamily == null
                ? "" : operationFamily.strip().toUpperCase(Locale.ROOT);
        if (!operationFamily.matches("[A-Z0-9_:-]{2,64}")) {
            throw new IllegalArgumentException("operationFamily is invalid");
        }
    }
}
