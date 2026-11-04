package com.uten.imp.application.port;

import java.util.*;

/** A financial code's currency identity is maintained once; source names never resolve a UUID. */
public interface FinancialChartCurrencyReadPort {
    record Choice(UUID id,String code,String name,boolean baseCurrency,String status) { }
    record Reference(String accountCode,UUID currencyId,boolean baseCurrency,String sourceCurrencyName,long chartVersion) { }
    List<Choice> choices();
    /** A missing foreign mapping is returned as a null currencyId, so preview can locate the problem. */
    Map<String,Reference> read(Set<String> accountCodes);
}
