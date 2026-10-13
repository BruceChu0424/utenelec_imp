package com.uten.imp.common.pricing;

import com.uten.imp.application.port.ProcurementPriceAssessmentPort.Assessment;
import com.uten.imp.common.history.DocumentHistoryMetadata;

/** Advice is computed after the save transaction, so its outage cannot undo a saved order. */
public abstract class ProcurementPriceAssessmentMetadata extends DocumentHistoryMetadata {
    private Assessment priceAssessment;
    public Assessment getPriceAssessment() { return priceAssessment; }
    public void setPriceAssessment(Assessment value) { priceAssessment = value; }
}
