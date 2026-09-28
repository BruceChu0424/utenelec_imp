package com.uten.imp.features.warehouse.place;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.place.WarehousePlaceSuggestionContracts.PlaceSuggestionItemRequest;
import com.uten.imp.features.warehouse.place.WarehousePlaceSuggestionContracts.PlaceSuggestionRequest;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class WarehousePlaceSuggestionServiceTest {

    private static final String PREAUTHORIZE =
            "hasAuthority('warehouse_inbound:view') or hasAuthority('stock_doc:view')";

    private final Validator validator =
            Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    void distinctGoodsColorPairsKeepFirstRequestOrderAndNullColorIsItsOwnDimension() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        UUID color = UUID.randomUUID();
        var dimensions = WarehousePlaceSuggestionService.normalize(new PlaceSuggestionRequest(
                UUID.randomUUID(),
                List.of(
                        new PlaceSuggestionItemRequest(second, null),
                        new PlaceSuggestionItemRequest(first, color),
                        new PlaceSuggestionItemRequest(second, null),
                        new PlaceSuggestionItemRequest(first, null),
                        new PlaceSuggestionItemRequest(first, color))));

        assertThat(dimensions).containsExactly(
                new WarehousePlaceSuggestionService.Dimension(second, null),
                new WarehousePlaceSuggestionService.Dimension(first, color),
                new WarehousePlaceSuggestionService.Dimension(first, null));
    }

    @Test
    void directCallsFailClosedOnMissingWarehouseEmptyOversizedOrBlankGoods() {
        UUID warehouse = UUID.randomUUID();
        List<PlaceSuggestionItemRequest> tooMany = IntStream.rangeClosed(0, 500)
                .mapToObj(ignored -> new PlaceSuggestionItemRequest(UUID.randomUUID(), null))
                .toList();
        List<PlaceSuggestionRequest> invalid = new ArrayList<>(List.of(
                new PlaceSuggestionRequest(null, List.of(
                        new PlaceSuggestionItemRequest(UUID.randomUUID(), null))),
                new PlaceSuggestionRequest(warehouse, List.of()),
                new PlaceSuggestionRequest(warehouse, tooMany),
                new PlaceSuggestionRequest(warehouse, List.of(
                        new PlaceSuggestionItemRequest(null, UUID.randomUUID()))),
                new PlaceSuggestionRequest(warehouse, Arrays.asList(
                        new PlaceSuggestionItemRequest(UUID.randomUUID(), null), null))));
        invalid.add(new PlaceSuggestionRequest(warehouse, null));
        invalid.add(null);
        for (PlaceSuggestionRequest request : invalid) {
            assertThatThrownBy(() -> WarehousePlaceSuggestionService.normalize(request))
                    .isInstanceOf(ApiException.class)
                    .satisfies(error -> assertThat(((ApiException) error).getCode())
                            .isEqualTo(ErrorCode.VALIDATION_FAILED));
        }
        assertThat(WarehousePlaceSuggestionService.normalize(
                new PlaceSuggestionRequest(warehouse, tooMany.subList(0, 500)))).hasSize(500);
    }

    @Test
    void beanValidationRejectsTheSameShapesAtTheHttpBoundary() {
        UUID warehouse = UUID.randomUUID();
        var ok = new PlaceSuggestionRequest(warehouse, List.of(
                new PlaceSuggestionItemRequest(UUID.randomUUID(), null)));
        assertThat(validator.validate(ok)).isEmpty();
        assertThat(WarehousePlaceSuggestionContracts.MAX_ITEMS).isEqualTo(500);

        List<PlaceSuggestionItemRequest> tooMany = IntStream.rangeClosed(0, 500)
                .mapToObj(ignored -> new PlaceSuggestionItemRequest(UUID.randomUUID(), null))
                .toList();
        assertThat(validator.validate(new PlaceSuggestionRequest(warehouse, tooMany))).isNotEmpty();
        assertThat(validator.validate(new PlaceSuggestionRequest(warehouse, List.of()))).isNotEmpty();
        assertThat(validator.validate(new PlaceSuggestionRequest(warehouse, null))).isNotEmpty();
        assertThat(validator.validate(new PlaceSuggestionRequest(null, ok.items()))).isNotEmpty();
        assertThat(validator.validate(new PlaceSuggestionRequest(warehouse, List.of(
                new PlaceSuggestionItemRequest(null, UUID.randomUUID()))))).isNotEmpty();
        assertThat(validator.validate(new PlaceSuggestionRequest(warehouse, Arrays.asList(
                new PlaceSuggestionItemRequest(UUID.randomUUID(), null), null)))).isNotEmpty();
    }

    @Test
    void oneBoundedQueryReadsPreferenceThenGoodsMasterWithoutScanningHistoricalDocuments() {
        String sql = WarehousePlaceSuggestionService.SUGGESTION_SQL;
        assertThat(sql)
                .contains("WITH ORDINALITY AS requested(goods_id, color_id, position)")
                .contains("CAST(string_to_array(:goodsIds, ',') AS uuid[])")
                .contains("CAST(string_to_array(:colorIds, ',', '') AS uuid[])")
                .contains("LEFT JOIN goods goods")
                .contains("goods.is_deleted = FALSE")
                .contains("LEFT JOIN warehouse_goods_place_preferences preference")
                .contains("preference.warehouse_id = CAST(:warehouseId AS uuid)")
                .contains("preference.goods_id = requested.goods_id")
                .contains("preference.color_id IS NOT DISTINCT FROM requested.color_id")
                .contains("WHERE fn_warehouse_is_active_accounting_leaf(CAST(:warehouseId AS uuid))")
                .contains("ORDER BY requested.position")
                // 优先级：本仓记忆 → 货品主档 → 无；未知/已删除货品一律 NONE。
                .containsSubsequence(
                        "WHEN goods.id IS NULL THEN NULL",
                        "WHEN preference.id IS NOT NULL THEN preference.place",
                        "ELSE NULLIF(BTRIM(goods.stock_place), '')")
                .containsSubsequence(
                        "WHEN goods.id IS NULL THEN 'NONE'",
                        "'WAREHOUSE_PREFERENCE'", "'GOODS_MASTER'", "ELSE 'NONE'")
                .doesNotContain("production_finished_arrival_registration")
                .doesNotContain("production_daily_report")
                .doesNotContain("procurement_iqc")
                .doesNotContain("purchase_receipt")
                .doesNotContain("subcontract_receipt")
                .doesNotContain("stock_doc")
                .doesNotContain("registration_history", "LEFT JOIN LATERAL")
                .doesNotContain("INSERT", "UPDATE", "DELETE", "FOR UPDATE");
    }

    @Test
    void unavailableWarehouseIsAValidationErrorAndServiceIsReadOnly() throws Exception {
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/place/"
                        + "WarehousePlaceSuggestionService.java"));
        assertThat(service)
                .contains("@Transactional(readOnly = true)")
                .contains("@PreAuthorize(\"" + PREAUTHORIZE + "\")")
                .contains("ErrorCode.VALIDATION_FAILED, \"所选仓库不可用，请重新选择\"")
                .contains("SOURCE_NONE");
        assertThat(WarehousePlaceSuggestionService.class
                .getMethod("suggest", PlaceSuggestionRequest.class)
                .getAnnotation(PreAuthorize.class).value()).isEqualTo(PREAUTHORIZE);
    }

    @Test
    void controllerExposesOnePostEndpointWithValidationAndInboundOrStockDocView() throws Exception {
        String controller = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/place/"
                        + "WarehousePlaceSuggestionController.java"));
        assertThat(controller)
                .contains("@RequestMapping(\"/api/warehouse/place-suggestions\")")
                .contains("@PostMapping\n")
                .contains("@PreAuthorize(\"" + PREAUTHORIZE + "\")")
                .contains("@Valid @RequestBody PlaceSuggestionRequest request")
                .doesNotContain("@GetMapping")
                .doesNotContain("EntityManager");

        assertThat(WarehousePlaceSuggestionController.class.getAnnotation(RequestMapping.class)
                .value()).containsExactly("/api/warehouse/place-suggestions");
        var method = WarehousePlaceSuggestionController.class
                .getMethod("suggest", PlaceSuggestionRequest.class);
        assertThat(method.getAnnotation(PostMapping.class).value()).isEmpty();
        assertThat(method.getAnnotation(PreAuthorize.class).value()).isEqualTo(PREAUTHORIZE);
        assertThat(method.getParameters()[0].isAnnotationPresent(jakarta.validation.Valid.class))
                .isTrue();

        String contracts = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/place/"
                        + "WarehousePlaceSuggestionContracts.java"));
        assertThat(contracts)
                .contains("@NotNull UUID warehouseId")
                .contains("@Size(min = 1, max = MAX_ITEMS")
                .contains("@NotNull UUID goodsId")
                .contains("UUID colorId)")
                .contains("public record PlaceSuggestionView(")
                .contains("String source)");
    }
}
