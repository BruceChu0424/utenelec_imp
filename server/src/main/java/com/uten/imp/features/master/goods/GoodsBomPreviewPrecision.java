package com.uten.imp.features.master.goods;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.Map;
import java.util.function.Supplier;

/** A confirmed BOM preview retains the explicit choices that produced it. */
final class GoodsBomPreviewPrecision {
    private GoodsBomPreviewPrecision() { }
    static Map<String,BusinessPrecisionContext.Choice> snapshot() {
        return Map.copyOf(BusinessPrecisionContext.choices());
    }
    static <T> T confirm(Map<String,BusinessPrecisionContext.Choice> frozen,Supplier<T> write) {
        var supplied=BusinessPrecisionContext.choices();
        if(!supplied.isEmpty() && !supplied.equals(frozen))
            throw new ApiException(ErrorCode.CONFLICT,"数值采用选择已变化，请重新预览后确认；本次未保存");
        try(var ignored=BusinessPrecisionContext.use(frozen)) { return write.get(); }
        catch(RuntimeException failure) { throw failure; }
        catch(Exception failure) { throw new IllegalStateException("无法恢复本次BOM预览的明确数值选择",failure); }
    }
}
