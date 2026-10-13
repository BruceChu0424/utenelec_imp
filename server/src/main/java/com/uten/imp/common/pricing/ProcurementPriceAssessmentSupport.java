package com.uten.imp.common.pricing;

import com.uten.imp.application.port.ProcurementPriceAssessmentPort;
import com.uten.imp.application.port.ProcurementPriceAssessmentPort.Assessment;
import com.uten.imp.application.port.ProcurementPriceAssessmentPort.Request;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Component;

/** Invoked after command completion. Inaccessible or unavailable advice never means a normal price. */
@Component
public class ProcurementPriceAssessmentSupport {
    private static final Logger LOG = LoggerFactory.getLogger(ProcurementPriceAssessmentSupport.class);
    private final ObjectProvider<ProcurementPriceAssessmentPort> ports;
    public ProcurementPriceAssessmentSupport(ObjectProvider<ProcurementPriceAssessmentPort> ports) { this.ports = ports; }

    public Assessment assess(Request request) {
        try {
            var port = ports.getIfAvailable();
            if (port == null || !port.available(request.kind())) return Assessment.unavailable();
            return port.assess(request);
        } catch (RuntimeException unavailable) {
            // The order is already saved. No prices, identifiers or exception messages enter this log.
            LOG.warn("Post-command price advice unavailable ({})", unavailable.getClass().getSimpleName());
            return Assessment.unavailable();
        }
    }
}
