package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationItemRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationRequest;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProductionFinishedArrivalRegistrationServiceTest {

    @Test
    void automaticReceiptRequiresExplicitCountButStandardRegistrationKeepsItsOldShape() {
        UUID warehouse=UUID.randomUUID(), item=UUID.randomUUID();
        var oldRow=new ArrivalRegistrationItemRequest(item,"A01");
        assertThatThrownBy(()->ProductionFinishedArrivalRegistrationService.normalize(
                new ArrivalRegistrationRequest("count-check-old",warehouse,List.of(oldRow),null,true)))
                .isInstanceOf(ApiException.class).hasMessageContaining("逐行填写实际点数");
        var standard=ProductionFinishedArrivalRegistrationService.normalize(
                new ArrivalRegistrationRequest("count-check-old",warehouse,List.of(oldRow),null,false));
        var standardWithUnusedCount=ProductionFinishedArrivalRegistrationService.normalize(
                new ArrivalRegistrationRequest("count-check-old",warehouse,
                        List.of(new ArrivalRegistrationItemRequest(item,"A01",BigDecimal.TEN)),null,false));
        assertThat(standard.requestHash()).isEqualTo(standardWithUnusedCount.requestHash());
        assertThat(standard.countedQuantities()).isEmpty();
    }

    @Test
    void physicalCountIsCanonicalAndCannotChangeUnderTheSameIdempotencyRequest() {
        UUID warehouse=UUID.randomUUID(), first=UUID.randomUUID(), second=UUID.randomUUID();
        var left=ProductionFinishedArrivalRegistrationService.normalize(new ArrivalRegistrationRequest(
                "count-check-hash",warehouse,List.of(new ArrivalRegistrationItemRequest(first,"A01",new BigDecimal("300.00")),
                new ArrivalRegistrationItemRequest(second,"B01",new BigDecimal("100"))),null,true));
        var reordered=ProductionFinishedArrivalRegistrationService.normalize(new ArrivalRegistrationRequest(
                "count-check-hash",warehouse,List.of(new ArrivalRegistrationItemRequest(second,"B01",new BigDecimal("100.0")),
                new ArrivalRegistrationItemRequest(first,"A01",new BigDecimal("300"))),null,true));
        var changed=ProductionFinishedArrivalRegistrationService.normalize(new ArrivalRegistrationRequest(
                "count-check-hash",warehouse,List.of(new ArrivalRegistrationItemRequest(first,"A01",new BigDecimal("299")),
                new ArrivalRegistrationItemRequest(second,"B01",new BigDecimal("101"))),null,true));
        assertThat(left.requestHash()).isEqualTo(reordered.requestHash()).isNotEqualTo(changed.requestHash());
        ProductionFinishedArrivalRegistrationService.requireCountedQuantities(
                Map.of(first,new BigDecimal("300"),second,new BigDecimal("100")),left.countedQuantities());
        assertThatThrownBy(()->ProductionFinishedArrivalRegistrationService.requireCountedQuantities(
                Map.of(first,new BigDecimal("300"),second,new BigDecimal("100")),changed.countedQuantities()))
                .isInstanceOf(ApiException.class).hasMessageContaining("人工点收");
    }

    @Test
    void countingCannotOmitOrSubstituteAnotherReportLineOrUseInvalidPrecision() {
        UUID item=UUID.randomUUID();
        assertThatThrownBy(()->ProductionFinishedArrivalRegistrationService.requireCountedQuantities(
                Map.of(item,BigDecimal.TEN),Map.of(UUID.randomUUID(),BigDecimal.TEN)))
                .isInstanceOf(ApiException.class).hasMessageContaining("逐行覆盖");
        for(String invalid:List.of("0","-1","1.00001","100000000000000")) {
            assertThatThrownBy(()->ProductionFinishedArrivalRegistrationService.normalize(new ArrivalRegistrationRequest(
                    "count-check-invalid",UUID.randomUUID(),List.of(new ArrivalRegistrationItemRequest(
                            item,"A01",new BigDecimal(invalid))),null,true)))
                    .isInstanceOf(ApiException.class);
        }
    }

    @Test
    void registrationWeightIsKilogramsAndPartOfTheIdempotencyHash() {
        UUID warehouse=UUID.randomUUID(), first=UUID.randomUUID(), second=UUID.randomUUID();
        var unweighed=ProductionFinishedArrivalRegistrationService.normalize(new ArrivalRegistrationRequest(
                "weight-check-hash",warehouse,List.of(new ArrivalRegistrationItemRequest(first,"A01"),
                new ArrivalRegistrationItemRequest(second,"B01")),null,false));
        var zero=ProductionFinishedArrivalRegistrationService.normalize(new ArrivalRegistrationRequest(
                "weight-check-hash",warehouse,List.of(new ArrivalRegistrationItemRequest(first,"A01",null,BigDecimal.ZERO),
                new ArrivalRegistrationItemRequest(second,"B01")),null,false));
        var weighed=ProductionFinishedArrivalRegistrationService.normalize(new ArrivalRegistrationRequest(
                "weight-check-hash",warehouse,List.of(new ArrivalRegistrationItemRequest(first,"A01",null,new BigDecimal("12.5000")),
                new ArrivalRegistrationItemRequest(second,"B01")),null,false));
        var sameScale=ProductionFinishedArrivalRegistrationService.normalize(new ArrivalRegistrationRequest(
                "weight-check-hash",warehouse,List.of(new ArrivalRegistrationItemRequest(second,"B01"),
                new ArrivalRegistrationItemRequest(first,"A01",null,new BigDecimal("12.5"))),null,false));
        var changed=ProductionFinishedArrivalRegistrationService.normalize(new ArrivalRegistrationRequest(
                "weight-check-hash",warehouse,List.of(new ArrivalRegistrationItemRequest(first,"A01",null,new BigDecimal("12.6")),
                new ArrivalRegistrationItemRequest(second,"B01")),null,false));

        // 0 = 没称: 与不填同一份登记事实, 老哈希逐字不变。
        assertThat(zero.requestHash()).isEqualTo(unweighed.requestHash());
        assertThat(zero.weights()).isEmpty();
        assertThat(weighed.weights()).containsOnlyKeys(first);
        assertThat(weighed.weights().get(first)).isEqualByComparingTo("12.5");
        assertThat(weighed.requestHash()).isEqualTo(sameScale.requestHash())
                .isNotEqualTo(unweighed.requestHash())
                .isNotEqualTo(changed.requestHash());
        for (String invalid : List.of("-0.0001", "1.00001", "100000000000000")) {
            assertThatThrownBy(() -> ProductionFinishedArrivalRegistrationService.normalizedWeight(
                    new BigDecimal(invalid)))
                    .isInstanceOf(ApiException.class).hasMessageContaining("千克");
        }
        assertThat(ProductionFinishedArrivalRegistrationService.normalizedWeight(new BigDecimal("1E+1")))
                .isEqualByComparingTo("10");
    }

    @Test
    void registrationRecordsFinishedObservationsAndReversalMarksThemReversed() throws Exception {
        String source = Files.readString(Path.of("src/main/java/com/uten/imp/features/warehouse/finishedin/ProductionFinishedArrivalRegistrationService.java"));
        // 登记行带实称重量入库(只在 INSERT 时写), 同事务记 FINISHED 观测; 撤回登记按同一幂等键红冲。
        assertThat(source).contains("counted_qty, weight)")
                .contains("SourceKind.FINISHED")
                .contains("FINISHED_CAPTURE_PREFIX + registrationItemId")
                .contains("counted != null ? COUNTED_QTY_EPS : REPORTED_QTY_EPS")
                .contains("line_profile.mass_unit_code IS NOT NULL")
                .containsSubsequence("cancelForReversedRegistration(", "reverseFinishedObservations(registrationId);");
        assertThat(ProductionFinishedArrivalRegistrationService.FINISHED_CAPTURE_PREFIX).isEqualTo("FINISHED:");
    }

    @Test
    void itemViewReturnsRegisteredWeightAndReportUnitRate() throws Exception {
        String source = Files.readString(Path.of("src/main/java/com/uten/imp/features/warehouse/finishedin/ProductionFinishedArrivalRegistrationService.java"));
        // 待登记与已登记两条明细查询都带报工行换算率(空按 1), 已登记行另带登记时的实称重量;
        // 页面按 报工数量 x unitRate 核对重量, 已登记行只读显示登记重量。
        assertThat(source).containsSubsequence("NULL::numeric AS weight,",
                "COALESCE(report_item.unit_rate, 1) AS unit_rate");
        assertThat(source).containsSubsequence("registration_item.weight,",
                "COALESCE(report_item.unit_rate, 1) AS unit_rate");
        assertThat(source).contains("(BigDecimal) row[19], decimal(row[20])))");
        assertThat(java.util.Arrays.stream(
                ProductionFinishedArrivalContracts.ArrivalRegistrationItemView.class.getRecordComponents())
                .map(java.lang.reflect.RecordComponent::getName).toList())
                .endsWith("countedQty", "weight", "unitRate");
    }

    @Test
    void batchLocksEveryReportBeforeAnyWarehouseAndReplaysBeforeCurrentReferenceChecks() throws Exception {
        String source = Files.readString(Path.of("src/main/java/com/uten/imp/features/warehouse/finishedin/ProductionFinishedArrivalRegistrationService.java"));
        int start = source.indexOf("public BatchArrivalRegistrationResult batchRegister(");
        int end = source.indexOf("// 同仓新建批次", start);
        String prepare = source.substring(start, end);
        assertThat(prepare).containsSubsequence("lockCommand(actorId, key)",
                "existingRegistration(entry.getKey()", "lockApprovedReport(reportId)",
                "ORDER BY report_id, id FOR UPDATE", "validatedWarehouse(warehouseId)",
                "references.receiver = requireReceiver(receiverEmployeeId)", "registerNew(");
        assertThat(prepare).contains("outcomes.get(id) == null")
                .contains(".distinct().sorted().toList()");
    }

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
                                        first, "A31-3-1")), null));
        var right = ProductionFinishedArrivalRegistrationService.normalize(
                new ArrivalRegistrationRequest(
                        "arrival-key-001", warehouseId,
                        List.of(
                                new ArrivalRegistrationItemRequest(
                                        first, "A31-3-1"),
                                new ArrivalRegistrationItemRequest(
                                        second, "B02-2-1")), null));

        assertThat(left.requestHash()).isEqualTo(right.requestHash());
        assertThat(left.places()).containsEntry(second, "B02-2-1");
    }

    @Test
    void remarkIsTrimmedEmptyBecomesNullAndEntersTheRequestHash() {
        UUID warehouseId = UUID.randomUUID();
        UUID reportItemId = UUID.randomUUID();
        var trimmed = ProductionFinishedArrivalRegistrationService.normalize(
                new ArrivalRegistrationRequest(
                        "arrival-key-remark", warehouseId,
                        List.of(new ArrivalRegistrationItemRequest(
                                reportItemId, "A31-3-1")), "  x  "));
        var empty = ProductionFinishedArrivalRegistrationService.normalize(
                new ArrivalRegistrationRequest(
                        "arrival-key-remark", warehouseId,
                        List.of(new ArrivalRegistrationItemRequest(
                                reportItemId, "A31-3-1")), ""));
        var absent = ProductionFinishedArrivalRegistrationService.normalize(
                new ArrivalRegistrationRequest(
                        "arrival-key-remark", warehouseId,
                        List.of(new ArrivalRegistrationItemRequest(
                                reportItemId, "A31-3-1")), null));
        var different = ProductionFinishedArrivalRegistrationService.normalize(
                new ArrivalRegistrationRequest(
                        "arrival-key-remark", warehouseId,
                        List.of(new ArrivalRegistrationItemRequest(
                                reportItemId, "A31-3-1")), "y"));

        assertThat(trimmed.remark()).isEqualTo("x");
        assertThat(empty.remark()).isNull();
        assertThat(absent.remark()).isNull();
        assertThat(empty.requestHash()).isEqualTo(absent.requestHash());
        assertThat(trimmed.requestHash()).isNotEqualTo(absent.requestHash());
        assertThat(different.requestHash()).isNotEqualTo(trimmed.requestHash());

        ArrivalRegistrationRequest tooLong = new ArrivalRegistrationRequest(
                "arrival-key-remark", warehouseId,
                List.of(new ArrivalRegistrationItemRequest(
                        reportItemId, "A31-3-1")), "r".repeat(501));
        assertThatThrownBy(() ->
                ProductionFinishedArrivalRegistrationService.normalize(tooLong))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.VALIDATION_FAILED));
    }

    @Test
    void reversalReasonIsTrimmedAndBoundedAndHashesRegistrationIdentity() {
        UUID registrationId = UUID.randomUUID();
        var normalized = ProductionFinishedArrivalRegistrationService.normalizeReversal(
                registrationId,
                new ProductionFinishedArrivalContracts.ArrivalRegistrationReversalRequest(
                        "reverse-key-001", "  仓库选错  "));
        var other = ProductionFinishedArrivalRegistrationService.normalizeReversal(
                UUID.randomUUID(),
                new ProductionFinishedArrivalContracts.ArrivalRegistrationReversalRequest(
                        "reverse-key-001", "仓库选错"));

        assertThat(normalized.reason()).isEqualTo("仓库选错");
        assertThat(normalized.requestHash()).isNotEqualTo(other.requestHash());
        assertThatThrownBy(() ->
                ProductionFinishedArrivalRegistrationService.normalizeReversal(
                        registrationId,
                        new ProductionFinishedArrivalContracts.ArrivalRegistrationReversalRequest(
                                "reverse-key-001", " x ")))
                .isInstanceOf(ApiException.class);
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
                                reportItemId, "A31-3-2")), null);
        assertThatThrownBy(() ->
                ProductionFinishedArrivalRegistrationService.normalize(duplicate))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.VALIDATION_FAILED));

        ArrivalRegistrationRequest blank = new ArrivalRegistrationRequest(
                "arrival-key-003", UUID.randomUUID(),
                List.of(new ArrivalRegistrationItemRequest(
                        UUID.randomUUID(), "  ")), null);
        assertThatThrownBy(() ->
                ProductionFinishedArrivalRegistrationService.normalize(blank))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void selectedPendingSubsetIsAcceptedButProcessedOrUnknownLineFailsClosed() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        ProductionFinishedArrivalRegistrationService.requireSelectedPending(
                List.of(first, second), java.util.Set.of(second));

        assertThatThrownBy(() ->
                ProductionFinishedArrivalRegistrationService.requireSelectedPending(
                        List.of(first), java.util.Set.of(second)))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT));
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
    void rememberPlanSkipsUnusableSourcesInsteadOfFailingTheRegistration() {
        UUID goodsId = UUID.randomUUID();
        var plan = ProductionFinishedArrivalRegistrationService.buildRememberPlan(
                java.util.Arrays.asList(
                        null,
                        new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                                null, null, "A31-3-1", "V5001", "成品"),
                        new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                                goodsId, null, null, "V5001", "成品"),
                        new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                                goodsId, null, "   ", "V5001", "成品"),
                        new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                                goodsId, null, "x".repeat(101), "V5001", "成品"),
                        new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                                goodsId, null, " C01 ", "V5001", "成品")));

        assertThat(plan.ambiguous()).isZero();
        assertThat(plan.candidates()).singleElement()
                .satisfies(candidate -> {
                    assertThat(candidate.goodsId()).isEqualTo(goodsId);
                    assertThat(candidate.colorId()).isNull();
                    assertThat(candidate.place()).isEqualTo("C01");
                });
        assertThat(ProductionFinishedArrivalRegistrationService.buildRememberPlan(null)
                .candidates()).isEmpty();
    }

    @Test
    void placeSuggestionsLiveInTheSharedWarehouseServiceAndReadMasterRelationsWithoutScanningHistoricalDocuments()
            throws Exception {
        String shared = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/place/"
                        + "WarehousePlaceSuggestionService.java"));
        String sql = section(shared,
                "static final String SUGGESTION_SQL = \"\"\"", "\"\"\";");
        assertThat(sql)
                .contains("LEFT JOIN warehouse_goods_place_preferences preference")
                .contains("preference.warehouse_id = CAST(:warehouseId AS uuid)")
                .contains("preference.goods_id = requested.goods_id")
                .contains("preference.color_id IS NOT DISTINCT FROM requested.color_id")
                .contains("NULLIF(BTRIM(goods.stock_place), '')")
                .contains("fn_warehouse_is_active_accounting_leaf(CAST(:warehouseId AS uuid))")
                .containsSubsequence("'WAREHOUSE_PREFERENCE'", "'GOODS_MASTER'", "'NONE'")
                .doesNotContain("production_finished_arrival_registration")
                .doesNotContain("production_daily_report")
                .doesNotContain("v_production_report_items_pending_registration")
                .doesNotContain("procurement_iqc")
                .doesNotContain("purchase_receipt")
                .doesNotContain("subcontract_receipt")
                .doesNotContain("registration_history", "LEFT JOIN LATERAL", "REGISTRATION_HISTORY")
                .doesNotContain("INSERT INTO warehouse_goods_place_preferences")
                .doesNotContain("UPDATE warehouse_goods_place_preferences");

        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/"
                        + "ProductionFinishedArrivalRegistrationService.java"));
        assertThat(service)
                .doesNotContain("placeSuggestionsInternal")
                .doesNotContain("public PlaceSuggestionsView placeSuggestions(")
                .doesNotContain("batchPlaceSuggestions(")
                .doesNotContain("lastWarehouse()")
                .doesNotContain("'WAREHOUSE_PREFERENCE'");
    }

    @Test
    void registrationRemembersPlacesInTheSameTransactionAndReplaysDoNot() throws Exception {
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/"
                        + "ProductionFinishedArrivalRegistrationService.java"));

        String single = section(service,
                "public ArrivalRegistrationView register(",
                "private RegistrationOutcome registerNormalized(");
        assertThat(single).containsSubsequence(
                "RegistrationOutcome outcome = registerNormalized(",
                "if (!outcome.replay()) {", "openInspectionSheet(",
                "rememberRegisteredPlaces(List.of(outcome.registrationId()));", "}",
                "return detailInternal(reportId, outcome.registrationId());");
        // 记忆与登记同一个 @Transactional：register 方法前紧挨着的注解就是它。
        String singleHeader = service.substring(
                service.lastIndexOf("@Transactional",
                        service.indexOf("public ArrivalRegistrationView register(")),
                service.indexOf("public ArrivalRegistrationView register("));
        assertThat(singleHeader).startsWith("@Transactional\n")
                .doesNotContain("readOnly");

        String batch = section(service,
                "public BatchArrivalRegistrationResult batchRegister(",
                "private Map<UUID, Object[]> sheetsByRegistration(");
        assertThat(batch)
                .containsSubsequence("if (outcome.replay()) continue;",
                        "openInspectionSheet(",
                        "rememberRegisteredPlaces(byWarehouse.values().stream()")
                .doesNotContain("rememberRegisteredPlaces(outcomes.");

        String remember = section(service,
                "private void rememberRegisteredPlaces(",
                "private ArrivalRegistrationView detailInternal(UUID reportId) {");
        assertThat(remember)
                .contains("WHERE registration.id IN (:registrationIds)")
                .contains("buildRememberPlan(")
                .contains("INSERT INTO warehouse_goods_place_preferences")
                .contains("'FINISHED_ARRIVAL'")
                .contains("ON CONFLICT ON CONSTRAINT")
                .contains("warehouse_goods_place_preference_dimension_uk")
                .contains("EXCLUDED.source_registered_at")
                .contains("CAST(:colorId AS uuid)")
                // 记不了(同维度多库位、货品已删除等)只跳过，绝不让登记失败。
                .doesNotContain("throw ")
                .doesNotContain("@Transactional")
                .doesNotContain("@PreAuthorize");
        String plan = section(service,
                "static RememberPlan buildRememberPlan(",
                "private static LocalDate localDate(");
        assertThat(plan).doesNotContain("throw ");
    }

    @Test
    void separateRememberAndReportBoundSuggestionEndpointsAreGone() throws Exception {
        String controller = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/"
                        + "ProductionFinishedInboundTaskController.java"));
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/"
                        + "ProductionFinishedArrivalRegistrationService.java"));
        String contracts = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/"
                        + "ProductionFinishedArrivalContracts.java"));

        assertThat(controller)
                .doesNotContain("\"/arrival-registrations/{reportId}/place-suggestions\"")
                .doesNotContain("\"/arrival-registrations/batch/place-suggestions\"")
                .doesNotContain("\"/arrival-registrations/{reportId}/remember-places\"")
                .doesNotContain("\"/arrival-registrations/batch/remember-registration-batches\"")
                .doesNotContain("\"/arrival-registrations/last-warehouse\"")
                .doesNotContain("arrivalRegistrations.rememberPlaces")
                .doesNotContain("arrivalRegistrations.placeSuggestions")
                .doesNotContain("arrivalRegistrations.batchPlaceSuggestions")
                .doesNotContain("arrivalRegistrations.lastWarehouse");
        assertThat(service)
                .doesNotContain("public RememberPlacesResult rememberPlaces(")
                .doesNotContain("rememberPlacesForRegistrations(")
                .doesNotContain("requireRegistrationIds(")
                .doesNotContain("该报工已有多个登记批次");
        assertThat(contracts)
                .doesNotContain("record PlaceSuggestionsView(")
                .doesNotContain("record PlaceSuggestionItemView(")
                .doesNotContain("record RememberPlacesResult(")
                .doesNotContain("record BatchRememberPlacesResult(")
                .doesNotContain("record LastWarehouseView(")
                // 待登记行的预填提示仍随详情返回。
                .contains("String placeHint,")
                .contains("UUID lastWarehouseId,");
    }

    private static String section(String source, String startMarker, String endMarker) {
        int start = source.indexOf(startMarker);
        assertThat(start).as(startMarker).isNotNegative();
        int end = source.indexOf(endMarker, start + startMarker.length());
        assertThat(end).as(endMarker).isGreaterThan(start);
        return source.substring(start, end);
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
        String contracts = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/"
                        + "ProductionFinishedArrivalContracts.java"));

        assertThat(controller)
                .contains("/arrival-registrations/{reportId}")
                .contains("/arrival-registrations/{registrationId}/reverse")
                .contains("/arrival-registrations/batch")
                .contains("hasAuthority('stock_doc:view')")
                .contains("hasAuthority('stock_doc:approve')");
        assertThat(contracts)
                .contains("public record RegisteredReportView(")
                .contains("UUID registrationId,");
        int insertItems = service.indexOf(
                "INSERT INTO production_finished_arrival_registration_items");
        int registerFqc = service.indexOf(
                "qualityInspection.registerApprovedReportItems(");
        assertThat(insertItems).isGreaterThan(0);
        assertThat(registerFqc).isGreaterThan(insertItems);
        assertThat(service)
                .contains("requireWarehouseTaskAccess")
                .contains("pg_advisory_xact_lock")
                .contains("requireSelectedPending(")
                .contains("request_hash")
                .contains("warehouse_goods_place_preferences")
                .contains("source_registered_at")
                // V548：「未登记」谓词统一引用数据库视图，不再各自拼三个 NOT EXISTS。
                .contains("v_production_report_items_pending_registration")
                .doesNotContain("registered_item.source_report_item_id")
                .doesNotContain("production_fqc_legacy_exemptions exemption")
                .contains("openInspectionSheet(")
                .contains("cancelForReversedRegistration(")
                .contains("app.production_finished_arrival_reversal_id")
                .contains("ON CONFLICT ON CONSTRAINT")
                .contains("warehouse_goods_place_preference_dimension_uk")
                .contains("buildRememberPlan")
                .doesNotContain("UPDATE goods SET stock_place");
    }

    @Test
    void selectedLinesRemainPartialAndReplayUsesExactRegistrationBatch()
            throws Exception {
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/"
                        + "ProductionFinishedArrivalRegistrationService.java"));

        assertThat(service)
                .contains("pendingReportItemIds")
                .contains("containsAll(")
                .contains("normalized.places().keySet()")
                .contains("Unselected report lines remain pending")
                .contains("(UUID) existing[0], true")
                .contains("detailInternal(reportId, outcome.registrationId())")
                .contains("detailInternal(reportId, registrationId)")
                .contains("pendingItemRows(reportId)")
                .contains("registration_item.registration_id = :registrationId")
                .contains("rememberRegisteredPlaces(")
                .contains("registration.source_report_id = :reportId")
                .contains("BatchReportRegistrationRequest::reportId")
                .contains("WHERE report_item.report_id IN (:reportIds)")
                .doesNotContain("rememberPlacesForRegistrations(")
                .doesNotContain("placeSuggestionsInternal(")
                .doesNotContain("ids.stream().map(this::detailInternal)")
                .doesNotContain("该生产报工已由其他登记命令完成")
                .doesNotContain("逐行精确覆盖当前报工全部明细");
    }
}
