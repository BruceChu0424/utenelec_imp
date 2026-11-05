package com.uten.imp.features.sales.order.dto;

import com.uten.imp.common.delivery.DeliveryPlan;
import lombok.Getter;
import lombok.Setter;

/** Separate inherited field keeps every pre-existing OrderItemDto constructor source-compatible. */
@Getter
@Setter
public class OrderDeliveryFields extends com.uten.imp.features.sales.SalesDocumentLineResponse {
    private DeliveryPlan deliveryPlan = DeliveryPlan.assembled();
}
