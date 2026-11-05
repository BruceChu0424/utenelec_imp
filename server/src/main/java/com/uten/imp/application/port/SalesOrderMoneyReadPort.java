package com.uten.imp.application.port;

import java.util.*;

/**
 * Exact order-attributed finance position; customer unassigned advances remain separate.
 * The owning public caller, including batch wrappers, must establish REPEATABLE_READ
 * or SERIALIZABLE before its first read. A nested REQUIRED annotation cannot upgrade
 * an existing transaction; an unsuitable caller receives unavailable positions.
 */
public interface SalesOrderMoneyReadPort {
    record Position(String cashReceivedOriginal, String plannedRemainingOriginal,
                    String prepaymentAvailableOriginal, String customerUnassignedPrepaymentOriginal,
                    String prepaymentAppliedOriginal,String returnCreditOriginal,String customerPendingBalanceOriginal,
                    String pendingReceiptOriginal,
                    boolean hasUnallocated, boolean positionComplete, String orderBillNo,String currencyName,List<String> warnings) {
        public static Position unavailable() {
            return new Position(null,null,null,null,null,null,null,null,true,false,null,null,
                    List.of("订单资金资料已变化，请刷新后重新核对"));
        }
    }
    Map<UUID, Position> read(Collection<UUID> salesOrderIds, boolean includeCustomerUnassigned);
}
