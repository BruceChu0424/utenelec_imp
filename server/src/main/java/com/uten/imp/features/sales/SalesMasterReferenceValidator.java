package com.uten.imp.features.sales;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.features.sales.order.SalesOrderItem;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.features.sales.quote.SalesQuoteItem;
import com.uten.imp.features.sales.quote.dto.QuoteItemLine;
import com.uten.imp.features.sales.quote.dto.QuoteSaveRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.util.List;

/** Validates and normalizes client-supplied master references before sales persistence. */
@Service
@RequiredArgsConstructor
public class SalesMasterReferenceValidator {

    private final MasterReferenceValidationPort references;

    public void validate(QuoteSaveRequest request) {
        references.requireVisibleActiveClient(request.getClientId());
        List<QuoteItemLine> lines = request.getItems();
        if (lines == null) return;
        int fallbackLineNo = 1;
        for (QuoteItemLine line : lines) {
            int lineNo = line.getLineNo() == null ? fallbackLineNo : line.getLineNo();
            var resolved = references.resolveVisibleActiveGoodsUnit(
                    line.getGoodsId(), line.getUnitId(), line.getUnitRate(), lineNo);
            line.setUnitId(resolved.unitId());
            line.setUnitRate(resolved.unitRate());
            fallbackLineNo++;
        }
    }

    public void validate(OrderSaveRequest request) {
        references.requireVisibleActiveClient(request.getClientId());
        List<OrderItemLine> lines = request.getItems();
        if (lines == null) return;
        int fallbackLineNo = 1;
        for (OrderItemLine line : lines) {
            int lineNo = line.getLineNo() == null ? fallbackLineNo : line.getLineNo();
            var resolved = references.resolveVisibleActiveGoodsUnit(
                    line.getGoodsId(), line.getUnitId(), line.getUnitRate(), lineNo);
            line.setUnitId(resolved.unitId());
            line.setUnitRate(resolved.unitRate());
            fallbackLineNo++;
        }
    }

    /** 审核前重验已保存引用，防止草稿期间主档被停用、软删或收回归属授权。 */
    public void validateStoredQuote(java.util.UUID clientId, List<SalesQuoteItem> lines) {
        references.requireVisibleActiveClient(clientId);
        for (SalesQuoteItem line : lines) {
            normalizeStoredLine(line.getGoodsId(), line.getUnitId(), line.getUnitRate(),
                    line.getLineNo(), line::setUnitId, line::setUnitRate);
        }
    }

    /** 审核前重验已保存引用，防止草稿期间主档被停用、软删或收回归属授权。 */
    public void validateStoredOrder(java.util.UUID clientId, List<SalesOrderItem> lines) {
        references.requireVisibleActiveClient(clientId);
        for (SalesOrderItem line : lines) {
            normalizeStoredLine(line.getGoodsId(), line.getUnitId(), line.getUnitRate(),
                    line.getLineNo(), line::setUnitId, line::setUnitRate);
        }
    }

    private void normalizeStoredLine(
            java.util.UUID goodsId,
            java.util.UUID unitId,
            java.math.BigDecimal unitRate,
            Integer lineNo,
            java.util.function.Consumer<java.util.UUID> unitSetter,
            java.util.function.Consumer<java.math.BigDecimal> rateSetter) {
        int effectiveLineNo = lineNo == null ? 1 : lineNo;
        var resolved = references.resolveVisibleActiveGoodsUnit(
                goodsId, unitId, unitRate, effectiveLineNo);
        unitSetter.accept(resolved.unitId());
        rateSetter.accept(resolved.unitRate());
    }
}
