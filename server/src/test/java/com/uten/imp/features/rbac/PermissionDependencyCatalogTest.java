package com.uten.imp.features.rbac;

import org.junit.jupiter.api.Test;

import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class PermissionDependencyCatalogTest {
    @Test
    void companyFilesUploadKeepsAttachmentDependenciesAndDownloadOnlyNeedsTheEntrance() {
        var catalog=catalog(view("company_file:view"),action("company_file:upload"),action("company_file:download"),
                view("attachment:view"),action("attachment:upload"),action("attachment:download"),action("attachment:delete"));
        assertThat(catalog.requiredPermissions("company_file:upload",Set.of()))
                .containsExactly("company_file:view","attachment:view","attachment:upload");
        // V958: 可见即可下载——公司资料下载不再依赖通用附件权限，仅随入口。
        assertThat(catalog.requiredPermissions("company_file:download",Set.of()))
                .containsExactly("company_file:view");
        assertThat(catalog.usablePermissions(Set.of("company_file:view","company_file:upload","attachment:view")))
                .doesNotContain("company_file:upload");
        assertThat(catalog.usablePermissions(Set.of("company_file:view","company_file:download")))
                .contains("company_file:download");
        assertThat(catalog.requiredPermissions("company_file:download",Set.of("company_file:view")))
                .doesNotContain("attachment:view","attachment:upload","attachment:download","attachment:delete");
    }
    @Test
    void materialEngineeringForwardRequiresItsActualAnalysisReadWithoutPlanOrGoodsWrites() {
        var catalog = catalog(view("production_material_analysis:view"),
                action("production_material_analysis:forward_rd"), view("production_plan:view"),
                action("goods:edit"));
        assertThat(catalog.requiredPermissions("production_material_analysis:forward_rd", Set.of()))
                .containsExactly("production_material_analysis:view");
        assertThat(catalog.hardRequiredPermissions("production_material_analysis:forward_rd", Set.of()))
                .containsExactly("production_material_analysis:view");
        assertThat(catalog.usablePermissions(Set.of("production_material_analysis:forward_rd"))).isEmpty();
        assertThat(catalog.usablePermissions(Set.of("production_material_analysis:view", "production_material_analysis:forward_rd")))
                .containsExactlyInAnyOrder("production_material_analysis:view", "production_material_analysis:forward_rd");
    }
    @Test
    void assetReversalOffersItsPageReadWithoutRequiringNormalPostingAuthority() {
        var catalog = catalog(view("finance_asset:view"), action("finance_asset:post"), action("finance_asset:reverse"));
        assertThat(catalog.requiredPermissions("finance_asset:reverse", Set.of())).containsExactly("finance_asset:view");
        assertThat(catalog.hardRequiredPermissions("finance_asset:reverse", Set.of())).isEmpty();
        assertThat(catalog.usablePermissions(Set.of("finance_asset:reverse"))).containsExactly("finance_asset:reverse");
    }

    @Test
    void anAssignedActionIsNotUsableUntilItsPageReadIsAssigned() {
        var catalog = catalog(view("sales_shipment_finance:view"), action("sales_shipment_finance:approve"));
        assertThat(catalog.usablePermissions(Set.of("sales_shipment_finance:approve"))).isEmpty();
        assertThat(catalog.missingDependencies("sales_shipment_finance:approve", Set.of()))
                .containsExactly("sales_shipment_finance:view");
        assertThat(catalog.usablePermissions(Set.of("sales_shipment_finance:view", "sales_shipment_finance:approve")))
                .containsExactlyInAnyOrder("sales_shipment_finance:view", "sales_shipment_finance:approve");
    }

    @Test
    void decompositionCompletesPreviewNavigationWithoutDisablingItsIndependentCreateConsumers() {
        var catalog = catalog(view("purchase_order:view"), view("purchase_request:view"),
                view("purchase_order:price:view"), action("purchase_order:decompose"),
                view("subcontract_order:view"), view("subcontract_application:view"), action("subcontract_order:decompose"));
        assertThat(catalog.requiredPermissions("purchase_order:decompose", Set.of()))
                .containsExactly("purchase_order:view", "purchase_request:view");
        assertThat(catalog.requiredPermissions("purchase_order:decompose", Set.of()))
                .doesNotContain("purchase_order:price:view");
        assertThat(catalog.requiredPermissions("subcontract_order:decompose", Set.of()))
                .containsExactly("subcontract_order:view", "subcontract_application:view");
        Set<String> actions = Set.of("purchase_order:decompose", "subcontract_order:decompose");
        assertThat(catalog.usablePermissions(actions)).containsExactlyInAnyOrderElementsOf(actions);
        assertThat(catalog.lookupPermissions(actions)).containsExactlyInAnyOrderElementsOf(actions);
        for (String action : actions) assertThat(catalog.missingHardDependencies(action, Set.of())).isEmpty();
        assertThat(catalog.rulesJson()).isEqualTo("{}");
    }

    @Test
    void fieldAndAllOwnerReadsDoNotAcquireOrRequireAnUnrelatedPageRead() {
        var catalog = catalog(view("goods:view"), view("goods:cost:view"), view("goods:price:view"),
                view("goods:view:all"), view("goods:price_analysis:view"));
        Set<String> fields = Set.of("goods:cost:view", "goods:price:view", "goods:view:all");
        assertThat(catalog.usablePermissions(fields)).containsExactlyInAnyOrderElementsOf(fields);
        assertThat(catalog.requiredPermissions("goods:cost:view", fields)).isEmpty();
        assertThat(catalog.requiredPermissions("goods:price_analysis:view", fields)).containsExactly("goods:view");
    }

    @Test
    void selfReadingCountAndIndependentHrApprovalActionsRemainUsable() {
        var catalog = catalog(view("stock:view"), action("stock:count:finance_review"),
                view("visitor:view"), action("visitor:approve"), view("profile:view"), action("profile:review"));
        Set<String> actions = Set.of("stock:count:finance_review", "visitor:approve", "profile:review");
        assertThat(catalog.usablePermissions(actions)).containsExactlyInAnyOrderElementsOf(actions);
    }

    @Test
    void staffAccountSupportNeverRequiresOrGrantsFinancialAccountReading() {
        var catalog = catalog(view("account:view"), action("account:support"), view("employee:view"));
        assertThat(catalog.requiredPermissions("account:support", Set.of())).isEmpty();
        assertThat(catalog.usablePermissions(Set.of("account:support"))).containsExactly("account:support");
    }

    @Test
    void salesFileEnglishNameLearningDoesNotRequireGeneralGoodsBrowsing() {
        var catalog = catalog(view("goods:view"), action("goods:name_en:edit"));
        assertThat(catalog.requiredPermissions("goods:name_en:edit", Set.of())).isEmpty();
        assertThat(catalog.usablePermissions(Set.of("goods:name_en:edit"))).containsExactly("goods:name_en:edit");
    }

    @Test
    void anIqcReturnCanUseEitherExistingPageWithoutOpeningTheOtherBusinessArea() {
        var catalog = catalog(view("warehouse_iqc_return:view"), view("procurement_iqc_rejection:view"),
                action("procurement_iqc_rejection:record_return"));
        assertThat(catalog.requiredPermissions("procurement_iqc_rejection:record_return",
                Set.of("warehouse_iqc_return:view"))).containsExactly("warehouse_iqc_return:view");
        assertThat(catalog.requiredPermissions("procurement_iqc_rejection:record_return",
                Set.of("procurement_iqc_rejection:view"))).containsExactly("procurement_iqc_rejection:view");
        assertThat(catalog.lookupPermissions(Set.of("procurement_iqc_rejection:record_return")))
                .containsExactlyInAnyOrder("procurement_iqc_rejection:record_return", "warehouse_iqc_return:view",
                        "procurement_iqc_rejection:view");
        assertThat(catalog.missingHardDependencies("procurement_iqc_rejection:record_return", Set.of(),
                "procurement_iqc_rejection:view"::equals)).containsExactly("procurement_iqc_rejection:view");
        assertThat(catalog.requiredPermissions("procurement_iqc_rejection:record_return", Set.of(),
                "procurement_iqc_rejection:view"::equals)).containsExactly("procurement_iqc_rejection:view");
    }

    @Test
    void masterDataCreationIncludesTheActualCategoryTreeRead() {
        var catalog = catalog(view("goods:view"), view("material_category:view"), action("goods:create"),
                view("goods:cost:view"));
        assertThat(catalog.requiredPermissions("goods:create", Set.of("goods:view")))
                .containsExactly("goods:view", "material_category:view");
        assertThat(catalog.requiredPermissions("goods:create", Set.of()))
                .doesNotContain("goods:cost:view");
    }

    @Test
    void globalMasterActionsDoNotDependOnAnUnrelatedCategoryTree() {
        Map<String, List<String>> operations = Map.of(
                "goods", List.of("edit", "delete", "status", "export", "import"),
                "client", List.of("edit", "delete", "status", "export", "assign"),
                "supplier", List.of("edit", "delete", "status", "export"),
                "mould", List.of("edit", "delete", "status", "export"));
        for (String resource : operations.keySet()) {
            String category = "goods".equals(resource) ? "material_category:view" : resource + "_category:view";
            for (String operation : operations.get(resource)) {
                String code = resource + ":" + operation;
                var catalog = catalog(view(resource + ":view"), view(category), action(code));
                assertThat(catalog.requiredPermissions(code, Set.of())).as(code)
                        .containsExactly(resource + ":view");
                assertThat(catalog.usablePermissions(Set.of(code, resource + ":view"))).as(code)
                        .containsExactlyInAnyOrder(code, resource + ":view");
            }
        }
    }

    @Test
    void onlyAddingABomComponentUsesTheCategoryPicker() {
        var catalog = catalog(view("goods:view"), view("material_category:view"), action("goods:bom:create"),
                action("goods:bom:edit"), action("goods:bom:delete"), action("goods:bom:audit"));
        assertThat(catalog.requiredPermissions("goods:bom:create", Set.of()))
                .containsExactly("goods:view", "material_category:view");
        for (String operation : List.of("edit", "delete", "audit")) {
            assertThat(catalog.requiredPermissions("goods:bom:" + operation, Set.of())).containsExactly("goods:view");
        }
    }

    @Test
    void mouldCreationAndAssetPeriodManagementReceiveTheirActualOrdinaryPageReads() {
        var catalog = catalog(view("mould:view"), view("mould_category:view"), action("mould:create"),
                view("finance_asset:view"), action("finance_asset_period:manage"));
        assertThat(catalog.requiredPermissions("mould:create", Set.of()))
                .containsExactly("mould:view", "mould_category:view");
        assertThat(catalog.requiredPermissions("finance_asset_period:manage", Set.of()))
                .containsExactly("finance_asset:view");
    }

    @Test
    void visitorCheckInOffersVerificationNavigationWithoutChangingItsIndependentCommand() {
        var catalog = catalog(view("visitor:verify"), action("visitor:check_in"), action("visitor:blacklist"));
        assertThat(catalog.requiredPermissions("visitor:check_in", Set.of())).containsExactly("visitor:verify");
        assertThat(catalog.requiredPermissions("visitor:blacklist", Set.of())).isEmpty();
        assertThat(catalog.usablePermissions(Set.of("visitor:check_in"))).containsExactly("visitor:check_in");
        assertThat(catalog.lookupPermissions(Set.of("visitor:check_in"))).containsExactly("visitor:check_in");
    }

    @Test
    void navigationCompletionDoesNotInventAnApiReadCondition() {
        var catalog = catalog(view("goods:view"), action("goods:edit"), view("material_category:view"),
                view("sales_shipment_finance:view"), action("sales_shipment_finance:reverse"));
        assertThat(catalog.missingDependencies("goods:edit", Set.of("goods:edit"))).containsExactly("goods:view");
        assertThat(catalog.usablePermissions(Set.of("goods:edit"))).containsExactly("goods:edit");
        assertThat(catalog.lookupPermissions(Set.of("goods:edit"))).containsExactly("goods:edit");
        assertThat(catalog.hardRequiredPermissions("goods:edit", Set.of())).isEmpty();
        assertThat(catalog.requiredPermissions("sales_shipment_finance:reverse", Set.of()))
                .containsExactly("sales_shipment_finance:view");
        assertThat(catalog.usablePermissions(Set.of("sales_shipment_finance:reverse")))
                .containsExactly("sales_shipment_finance:reverse");
        assertThat(catalog.lookupPermissions(Set.of("sales_shipment_finance:reverse")))
                .containsExactly("sales_shipment_finance:reverse");
        assertThat(catalog.rulesJson()).isEqualTo("{}");
    }

    @Test
    void onboardingAndOffboardingKeepTheirActualNavigationSeparateFromCommandAuthority() {
        var catalog = catalog(view("employee:view"), view("department:view"), action("employee:create"),
                action("employee:pii:edit"), action("employee:compensation:edit"), action("employee:offboard"));
        assertThat(catalog.requiredPermissions("employee:create", Set.of())).containsExactly("department:view");
        assertThat(catalog.requiredPermissions("employee:offboard", Set.of())).containsExactly("employee:view");
        assertThat(catalog.requiredPermissions("employee:pii:edit", Set.of())).isEmpty();
        assertThat(catalog.requiredPermissions("employee:compensation:edit", Set.of())).isEmpty();
        Set<String> actions = Set.of("employee:create", "employee:pii:edit", "employee:compensation:edit", "employee:offboard");
        assertThat(catalog.usablePermissions(actions)).containsExactlyInAnyOrderElementsOf(actions);
        assertThat(catalog.lookupPermissions(actions)).containsExactlyInAnyOrderElementsOf(actions);
    }

    @Test
    void independentFieldsAndCommandsDoNotInheritARootReadEvenWhenOneIsAddedToTheCatalog() {
        List<String> independent = List.of("goods:price:edit", "goods:name_en:edit", "employee:pii:edit",
                "employee:compensation:edit", "employee:avatar_edit", "employee:task_takeover",
                "employee:transfer", "employee:handover", "employee:confirm",
                "employee:rehire", "employee:contract_renew", "account:support", "attachment:upload",
                "attachment:download", "attachment:delete", "attachment:reconcile:approve_delete",
                "rd_task:resolve", "webinquiry:claim", "webinquiry:close", "webinquiry:convert_client",
                "expense:apply", "expense:approve", "expense:pay", "payroll:generate", "payroll:review",
                "payroll:publish", "payroll:export", "stock:count:submit", "stock:count:finance_review",
                "stock:count:warehouse_review", "visitor:approve", "visitor:host_confirm", "visitor:blacklist",
                "profile:edit:self", "profile:review", "suggestion:submit", "suggestion:reply");
        List<Permission> definitions = new java.util.ArrayList<>();
        for (String code : independent) {
            definitions.add(action(code));
            definitions.add(view(code.substring(0, code.indexOf(':')) + ":view"));
        }
        var catalog = new PermissionDependencyCatalog(definitions);
        for (String code : independent) {
            assertThat(catalog.requiredPermissions(code, Set.of())).as(code).isEmpty();
        }
        assertThat(catalog.usablePermissions(independent)).containsExactlyInAnyOrderElementsOf(independent);
        assertThat(catalog.lookupPermissions(independent)).containsExactlyInAnyOrderElementsOf(independent);
        assertThat(catalog.rulesJson()).isEqualTo("{}");
    }

    @Test
    void newResourcesAndUnlistedActionsCannotCreateDependenciesByTheirNames() {
        var catalog = catalog(view("new_command:view"), action("new_command:execute"),
                view("goods:view"), action("goods:future_independent_command"));
        Set<String> commands = Set.of("new_command:execute", "goods:future_independent_command");
        for (String code : commands) assertThat(catalog.requiredPermissions(code, Set.of())).isEmpty();
        assertThat(catalog.usablePermissions(commands)).containsExactlyInAnyOrderElementsOf(commands);
        assertThat(catalog.lookupPermissions(commands)).containsExactlyInAnyOrderElementsOf(commands);
        assertThat(catalog.rulesJson()).isEqualTo("{}");
    }

    @Test
    void financialAndQualityReviewsRetainTheirExistingHardReadConditions() {
        Map<String, List<String>> reviews = Map.of(
                "finance_order_approval", List.of("approve", "reject"),
                "sales_order_finance", List.of("confirm"),
                "sales_quote_finance", List.of("confirm", "reject", "reverse"),
                "sales_shipment_finance", List.of("approve", "reject"),
                "production_quality_inspection", List.of("approve"));
        reviews.forEach((resource, operations) -> operations.forEach(operation -> {
            String code = resource + ":" + operation;
            String read = resource + ":view";
            var catalog = catalog(view(read), action(code));
            assertThat(catalog.usablePermissions(Set.of(code))).as(code).isEmpty();
            assertThat(catalog.usablePermissions(Set.of(code, read))).as(code).containsExactlyInAnyOrder(code, read);
            assertThat(catalog.lookupPermissions(Set.of(code))).as(code).containsExactlyInAnyOrder(code, read);
        }));
    }

    @Test
    void costAndBalanceSeparateUniversalReadRequirementsFromSpecificPageNavigation() {
        var catalog = catalog(view("goods:view"), view("goods:cost:view"), view("goods:price:view"),
                action("goods:cost:edit"), action("goods:cost:confirm"), action("goods:cost:export"),
                action("goods:cost:template"), view("account:view"), view("account:balance:view"),
                view("account:flow:view"), action("account:balance:adjust"));
        for (String operation : List.of("edit", "confirm", "export", "template")) {
            String code = "goods:cost:" + operation;
            assertThat(catalog.requiredPermissions(code, Set.of())).containsExactly("goods:view", "goods:cost:view");
            assertThat(catalog.usablePermissions(Set.of(code, "goods:view"))).doesNotContain(code);
            assertThat(catalog.usablePermissions(Set.of(code, "goods:view", "goods:cost:view"))).contains(code);
        }
        assertThat(catalog.usablePermissions(Set.of("goods:cost:edit", "goods:cost:view")))
                .containsExactlyInAnyOrder("goods:cost:edit", "goods:cost:view");
        assertThat(catalog.lookupPermissions(Set.of("goods:cost:edit")))
                .containsExactlyInAnyOrder("goods:cost:edit", "goods:cost:view");
        for (String operation : List.of("confirm", "export", "template")) {
            String code = "goods:cost:" + operation;
            assertThat(catalog.usablePermissions(Set.of(code, "goods:cost:view"))).doesNotContain(code);
        }
        assertThat(catalog.requiredPermissions("account:balance:adjust", Set.of()))
                .containsExactly("account:view", "account:balance:view");
        assertThat(catalog.usablePermissions(Set.of("account:balance:adjust")))
                .containsExactly("account:balance:adjust");
        assertThat(catalog.lookupPermissions(Set.of("account:balance:adjust")))
                .containsExactly("account:balance:adjust");
    }

    private static PermissionDependencyCatalog catalog(Permission... permissions) {
        return new PermissionDependencyCatalog(Arrays.asList(permissions));
    }
    @Test void fieldGroupAndEmployeeNavigationAddsReadAccessWithoutGrantingMasterWrites() {
        var catalog=catalog(view("goods:view"),view("supplier:view"),view("client:view"),view("employee:view"),view("department:view"),
                action("goods:purchase:edit"),action("goods:sales:edit"),action("employee:edit"),action("department:edit"),action("supplier:edit"),action("client:edit"));
        assertThat(catalog.requiredPermissions("goods:purchase:edit",Set.of())).containsExactlyInAnyOrder("goods:view","supplier:view");
        assertThat(catalog.requiredPermissions("goods:sales:edit",Set.of())).containsExactlyInAnyOrder("goods:view","client:view");
        assertThat(catalog.requiredPermissions("employee:edit",Set.of())).containsExactlyInAnyOrder("employee:view","department:view");
        assertThat(catalog.lookupPermissions(Set.of("goods:purchase:edit","goods:sales:edit","employee:edit")))
                .doesNotContain("department:edit","supplier:edit","client:edit");
        assertThat(catalog.usablePermissions(Set.of("goods:view","goods:purchase:edit","goods:sales:edit")))
                .contains("goods:purchase:edit","goods:sales:edit");
    }

    private static Permission view(String code) { return permission(code, "VIEW"); }
    private static Permission action(String code) { return permission(code, "APPROVE"); }
    private static Permission permission(String code, String type) {
        Permission permission = new Permission();
        permission.setCode(code);
        permission.setActionType(type);
        return permission;
    }
}
