package com.uten.imp.features.stock.dto;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;

/**
 * 仓库单据请求里的称重输入口径(ADR-135 §1 精度约定): 千克, 不小于 0, 最多24位小数，整数部分最多40位，超过小数支持范围必须明确本次精度;
 * 填 0 视为没称(返回 null)。控制器层已有同样的 Bean 校验, 这里给绕过控制器的服务内调用兜底, 并统一请求哈希里的写法。
 */
public final class WeightInput {

    private WeightInput() {
    }

    /**
     * 规范化一个称重输入。
     *
     * @param kg    请求里的千克数(可空)
     * @param label 报错时指明是哪一格(如「第 3 行实称重量」)
     * @return 大于 0 的完整支持精度千克数; 空或 0 返回 null
     */
    public static BigDecimal kg(BigDecimal kg, String label) {
        rawKg(kg,label);
        if (kg == null || kg.signum() == 0) return null;
        if (kg.signum() < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "不能小于 0");
        }
        BigDecimal value=com.uten.imp.features.stock.weight.WeightMath.normalizeInput(kg);
        if(value.signum()==0)throw new ApiException(ErrorCode.VALIDATION_FAILED,label+"取位后会把非零实称变成0，请核对原单位或支持精度；原输入应保留");
        return value;
    }

    /** Original warehouse input capacity, before the separate native adoption. */
    public static BigDecimal rawKg(BigDecimal kg,String label){
        if(kg==null)return null;
        BigDecimal exact=kg.stripTrailingZeros();
        if(exact.signum()<0||exact.scale()>48||exact.abs().compareTo(BigDecimal.ONE.scaleByPowerOfTen(40))>=0)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,label+"必须为非负数，最多40位整数和48位有效小数；原输入应保留");
        return kg;
    }

    /** 请求哈希/指纹里的千克写法: 去尾零的纯数字, 空为 ""。 */
    public static String text(BigDecimal kg) {
        return kg == null ? "" : kg.stripTrailingZeros().toPlainString();
    }
}
