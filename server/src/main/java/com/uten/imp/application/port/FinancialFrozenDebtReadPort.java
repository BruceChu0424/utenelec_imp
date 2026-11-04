package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Existing debts are cleared using their booked account/party/unit evidence, never a newly changed global role. */
public interface FinancialFrozenDebtReadPort {
    record Entry(String evidenceKind,UUID voucherId,UUID entryId,Integer allocationNo,
            UUID styleId,String accountCode,UUID accountingCurrencyId,
            FinancialAuxiliaryValidationPort.Ref auxiliary,UUID originalCurrencyId,
            BigDecimal amountOriginal,BigDecimal amountLocal,int naturalDirection,String fingerprint) { }
    record Debt(UUID ledgerId,String direction,NativeFinancialPostingAccountPort.Party party,
            UUID originalCurrencyId,LocalDate postingDate,BigDecimal amountOriginal,BigDecimal amountLocal,
            BigDecimal remainingOriginal,BigDecimal remainingLocal,List<Entry> entries,boolean complete,String basis,String fingerprint) { }
    /** Read-only, actual source UUIDs only. Owner authorizes the settlement and locks its original balances before posting. */
    Map<UUID,Debt> readArAp(List<UUID> ledgerIds);
}
