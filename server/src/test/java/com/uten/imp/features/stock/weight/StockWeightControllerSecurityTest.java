package com.uten.imp.features.stock.weight;

import com.uten.imp.features.stock.weight.dto.SetBalanceWeightRequest;
import com.uten.imp.features.stock.weight.dto.WeightExcludeRequest;
import com.uten.imp.features.stock.weight.dto.WeightParamsRequest;
import com.uten.imp.features.stock.weight.dto.WeightProfileUpdateRequest;
import com.uten.imp.features.stock.weight.dto.WeightSampleRequest;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;

import java.lang.reflect.Method;
import java.lang.reflect.Parameter;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** 重量接口的权限点 (ADR-135 §7.2): 读 stock:view, 称样三选一, 设置/排除/重新学习/核重只给 stock:weight:manage。 */
class StockWeightControllerSecurityTest {

    private static final String VIEW = "hasAuthority('stock:view')";
    private static final String MANAGE = "hasAuthority('stock:weight:manage')";
    private static final String SAMPLE =
            "hasAnyAuthority('warehouse_inbound:stock_in', 'stock_doc:edit', 'stock:weight:manage')";

    @Test
    void everyEndpointDeclaresTheSpecifiedAuthority() throws Exception {
        assertGuard("params", VIEW, WeightParamsRequest.class);
        assertGuard("goods", VIEW, UUID.class);
        assertGuard("observations", VIEW, UUID.class, int.class, int.class, String.class, UUID.class,
                String.class);
        assertGuard("sample", SAMPLE, UUID.class, WeightSampleRequest.class);
        assertGuard("updateProfile", MANAGE, UUID.class, WeightProfileUpdateRequest.class);
        assertGuard("exclude", MANAGE, UUID.class, WeightExcludeRequest.class);
        assertGuard("include", MANAGE, UUID.class);
        assertGuard("resetRegime", MANAGE, UUID.class);
        assertGuard("setBalanceWeight", MANAGE, SetBalanceWeightRequest.class);
    }

    @Test
    void routesUseNamedPathVariablesUnderTheWeightPrefix() {
        int mapped = 0;
        for (Method m : StockWeightController.class.getDeclaredMethods()) {
            if (!m.isAnnotationPresent(GetMapping.class) && !m.isAnnotationPresent(PostMapping.class)
                    && !m.isAnnotationPresent(PutMapping.class)) {
                continue;
            }
            mapped++;
            assertThat(m.isAnnotationPresent(PreAuthorize.class)).as(m.getName()).isTrue();
            for (Parameter p : m.getParameters()) {
                if (p.isAnnotationPresent(PathVariable.class)) {
                    assertThat(p.getName()).as(m.getName()).isIn("goodsId", "observationId");
                }
            }
        }
        assertThat(mapped).isEqualTo(9);
    }

    private static void assertGuard(String name, String expected, Class<?>... parameterTypes) throws Exception {
        Method method = StockWeightController.class.getDeclaredMethod(name, parameterTypes);
        assertThat(method.getAnnotation(PreAuthorize.class).value()).as(name).isEqualTo(expected);
    }
}
