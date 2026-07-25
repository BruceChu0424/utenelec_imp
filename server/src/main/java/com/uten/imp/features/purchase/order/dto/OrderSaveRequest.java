package com.uten.imp.features.purchase.order.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

@Getter
@Setter
public class OrderSaveRequest {
    @NotBlank private String billNo;
    @NotNull private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private UUID purchaserId;
    private LocalDate deliverDate;
    private String remark;
    @Valid @NotNull private List<OrderItemLine> items;
}
