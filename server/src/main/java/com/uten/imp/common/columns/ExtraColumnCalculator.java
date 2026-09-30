package com.uten.imp.common.columns;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.util.List;

/** A bounded ordered calculation, with no expression language or floating point. */
public final class ExtraColumnCalculator {
    private ExtraColumnCalculator() { }

    public static BigDecimal apply(BigDecimal base, List<ExtraColumnSnapshot> columns) {
        if (columns != null && columns.size() > 32) throw invalid("最多添加 32 个扩展列");
        if (base == null) return null;
        BigDecimal amount = base;
        for (ExtraColumnSnapshot column : columns == null ? List.<ExtraColumnSnapshot>of() : columns) {
            if (column == null || column.operation() == null) throw invalid("扩展列定义无效");
            if ("NONE".equals(column.operation()) || column.value() == null || column.value().isBlank()) continue;
            if ("TEXT".equals(column.type())) throw invalid("文本列不能参与金额运算");
            BigDecimal value = decimal(column.value(), column.name());
            try {
                amount = switch (column.operation()) {
                    case "ADD" -> amount.add(value);
                    case "SUBTRACT" -> amount.subtract(value);
                    case "MULTIPLY" -> amount.multiply(value);
                    case "DIVIDE" -> {
                        if (value.signum() == 0) throw invalid(column.name() + "不能除以 0");
                        yield amount.divide(value);
                    }
                    default -> throw invalid("扩展列运算无效");
                };
            } catch (ArithmeticException nonTerminating) {
                throw invalid(column.name() + "的除法不能保存为精确有限小数，请修改除数");
            }
            FinancialExactAmount.book(amount, column.name() + "计算结果");
        }
        if (amount.signum() < 0) throw invalid("扩展费用计算后金额不能为负数");
        return MoneyPolicy.canonical(FinancialExactAmount.book(amount, "扩展费用后的金额"));
    }

    public static BigDecimal decimal(String value, String label) {
        if (value == null || value.length() > 120 || !value.matches("[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)")) {
            throw invalid(label + "请输入十进制数值");
        }
        return FinancialExactAmount.book(new BigDecimal(value), label);
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
