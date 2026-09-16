package com.uten.imp.features.production.dailyreport.dto;

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
}
