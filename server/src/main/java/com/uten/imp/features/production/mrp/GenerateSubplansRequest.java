package com.uten.imp.features.production.mrp;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 按车间拆分生成子计划请求：用户自选自制件行（可部分）、各自数量与归属车间。
 * 服务端按 货品+颜色 净需求 − 已有子计划量 做防超产硬校验，按车间分组各生成一张草稿计划。
 */
@Getter
@Setter
public class GenerateSubplansRequest {

    @NotEmpty(message = "至少选择一行自制件")
    @Valid
    private List<Line> items;

    @Getter
    @Setter
    public static class Line {
        @NotNull
        private UUID goodsId;
        private UUID colorId;
        private UUID unitId;
        @NotNull
        @Positive(message = "排产量必须大于 0")
        private BigDecimal qty;
        /** 归属车间（部门 id）；空则归入未指定车间组。 */
        private UUID departmentId;
        /** 车间名冗余（报表 facet）；空则由服务端按部门解析。 */
        private String workshopName;
    }

    /** 一张生成的子计划结果。 */
    public record Created(UUID planId, String billNo, int lineCount, String workshopName) {
    }
}
