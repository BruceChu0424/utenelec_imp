package com.uten.imp.features.finance.payables;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

public final class SupplierOffsetContracts {
    private SupplierOffsetContracts() {}
    public record Target(UUID payableId, BigDecimal amountOriginal) {}
    public record ApplyRequest(UUID sourceLedgerId, LocalDate effectiveDate,
                               String reason, List<Target> targets) {}
    public record ApplyResult(UUID offsetBatchId) {}
    public record ReverseRequest(String reason) {}
}
