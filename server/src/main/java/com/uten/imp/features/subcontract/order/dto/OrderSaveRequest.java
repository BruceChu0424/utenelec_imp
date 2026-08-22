package com.uten.imp.features.subcontract.order.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外订货单新建/编辑请求（主表字段 + 明细行）。BOM 成本子表只读，不参与保存。 */
@Getter
@Setter
public class OrderSaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private UUID settlementMethodId;
    private BigDecimal taxRate;
    private UUID purchaserId;
    private LocalDate deliverDate;
    private String remark;

    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<OrderItemLine> items;
}
