package com.uten.imp.common.finance;

import java.math.BigDecimal;
import java.math.RoundingMode;

/** One consumption curve; callers choose economic projection or the existing execution storage boundary. */
public final class BomConsumptionCurve {
    private BomConsumptionCurve() {}
    public static BigDecimal raw(BigDecimal output,BigDecimal qty,String basis,BigDecimal base,
            boolean partial,int divisionScale,RoundingMode divisionMode) {
        if(output==null || output.signum()<=0) return BigDecimal.ZERO;
        CostFraction result=exact(CostFraction.of(output),qty,basis,base,partial);
        if("PER_PACKAGE".equals(basis==null?"PER_UNIT":basis.strip().toUpperCase(java.util.Locale.ROOT))&&partial)
            return result.scaled(divisionScale,divisionMode);
        return result.project();
    }
    public static CostFraction exact(CostFraction output,BigDecimal qty,String basis,BigDecimal base,boolean partial) {
        if(output==null || output.signum()<=0)return CostFraction.of(BigDecimal.ZERO);
        if(qty==null || qty.signum()<=0 || base==null || base.signum()<=0)
            throw new IllegalArgumentException("BOM用量与基准产量必须大于零");
        String mode=basis==null?"PER_UNIT":basis.strip().toUpperCase(java.util.Locale.ROOT);
        return switch(mode) {
            case "PER_UNIT" -> output.multiply(qty);
            case "PER_PACKAGE" -> partial
                    ? output.multiply(qty).divide(base)
                    : CostFraction.of(output.divide(base).ceiling()).multiply(qty);
            case "FIXED_BATCH" -> CostFraction.of(output.divide(base).ceiling()).multiply(qty);
            default -> throw new IllegalArgumentException("不支持的物料计量方式");
        };
    }
}
