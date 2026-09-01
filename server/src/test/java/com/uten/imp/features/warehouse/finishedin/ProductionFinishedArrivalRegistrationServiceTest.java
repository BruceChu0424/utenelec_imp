package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProductionFinishedArrivalRegistrationServiceTest {

    @Test
    void canonicalHashIsOrderIndependentAndPlaceIsTrimmed() {
        UUID warehouseId = UUID.randomUUID();
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        var left = ProductionFinishedArrivalRegistrationService.normalize(
                new ArrivalRegistrationRequest(
                        "arrival-key-001", warehouseId,
                        List.of(
                                new ArrivalRegistrationItemRequest(
                                        second, " B02-2-1 "),
                                new ArrivalRegistrationItemRequest(
                                        first, "A31-3-1"))));
        var right = ProductionFinishedArrivalRegistrationService.normalize(
                new ArrivalRegistrationRequest(
                        "arrival-key-001", warehouseId,
                        List.of(
                                new ArrivalRegistrationItemRequest(
                                        first, "A31-3-1"),
                                new ArrivalRegistrationItemRequest(
                                        second, "B02-2-1"))));

        assertThat(left.requestHash()).isEqualTo(right.requestHash());
        assertThat(left.places()).containsEntry(second, "B02-2-1");
    }

    @Test
    void duplicateReportItemAndBlankPlaceFailClosed() {
        UUID reportItemId = UUID.randomUUID();
        ArrivalRegistrationRequest duplicate = new ArrivalRegistrationRequest(
                "arrival-key-002", UUID.randomUUID(),
                List.of(
                        new ArrivalRegistrationItemRequest(
                                reportItemId, "A31-3-1"),
                        new ArrivalRegistrationItemRequest(
                                reportItemId, "A31-3-2")));
        assertThatThrownBy(() ->
                ProductionFinishedArrivalRegistrationService.normalize(duplicate))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.VALIDATION_FAILED));

        ArrivalRegistrationRequest blank = new ArrivalRegistrationRequest(
                "arrival-key-003", UUID.randomUUID(),
                List.of(new ArrivalRegistrationItemRequest(
                        UUID.randomUUID(), "  ")));
        assertThatThrownBy(() ->
                ProductionFinishedArrivalRegistrationService.normalize(blank))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void rememberPlanMergesSameDimensionAndSeparatesColors() {
        UUID goodsId = UUID.randomUUID();
        UUID firstColor = UUID.randomUUID();
        UUID secondColor = UUID.randomUUID();
        var plan = ProductionFinishedArrivalRegistrationService.buildRememberPlan(
                List.of(
                        new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                                goodsId, firstColor, " A31-3-1 ", "V5001", "成品"),
                        new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                                goodsId, firstColor, "A31-3-1", "V5001", "成品"),
                        new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                                goodsId, secondColor, "B02-1-4", "V5001", "成品")));

        assertThat(plan.ambiguous()).isZero();
        assertThat(plan.warnings()).isEmpty();
        assertThat(plan.candidates())
                .extracting(
                        ProductionFinishedArrivalRegistrationService.RememberCandidate::place)
                .containsExactly("A31-3-1", "B02-1-4");
    }

    @Test
    void rememberPlanRejectsDifferentPlacesForSameGoodsAndColor() {
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        var plan = ProductionFinishedArrivalRegistrationService.buildRememberPlan(
                List.of(
                        new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                                goodsId, colorId, "A31-3-1", "V5001", "成品"),
                        new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                                goodsId, colorId, "B02-1-4", "V5001", "成品")));

        assertThat(plan.candidates()).isEmpty();
        assertThat(plan.ambiguous()).isEqualTo(1);
        assertThat(plan.warnings()).singleElement()
                .asString()
                .contains("V5001", "A31-3-1", "B02-1-4");
    }

    @Test
    void placeSuggestionsUseExactUuidHistoryFallbackWithoutImplicitLearning()
            throws Exception {
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/"
                        + "ProductionFinishedArrivalRegistrationService.java"));
        int suggestionsStart = service.indexOf(
                "public PlaceSuggestionsView placeSuggestions(");
        int registerStart = service.indexOf(
                "public ArrivalRegistrationView register(", suggestionsStart);
        assertThat(suggestionsStart).isGreaterThanOrEqualTo(0);
        assertThat(registerStart).isGreaterThan(suggestionsStart);
        String suggestions = service.substring(suggestionsStart, registerStart);

        int preferencePrecedence = suggestions.indexOf(
                "WHEN preference.id IS NOT NULL");
        int historyPrecedence = suggestions.indexOf(
                "WHEN registration_history.place IS NOT NULL");
        int masterPrecedence = suggestions.indexOf(
                "WHEN NULLIF(BTRIM(goods.stock_place), '') IS NOT NULL");
        assertThat(preferencePrecedence).isGreaterThanOrEqualTo(0);
        assertThat(historyPrecedence).isGreaterThan(preferencePrecedence);
        assertThat(masterPrecedence).isGreaterThan(historyPrecedence);

        int latestLimit = suggestions.indexOf("LIMIT 1");
        int uniquePlaceGuard = suggestions.indexOf(
                "WHERE latest_history.place_count = 1");
        assertThat(latestLimit).isGreaterThanOrEqualTo(0);
        assertThat(uniquePlaceGuard).isGreaterThan(latestLimit);
        assertThat(suggestions)
                .contains("'REGISTRATION_HISTORY'")
                .contains("LEFT JOIN LATERAL (")
                .contains("history_registration.warehouse_id =")
                .contains("selected_warehouse.id")
                .contains("history_report_item.goods_id =")
                .contains("report_item.goods_id")
                .contains("history_report_item.color_id")
                .contains("IS NOT DISTINCT FROM report_item.color_id")
                .contains("history_registration.source_report_id <>")
                .contains("report.id")
                .contains("COUNT(DISTINCT BTRIM(")
                .contains("GROUP BY history_registration.id,")
                .contains("ORDER BY history_registration.created_at DESC,")
                .contains("history_registration.id DESC")
                .contains(") registration_history ON preference.id IS NULL")
                .doesNotContain("HAVING")
                .doesNotContain("INSERT INTO warehouse_goods_place_preferences")
                .doesNotContain("UPDATE warehouse_goods_place_preferences");
    }

    @Test
    void controllerAndServiceKeepRegistrationBeforeFqcContract()
            throws Exception {
        String controller = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/"
                        + "ProductionFinishedInboundTaskController.java"));
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/"
                        + "ProductionFinishedArrivalRegistrationService.java"));

        assertThat(controller)
                .contains("/arrival-registrations/{reportId}")
                .contains("/arrival-registrations/{reportId}/place-suggestions")
                .contains("/arrival-registrations/{reportId}/remember-places")
                .contains("hasAuthority('stock_doc:view')")
                .contains("hasAuthority('stock_doc:approve')");
        int insertItems = service.indexOf(
                "INSERT INTO production_finished_arrival_registration_items");
        int registerFqc = service.indexOf(
                "qualityInspection.registerApprovedReport(");
        assertThat(insertItems).isGreaterThan(0);
        assertThat(registerFqc).isGreaterThan(insertItems);
        assertThat(service)
                .contains("requireWarehouseTaskAccess")
                .contains("pg_advisory_xact_lock")
                .contains("Set.copyOf(reportItemIds)")
                .contains("request_hash")
                .contains("warehouse_goods_place_preferences")
                .contains("source_registered_at")
                .contains("visible_registration")
                .contains("production_fqc_inspections inspection")
                .contains("production_fqc_legacy_exemptions exemption")
                .contains("ON CONFLICT ON CONSTRAINT")
                .contains("warehouse_goods_place_preference_dimension_uk")
                .contains("buildRememberPlan")
                .doesNotContain("UPDATE goods SET stock_place");
    }
}
