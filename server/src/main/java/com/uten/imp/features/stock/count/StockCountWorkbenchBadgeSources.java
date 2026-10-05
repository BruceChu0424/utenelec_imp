package com.uten.imp.features.stock.count;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import org.springframework.stereotype.Component;
import java.util.List;

@Component
class StockCountWorkbenchBadgeSources implements WorkbenchBadgeSources {
    private final StockCountReviewBadgeController counts;
    StockCountWorkbenchBadgeSources(StockCountReviewBadgeController counts) { this.counts = counts; }
    @Override public List<Source> sources() {
        return List.of(new Source("stockCountFinance", counts::finance), new Source("stockCountWarehouse", () -> counts.warehouse(null)));
    }
}
