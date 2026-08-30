package com.uten.imp.features.sales;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.order.SalesOrderController;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.order.SalesOrderTimelineService;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.other_shipment.SalesOtherShipmentController;
import com.uten.imp.features.sales.other_shipment.SalesOtherShipmentService;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentDetail;
import com.uten.imp.features.sales.quote.SalesQuoteController;
import com.uten.imp.features.sales.quote.SalesQuoteService;
import com.uten.imp.features.sales.quote.dto.QuoteDetail;
import com.uten.imp.features.sales.ret.SalesReturnController;
import com.uten.imp.features.sales.ret.SalesReturnQualityService;
import com.uten.imp.features.sales.ret.SalesReturnService;
import com.uten.imp.features.sales.ret.dto.ReturnDetail;
import com.uten.imp.features.sales.shipment.SalesShipmentController;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class SalesDetailViewAuditControllerTest {

    @Test
    void allFiveSuccessfulDetailsRecordUuidBillNumberAndLegacyMarker() {
        AuditDetailViewRecorder audit = mock(AuditDetailViewRecorder.class);

        UUID quoteId = UUID.randomUUID();
        SalesQuoteService quotes = mock(SalesQuoteService.class);
        QuoteDetail quote = detail(QuoteDetail.class, "BJ-001", 11);
        when(quotes.detail(quoteId)).thenReturn(quote);
        assertSame(quote, new SalesQuoteController(quotes, audit).detail(quoteId));
        verify(audit).record(
                "view_sales_quote_detail", "sales_quotes", quoteId,
                "BJ-001", 11, "销售报价单");

        UUID orderId = UUID.randomUUID();
        SalesOrderService orders = mock(SalesOrderService.class);
        OrderDetail order = detail(OrderDetail.class, "SO-001", 22);
        when(orders.detail(orderId)).thenReturn(order);
        assertSame(order, new SalesOrderController(
                orders, mock(SalesOrderTimelineService.class), audit).detail(orderId));
        verify(audit).record(
                "view_sales_order_detail", "sales_orders", orderId,
                "SO-001", 22, "销售订货单");

        UUID shipmentId = UUID.randomUUID();
        SalesShipmentService shipments = mock(SalesShipmentService.class);
        ShipmentDetail shipment = detail(ShipmentDetail.class, "XS-001", 33);
        when(shipments.detail(shipmentId)).thenReturn(shipment);
        assertSame(shipment, new SalesShipmentController(shipments, audit).detail(shipmentId));
        verify(audit).record(
                "view_sales_shipment_detail", "sales_shipments", shipmentId,
                "XS-001", 33, "销售出货单");

        UUID otherId = UUID.randomUUID();
        SalesOtherShipmentService others = mock(SalesOtherShipmentService.class);
        OtherShipmentDetail other = detail(OtherShipmentDetail.class, "QT-001", 44);
        when(others.detail(otherId)).thenReturn(other);
        assertSame(other, new SalesOtherShipmentController(others, audit).detail(otherId));
        verify(audit).record(
                "view_sales_other_shipment_detail", "sales_other_shipments", otherId,
                "QT-001", 44, "其它出货单");

        UUID returnId = UUID.randomUUID();
        SalesReturnService returns = mock(SalesReturnService.class);
        ReturnDetail salesReturn = detail(ReturnDetail.class, "XT-001", 55);
        when(returns.detail(returnId)).thenReturn(salesReturn);
        assertSame(salesReturn, new SalesReturnController(
                returns, mock(SalesReturnQualityService.class), audit).detail(returnId));
        verify(audit).record(
                "view_sales_return_detail", "sales_returns", returnId,
                "XT-001", 55, "销售退货单");
    }

    @Test
    void notFoundOrForbiddenDetailNeverWritesSuccessfulViewEvent() {
        AuditDetailViewRecorder audit = mock(AuditDetailViewRecorder.class);
        SalesQuoteService service = mock(SalesQuoteService.class);
        UUID id = UUID.randomUUID();
        when(service.detail(id)).thenThrow(new ApiException(ErrorCode.NOT_FOUND));

        assertThrows(ApiException.class,
                () -> new SalesQuoteController(service, audit).detail(id));

        UUID forbiddenId = UUID.randomUUID();
        when(service.detail(forbiddenId)).thenThrow(new ApiException(ErrorCode.FORBIDDEN));
        assertThrows(ApiException.class,
                () -> new SalesQuoteController(service, audit).detail(forbiddenId));

        verifyNoInteractions(audit);
    }

    private <T> T detail(Class<T> type, String billNo, int legacyId) {
        T value = mock(type);
        if (value instanceof QuoteDetail detail) {
            when(detail.getBillNo()).thenReturn(billNo);
            when(detail.getLegacyId()).thenReturn(legacyId);
        } else if (value instanceof OrderDetail detail) {
            when(detail.getBillNo()).thenReturn(billNo);
            when(detail.getLegacyId()).thenReturn(legacyId);
        } else if (value instanceof ShipmentDetail detail) {
            when(detail.getBillNo()).thenReturn(billNo);
            when(detail.getLegacyId()).thenReturn(legacyId);
        } else if (value instanceof OtherShipmentDetail detail) {
            when(detail.getBillNo()).thenReturn(billNo);
            when(detail.getLegacyId()).thenReturn(legacyId);
        } else if (value instanceof ReturnDetail detail) {
            when(detail.getBillNo()).thenReturn(billNo);
            when(detail.getLegacyId()).thenReturn(legacyId);
        }
        return value;
    }
}
