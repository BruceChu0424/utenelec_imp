package com.uten.imp.features.production.schedule.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 合并排产请求（调度工作台）：勾选若干订单行 → 一张生产计划（草稿）。
 *
 * <p>同货品+颜色的行自动合并为一个计划行（批量生产减少换线）；
 * 每订单行的分摊量预写 plan_order_item_links，审核时校验回写（不再按 salesOrderItemId 单行推导）。
 */
@Getter
@Setter
public class MergePlanRequest {

    @Valid
    @NotEmpty
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<Line> items;

    /** 计划开工/完工日期（落到每个计划行）。 */
    private LocalDate planBeginDate;
    private LocalDate planEndDate;

    /** 交货日期（主表；缺省取所选行最早交货日）。 */
    private LocalDate deliveryDate;

    private UUID departmentId;
    private String workshopName;
    private String workerName;
    private String remark;

    @Getter
    @Setter
    public static class Line {
        @NotNull
        private UUID orderItemId;
        /** 本订单行本次排产量（≤ 待生产缺口）。 */
        @NotNull
        private BigDecimal qty;
    }
}
