package com.uten.imp.features.master.referencemethod;

import jakarta.validation.constraints.NotBlank;

/** 结算方式新建请求（payment_style:edit；销售单据编辑页「结帐方式」内联新增用）。 */
public record SettlementMethodSaveRequest(@NotBlank String name) {}
