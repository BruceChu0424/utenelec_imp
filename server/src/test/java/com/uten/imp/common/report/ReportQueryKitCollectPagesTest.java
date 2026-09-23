package com.uten.imp.common.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** audit-retention-settings-11: 主档导出统一按系统设置「导出行数上限」拦截, 提示里带当前上限。 */
class ReportQueryKitCollectPagesTest {

    private static PageResponse<Integer> page(List<Integer> all, int page, int size) {
        int from = Math.min(all.size(), (page - 1) * size);
        int to = Math.min(all.size(), from + size);
        return new PageResponse<>(all.subList(from, to), page, size, all.size(),
                (all.size() + size - 1) / size);
    }

    @Test
    void rejectsExportsLargerThanTheConfiguredLimitWithTheLimitInTheMessage() {
        List<Integer> sixty = IntStream.range(0, 60).boxed().toList();

        ApiException error = assertThrows(ApiException.class, () -> ReportQueryKit.collectPages(
                50, (p, size) -> page(sixty, p, size), v -> Map.of("v", v)));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertTrue(error.getMessage().contains("50"), error.getMessage());
    }

    @Test
    void collectsEveryPageWithinTheLimit() {
        List<Integer> rows = IntStream.range(0, 250).boxed().toList();

        List<Map<String, Object>> exported = ReportQueryKit.collectPages(
                1_000, (p, size) -> page(rows, p, size), v -> Map.of("v", v));

        assertEquals(250, exported.size());
        assertEquals(249, exported.get(249).get("v"));
    }
}
