package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;

import java.math.BigDecimal;

/**
 * 货品成本预算的服务端数值边界。
 *
 * <p>金额对应 {@code NUMERIC(18,4)}，必须为非负有限值；百分比费率按业务语义限制在
 * 0-100。请求校验保护 HTTP/导入入口，实体校验覆盖未在线开放但仍由旧库保留的
 * {@code manage_e}/{@code electric_e}，数据库 V421 作为最终写入守卫。
 */
final class GoodsCostValuePolicy {

    static final BigDecimal MAX_AMOUNT = new BigDecimal("99999999999999.9999");
    static final BigDecimal MAX_RATE = new BigDecimal("100.0000");

    private GoodsCostValuePolicy() {}

    static void validateRequest(GoodsSaveRequest request) {
        amount("材料合计", request.getSourceE());
        amount("加工费", request.getMachiningE());
        amount("杂费", request.getIncidentalE());
        amount("喷漆费", request.getLacquerE());
        amount("电镀费", request.getPlatingE());
        amount("包装费", request.getCasingE());
        amount("抛光费", request.getPolishE());
        amount("成品价", request.getTotal());
        rate("人工比率", request.getWorkRate());
        amount("人工费", request.getWorkE());
        rate("损耗比率", request.getLostRate());
        amount("损耗费", request.getLostE());
        rate("厂租比率", request.getRentRate());
        amount("厂房租金", request.getRentE());
        rate("生产利率", request.getMakeRate());
        amount("生产利润", request.getMakeE());
        amount("成本价", request.getCTotal());
        amount("出厂价", request.getGTotal());
    }

    static void validateEntity(Goods goods) {
        amount("材料合计", goods.getSourceE());
        amount("人工费", goods.getWorkE());
        amount("喷漆费", goods.getLacquerE());
        amount("杂费", goods.getIncidentalE());
        amount("电镀费", goods.getPlatingE());
        amount("包装费", goods.getCasingE());
        amount("管理费", goods.getManageE());
        amount("抛光费", goods.getPolishE());
        amount("电气费", goods.getElectricE());
        amount("加工费", goods.getMachiningE());
        amount("损耗费", goods.getLostE());
        amount("厂房租金", goods.getRentE());
        amount("生产利润", goods.getMakeE());
        rate("人工比率", goods.getWorkRate());
        rate("损耗比率", goods.getLostRate());
        rate("生产利率", goods.getMakeRate());
        rate("厂租比率", goods.getRentRate());
        amount("成品价", goods.getTotal());
        amount("成本价", goods.getCTotal());
        amount("出厂价", goods.getGTotal());
    }

    private static void amount(String field, BigDecimal value) {
        range(field, value, MAX_AMOUNT, "金额");
    }

    private static void rate(String field, BigDecimal value) {
        range(field, value, MAX_RATE, "百分比");
    }

    private static void range(
            String field, BigDecimal value, BigDecimal maximum, String kind) {
        if (value == null) return;
        if (value.signum() < 0 || value.compareTo(maximum) > 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    field + kind + "必须在 0 到 " + maximum.toPlainString() + " 之间");
        }
    }
}
