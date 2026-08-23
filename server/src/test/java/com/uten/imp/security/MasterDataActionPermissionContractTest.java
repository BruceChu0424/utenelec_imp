package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class MasterDataActionPermissionContractTest {

    private static final List<MasterSpec> MASTERS = List.of(
            master("goods", "goods.Goods", "GoodsDetail"),
            master("mould", "mould.Mould", "MouldDetail"),
            master("client", "client.Client", "ClientDetail"),
            master("supplier", "supplier.Supplier", "SupplierDetail"),
            master("color", "color.Color", "ColorDetail"),
            master("unit", "unit.Unit", "UnitDetail"),
            master("currency", "currency.Currency", "CurrencyDetail"),
            master("warehouse", "warehouse.Warehouse", "WarehouseDetail"),
            master("account", "account.Account", "AccountDetail"));

    private static final List<CategorySpec> CATEGORIES = List.of(
            category("material_category", "materialcategory.MaterialCategory"),
            category("mould_category", "mouldcategory.MouldCategory"),
            category("client_category", "clientcategory.ClientCategory"),
            category("supplier_category", "suppliercategory.SupplierCategory"));

    @Test
    void nineMastersUseMatchingControllerAndServiceActionGates() {
        for (MasterSpec spec : MASTERS) {
            for (Class<?> layer : List.of(spec.controller(), spec.service())) {
                assertGateContains(layer, "create", spec.prefix() + ":create");
                assertGateContains(layer, "update",
                        spec.prefix() + ":edit", spec.prefix() + ":status");
                assertGateContains(layer, "changeStatus", spec.prefix() + ":status");
                assertGateContains(layer, "delete", spec.prefix() + ":delete");
            }
        }
    }

    @Test
    void mixedMasterPutRequiresEditAndAddsStatusOnlyWhenPersistedValueChanges()
            throws Exception {
        for (MasterSpec spec : MASTERS) {
            String source = source(spec.service());
            assertThat(source)
                    .contains("CurrentAuthorityGuard.requireAll(\""
                            + spec.prefix() + ":edit\")")
                    .contains("CurrentAuthorityGuard.requireAll(\""
                            + spec.prefix() + ":status\")")
                    .contains("PESSIMISTIC_WRITE")
                    .contains("MasterStatusChangeRequest");
        }
    }

    @Test
    void categoryCreateEditMoveReorderDeleteAreDoubleLayeredAndFieldSensitive()
            throws Exception {
        for (CategorySpec spec : CATEGORIES) {
            for (Class<?> layer : List.of(spec.controller(), spec.service())) {
                assertGateContains(layer, "create", spec.prefix() + ":create");
                assertGateContains(layer, "update",
                        spec.prefix() + ":edit",
                        spec.prefix() + ":move",
                        spec.prefix() + ":reorder");
                assertGateContains(layer, "delete", spec.prefix() + ":delete");
            }
            String source = source(spec.service());
            assertThat(source)
                    .contains("getMoveToRoot()")
                    .contains("editChanged")
                    .contains("CurrentAuthorityGuard.requireAll(\""
                            + spec.prefix() + ":edit\")")
                    .contains("CurrentAuthorityGuard.requireAll(\""
                            + spec.prefix() + ":move\")")
                    .contains("CurrentAuthorityGuard.requireAll(\""
                            + spec.prefix() + ":reorder\")");
        }
    }

    @Test
    void bomImportAddressSettlementAndPaymentStyleUseExactSplitGates()
            throws Exception {
        Class<?> bomController = type("com.uten.imp.features.master.goods.GoodsBomController");
        Class<?> bomService = type("com.uten.imp.features.master.goods.GoodsBomService");
        for (Class<?> layer : List.of(bomController, bomService)) {
            assertGateContains(layer, "create", "goods:bom:create");
            assertGateContains(layer, "update", "goods:bom:edit");
            assertGateContains(layer, "delete", "goods:bom:delete");
        }
        assertGateContains(bomController, "setAudited", "goods:bom:audit");
        assertGateContains(bomService, "setAudited", "goods:bom:audit");

        for (Class<?> layer : List.of(
                type("com.uten.imp.features.master.goods.importing.GoodsImportController"),
                type("com.uten.imp.features.master.goods.importing.GoodsImportService"))) {
            assertGateContains(layer, "undo", "goods:import:undo");
        }
        for (Class<?> layer : List.of(
                type("com.uten.imp.features.master.client.ClientShipAddressController"),
                type("com.uten.imp.features.master.client.ClientShipAddressService"))) {
            assertGateContains(layer, "add", "client_address:create");
            assertGateContains(layer, "delete", "client_address:delete");
        }
        for (Class<?> layer : List.of(
                type("com.uten.imp.features.master.referencemethod.ReferenceMethodController"),
                type("com.uten.imp.features.master.referencemethod.ReferenceMethodService"))) {
            assertGateContains(layer,
                    layer.getSimpleName().endsWith("Controller")
                            ? "createSettlement" : "create",
                    "settlement_method:create");
        }

        Class<?> paymentController = type(
                "com.uten.imp.features.master.paymentstyle.PaymentStyleController");
        Class<?> paymentService = type(
                "com.uten.imp.features.master.paymentstyle.PaymentStyleService");
        for (Class<?> layer : List.of(paymentController, paymentService)) {
            assertGateContains(layer, "create", "payment_style:create");
            assertGateContains(layer, "update",
                    "payment_style:edit", "payment_style:status",
                    "payment_style:move", "payment_style:reorder");
        }
        assertThat(source(paymentService))
                .contains("CurrentAuthorityGuard.requireAll(\"payment_style:edit\")")
                .contains("CurrentAuthorityGuard.requireAll(\"payment_style:status\")")
                .contains("CurrentAuthorityGuard.requireAll(\"payment_style:move\")")
                .contains("CurrentAuthorityGuard.requireAll(\"payment_style:reorder\")")
                .contains("财务类别不能直接删除")
                .doesNotContain("payment_style:delete");
    }

    private static void assertGateContains(
            Class<?> type, String methodName, String... authorities) {
        List<java.lang.reflect.Method> methods = Arrays.stream(type.getDeclaredMethods())
                .filter(method -> method.getName().equals(methodName))
                .toList();
        assertThat(methods)
                .as(type.getName() + "#" + methodName)
                .hasSize(1);
        PreAuthorize gate = methods.getFirst().getAnnotation(PreAuthorize.class);
        assertThat(gate)
                .as(type.getName() + "#" + methodName + " must have @PreAuthorize")
                .isNotNull();
        for (String authority : authorities) {
            assertThat(gate.value()).contains("'" + authority + "'");
        }
    }

    private static String source(Class<?> type) throws IOException {
        String relative = type.getName()
                .replace("com.uten.imp.", "")
                .replace('.', '/') + ".java";
        return Files.readString(
                Path.of("src/main/java/com/uten/imp").resolve(relative),
                StandardCharsets.UTF_8);
    }

    private static MasterSpec master(String prefix, String stem, String detail) {
        return new MasterSpec(
                prefix,
                type("com.uten.imp.features.master." + stem + "Controller"),
                type("com.uten.imp.features.master." + stem + "Service"),
                detail);
    }

    private static CategorySpec category(String prefix, String stem) {
        return new CategorySpec(
                prefix,
                type("com.uten.imp.features.master." + stem + "Controller"),
                type("com.uten.imp.features.master." + stem + "Service"));
    }

    private static Class<?> type(String name) {
        try {
            return Class.forName(name);
        } catch (ClassNotFoundException error) {
            throw new AssertionError("Missing class " + name, error);
        }
    }

    private record MasterSpec(
            String prefix, Class<?> controller, Class<?> service, String detail) {
    }

    private record CategorySpec(
            String prefix, Class<?> controller, Class<?> service) {
    }
}
