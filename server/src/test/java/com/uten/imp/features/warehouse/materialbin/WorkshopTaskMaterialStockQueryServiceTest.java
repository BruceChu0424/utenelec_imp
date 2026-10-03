package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PositionRow;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PositionView;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WorkshopTaskMaterialStockQueryServiceTest {
    private final UUID segment = UUID.randomUUID();
    private final UUID workshop = UUID.randomUUID();
    private final UUID bin = UUID.randomUUID();
    private final UUID goods = UUID.randomUUID();
    private final UUID color = UUID.randomUUID();
    private NamedParameterJdbcTemplate db;
    private WorkshopMaterialScope scope;
    private WorkshopMaterialBinSupport bins;
    private WorkshopMaterialPositionQueryService positions;
    private WorkshopMaterialPermissions permissions;
    private WorkshopTaskMaterialStockQueryService service;

    @BeforeEach
    void setup() {
        db = mock(NamedParameterJdbcTemplate.class);
        scope = mock(WorkshopMaterialScope.class);
        bins = mock(WorkshopMaterialBinSupport.class);
        positions = mock(WorkshopMaterialPositionQueryService.class);
        permissions = mock(WorkshopMaterialPermissions.class);
        service = new WorkshopTaskMaterialStockQueryService(db, scope, bins, positions, permissions);
        when(db.queryForList(anyString(), anyMap())).thenReturn(List.of(Map.of(
                "workshop_department_id", workshop, "workshop_name", "注塑车间",
                "status", "IN_PROGRESS", "remaining_output_qty", new BigDecimal("1000"))));
        when(bins.settings(workshop)).thenReturn(new WorkshopMaterialBinSupport.Settings(
                workshop, "注塑车间", true, bin, LocalDate.of(2026, 9, 30), 1));
        when(permissions.has(WorkshopMaterialPermissions.REQUEST)).thenReturn(true);
        when(db.queryForList(anyString(), any(MapSqlParameterSource.class)))
                .thenReturn(List.of(material("0.0086", "kg")));
        withStock(stock("100", "50", 0, 0, color));
    }

    @Test
    void usesEstimatedRemainingInsteadOfBookBalanceAndKeepsRequestAvailable() {
        withStock(stock("100", "5", 0, 0, color));
        var view = service.readiness(segment);
        var row = view.rows().getFirst();
        assertDecimal("8.6", row.requiredQty());
        assertDecimal("3.6", row.shortageQty());
        assertEquals("ESTIMATED_SHORT", row.status());
        assertEquals(List.of("REQUEST"), view.allowedActions());

        withStock(stock("100", "50", 0, 0, color));
        view = service.readiness(segment);
        assertEquals("ESTIMATED_ENOUGH", view.rows().getFirst().status());
        assertEquals(List.of("REQUEST"), view.allowedActions(), "足料也可提前整批补料");
    }

    @Test
    void quantitiesStayInTheirMaterialBaseUnitWithoutGuessingKilograms() {
        var row = WorkshopTaskMaterialStockQueryService.stockRow(material("8.6", "g"),
                new BigDecimal("1000"), stock("9000", "9000", 0, 0, color));
        assertDecimal("8600", row.requiredQty());
        assertEquals("g", row.unitName());
        assertEquals("ESTIMATED_ENOUGH", row.status());
    }

    @Test
    void smallPositiveRequirementIsNotRoundedToZero() {
        var row = WorkshopTaskMaterialStockQueryService.stockRow(material("0.0000004", "kg"),
                BigDecimal.ONE, stock("0", "0", 0, 0, color));
        assertDecimal("0.0000004", row.requiredQty());
        assertDecimal("0.0000004", row.shortageQty());
        assertEquals("ESTIMATED_SHORT", row.status());
    }

    @Test
    void missingWeightDraftReportsAndAbsentStockNeverMeanEnough() {
        var missingWeight = WorkshopTaskMaterialStockQueryService.stockRow(material(null, "kg"),
                new BigDecimal("1000"), stock("100", "100", 0, 0, color));
        assertNull(missingWeight.requiredQty());
        assertNull(missingWeight.shortageQty());
        assertEquals("UNKNOWN", missingWeight.status());
        for (PositionRow position : List.of(stock("100", "100", 1, 0, color),
                stock("100", "100", 0, 1, color))) {
            var row = WorkshopTaskMaterialStockQueryService.stockRow(material("0.0086", "kg"),
                    new BigDecimal("1000"), position);
            assertEquals("UNKNOWN", row.status());
            assertTrue(row.estimateIncomplete());
            assertNull(row.shortageQty());
        }
        withStock();
        var view = service.readiness(segment);
        assertEquals("UNKNOWN", view.rows().getFirst().status());
        assertNull(view.rows().getFirst().estimatedRemainingQty());
        assertEquals(List.of("REQUEST"), view.allowedActions(), "未知余量也可补料");
    }

    @Test
    void materialColorAndBoundBinMustBothMatch() {
        withStock(stock("100", "100", 0, 0, UUID.randomUUID()));
        assertNull(service.readiness(segment).rows().getFirst().estimatedRemainingQty());

        withStock(stock("100", "100", 0, 0, color));
        Map<String, Object> elsewhere = material("0.0086", "kg");
        elsewhere.put("bin_warehouse_id", UUID.randomUUID());
        when(db.queryForList(anyString(), any(MapSqlParameterSource.class))).thenReturn(List.of(elsewhere));
        assertEquals("UNKNOWN", service.readiness(segment).rows().getFirst().status());
    }

    @Test
    void negativeEstimatedBalanceIsVisibleAsAdditionalShortage() {
        var row = WorkshopTaskMaterialStockQueryService.stockRow(material("0.0086", "kg"),
                new BigDecimal("1000"), stock("0", "-2", 0, 0, color));
        assertDecimal("10.6", row.shortageQty());
        assertDecimal("-2", row.estimatedRemainingQty());
    }

    @Test
    void cannotReadOtherWorkshopInventoryOrAdvertiseUnauthorizedRequests() {
        when(permissions.has(WorkshopMaterialPermissions.REQUEST)).thenReturn(false);
        assertTrue(service.readiness(segment).allowedActions().isEmpty());
        clearInvocations(bins, positions);
        doThrow(new ApiException(ErrorCode.FORBIDDEN, "只能查看本车间"))
                .when(scope).requireWorkshop(workshop);
        assertThrows(ApiException.class, () -> service.readiness(segment));
        verifyNoInteractions(bins, positions);
    }

    @Test
    void noEffectiveMaterialIsUnknownAndDoesNotPreventIndependentReplenishment() {
        when(db.queryForList(anyString(), any(MapSqlParameterSource.class))).thenReturn(List.of());
        var result = service.readiness(segment);
        assertTrue(result.rows().isEmpty());
        assertTrue(result.estimateIncomplete());
        assertNotNull(result.reason());
        assertEquals(List.of("REQUEST"), result.allowedActions());
    }

    private Map<String, Object> material(String weight, String unit) {
        Map<String, Object> row = new HashMap<>();
        row.put("goods_id", goods);
        row.put("goods_code", "PC-01");
        row.put("goods_name", "PC颗粒");
        row.put("color_id", color);
        row.put("unit_name", unit);
        row.put("bin_warehouse_id", bin);
        row.put("unit_weight", weight == null ? null : new BigDecimal(weight));
        row.put("bulk_package_qty", new BigDecimal("25"));
        return row;
    }

    private PositionRow stock(String book, String estimated, int missing, int drafts, UUID stockColor) {
        return new PositionRow(goods, "PC-01", "PC颗粒", stockColor, null, "kg", new BigDecimal("25"),
                new BigDecimal(book), null, null, null, null, null, null,
                new BigDecimal(estimated), new BigDecimal("500"), missing, drafts);
    }

    private void withStock(PositionRow... rows) {
        when(positions.position(bin)).thenReturn(new PositionView(bin, "注塑内料仓", workshop, "注塑车间",
                "OPEN", "NONE", List.of(), null, null, null, List.of(rows), List.of("REQUEST")));
    }

    private static void assertDecimal(String expected, BigDecimal actual) {
        assertNotNull(actual);
        assertEquals(0, new BigDecimal(expected).compareTo(actual));
    }
}
