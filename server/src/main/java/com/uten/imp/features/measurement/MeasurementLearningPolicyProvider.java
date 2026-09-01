package com.uten.imp.features.measurement;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Keeps inference thresholds configurable while sharing one immutable policy. */
@Component
public class MeasurementLearningPolicyProvider {

    private final MeasurementLearningPolicy policy;

    public MeasurementLearningPolicyProvider(
            @Value("${uten.measurement.learning.minimum-independent-documents:3}")
            int minimumIndependentDocuments,
            @Value("${uten.measurement.learning.minimum-business-days:2}")
            int minimumBusinessDays) {
        this.policy = new MeasurementLearningPolicy(
                minimumIndependentDocuments, minimumBusinessDays);
    }

    public MeasurementLearningPolicy policy() {
        return policy;
    }
}
