package com.uten.imp.application.port;

import com.uten.imp.common.finance.PartyOpenBalances;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** Narrow, read-only customer credit facts; implementations must recheck customer and financial access. */
public interface ClientCreditFactsPort {
    Snapshot read(UUID clientId);
    record Snapshot(LocalDate asOf, PartyOpenBalances balances, long formalRows, long openRows,
            long overdueRows, BigDecimal overdueLocal, long missingDueDateRows,
            BigDecimal receivedLocal, LocalDate latestSettledDate) {}
}
