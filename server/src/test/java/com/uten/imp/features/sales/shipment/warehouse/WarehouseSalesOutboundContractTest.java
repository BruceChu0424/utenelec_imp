package com.uten.imp.features.sales.shipment.warehouse;

import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.Method;
import java.lang.reflect.RecordComponent;
import java.time.LocalDate;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class WarehouseSalesOutboundContractTest {

    private static final Set<String> PROHIBITED = Set.of(
            "price", "amount", "currency", "exchange", "tax", "settlement",
            "receivable", "prepayment", "finance", "risk", "cost", "discount",
            "arposted");

    @Test
    void publicWarehouseRecordsContainNoCommercialOrFinanceField() {
        for (Class<?> projection : Set.of(
                WarehouseSalesOutboundListItem.class,
                WarehouseSalesOutboundDetail.class,
                WarehouseSalesOutboundLine.class,
                WarehouseSalesOutboundWarehouseChoice.class)) {
            assertThat(projection.isRecord()).isTrue();
            for (RecordComponent component : projection.getRecordComponents()) {
                String field = component.getName().toLowerCase(Locale.ROOT);
                assertThat(PROHIBITED)
                        .as("%s.%s", projection.getSimpleName(), component.getName())
                        .noneMatch(field::contains);
            }
        }
    }

    @Test
    void controllerUsesWarehouseRouteAndOnlyWarehouseWorkAuthority() throws Exception {
        RequestMapping root = WarehouseSalesOutboundController.class
                .getAnnotation(RequestMapping.class);
        PreAuthorize authority = WarehouseSalesOutboundController.class
                .getAnnotation(PreAuthorize.class);
        assertThat(root.value()).containsExactly("/api/warehouse/sales-outbound");
        assertThat(authority.value())
                .isEqualTo("hasAuthority('warehouse_sales_outbound:view')");

        Method list = WarehouseSalesOutboundController.class.getDeclaredMethod(
                "list", String.class, String.class, LocalDate.class, LocalDate.class, int.class, int.class,
                String.class, UUID.class);
        Method detail = WarehouseSalesOutboundController.class.getDeclaredMethod(
                "detail", UUID.class);
        Method command = WarehouseSalesOutboundController.class.getDeclaredMethod(
                "warehouseWork", UUID.class, WarehouseWorkTransitionRequest.class);
        assertThat(list.getAnnotation(GetMapping.class).value()).isEmpty();
        assertThat(detail.getAnnotation(GetMapping.class).value()).containsExactly("/{id}");
        assertThat(command.getAnnotation(PostMapping.class).value())
                .containsExactly("/{id}/warehouse-work");
        // permissions-09：查看与执行拆成两个码，写入口额外要求执行码。
        assertThat(command.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse_sales_outbound:view')"
                        + " and hasAuthority('warehouse_sales_outbound:execute')");
        // 角标计数两个只读端点: /count = 待出库张数(hub 卡/父分类), /counts = 按仓库作业状态分组(小类行).
        Method pendingCount = WarehouseSalesOutboundController.class.getDeclaredMethod("pendingCount");
        Method counts = WarehouseSalesOutboundController.class.getDeclaredMethod("counts");
        assertThat(pendingCount.getAnnotation(GetMapping.class).value()).containsExactly("/count");
        assertThat(counts.getAnnotation(GetMapping.class).value()).containsExactly("/counts");
    }
}
