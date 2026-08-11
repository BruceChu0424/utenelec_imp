package com.uten.imp.features.sales;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.features.sales.quote.dto.QuoteItemLine;
import com.uten.imp.features.sales.quote.dto.QuoteSaveRequest;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SalesMasterReferenceValidatorTest {

    @Test
    void validatesQuoteClientAndNormalizesEveryLine() {
        MasterReferenceValidationPort references = mock(MasterReferenceValidationPort.class);
        SalesMasterReferenceValidator validator = new SalesMasterReferenceValidator(references);
        UUID clientId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID baseUnitId = UUID.randomUUID();
        QuoteItemLine line = new QuoteItemLine();
        line.setGoodsId(goodsId);
        QuoteSaveRequest request = new QuoteSaveRequest();
        request.setClientId(clientId);
        request.setItems(List.of(line));
        when(references.resolveVisibleActiveGoodsUnit(goodsId, null, null, 1))
                .thenReturn(new MasterReferenceValidationPort.ResolvedLineUnit(
                        baseUnitId, BigDecimal.ONE));

        validator.validate(request);

        verify(references).requireVisibleActiveClient(clientId);
        assertEquals(baseUnitId, line.getUnitId());
        assertEquals(0, BigDecimal.ONE.compareTo(line.getUnitRate()));
    }

    @Test
    void validatesOrderClientAndUsesTheExplicitLineNumber() {
        MasterReferenceValidationPort references = mock(MasterReferenceValidationPort.class);
        SalesMasterReferenceValidator validator = new SalesMasterReferenceValidator(references);
        UUID clientId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        OrderItemLine line = new OrderItemLine();
        line.setLineNo(7);
        line.setGoodsId(goodsId);
        line.setUnitId(unitId);
        line.setUnitRate(new BigDecimal("12"));
        OrderSaveRequest request = new OrderSaveRequest();
        request.setClientId(clientId);
        request.setItems(List.of(line));
        when(references.resolveVisibleActiveGoodsUnit(
                goodsId, unitId, new BigDecimal("12"), 7))
                .thenReturn(new MasterReferenceValidationPort.ResolvedLineUnit(
                        unitId, new BigDecimal("12")));

        validator.validate(request);

        verify(references).requireVisibleActiveClient(clientId);
        verify(references).resolveVisibleActiveGoodsUnit(
                goodsId, unitId, new BigDecimal("12"), 7);
    }
}
