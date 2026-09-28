package com.uten.imp.features.stock.ledger;

import com.uten.imp.features.stock.StockQueryController;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.Method;
import java.lang.reflect.Parameter;
import java.util.Arrays;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 货品出入库流水接口: stock:view, 路径变量叫 goodsId (不是 {id}, 不触发详情查看审计要求);
 * 旧的 GET /api/stock/movements 已删除。
 */
class StockLedgerControllerSecurityTest {

    @Test
    void ledgerIsReadableWithStockViewUnderTheGoodsPath() throws Exception {
        Method ledger = Arrays.stream(StockLedgerController.class.getDeclaredMethods())
                .filter(m -> m.getName().equals("ledger")).findFirst().orElseThrow();
        assertThat(StockLedgerController.class.getAnnotation(RequestMapping.class).value())
                .containsExactly("/api/stock/goods");
        assertThat(ledger.getAnnotation(GetMapping.class).value()).containsExactly("/{goodsId}/ledger");
        assertThat(ledger.getAnnotation(PreAuthorize.class).value()).isEqualTo("hasAuthority('stock:view')");
        for (Parameter p : ledger.getParameters()) {
            if (p.isAnnotationPresent(PathVariable.class)) {
                assertThat(p.getName()).isEqualTo("goodsId");
            }
        }
    }

    @Test
    void theOldMovementsEndpointIsGone() {
        assertThat(Arrays.stream(StockQueryController.class.getDeclaredMethods())
                .filter(m -> m.isAnnotationPresent(GetMapping.class))
                .flatMap(m -> Arrays.stream(m.getAnnotation(GetMapping.class).value())))
                .doesNotContain("/movements");
    }
}
