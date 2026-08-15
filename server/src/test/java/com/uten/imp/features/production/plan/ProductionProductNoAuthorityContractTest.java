package com.uten.imp.features.production.plan;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionProductNoAuthorityContractTest {

    private static final Path JAVA = Path.of("src/main/java/com/uten/imp");

    @Test
    void planServiceAllocatesOnlyBlankProductNumbersAfterPersistingThePlan() throws Exception {
        String service = source(
                "features/production/plan/ProductionPlanService.java");
        String request = source(
                "features/production/plan/dto/PlanItemLine.java");

        assertThat(service)
                .contains("planRepo.flush();")
                .contains("productNoAllocator.allocate(")
                .contains("collectExplicitProductNos(lines)")
                .contains("trimmedToNull(l.getProductNo())");
        assertThat(request)
                .contains("private String productNo;")
                .doesNotContain("@NotBlank");
    }

    @Test
    void allocatorDelegatesToTheSingleDatabaseAuthority() throws Exception {
        String allocator = source(
                "features/production/plan/ProductionProductNoAllocator.java");

        assertThat(allocator)
                .contains("SELECT fn_allocate_production_product_no(?)")
                .contains("Propagation.MANDATORY")
                .doesNotContain("INSERT INTO business_identifier_reservations")
                .doesNotContain("INSERT INTO business_identifier_reservation_members");
    }

    @Test
    void materialAnalysisCarriesExplicitProductNumbersAndNeverMintsUuidValues() throws Exception {
        String commands = source(
                "features/production/analysis/MaterialAnalysisCommandService.java");
        String service = source(
                "features/production/analysis/MaterialAnalysisService.java");
        String contracts = source(
                "features/production/analysis/MaterialAnalysisContracts.java");

        assertThat(commands)
                .contains("line.setProductNo(quantity.productNo());")
                .contains("MaterialAnalysisService.blankToNull(item.productNo())")
                .contains("|PRODUCT_NO|")
                .doesNotContain("line.setProductNo(\"MA-\"");
        assertThat(service)
                .contains("blankToNull(selected.productNo())")
                .contains("itemFingerprint.add(\"PRODUCT_NO\")");
        assertThat(contracts)
                .contains("@Size(max = 200) String productNo");
    }

    @Test
    void everySystemGeneratedPlanLineUsesTheDatabaseAllocator() throws Exception {
        String reports = source(
                "features/production/dailyreport/ProductionDailyReportService.java");
        String mrp = source("features/production/mrp/MrpService.java");

        assertThat(reports)
                .contains("planRepo.flush();")
                .contains("productNoAllocator.allocate(rp.getId(), Set.of())")
                .doesNotContain("ri.setProductNo(rp.getBillNo() + \"-1\")");
        assertThat(mrp)
                .contains("planRepo.flush();")
                .contains("productNoAllocator.allocate(sub.getId(), Set.of())")
                .doesNotContain("item.setProductNo(sub.getBillNo() + \"-\" + line)");
    }

    private static String source(String relative) throws Exception {
        return Files.readString(JAVA.resolve(relative), StandardCharsets.UTF_8);
    }
}
