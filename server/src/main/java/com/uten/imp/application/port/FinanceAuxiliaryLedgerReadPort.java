package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** Read the one posted GL at its exact auxiliary/account-property/original-unit grain. */
public interface FinanceAuxiliaryLedgerReadPort {
    record Scope(String accountCode,UUID auxiliaryId,UUID accountingCurrencyId,UUID originalCurrencyId,
                 LocalDate dateFrom,LocalDate dateTo) { }
    record Amounts(BigDecimal opening,BigDecimal debit,BigDecimal credit,BigDecimal closing,boolean known) { }
    record Balance(Scope scope,Amounts local,Amounts original,long sourceRows,String fingerprint,String basis,String originalFingerprint) {
        public Balance(Scope scope,Amounts local,Amounts original,long sourceRows,String fingerprint,String basis){
            this(scope,local,original,sourceRows,fingerprint,basis,fingerprint);
        }
    }
    Balance read(Scope scope);
}
