package com.uten.imp.features.sales.shipment.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * Finance reviews a particular sales-confirmed revision while retaining the same live lease.
 *
 * <p>V632：放行可带 {@code exchangeRate}(记账汇率，本位币/1 原币)。不带时用币种主档参考汇率；
 * 带了就以财务填写的为准并冻结到本单，仓库确认出库按它立应收。退回不使用该字段。
 */
public record ShipmentFinanceDecisionRequest(Long expectedRevision,
        @Size(max=64) String expectedContentHash, UUID expectedClaimId,
        @Size(max=500) String reason,
        @DecimalMin(value="0", inclusive=false) @Digits(integer=12, fraction=6) BigDecimal exchangeRate) {

    /** 兼容旧调用(批量放行/退回与既有测试)：不指定汇率。 */
    public ShipmentFinanceDecisionRequest(Long expectedRevision, String expectedContentHash,
            UUID expectedClaimId, String reason) {
        this(expectedRevision, expectedContentHash, expectedClaimId, reason, null);
    }
}
