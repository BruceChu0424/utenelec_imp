package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class WarehouseWorkshopUuidContractTest {

    @Test
    void v274SeparatesLegacyOperatorNamespaceFromLiveWorkshopUuid()
            throws IOException {
        String sql = compact(read("src/main/resources/db/migration/"
                + "V274__warehouse_workshop_uuid_relationship.sql"));

        assertThat(sql)
                .contains("add column workshop_department_id uuid")
                .contains("add column legacy_operator_id int")
                .contains("foreign key (workshop_department_id) references departments(id) on delete restrict not valid")
                .contains("validate constraint fk_warehouses_workshop_department")
                .contains("production_department.code = 'dept_prod'")
                .contains("link.warehouse_legacy_id = warehouse.legacy_id")
                .contains("set legacy_operator_id = warehouse.workshop_legacy_id")
                .contains("warehouse.workshop_legacy_id <> 0")
                .contains("b_storage.workid/workshop_legacy_id is intentionally")
                .contains("excluded because it belongs to the sys_operator namespace")
                .contains("for each row execute function fn_audit()")
                .doesNotContain("lower(warehouse.name)")
                .doesNotContain("workshop.name = warehouse.name");

        assertThat(sql.indexOf("fk_warehouses_workshop_department"))
                .isLessThan(sql.indexOf(
                        "validate constraint fk_warehouses_workshop_department"));
        assertThat(sql.indexOf(
                "validate constraint fk_warehouses_workshop_department"))
                .isLessThan(sql.indexOf("update warehouses warehouse"));
    }

    @Test
    void normalApiWritesUuidOnlyAndLegacyReimportUsesReviewedWarehouseBridge()
            throws IOException {
        String request = compact(read(
                "src/main/java/com/uten/imp/features/master/warehouse/dto/"
                        + "WarehouseSaveRequest.java"));
        String service = compact(read(
                "src/main/java/com/uten/imp/features/master/warehouse/"
                        + "WarehouseService.java"));
        String entity = compact(read(
                "src/main/java/com/uten/imp/features/master/warehouse/"
                        + "Warehouse.java"));
        String controller = compact(read(
                "src/main/java/com/uten/imp/features/master/warehouse/"
                        + "WarehouseController.java"));
        String legacy = compact(read("legacy_migration/migrate_warehouse.sql"));

        assertThat(request)
                .contains("@jsonsetter(\"workshopdepartmentid\")")
                .contains("hasworkshopdepartmentreference()")
                .doesNotContain("workshoplegacyid")
                .doesNotContain("legacyoperatorid");
        assertThat(service)
                .contains("if (req.hasworkshopdepartmentreference())")
                .contains("organizationreferences.findactivedepartment(id)")
                .contains("\"dept_prod\".equals(workshop.parentcode())")
                .contains("w.setworkshopdepartmentid(workshop == null ? null : workshop.id())")
                .contains("insert into legacy_warehouse_workshop_links")
                .doesNotContain("setworkshoplegacyid(req.")
                .doesNotContain("setlegacyoperatorid(req.");
        assertThat(entity)
                .contains("@column(name = \"workshop_department_id\")")
                .contains("private uuid workshopdepartmentid")
                .doesNotContain("features.org")
                .doesNotContain("@manytoone");
        assertThat(service)
                .contains("findactivedepartmentbycode(\"dept_prod\")")
                .contains("findactivechildrenofdepartmentcode(\"dept_prod\")")
                .contains("new warehouseworkshopoption(");
        assertThat(controller)
                .contains("@getmapping(\"/workshops\")")
                .contains("@preauthorize(\"hasauthority('warehouse:view')\")")
                .contains("service.workshopoptions()");
        assertThat(legacy)
                .contains("left join legacy_warehouse_workshop_links link on link.warehouse_legacy_id = stage.legacy_id")
                .contains("link.workshop_department_id")
                .contains("nullif(stage.workshop_legacy_id, 0)")
                .doesNotContain("departments where name");
    }

    @Test
    void flutterUsesWorkshopUuidAndTreatsOldWorkIdAsOperatorSnapshot()
            throws IOException {
        String model = compact(read("../lib/features/basic_data/models/warehouse_node.dart"));
        String page = compact(read("../lib/features/basic_data/pages/warehouse_page.dart"));
        String repository = compact(read(
                "../lib/features/basic_data/repositories/warehouse_repository.dart"));

        assertThat(model)
                .contains("final string? workshopdepartmentid")
                .contains("final string? workshopdepartmentname")
                .contains("final int? legacyoperatorid")
                .contains("json['legacyoperatorid'] ?? json['workshoplegacyid']");
        assertThat(page)
                .contains("key: 'workshopdepartmentid'")
                .contains("ref.watch(warehouseworkshopoptionsprovider)")
                .contains("utendropdownitem(")
                .contains("widget.onchanged(value)")
                .contains("d.workshopdepartmentid ?? ''")
                .contains("w.legacyoperatorid?.tostring()")
                .doesNotContain("key: 'workshoplegacyid'");
        assertThat(repository)
                .contains("future<list<warehouseworkshopoption>> workshops()")
                .contains("apiendpoints.warehousesworkshops")
                .contains("warehouseworkshopoption.fromjson");
    }

    private static String read(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path.normalize(), StandardCharsets.UTF_8);
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
