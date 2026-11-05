package com.uten.imp.application.port;

import java.util.*;

/** Exact cash/debt facts for one physical shipment AR, never an order-wide balance. RR/SERIALIZABLE is required. */
public interface ShipmentReceivablePositionPort {
    record Position(UUID ledgerId,UUID currencyId,String currencyName,String shipmentOriginal,
                    String formalReceivableOriginal,String cashReceivedOriginal,String prepaymentAppliedOriginal,
                    String confirmedPaidOriginal,String reductionOriginal,String returnOffsetOriginal,
                    String otherOffsetOriginal,String balanceOriginal,String dueDate,long overdueDays,
                    String state,boolean complete,List<String> warnings) { }
    Map<UUID,Position> read(Collection<UUID> shipmentIds);
}
