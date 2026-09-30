package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.columns.ExtraColumnSnapshot;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class SubcontractOrderColumnPreservationTest {
    @Test void quantityChangesAndSourceRowsPreserveTheirExistingTerms() {
        var old = item();
        old.setApplicationItemId(UUID.randomUUID());
        var request = request(old);
        request.setQty(new BigDecimal("20"));
        assertThat(SubcontractOrderService.previousColumns(List.of(request), List.of(old)).get(request))
                .isEqualTo(old.getExtraColumns());
    }
    @Test void rejectsDuplicateAndForeignIdsAndAmbiguousLegacyRows() {
        var old = item();
        var request = request(old);
        assertThatThrownBy(() -> SubcontractOrderService.previousColumns(List.of(request, request(old)), List.of(old)))
                .isInstanceOf(ApiException.class);
        request.setId(UUID.randomUUID());
        assertThatThrownBy(() -> SubcontractOrderService.previousColumns(List.of(request), List.of(old)))
                .isInstanceOf(ApiException.class);
        var second = item(); second.setGoodsId(old.getGoodsId());
        request.setId(null);
        assertThatThrownBy(() -> SubcontractOrderService.previousColumns(List.of(request), List.of(old, second)))
                .isInstanceOf(ApiException.class).hasMessageContaining("不同扩展条款");
    }
    private static SubcontractOrderItem item() {
        var row = new SubcontractOrderItem(); row.setId(UUID.randomUUID()); row.setGoodsId(UUID.randomUUID());
        row.setQty(BigDecimal.TEN);
        row.setExtraColumns(List.of(new ExtraColumnSnapshot(UUID.randomUUID(), "包装费", "AMOUNT", "ADD", "5")));
        return row;
    }
    private static OrderItemLine request(SubcontractOrderItem old) {
        var row = new OrderItemLine(); row.setId(old.getId()); row.setGoodsId(old.getGoodsId());
        row.setApplicationItemId(old.getApplicationItemId()); row.setQty(old.getQty()); return row;
    }
}
