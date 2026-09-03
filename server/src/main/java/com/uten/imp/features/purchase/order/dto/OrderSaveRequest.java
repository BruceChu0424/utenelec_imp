package com.uten.imp.features.purchase.order.dto;

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

@Getter
@Setter
public class OrderSaveRequest {
    private String billNo;
    @NotNull private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private UUID purchaserId;
    /**
     * 结账方式：单张创建/编辑必填（服务端 create/update 运行时校验，原 @NotNull
     * 已随批量拆单放开——批量请求头不再携带商业条款，改为逐行校验后按组合归集）。
     */
    private UUID settlementMethodId;
    private Integer settlementStyleLegacy;
    private LocalDate deliverDate;
    private String remark;
    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<OrderItemLine> items;
}
