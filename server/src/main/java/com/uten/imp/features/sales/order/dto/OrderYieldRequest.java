package com.uten.imp.features.sales.order.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;

/**
 * 稀缺让单重排请求：主管释放某订单行的部分/全部现货预留。
 *
 * <p>释放量不超过该行 {@code reserved_qty}；释放后该行 chain_status 回退待排产，
 * 缺口自动回调度转生产补足，并通知其归属销售。库存回到可分配池供急单随后经正常预留链占用。
 */
@Getter
@Setter
public class OrderYieldRequest {
    /** 让单数量（行单位，≤该行生效预留 reserved_qty）。 */
    @NotNull
    @DecimalMin(value = "0.0001", message = "让单数量必须大于 0")
    private BigDecimal qty;

    /** 让单原因（必填，记审计 + 通知被让单销售）。 */
    @NotBlank(message = "让单须填写原因")
    private String reason;

    /** 调入方订单号（可选，通知文案用，便于被让单销售了解库存去向）。 */
    private String yielderOrderNo;
}
