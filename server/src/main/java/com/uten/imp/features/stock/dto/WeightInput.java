package com.uten.imp.features.stock.dto;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;

/**
 * 仓库单据请求里的称重输入口径(ADR-135 §1 精度约定): 千克, 不小于 0, 最多 4 位小数(0.1 克), 整数部分最多 14 位;
 * 填 0 视为没称(返回 null)。控制器层已有同样的 Bean 校验, 这里给绕过控制器的服务内调用兜底, 并统一请求哈希里的写法。
 */
public final class WeightInput {

    private static final int SCALE = 4;
    private static final int INTEGER_DIGITS = 14;

    private WeightInput() {
    }

    /**
     * 规范化一个称重输入。
     *
     * @param kg    请求里的千克数(可空)
     * @param label 报错时指明是哪一格(如「第 3 行实称重量」)
     * @return 大于 0 的千克数(4 位小数); 空或 0 返回 null
     */
    public static BigDecimal kg(BigDecimal kg, String label) {
        if (kg == null || kg.signum() == 0) return null;
        if (kg.signum() < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "不能小于 0");
        }
        BigDecimal stripped = kg.stripTrailingZeros();
        if (stripped.scale() > SCALE) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "最多 4 位小数(千克)");
        }
        if (stripped.precision() - stripped.scale() > INTEGER_DIGITS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "超出可登记范围");
        }
        return stripped.setScale(SCALE);
    }

    /** 请求哈希/指纹里的千克写法: 去尾零的纯数字, 空为 ""。 */
    public static String text(BigDecimal kg) {
        return kg == null ? "" : kg.stripTrailingZeros().toPlainString();
    }
}
