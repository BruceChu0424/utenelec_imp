package com.uten.imp.features.master.currency.dto;

import jakarta.validation.constraints.NotBlank;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;

/**
 * 币种新建/编辑请求（currency:edit）。
 *
 * <p>名称（必填）/ 编号 / 参考汇率 / 状态（使用/禁用）。
 * legacy_id/审计/软删/auto_created 不可改；新建与编辑共用本 DTO。
 */
@Getter
@Setter
public class CurrencySaveRequest {

    @NotBlank
    private String name;             // 币种名称（人民币/美金/港币）
    private String code;             // 币种编号（001/002/003）
    private BigDecimal exchangeRate; // 参考汇率
    private String status;           // 使用/禁用
}
