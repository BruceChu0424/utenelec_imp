package com.uten.imp.features.stock.count;

import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class StockCountReviewBadgeTest {
    @Test void badgeReadsTheSameScopedCountAsTheReviewListAndKeepsRolesSeparate() throws Exception {
        var requests = mock(StockCountRequestController.class);
        when(requests.counts()).thenReturn(Map.of("financePending", 2L, "warehousePending", 5L, "myPending", 10L));
        var controller = new StockCountReviewBadgeController(requests);
        assertThat(controller.finance()).containsExactlyEntriesOf(Map.of("count", 2L));
        assertThat(controller.warehouse()).containsExactlyEntriesOf(Map.of("count", 5L));
        assertThat(StockCountReviewBadgeController.class.getMethod("finance").getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('stock:count:finance_review')");
        assertThat(StockCountReviewBadgeController.class.getMethod("warehouse").getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('stock:count:warehouse_review')");
        assertThat(new StockCountWorkbenchBadgeSources(controller).sources()).extracting(source -> source.key())
                .containsExactly("stockCountFinance", "stockCountWarehouse");
    }
}
