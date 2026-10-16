package com.uten.imp.features.master.mould;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.time.DateTimeException;
import java.time.LocalDate;
import java.time.YearMonth;
import java.util.Objects;
import java.util.regex.Pattern;

/** 制造年月为月份精度；兼容原库文本和旧客户端日精度，禁止月份自动进位。 */
final class MouldManufacturingMonth {
    private static final Pattern NUMERIC = Pattern.compile("^(\\d{4})[-/](\\d{1,2})(?:[-/](\\d{1,2}))?$");
    private static final Pattern CHINESE = Pattern.compile("^(\\d{4})\\s*年\\s*(\\d{1,2})\\s*月$");

    private MouldManufacturingMonth() { }

    static String normalize(String value, String previous) {
        // 未修改的历史资料保持原值；不猜测或批量清洗历史日期。
        if (Objects.equals(value, previous)) return previous;
        if (value == null || value.isBlank()) return null;
        var text = value.strip();
        var match = NUMERIC.matcher(text);
        var numeric = match.matches();
        if (!numeric) match = CHINESE.matcher(text);
        if (numeric || match.matches()) {
            try {
                var year = Integer.parseInt(match.group(1));
                var month = Integer.parseInt(match.group(2));
                var result = YearMonth.of(year, month);
                if (numeric && match.group(3) != null) {
                    LocalDate.of(year, month, Integer.parseInt(match.group(3)));
                }
                if (year >= 1900 && year <= 2100) return result.toString();
            } catch (DateTimeException | NumberFormatException ignored) {
                // 统一转为可定位的业务校验错误。
            }
        }
        throw new ApiException(ErrorCode.VALIDATION_FAILED, "制造年月不正确，请填写有效年月，如 2018-07");
    }
}
