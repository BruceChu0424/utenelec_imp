package com.uten.imp.features.procurement;

import com.uten.imp.features.purchase.request.PurchaseRequestController;
import com.uten.imp.features.purchase.request.dto.DecompositionPreviewRequest;
import com.uten.imp.features.subcontract.application.SubcontractApplicationController;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class DemandDecompositionControllerContractTest {

    private static final String[] LINE_FIELDS = {
            "sourceDocumentId", "sourceDocumentNo", "sourceItemId",
            "goodsId", "colorId", "unitId", "unitRate", "requestedQty",
            "orderedQty", "pendingQty", "remainingQty", "needDate",
            "warehouseId", "sourcePlanNo"
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
    void bothPreviewLinesExposeTheSameDemandOnlyJsonShape() {
        assertLineFields(
                com.uten.imp.features.purchase.request.dto.DecompositionPreviewItem.class);
        assertLineFields(
                com.uten.imp.features.subcontract.application.dto.DecompositionPreviewItem.class);
    }

    private static void assertReadOnlySurface(Class<?> controllerType) {
        assertThat(Arrays.stream(controllerType.getDeclaredMethods())
                        .filter(method -> Modifier.isPublic(method.getModifiers()))
                        .map(Method::getName))
                .containsExactlyInAnyOrder("list", "detail", "decompositionPreview");
    }

    private static void assertPreviewContract(Method method, String permission) {
        assertThat(method.getReturnType()).isEqualTo(List.class);
        assertThat(method.getAnnotation(PostMapping.class).value())
                .containsExactly("/decomposition-preview");
        assertThat(method.getAnnotation(PreAuthorize.class).value())
                .isEqualTo(permission);
    }

    private static void assertLineFields(Class<?> lineType) {
        assertThat(Arrays.stream(lineType.getRecordComponents())
                        .map(component -> component.getName()))
                .containsExactly(LINE_FIELDS);
    }
}
