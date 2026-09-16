package com.uten.imp.features.sales.shipment;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SalesShipmentWarehouseReservationSqlContractTest {

    private static String service() throws Exception {
        return Files.readString(Path.of(
                        "src/main/java/com/uten/imp/features/sales/shipment/"
                                + "SalesShipmentService.java"),
                StandardCharsets.UTF_8);
    }

    @Test
    void selectedWarehouseCanConsumeItsOwnGlobalOrAlreadyBoundReservation() throws Exception {
        String source = service();
        // 切片锚点在 V582 换过一次：原来的收尾锚 `BigDecimal ownActive =` 随
        // 「其它在拣任务占用」一起删除，现在以本行需求量 `BigDecimal need =` 收尾。
        int eligibleStart = source.indexOf("BigDecimal eligible =");
        int nextQuery = source.indexOf("BigDecimal need =", eligibleStart);

        assertThat(eligibleStart).isGreaterThanOrEqualTo(0);
        assertThat(nextQuery).isGreaterThan(eligibleStart);
        assertThat(source.substring(eligibleStart, nextQuery))
                .contains("AND (warehouse_id IS NULL OR warehouse_id = :wid)");
    }

    /**
     * 顺序即契约：V582 的实仓取证触发器按 {@code handed_over_by/at} 与那条
     * {@code to_status='SHIPPED'} 事件逐字段比对，而事件是原生 INSERT——Hibernate
     * 会在它之前 flush 脏表头。把两个 setter 挪到 recordWarehouseEvent 之后，
     * Java 侧看不出任何区别，只有 PostgreSQL 会抛 evidence 不匹配。
     */
    @Test
    void handoverFactsAreFlushedBeforeTheOutboundEvidenceEvent() throws Exception {
        String source = service();
        int confirm = source.indexOf("public ShipmentDetail transitionWarehouseWork(");
        assertThat(confirm).isGreaterThanOrEqualTo(0);
        int handedOverAt = source.indexOf("s.setHandedOverAt(now);", confirm);
        int handedOverBy = source.indexOf("s.setHandedOverBy(actor);", confirm);
        int event = source.indexOf("recordWarehouseEvent(", confirm);

        assertThat(handedOverAt).isGreaterThan(confirm);
        assertThat(handedOverBy).isGreaterThan(confirm);
        assertThat(event).isGreaterThan(handedOverAt);
        assertThat(event).isGreaterThan(handedOverBy);
    }

    /**
     * 出库事件必须带上库位证据；退回 6 参重载会让「实际库位号」静默丢失，
     * 而且 V582 的取证触发器只认挂在 SHIPPED 事件上的库位。
     */
    @Test
    void outboundEventCarriesTheReviewedStockPlaces() throws Exception {
        String source = service();
        int confirm = source.indexOf("public ShipmentDetail transitionWarehouseWork(");
        int event = source.indexOf("recordWarehouseEvent(", confirm);
        int end = source.indexOf("approveLocked(s, WAREHOUSE_WORK_AUTHORITY)", event);

        assertThat(end).isGreaterThan(event);
        assertThat(source.substring(event, end))
                .contains("SalesShipment.WORK_SHIPPED")
                .contains("stockPlaces");
    }
}
