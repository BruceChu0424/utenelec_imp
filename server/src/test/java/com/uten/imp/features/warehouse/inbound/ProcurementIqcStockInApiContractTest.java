package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ReleasedSlice;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.StockInHistoryItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.TaskDetail;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.Method;
import java.lang.reflect.RecordComponent;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementIqcStockInApiContractTest {

    private static final Set<String> COMMERCIAL_TOKENS = Set.of(
            "price", "amount", "cost", "currency", "exchange", "tax",
            "payable", "settlement", "credit");

    @Test
    void warehouseResponseContractsExposeNoCommercialField() throws Exception {
        List<Class<?>> responseTypes = List.of(
                TaskDetail.class,
                ReleasedSlice.class,
                StockInHistoryItem.class,
                ProcurementIqcStockInContracts.ConfirmResult.class);

        List<String> componentNames = responseTypes.stream()
                .flatMap(type -> Arrays.stream(type.getRecordComponents()))
                .map(RecordComponent::getName)
                .map(name -> name.toLowerCase(Locale.ROOT))
                .toList();
        assertThat(componentNames).noneMatch(this::containsCommercialToken);

        UUID receiptId = UUID.randomUUID();
        UUID passEventId = UUID.randomUUID();
        UUID inspectionItemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        OffsetDateTime now = OffsetDateTime.parse("2026-08-31T12:00:00Z");
        ReleasedSlice slice = new ReleasedSlice(
                passEventId, inspectionItemId, goodsId,
                "G-001", "测试货品", "本色", unitId, "个", "CD-001",
                new BigDecimal("10.0000"), new BigDecimal("8.0000"),
                new BigDecimal("3.0000"), new BigDecimal("5.0000"),
                new BigDecimal("3.0000"), new BigDecimal("2.0000"),
                null, null, "", "A01-01", "合格", "品质员", now);
        TaskDetail detail = new TaskDetail(
                "PURCHASE", receiptId, "CJ-001", LocalDate.of(2026, 8, 31),
                UUID.randomUUID(), "供应商", warehouseId, "原料仓",
                "RESOLVED", 1, false, List.of("CONFIRM"),
                List.of(slice), List.of());

        String json = new ObjectMapper().findAndRegisterModules()
                .writeValueAsString(detail)
                .toLowerCase(Locale.ROOT);
        for (String token : COMMERCIAL_TOKENS) {
            assertThat(json).doesNotContain("\\\"" + token);
        }
    }

    @Test
    void endpointAndMethodPermissionsAreExact() throws Exception {
        RequestMapping mapping = ProcurementIqcStockInController.class
                .getAnnotation(RequestMapping.class);
        assertThat(mapping.value()).containsExactly("/api/warehouse/iqc-stock-ins");

        Method detail = ProcurementIqcStockInController.class.getDeclaredMethod(
                "detail", String.class, UUID.class);
        Method confirm = ProcurementIqcStockInController.class.getDeclaredMethod(
                "confirm", String.class, UUID.class,
                ProcurementIqcStockInContracts.ConfirmRequest.class);

        assertThat(detail.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse_iqc_stock_in:view')");
        // 2026-09-01 合并后旧列表/计数端点已删除：队列由 /warehouse/quality-results 提供。
        assertThat(java.util.Arrays.stream(
                        ProcurementIqcStockInController.class.getDeclaredMethods())
                .map(java.lang.reflect.Method::getName)
                .toList())
                .doesNotContain("list", "count");
        assertThat(confirm.getAnnotation(PreAuthorize.class).value())
                .contains("warehouse_iqc_stock_in:view")
                .contains("warehouse_iqc_stock_in:confirm")
                .doesNotContain("procurement_inspection:handle")
                .doesNotContain("price:view");
    }

    @Test
    void confirmationRecalculatesOrderClosureOnlyAfterWarehouseStockIn() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "ProcurementIqcStockInService.java"), StandardCharsets.UTF_8);
        int projection = source.indexOf("incrementStockedProjection(");
        int orderClosure = source.indexOf("recalculateOrderClosure(type, receiptId)");
        assertThat(projection).isGreaterThanOrEqualTo(0);
        assertThat(orderClosure).isGreaterThan(projection);
        assertThat(source)
                .contains("ProcurementOrderClosurePolicy.recalculate(em, type, orderItemId)")
                .contains("SELECT DISTINCT order_item_id")
                .contains("ORDER BY order_item_id");
    }

    private boolean containsCommercialToken(String fieldName) {
        return COMMERCIAL_TOKENS.stream().anyMatch(fieldName::contains);
    }
}
