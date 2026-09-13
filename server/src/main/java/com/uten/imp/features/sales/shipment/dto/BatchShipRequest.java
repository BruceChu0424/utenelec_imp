package com.uten.imp.features.sales.shipment.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 批量发货开单请求（SOP §一9）：勾选可发行 + 本次数量，
 * 服务端按客户 + 归属人分组；只有同客户、同 owner 的行才会合并为一张出货草稿。
 */
@Getter
@Setter
public class BatchShipRequest {

    @NotNull
    private LocalDate billDate;

    /** 出货仓（可空：旧客户端可指定；新自动分仓由实际库存来源建议，仓库最终确认）。 */
    private UUID warehouseId;

    private String remark;
    @Size(min=8,max=128) private String idempotencyKey;
    private String shipAddr;
    private String linkPhone;
    private String logisticsNo;
    private UUID sellerId;
    private UUID senderId;
    private UUID settlementMethodId;
    @jakarta.validation.constraints.Min(0) private Integer parcelCount;

    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<Line> lines;

    @Getter
    @Setter
    public static class Line {
        @NotNull
        private UUID orderItemId;
        @NotNull
        private BigDecimal qty;
        /** 本次发货行的实际总重量；不从订单或货品单重猜测。 */
        @DecimalMin(value = "0", inclusive = true)
        @Digits(integer = 14, fraction = 4)
        private BigDecimal weight;
        private String remark;
    }
}
