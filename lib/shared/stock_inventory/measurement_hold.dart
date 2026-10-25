const historicalMeasurementHold = 'LEGACY_QUANTITY_BASIS_UNPROVEN';

String measurementHoldLabel(String? reason) =>
    reason == historicalMeasurementHold ? '历史计量待核' : '计量待核';

String measurementHoldNotice(String? reason) =>
    '${measurementHoldLabel(reason)} · 账面数仅核对';
