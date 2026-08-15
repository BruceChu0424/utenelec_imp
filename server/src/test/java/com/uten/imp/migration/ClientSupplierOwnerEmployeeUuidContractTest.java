package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ClientSupplierOwnerEmployeeUuidContractTest {

    @Test
    void migrationBackfillsOnlyUnambiguousNumericLegacyEmployeeIds() throws IOException {
        String sql = source("src/main/resources/db/migration/"
                + "V261__client_supplier_owner_employee_uuid.sql");
        String normalized = sql.replaceAll("\\s+", " ").toLowerCase();

        assertTrue(normalized.contains("alter table suppliers add column owner_employee_id uuid"));
        assertEquals(2, count(normalized, "having count(*) = 1"));
        assertEquals(2, count(normalized, "~ '^[0-9]{1,9}$'"));
        assertEquals(2, count(normalized, "nullif(btrim("));
        assertTrue(normalized.contains("foreign key (owner_employee_id) references employees(id)"));
        assertTrue(normalized.contains("on delete restrict not valid"));
        assertTrue(normalized.contains(
                "validate constraint fk_suppliers_owner_employee"));
        assertFalse(normalized.contains("lower("));
        assertFalse(normalized.contains("e.name"));
    }

    @Test
    void normalWritesResolveUuidAndOnlyDeriveLegacySnapshotServerSide() throws IOException {
        for (String service : new String[]{
                "features/master/client/ClientService.java",
                "features/master/supplier/SupplierService.java"
        }) {
            String source = source("src/main/java/com/uten/imp/" + service);
            assertTrue(source.contains("if (!req.hasOwnerEmployeeReference()) return;"));
            assertTrue(source.contains("employeeRepo.findById(id)"));
            assertTrue(source.contains("setOwnerEmployeeId(employee.getId())"));
            assertTrue(source.contains("setEmpId(employee.getLegacyId() == null ? null"));
            assertFalse(source.contains("setEmpId(req.getEmpId())"));
        }
    }

    @Test
    void financeReadsClientOwnerUuidBeforeExactNumericLegacyFallback() throws IOException {
        String financeReport = source(
                "src/main/java/com/uten/imp/features/finance/report/FinanceReportService.java");
        String financeCost = source(
                "src/main/java/com/uten/imp/features/finance/cost/FinanceCostService.java");
        String join = "em_sel.id = c.owner_employee_id";
        String guard = "c.owner_employee_id IS NULL";

        assertEquals(3, count(financeReport, join));
        assertEquals(3, count(financeReport, guard));
        assertEquals(1, count(financeCost, join));
        assertEquals(1, count(financeCost, guard));
        assertFalse(financeReport.contains("REGEXP_REPLACE(COALESCE(c.emp_id"));
        assertFalse(financeCost.contains("REGEXP_REPLACE(COALESCE(c.emp_id"));
    }

    @Test
    void legacyMasterReimportKeepsEmpSnapshotAndWritesUuidByUniqueNumericLegacyId() throws IOException {
        for (String file : new String[]{"migrate_client_data.sql", "migrate_supplier_data.sql"}) {
            String sql = source("legacy_migration/" + file);
            String normalized = sql.replaceAll("\\s+", " ").toLowerCase();

            assertTrue(normalized.contains("emp_id, owner_employee_id"), file);
            assertTrue(normalized.contains("from employees"), file);
            assertTrue(normalized.contains("group by legacy_id having count(*) = 1"), file);
            assertTrue(normalized.contains("~ '^[0-9]{1,9}$'"), file);
            assertTrue(normalized.contains("nullif(btrim("), file);
            assertTrue(normalized.contains(".emp_id, employee_owner.employee_id"), file);
            assertTrue(normalized.contains("employee_owner.legacy_id = case"), file);
            assertFalse(normalized.contains("lower("), file);
            assertFalse(normalized.contains("employee_owner.full_name"), file);
            assertFalse(normalized.contains("set emp_id"), file);
        }
    }

    @Test
    void postEmployeeReimportFillsBothDomainsWithoutOverwritingLiveOwners() throws IOException {
        String sql = source("legacy_migration/migrate_client_owner.sql");
        String normalized = sql.replaceAll("\\s+", " ").toLowerCase();

        assertTrue(normalized.contains("update clients c set owner_employee_id"));
        assertTrue(normalized.contains("update suppliers s set owner_employee_id"));
        assertTrue(normalized.contains("where c.owner_employee_id is null"));
        assertTrue(normalized.contains("where s.owner_employee_id is null"));
        assertEquals(2, count(normalized, "having count(*) = 1"));
        assertEquals(2, count(normalized, "employee_owner.legacy_id = case"));
        assertTrue(count(normalized, "~ '^[0-9]{1,9}$'") >= 2);
        assertFalse(normalized.contains("update clients set owner_employee_id = null"));
        assertFalse(normalized.contains("update suppliers set owner_employee_id = null"));
        assertFalse(normalized.contains("owner_employee_id = null"));
        assertFalse(normalized.contains("set emp_id"));
        assertFalse(normalized.contains("lower("));
    }

    @Test
    void destructiveBootstrapReconcilesOwnersAfterEmployeesExist() throws IOException {
        String shell = source("legacy_migration/migrate.sh");
        int bootstrap = shell.lastIndexOf("--bootstrap-all|--all|-a)");
        assertTrue(bootstrap >= 0);
        String branch = shell.substring(bootstrap);
        int clients = branch.indexOf("migrate_client_data");
        int suppliers = branch.indexOf("migrate_supplier_data");
        int employees = branch.indexOf("migrate_hr_workers");
        int owners = branch.indexOf("migrate_client_owner");
        assertTrue(clients >= 0);
        assertTrue(suppliers >= 0);
        assertTrue(employees >= 0);
        assertTrue(owners >= 0);
        assertTrue(clients < employees);
        assertTrue(suppliers < employees);
        assertTrue(employees < owners);
    }

    private static int count(String source, String token) {
        int result = 0;
        for (int offset = 0; (offset = source.indexOf(token, offset)) >= 0;
             offset += token.length()) {
            result++;
        }
        return result;
    }

    private static String source(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path, StandardCharsets.UTF_8);
    }
}
