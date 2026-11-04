package com.uten.imp.application.port;

import java.time.OffsetDateTime;
import java.util.*;

/** Minimal verified bank facts for an authorized customer-shipment review, distinct from open AR. */
public interface CustomerActualReceiptContextPort {
    record Receipt(UUID receiptId,String billNo,String bankBookedAt,String accountCurrency,String accountAmount,String cashLocal) { }
    record Context(boolean available,String asOf,long verifiedCount,String verifiedCashLocal,long pendingCount,List<Receipt> receipts,boolean more,String basis) { }
    Context read(UUID clientId,UUID tradeCurrencyId,OffsetDateTime asOf);
}
