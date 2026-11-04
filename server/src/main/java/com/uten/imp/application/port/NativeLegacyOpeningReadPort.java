package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.*;

/** Reviewed references to already-existing R1 money and immutable verified bootstrap opening state. */
public interface NativeLegacyOpeningReadPort {
    record Binding(UUID reviewId,NativeFinancialPostingAccountPort.Account account,List<FinancialFrozenDebtReadPort.Entry> sources,
            @com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal initialLocal,@com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal initialOriginal,String fingerprint) { }
    Binding read(UUID ledgerId);
}
