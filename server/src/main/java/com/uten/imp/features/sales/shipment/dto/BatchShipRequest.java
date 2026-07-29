package com.uten.imp.features.sales.shipment.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 批量发货开单请求（SOP §一9）：勾选可发行 + 本次数量，
 * 服务端按客户分组，同客户合并生成一张出货草稿。
 */
@Getter
@Setter
public class BatchShipRequest {

    @NotNull
    private LocalDate billDate;

    /** 出货仓（可空：草稿可先不指定，审核前必填）。 */
    private UUID warehouseId;

    private String remark;

    @Valid
    @NotNull
    private List<Line> lines;

    @Getter
    @Setter
    public static class Line {
        @NotNull
        private UUID orderItemId;
        @NotNull
        private BigDecimal qty;
    }
}
