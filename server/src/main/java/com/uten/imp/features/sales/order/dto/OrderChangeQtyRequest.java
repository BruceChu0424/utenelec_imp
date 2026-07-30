package com.uten.imp.features.sales.order.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 订单改量请求（业务链 · 异常段，V100）。
 *
 * <p>规则（SOP）：新数量 ≥ 已发净量（shipped − returned）；
 * 增量重走库存检查+软预留（不足部分自动回到调度待排产）；
 * 减量先释放预留、再回退排产分摊（断链接留痕）；
 * 涉及已排产/已产行需持 sales_order:change_planned（生产部确认）。
 */
@Getter
@Setter
public class OrderChangeQtyRequest {

    @Valid
    @NotEmpty
    private List<Line> items;

    @Getter
    @Setter
    public static class Line {
        @NotNull
        private UUID orderItemId;
        @NotNull
        private BigDecimal newQty;
    }
}
