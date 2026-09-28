package com.uten.imp.features.production.dailyreport.dto;

import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 报工同页登记的一条「本次实际用料」(V583)。
 *
 * <p>只收需求 UUID 与基本量：计划、物料所属执行段、单位都由服务端从
 * {@code production_material_demands} 反查，客户端报什么都不算数。
 */
@Getter
@Setter
public class DailyReportMaterialUsageLine {

    @NotNull
    private UUID demandId;

    /** 允许 0：「这批料一点没用」是合法事实，不能逼车间编一个正数。 */
    @NotNull
    @PositiveOrZero
    private BigDecimal qtyBase;

    /**
     * 实盘收尾(ADR-129 §2.7)：最后一次报工清点出的实际剩余(基本量)，空 = 没有清点。
     * 填了时审核按「本次用料 = 审核时的账面可用 − 实际剩余」覆盖 qtyBase，退仓按实际剩余。
     */
    @PositiveOrZero
    @Digits(integer = 14, fraction = 4)
    private BigDecimal countedLeftoverQty;
}
