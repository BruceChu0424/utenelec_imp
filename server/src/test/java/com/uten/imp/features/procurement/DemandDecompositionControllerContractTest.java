package com.uten.imp.features.procurement;

import com.uten.imp.features.purchase.request.PurchaseRequestController;
import com.uten.imp.features.purchase.request.dto.DecompositionPreviewRequest;
import com.uten.imp.features.subcontract.application.SubcontractApplicationController;
import org.junit.jupiter.api.Test;
import org.springframework.core.annotation.AnnotatedElementUtils;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class DemandDecompositionControllerContractTest {

    private static final String[] LINE_FIELDS = {
            "sourceDocumentId", "sourceDocumentNo", "sourceItemId",
            "goodsId", "colorId", "unitId", "unitRate", "requestedQty",
            "orderedQty", "pendingQty", "remainingQty", "needDate",
            "warehouseId", "sourcePlanNo"
    };
    private static final Class<?>[] LINE_TYPES = {
            UUID.class, String.class, UUID.class, UUID.class, UUID.class, UUID.class,
            BigDecimal.class, BigDecimal.class, BigDecimal.class, BigDecimal.class,
            BigDecimal.class, LocalDate.class, UUID.class, String.class
    };

    @Test
    void purchaseRequestHttpApiIsReadOnlyAndRequiresBothPreviewPermissions()
            throws Exception {
        assertReadOnlySurface(PurchaseRequestController.class);
        Method method = PurchaseRequestController.class.getDeclaredMethod(
                "decompositionPreview", DecompositionPreviewRequest.class);
        assertPreviewContract(
                method,
                "hasAuthority('purchase_request:view') and hasAuthority('purchase_order:decompose')");
    }

    @Test
    void subcontractApplicationHttpApiIsReadOnlyAndRequiresBothPreviewPermissions()
            throws Exception {
        assertReadOnlySurface(SubcontractApplicationController.class);
        Method method = SubcontractApplicationController.class.getDeclaredMethod(
                "decompositionPreview",
                com.uten.imp.features.subcontract.application.dto.DecompositionPreviewRequest.class);
        assertPreviewContract(
                method,
                "hasAuthority('subcontract_application:view') and hasAuthority('subcontract_order:decompose')");
    }

    @Test
    void bothPreviewLinesKeepTheTypedDemandPrefixAndAppendTheirOwnFields() {
        String[] purchaseFields = Arrays.copyOf(LINE_FIELDS, LINE_FIELDS.length + 6);
        System.arraycopy(new String[]{"quantitySemantics", "giftQty", "giftOrderedQty",
                "pendingGiftQty", "remainingGiftQty", "physicalRemainingQty"},
                0, purchaseFields, LINE_FIELDS.length, 6);
        Class<?>[] purchaseTypes = Arrays.copyOf(LINE_TYPES, LINE_TYPES.length + 6);
        purchaseTypes[LINE_TYPES.length] = String.class;
        Arrays.fill(purchaseTypes, LINE_TYPES.length + 1, purchaseTypes.length, BigDecimal.class);
        assertLineFields(
                com.uten.imp.features.purchase.request.dto.DecompositionPreviewItem.class,
                purchaseFields, purchaseTypes);
        // ADR-156: 委外在同一份14项需求前缀之后只追加齐套/可下单量。
        String[] subcontractFields = Arrays.copyOf(LINE_FIELDS, LINE_FIELDS.length + 2);
        subcontractFields[LINE_FIELDS.length] = "kitQty";
        subcontractFields[LINE_FIELDS.length + 1] = "orderableQty";
        Class<?>[] subcontractTypes = Arrays.copyOf(LINE_TYPES, LINE_TYPES.length + 2);
        Arrays.fill(subcontractTypes, LINE_TYPES.length, subcontractTypes.length, BigDecimal.class);
        assertLineFields(
                com.uten.imp.features.subcontract.application.dto.DecompositionPreviewItem.class,
                subcontractFields, subcontractTypes);
    }

    @Test
    void purchasePreviewStillAcceptsTheOriginalFourteenArgumentConstructor() throws Exception {
        Class<com.uten.imp.features.purchase.request.dto.DecompositionPreviewItem> lineType =
                com.uten.imp.features.purchase.request.dto.DecompositionPreviewItem.class;
        Object[] original = {UUID.randomUUID(), "PR-compat", UUID.randomUUID(), UUID.randomUUID(),
                UUID.randomUUID(), UUID.randomUUID(), new BigDecimal("999999999999.000001"),
                new BigDecimal("99.1250"), new BigDecimal("60.0000"), new BigDecimal("10.1250"),
                new BigDecimal("29.0000"), LocalDate.of(2026, 10, 12), UUID.randomUUID(), "PLAN-compat"};
        var line = lineType.getConstructor(LINE_TYPES).newInstance(original);
        for (int index = 0; index < LINE_FIELDS.length; index++) {
            assertThat(lineType.getRecordComponents()[index].getAccessor().invoke(line))
                    .as(LINE_FIELDS[index]).isEqualTo(original[index]);
        }
        assertThat(line.quantitySemantics()).isEqualTo(
                com.uten.imp.common.finance.ProcurementQuantities.LEGACY);
        assertThat(line.giftQty()).isZero();
        assertThat(line.giftOrderedQty()).isZero();
        assertThat(line.pendingGiftQty()).isZero();
        assertThat(line.remainingGiftQty()).isZero();
        assertThat(line.physicalRemainingQty()).isEqualTo(line.remainingQty());
        assertThat(line.getUnitRateExact()).isEqualTo("999999999999.000001");
    }

    private static void assertReadOnlySurface(Class<?> controllerType) throws NoSuchMethodException {
        Method facets = Arrays.stream(controllerType.getDeclaredMethods())
                .filter(method -> method.getName().equals("facets")).findFirst().orElseThrow();
        assertThat(facets.getAnnotation(GetMapping.class).value()).containsExactly("/facets");
        String viewPermission = controllerType == PurchaseRequestController.class
                ? "hasAuthority('purchase_request:view')"
                : "hasAuthority('subcontract_application:view')";
        assertThat(facets.getAnnotation(PreAuthorize.class).value()).isEqualTo(viewPermission);
        Method detail = controllerType.getDeclaredMethod("detail", UUID.class);
        Method history = controllerType.getDeclaredMethod("history", UUID.class);
        assertThat(detail.getAnnotation(GetMapping.class).value()).containsExactly("/{id}");
        assertThat(history.getAnnotation(GetMapping.class).value()).containsExactly("/{id}/history");
        assertThat(detail.getAnnotation(PreAuthorize.class).value()).isEqualTo(viewPermission);
        assertThat(history.getAnnotation(PreAuthorize.class).value()).isEqualTo(viewPermission);
        assertThat(history.getReturnType()).isEqualTo(detail.getReturnType());
        Method historyRows = controllerType.getDeclaredMethod("historyRows", UUID.class, Long.class, int.class);
        assertThat(historyRows.getAnnotation(GetMapping.class).value()).containsExactly("/{id}/history/rows");
        assertThat(historyRows.getAnnotation(PreAuthorize.class).value()).isEqualTo(viewPermission);
        assertThat(historyRows.getReturnType()).isEqualTo(List.class);
        if (controllerType == PurchaseRequestController.class) {
            Method adjust = controllerType.getDeclaredMethod("adjustItemQty", UUID.class, UUID.class,
                    PurchaseRequestController.ItemQtyAdjustRequest.class);
            assertThat(adjust.getAnnotation(PutMapping.class).value())
                    .containsExactly("/{id}/items/{itemId}/qty");
            assertThat(adjust.getAnnotation(PreAuthorize.class).value())
                    .isEqualTo("hasAuthority('purchase_request:view') and hasAuthority('purchase_order:decompose')");
        }
        List<Method> endpoints = Arrays.stream(controllerType.getDeclaredMethods())
                .filter(method -> AnnotatedElementUtils.hasAnnotation(method, RequestMapping.class))
                .toList();
        assertThat(endpoints).allSatisfy(method ->
                assertThat(Modifier.isPublic(method.getModifiers())).as(method.getName()).isTrue());
        assertThat(endpoints.stream().map(Method::getName))
                .containsExactlyInAnyOrder(
                        // 2026-09-05 申请详情分解前行内改量（读+改量权限同族，
                        // 非 write 全开）：仅采购申请面有，委外申请面保持只读。
                        controllerType == PurchaseRequestController.class
                                ? new String[]{"list", "detail", "history", "historyRows", "facets",
                                        "decompositionPreview", "adjustItemQty"}
                                // ADR-143 §二.3：委外申请面唯一的写口是缺 BOM 时「通知研发完善」，
                                // 不改申请本身，权限与分解订货同一组。
                                // ADR-156 §齐套: 每个申请行只读查看「够做的套数 / 可下单数量」。
                                : new String[]{"list", "detail", "history", "historyRows", "facets",
                                        "decompositionPreview", "forwardBom", "kit"});
        if (controllerType == SubcontractApplicationController.class) {
            Method forwardBom = controllerType.getDeclaredMethod("forwardBom", UUID.class);
            assertThat(forwardBom.getAnnotation(PostMapping.class).value())
                    .containsExactly("/items/{applicationItemId}/forward-bom");
            assertThat(forwardBom.getAnnotation(PreAuthorize.class).value())
                    .isEqualTo("hasAuthority('subcontract_application:view') and hasAuthority('subcontract_order:decompose')");
            Method kit = controllerType.getDeclaredMethod("kit", UUID.class);
            assertThat(kit.getAnnotation(GetMapping.class).value())
                    .containsExactly("/items/{applicationItemId}/kit");
            assertThat(kit.getAnnotation(PreAuthorize.class).value()).isEqualTo(viewPermission);
        }
    }

    private static void assertPreviewContract(Method method, String permission) {
        assertThat(method.getReturnType()).isEqualTo(List.class);
        assertThat(method.getAnnotation(PostMapping.class).value())
                .containsExactly("/decomposition-preview");
        assertThat(method.getAnnotation(PreAuthorize.class).value())
                .isEqualTo(permission);
    }

    private static void assertLineFields(Class<?> lineType, String[] fields, Class<?>[] types) {
        assertThat(lineType.isRecord()).isTrue();
        assertThat(Arrays.stream(lineType.getRecordComponents())
                        .map(component -> component.getName()))
                .containsExactly(fields);
        Class<?>[] actualTypes = Arrays.stream(lineType.getRecordComponents())
                .map(component -> component.getType()).toArray(Class<?>[]::new);
        assertThat(actualTypes).containsExactly(types);
    }
}
