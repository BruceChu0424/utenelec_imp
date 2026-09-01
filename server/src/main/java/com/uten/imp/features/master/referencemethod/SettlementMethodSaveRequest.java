package com.uten.imp.features.master.referencemethod;

import jakarta.validation.constraints.NotBlank;

/**
 * 结算方式新建请求（settlement_method:create）。
 *
 * <p>销售/采购/委外单据编辑页「结账方式」下拉的内联新增只传 name（账期落库默认
 * 收货日当天到期）；结算方式管理页可同时提交账期策略（termsBase/dueRule/...，
 * 校验与 {@link SettlementMethodTermsRequest} 同一套）。
 */
public record SettlementMethodSaveRequest(
        @NotBlank String name,
        SettlementMethodTermsRequest terms) {}
