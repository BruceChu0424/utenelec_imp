package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.UUID;

/** Read-only ownership of a subcontract quantity, never inferred from matching goods codes. */
public record SubcontractTaskSource(
        UUID analysisItemId,
        String sourceType,
        String sourceNo,
        Integer sourceLineNo,
        String productCode,
        String productName,
        String materialCode,
        String materialName,
        BigDecimal quantity,
        String unitName) {
}
