package com.uten.imp.common.integrity;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.util.UUID;

/** A source document's quantity conversion is a recorded fact, not today's goods default. */
public final class SourceQuantityBasis {
    private SourceQuantityBasis() { }
    public static BigDecimal requireKnown(UUID unitId,BigDecimal rate) {
        if(unitId==null||rate==null||rate.signum()<=0) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "来源单据的单位或换算率尚未核验，不能默认按1换算或继续累计数量，请先核对原始计量依据");
        }
        return rate;
    }
}
