package com.uten.imp.features.master.goods.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

/**
 * 组装信息行审计标记请求（goods:bom:audit）。
 * audited=true 标记「该组件已核对无误」；false 取消标记。
 */
@Getter
@Setter
public class BomAuditRequest {

    @NotNull
    private Boolean audited;
}
