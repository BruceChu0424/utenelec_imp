package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentRequest;
import com.uten.imp.features.stock.weight.GoodsWeightEstimateService;
import com.uten.imp.features.stock.weight.GoodsWeightProfileService;
import com.uten.imp.features.stock.weight.StockWeightAdjustmentService;
import com.uten.imp.features.stock.weight.StockWeightController;
import com.uten.imp.features.stock.weight.dto.SetBalanceWeightRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

/** 旧权限仍在，但旧库存快捷入口不能绕过审批写入；主档称重配置不在本限制内。 */
class StockCountLegacyShortcutTest {
    @Test void oldBalanceShortcutNeverCallsTheDirectPostingService() {
        var service = mock(StockBalanceAdjustmentService.class);
        var controller = new StockBalanceAdjustmentController(service);
        assertThatThrownBy(() -> controller.adjust(new StockBalanceAdjustmentRequest()))
                .isInstanceOf(ApiException.class).hasMessageContaining("提交财务审核");
        verifyNoInteractions(service);
    }

    @Test void oldWeightShortcutNeverWritesAnAdjustmentOrReadsBackAnImaginaryResult() {
        var estimates = mock(GoodsWeightEstimateService.class);
        var profiles = mock(GoodsWeightProfileService.class);
        var adjustments = mock(StockWeightAdjustmentService.class);
        var currentUser = mock(SecurityContextCurrentUser.class);
        var controller = new StockWeightController(estimates, profiles, adjustments, currentUser);
        var request = new SetBalanceWeightRequest(UUID.randomUUID(), UUID.randomUUID(), null,
                BigDecimal.ONE, BigDecimal.TEN, "现场盘点", "count-legacy-shortcut");
        assertThatThrownBy(() -> controller.setBalanceWeight(request))
                .isInstanceOf(ApiException.class).hasMessageContaining("提交审核");
        verifyNoInteractions(estimates, profiles, adjustments, currentUser);
    }
}
