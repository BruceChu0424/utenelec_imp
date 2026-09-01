package com.uten.imp.features.warehouse.history;

import org.junit.jupiter.api.Test;

import java.lang.reflect.RecordComponent;
import java.util.Arrays;
import java.util.EnumMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class WarehouseHistoryProjectionContractTest {

    private static final Set<String> PROHIBITED_FIELD_TOKENS = Set.of(
            "price",
            "amount",
            "currency",
            "exchange",
            "tax",
            "settlement",
            "payable",
            "receivable",
            "ap_posted",
            "apposted",
            "claim",
            "deduct");

    @Test
    void publicProjectionRecordsContainNoCommercialField() {
        for (Class<?> projection : Set.of(
                WarehouseHistoryListItem.class,
                WarehouseHistoryDetail.class,
                WarehouseHistoryLine.class)) {
            assertThat(projection.isRecord()).isTrue();
            for (RecordComponent component : projection.getRecordComponents()) {
                String normalized = component.getName().toLowerCase(Locale.ROOT);
                assertThat(PROHIBITED_FIELD_TOKENS)
                        .as("%s.%s must not expose commercial data", projection.getSimpleName(), component.getName())
                        .noneMatch(normalized::contains);
            }
        }
    }

    @Test
    void sixWhitelistedSourcesHaveUniqueSegmentsAndExactAuthorities() {
        Map<WarehouseHistoryType, String> expected = new EnumMap<>(WarehouseHistoryType.class);
        expected.put(WarehouseHistoryType.PURCHASE_RECEIPT,
                WarehouseHistoryPermissions.PURCHASE_RECEIPT_VIEW);
        expected.put(WarehouseHistoryType.SUBCONTRACT_RECEIPT,
                WarehouseHistoryPermissions.SUBCONTRACT_RECEIPT_VIEW);
        expected.put(WarehouseHistoryType.SUBCONTRACT_MATERIAL_ISSUE,
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_ISSUE_VIEW);
        expected.put(WarehouseHistoryType.SUBCONTRACT_RETURN,
                WarehouseHistoryPermissions.SUBCONTRACT_RETURN_VIEW);
        expected.put(WarehouseHistoryType.SUBCONTRACT_MATERIAL_RETURN,
                WarehouseHistoryPermissions.SUBCONTRACT_MATERIAL_RETURN_VIEW);
        expected.put(WarehouseHistoryType.SUBCONTRACT_WASTE,
                WarehouseHistoryPermissions.SUBCONTRACT_WASTE_VIEW);

        assertThat(Arrays.asList(WarehouseHistoryType.values()))
                .containsExactlyElementsOf(expected.keySet());
        Set<String> segments = new HashSet<>();
        Set<String> authorities = new HashSet<>();
        expected.forEach((type, permission) -> {
            assertThat(type.permission()).isEqualTo(permission);
            assertThat(type.pathSegment()).isNotBlank();
            assertThat(segments.add(type.pathSegment())).isTrue();
            assertThat(authorities.add(type.permission())).isTrue();
        });
    }
}
