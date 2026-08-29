package com.uten.imp.features.finance.payment.dto;

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

/** 采购付款单新建/编辑请求（明细可空 = 直接付款 / 供应商预付）。 */
@Getter
@Setter
public class FinancePaymentSaveRequest {

    private String billNo;
    private Long expectedVersion;

    @Size(min = 8, max = 128)
    private String createIdempotencyKey;

    @NotNull
    private LocalDate billDate;

    private UUID supplierId;
    private UUID accountId;
    private UUID counterpartAccountId;
    private UUID currencyId;
    @NotNull
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    /** 服务端按原币金额与付款汇率重算；仅保留用于兼容旧客户端。 */
    private BigDecimal amountLocal;
    private UUID paymentMethodId;
    private Integer paymentMethodLegacyId;
    private String invoiceNo;
    private String operatorName;
    private UUID operatorId;
    private String sourceRemark;
    private String remark;

    @Valid
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<FinancePaymentLineInput> items;
}
