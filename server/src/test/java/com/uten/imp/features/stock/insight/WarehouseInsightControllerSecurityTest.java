package com.uten.imp.features.stock.insight;

import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;

import java.lang.reflect.Method;
import java.lang.reflect.Parameter;
import java.util.Arrays;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 库存分析接口权限: 四个清单是报表级数据 (消耗速度、ABC、供应商来料少数排名) → stock_report:view;
 * 单货品指标条 (不含供应商层面数字) → stock:view。路径变量叫 goodsId。
 */
class WarehouseInsightControllerSecurityTest {

    private static final String REPORT = "hasAuthority('stock_report:view')";
    private static final String VIEW = "hasAuthority('stock:view')";

    @Test
    void everyEndpointDeclaresTheSpecifiedAuthority() {
        Map<String, String> expected = Map.of(
                "/health", REPORT,
                "/cycle-count", REPORT,
                "/weight-alerts", REPORT,
                "/learning", REPORT,
                "/goods/{goodsId}", VIEW);
        int mapped = 0;
        for (Method m : WarehouseInsightController.class.getDeclaredMethods()) {
            GetMapping get = m.getAnnotation(GetMapping.class);
            if (get == null) {
                continue;
            }
            mapped++;
            String path = get.value()[0];
            assertThat(expected).containsKey(path);
            assertThat(m.getAnnotation(PreAuthorize.class).value()).as(path).isEqualTo(expected.get(path));
            for (Parameter p : m.getParameters()) {
                if (p.isAnnotationPresent(PathVariable.class)) {
                    assertThat(p.getName()).isEqualTo("goodsId");
                }
            }
        }
        assertThat(mapped).isEqualTo(expected.size());
        assertThat(Arrays.stream(WarehouseInsightController.class.getAnnotations())
                .anyMatch(a -> a.toString().contains("/api/stock/insights"))).isTrue();
    }
}
