package com.uten.imp.features.sales.order.dto;

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
    /**
     * 旧客户端兼容字段，服务端忽略该值。关联出货到达 SHIPPED 时，
     * 才由财务维护的汇率形成正式立账快照。
     */
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private Integer paymentStyleId;
    private UUID settlementMethodId;
    private UUID sellerId;
    private LocalDate deliverDate;
    private String contractNo;
    private String linkPhone;
    private String signAddr;
    private String shipAddr;
    /**
     * @deprecated Compatibility input only. The sales service ignores it; customer
     * advances are finance-owned money facts registered through FinanceReceipt.
     */
    @Deprecated
    private BigDecimal deposit;
    private String remark;
    /** 来源单据号显示快照；报价转入关系由服务端 UUID 入口建立，不按本字段回查。 */
    private String sourceDocNo;

    /**
     * ALLOW_PARTIAL / REQUIRE_COMPLETE / CUSTOMER_CONFIRM.
     * Null leaves a new order unset and preserves the stored value on update;
     * non-null values are normalized and validated by the order service.
     */
    private String shipmentPolicy;

    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<OrderItemLine> items;
}
