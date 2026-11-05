package com.uten.imp.features.finance.receivables;

import com.uten.imp.application.port.ShipmentReceivableFilterPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.arap.ArApLedger;
import jakarta.persistence.criteria.*;
import org.springframework.stereotype.Component;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Locale;
import java.util.UUID;

/** This is a current formal debt filter, not an estimate from shipment/order totals. */
@Component
public class ShipmentReceivableFilterAdapter implements ShipmentReceivableFilterPort {
    @Override public Predicate predicate(CriteriaBuilder builder, CriteriaQuery<?> query,
                                         Expression<UUID> shipmentId, String state) {
        String normalized=state==null?"":state.trim().toUpperCase(Locale.ROOT);
        if(normalized.isEmpty())return builder.conjunction();
        if(!"OPEN".equals(normalized)&&!"OVERDUE".equals(normalized))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择有效的出货收款范围");
        Subquery<UUID> debt=query.subquery(UUID.class);
        Root<ArApLedger> ledger=debt.from(ArApLedger.class);
        var conditions=new ArrayList<Predicate>();
        conditions.add(builder.equal(ledger.get("direction"),"AR"));
        conditions.add(builder.equal(ledger.get("openItemKind"),"RECEIVABLE"));
        conditions.add(builder.equal(ledger.get("sourceDocType"),"SALES_SHIPMENT"));
        conditions.add(builder.equal(ledger.get("sourceDocId"),shipmentId));
        conditions.add(builder.equal(ledger.get("status"),(short)1));
        conditions.add(builder.isFalse(ledger.get("deleted")));
        conditions.add(builder.greaterThan(ledger.<BigDecimal>get("amountBalanceOriginal"),BigDecimal.ZERO));
        if("OVERDUE".equals(normalized))
            conditions.add(builder.lessThan(ledger.get("dueDate"),BusinessTime.today()));
        debt.select(ledger.get("sourceDocId")).where(conditions.toArray(Predicate[]::new));
        return builder.exists(debt);
    }
}
