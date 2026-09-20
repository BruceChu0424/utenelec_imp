package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class PurchaseReportUuidReferenceContractTest {

    @Test
    void v269ProtectsNewWritesBeforeDeterministicLegacyBackfillAndValidation()
            throws IOException {
        String sql = compact(read("src/main/resources/db/migration/"
                + "V269__purchase_report_uuid_references.sql"));

        assertThat(sql)
                .contains("alter table purchase_receipts add column purchaser_id uuid")
                .contains("alter table purchase_requests add column department_id uuid")
                .contains("foreign key (purchaser_id) references employees(id) on delete restrict not valid")
                .contains("foreign key (department_id) references departments(id) on delete restrict not valid")
                .contains("having count(*) = 1")
                .contains("receipt.purchaser_legacy_id <> 0")
                .contains("employee.legacy_id = receipt.purchaser_legacy_id")
                .contains("request.department_legacy_id <> 0")
                .contains("legacy_department.legacy_id = request.department_legacy_id")
                .contains("validate constraint fk_purchase_receipts_purchaser")
                .contains("validate constraint fk_purchase_requests_department");

        assertThat(sql.indexOf("fk_purchase_receipts_purchaser"))
                .isLessThan(sql.indexOf(
                        "validate constraint fk_purchase_receipts_purchaser"));
        assertThat(sql.indexOf(
                "validate constraint fk_purchase_receipts_purchaser"))
                .isLessThan(sql.indexOf("update purchase_receipts receipt"));
        assertThat(sql.indexOf("fk_purchase_requests_department"))
                .isLessThan(sql.indexOf(
                        "validate constraint fk_purchase_requests_department"));
        assertThat(sql.indexOf(
                "validate constraint fk_purchase_requests_department"))
                .isLessThan(sql.indexOf("update purchase_requests request"));
    }

    @Test
    void normalApisAcceptUuidOnlyAndPreserveOmittedReferences() throws IOException {
        String receiptRequest = compact(read(
                "src/main/java/com/uten/imp/features/purchase/receipt/dto/ReceiptSaveRequest.java"));
        String requestRequest = compact(read(
                "src/main/java/com/uten/imp/features/purchase/request/dto/RequestSaveRequest.java"));
        String receiptService = compact(read(
                "src/main/java/com/uten/imp/features/purchase/receipt/PurchaseReceiptService.java"));
        String requestService = compact(read(
                "src/main/java/com/uten/imp/features/purchase/request/PurchaseRequestService.java"));
        String productionFacade = compact(read(
                "src/main/java/com/uten/imp/features/purchase/request/ProductionPurchaseRequestFacade.java"));
        String legacyMrp = compact(read(
                "src/main/java/com/uten/imp/features/production/mrp/MrpService.java"));

        assertThat(receiptRequest)
                .contains("@jsonsetter(\"purchaserid\")")
                .contains("haspurchaserreference()")
                .doesNotContain("purchaserlegacyid");
        assertThat(requestRequest)
                .contains("@jsonsetter(\"departmentid\")")
                .contains("hasdepartmentreference()")
                .doesNotContain("departmentlegacyid");
        assertThat(receiptService)
                .contains("if (!req.haspurchaserreference()) return")
                .contains("organizationreferences.findactiveemployee(purchaserid)")
                .contains("receipt.setpurchaserid(employee.id())")
                .contains("receipt.setpurchaserlegacyid(employee.legacyid())")
                .doesNotContain("em.find(employee.class, purchaserid)");
        assertThat(requestService)
                .contains("if (!req.hasdepartmentreference()) return")
                .contains("organizationreferences.findactivedepartment(departmentid)")
                .contains("request.setdepartmentid(resolveddepartmentid)")
                .doesNotContain("em.find(department.class, departmentid)")
                .doesNotContain("setdepartmentlegacyid(req.");
        assertThat(productionFacade)
                .contains("organizationreferences.findactiveemployee(applicantemployeeid)")
                .contains(".map(organizationreferenceport.employeereference::departmentid)")
                .doesNotContain("em.find(employee.class, applicantemployeeid)");
        assertThat(legacyMrp)
                .contains("uuid applicantemployeeid = currentuser.requireemployeeid()")
                .contains("r.setapplicantid(applicantemployeeid)")
                .contains("organizationreferences.findactiveemployee(applicantemployeeid)")
                .contains(".ifpresent(r::setdepartmentid)")
                .doesNotContain("r.setapplicantid(currentuser.requireid())");
    }

    @Test
    void purchaseReportsUseUuidAndGuardEveryLegacyFallbackWithUuidNull()
            throws IOException {
        String report = compact(read(
                "src/main/java/com/uten/imp/features/purchase/report/PurchaseReportService.java"));

        assertThat(report)
                .contains("left join departments dept on dept.id = o.department_id")
                .contains("left join legacy_departments legacy_dept on o.department_id is null and legacy_dept.legacy_id = o.department_legacy_id")
                .contains("coalesce(dept.name, legacy_dept.name) as \"departmentname\"")
                .contains("left join employees em_sman on em_sman.id = o.purchaser_id or (o.purchaser_id is null and em_sman.legacy_id = o.purchaser_legacy_id)")
                .doesNotContain("left join employees em_sman on em_sman.legacy_id = o.purchaser_legacy_id");
    }

    @Test
    void destructiveLegacyReimportWritesUuidTruthAlongsideSnapshots() throws IOException {
        String legacy = compact(read("legacy_migration/migrate_purchase.sql"));

        assertThat(legacy)
                .contains("warehouse_id, department_id, applicant_id")
                .contains("select department_id from legacy_departments where legacy_id = s.step_id")
                .contains("sender_id, receiver_id, purchaser_id, maker_id")
                .contains("department_legacy_id")
                .contains("purchaser_legacy_id");
        // V626/V627 重写后口径：收货单 purchaser_id 不再由 loader 内联子查询解析，改在
        // V627 权威来源投影 fn_legacy_receipt_source_projection 内按 salesman_legacy →
        // employees.legacy_id 解析；loader 先 set_config('uten.legacy_reference_import',
        // 'legacy-purchase-v273') 再按 FK 逆序 DELETE，并以 legacy_import_run_id 引用
        // legacy_procurement_receipt_import_sources 落来源证明。
        assertThat(legacy)
                .contains("set_config('uten.legacy_reference_import', 'legacy-purchase-v273', true)")
                .contains("delete from purchase_return_items;")
                .contains("legacy_import_run_id")
                .contains("legacy_procurement_receipt_import_sources");
        assertThat(compact(read(
                "src/main/resources/db/migration/"
                        + "V627__legacy_receipt_consideration_provenance.sql")))
                .contains("'purchaser_id',(select id from public.employees "
                        + "where legacy_id=nullif((s->>'salesman_legacy')::integer,0))");
        // 破坏性重导只允许发生在 --bootstrap-all 单事务内；migrate.sh 拒绝 --purchase
        // 单模块重导。
        assertThat(compact(read("legacy_migration/migrate.sh")))
                .contains("[ \"$target\" = \"--purchase\" ]")
                .contains("不支持这些模块单独重导");
    }

    private static String read(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path, StandardCharsets.UTF_8);
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
