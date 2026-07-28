package com.uten.imp.features.sales.order.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 销售订货新建/编辑请求（BOM 展开不参与编辑，仅主表 + 订货明细）。 */
@Getter
@Setter
public class OrderSaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    @NotNull
    private UUID clientId;

    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private Integer paymentStyleId;
    private UUID sellerId;
    private LocalDate deliverDate;
    private String contractNo;
    private String linkPhone;
    private String signAddr;
    private String shipAddr;
    private BigDecimal deposit;
    private String remark;

    @Valid
    @NotNull
    private List<OrderItemLine> items;
}
