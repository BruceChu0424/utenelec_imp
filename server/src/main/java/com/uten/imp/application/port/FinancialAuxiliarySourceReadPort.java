package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Immutable, parsed source detail; the connector still validates real identities and amount conservation. */
public interface FinancialAuxiliarySourceReadPort {
    record Row(int sourceRow,String accountCode,String accountName,String partyCode,String partyName,BigDecimal openingDebit,
               BigDecimal openingCredit,BigDecimal debit,BigDecimal credit,BigDecimal closingDebit,BigDecimal closingCredit,
               UUID currencyId,Long chartVersion) {
        public Row(int sourceRow,String accountCode,String accountName,String partyCode,String partyName,BigDecimal openingDebit,
                BigDecimal openingCredit,BigDecimal debit,BigDecimal credit,BigDecimal closingDebit,BigDecimal closingCredit) {
            this(sourceRow,accountCode,accountName,partyCode,partyName,openingDebit,openingCredit,debit,credit,closingDebit,closingCredit,null,null);
        }
    }
    record Source(UUID importId,UUID actorId,String role,String sourceSystem,UUID currencyId,LocalDate dateFrom,
                  LocalDate dateTo,String sha256,boolean valid,List<Row> rows) { }
    Source readForAccounting(UUID sourceId);
}
