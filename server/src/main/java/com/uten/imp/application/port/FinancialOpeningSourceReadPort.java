package com.uten.imp.application.port;

import com.fasterxml.jackson.annotation.JsonFormat;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Exact, already-posted R1 opening evidence. No current-name or balance-amount matching. */
public interface FinancialOpeningSourceReadPort {
    record Source(FinanceGlSettlementCapacityPort.SourceRef reference,UUID voucherId,UUID importBatchId,UUID balanceImportId,
            UUID openingEvidenceId,LocalDate effectiveFrom,UUID styleId,String accountCode,UUID accountingCurrencyId,
            UUID originalCurrencyId,int direction,@JsonFormat(shape=JsonFormat.Shape.STRING)BigDecimal amountLocal,
            @JsonFormat(shape=JsonFormat.Shape.STRING)BigDecimal amountOriginal,FinancialAuxiliaryValidationPort.Ref auxiliary,
            String accountName,String sourceSystem,String sourceLedger,String sourceSha256,int sourceRow,String fingerprint) { }
    Map<FinanceGlSettlementCapacityPort.SourceRef,Source> read(List<FinanceGlSettlementCapacityPort.SourceRef> references);
    Map<String,Object> choices(String role,UUID partyId,LocalDate effectiveFrom,int page,int size);
}
