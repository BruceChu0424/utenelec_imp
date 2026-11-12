package com.uten.imp.features.sales.quote.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.UUID;

/**
 * 财务退回 / 确认报价请求。退回原因(text)选填(2026-11-11 口径, 留空记「未填写原因」);
 * 确认时 text 是可选的财务备注。expectedClaimId 为页面持有的认领代次, 认领被接管后按冲突拒绝。
 */
public record QuoteFinanceDecisionRequest(
        @NotNull(message = "缺少核价修订号, 请刷新后重试") Integer expectedRevision,
        UUID expectedClaimId,
        @Size(max = 500, message = "内容不能超过 500 个字符") String text) {
}
