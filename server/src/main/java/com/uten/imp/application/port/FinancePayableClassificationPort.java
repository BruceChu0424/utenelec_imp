package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.*;

/** Exact goods/tooling identity for an existing payable and its actual credit.
 * This writes category evidence only; the payables owner posts every amount. */
public interface FinancePayableClassificationPort {
    record Part(String category,BigDecimal amountOriginal,BigDecimal amountLocal,BigDecimal remainingOriginal,BigDecimal remainingLocal){
        public Part(String category,BigDecimal amountOriginal,BigDecimal amountLocal){this(category,amountOriginal,amountLocal,null,null);}
    }
    record Target(UUID ledgerId,UUID classificationId,long revision,List<Part> parts){
        public Target{parts=List.copyOf(parts);}
    }
    record Assignment(UUID operationId,UUID creditLedgerId,UUID targetLedgerId,UUID offsetId,
        UUID expectedTargetClassificationId,String category,BigDecimal amountOriginal,
        BigDecimal sourceLocal,BigDecimal targetLocal,String sourceReference){ }
    record Applied(UUID sourceClassificationId,UUID offsetClassificationId){ }
    Target target(UUID ledgerId);
    /** Acquire before AP/style row locks when a writing domain will assign
     * category evidence later in this same transaction. */
    void lockForWrite();
    Applied assign(Assignment command);
}
