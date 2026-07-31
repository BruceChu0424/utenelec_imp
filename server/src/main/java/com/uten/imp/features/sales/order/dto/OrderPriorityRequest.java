package com.uten.imp.features.sales.order.dto;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

/**
 * 设置订单行优先级请求（V178 缺口 B）：1急单 / 2普通 / 3现货。
 * 设为急单(1) 须填原因；全程审计。优先级仅用于稀缺手动让单的决策与排序，不触发自动抢占。
 */
@Getter
@Setter
public class OrderPriorityRequest {
    @NotNull
    @Min(value = 1, message = "优先级取值 1/2/3")
    @Max(value = 3, message = "优先级取值 1/2/3")
    private Short priority;

    /** 原因（设为急单时必填，前端校验 + 服务端复核；普通/现货可选）。 */
    private String reason;
}
