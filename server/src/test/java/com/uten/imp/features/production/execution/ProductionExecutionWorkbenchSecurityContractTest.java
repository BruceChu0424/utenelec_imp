package com.uten.imp.features.production.execution;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionExecutionWorkbenchSecurityContractTest {

    @Test
    void overviewKeepsProductionOwnerScopeAndRelatedDocumentScopes()
            throws Exception {
        String service = source("ProductionExecutionWorkbenchService.java");
        String controller = source("ProductionExecutionWorkbenchController.java");

        assertThat(controller)
                .contains("hasAuthority('production_execution:overview')");
        assertThat(service)
                .contains("productionAccess.nativeReadScope(")
                .contains("root.owner_employee_id")
                .contains("rootOwners")
                .contains("scope.bind(count)")
                .contains("scope.bind(data)")
                .contains("purchaseAccess.nativeReadScope(")
                .contains("subcontractAccess.nativeReadScope(");
    }

    @Test
    void replacementQueryNeverExposesManualDispatchOrStart() throws Exception {
        String service = source("ProductionExecutionWorkbenchService.java");

        // 2026-09-10：READY_TO_REPORT 兼容参数与 breakdown.readyToReport 端到端删除
        //（无客户端调用方，且与分段计数第三列口径互相矛盾）。
        assertThat(service)
                .doesNotContain("READY_TO_REPORT")
                .doesNotContain("readyToReport")
                .contains("READY_TO_START")
                .contains("('COMPLETED','CANCELLED','REVERSED')")
                .contains("CAST(:dateFrom AS date) IS NULL")
                .contains("CAST(:dateTo AS date) IS NULL")
                .contains("FALSE,\n                       FALSE,")
                .contains("production_daily_report:view")
                .contains("production_daily_report:create")
                .contains("production_execution:view")
                .contains("reportAllowed(")
                .doesNotContain(":allowDispatch")
                .doesNotContain(":allowStart");
    }

    @Test
    void keywordIncludesWorkshopAndClientWithoutDroppingRootScope()
            throws Exception {
        String service = source("ProductionExecutionWorkbenchService.java");

        assertThat(service)
                .contains("task.workshop_name")
                .contains("JOIN clients client")
                .contains("client.name")
                .contains("sales_order:view")
                .contains("canSearchClient ?")
                .contains("task.root_type=root.root_type")
                .contains("task.root_id=root.root_id");
    }

    @Test
    void reportActionRequiresAllThreeAuthorities() {
        assertThat(ProductionExecutionWorkbenchService.reportAllowed(
                true, true, true)).isTrue();
        assertThat(ProductionExecutionWorkbenchService.reportAllowed(
                false, true, true)).isFalse();
        assertThat(ProductionExecutionWorkbenchService.reportAllowed(
                true, false, true)).isFalse();
        assertThat(ProductionExecutionWorkbenchService.reportAllowed(
                true, true, false)).isFalse();
    }

    private static String source(String name) throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/production/execution")
                .resolve(name);
        Path fallback = Path.of("server").resolve(direct);
        return Files.readString(
                Files.exists(direct) ? direct : fallback,
                StandardCharsets.UTF_8);
    }
}
