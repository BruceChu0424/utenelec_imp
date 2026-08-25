package com.uten.imp.responsibility;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class EmployeeOffboardHandoverContractTest {

    private static final Path MAIN = Path.of("src/main/java/com/uten/imp");

    @Test
    void offboardBeginsIdempotencyThenHandsOverBeforeDisablingAccount()
            throws Exception {
        String source = read("features/org/employee/EmployeeCommandService.java");

        int begin = source.indexOf("dataHandoverService.beginOffboarding(");
        int resigned = source.indexOf("employee.setStatus(\"resigned\")");
        int preview = source.indexOf("dataHandoverService.previewOffboarding(");
        int execute = source.indexOf("dataHandoverService.executeOffboarding(");
        int cleanup = source.indexOf("dataHandoverService.cleanupDepartingEmployee(id)");
        int disabled = source.indexOf("account.setStatus(\"disabled\")");
        int complete = source.indexOf("dataHandoverService.completeOffboarding(");

        assertThat(begin).isGreaterThan(0);
        assertThat(resigned).isGreaterThan(begin);
        assertThat(preview).isGreaterThan(resigned);
        assertThat(execute).isGreaterThan(preview);
        assertThat(cleanup).isGreaterThan(execute);
        assertThat(disabled).isGreaterThan(cleanup);
        assertThat(complete).isGreaterThan(disabled);
        assertThat(source).contains(
                "@Transactional(isolation = Isolation.REPEATABLE_READ)",
                "empRepo.saveAndFlush(employee)",
                "handover.requiresTarget()",
                "该员工仍有未交接责任数据，请选择默认接手人",
                "requireCompleteOffboardingChecklist(",
                "offboardingHistoryRemark(",
                "account.setRemoteAccess(false)",
                "account.setMustChangePassword(true)",
                "normalizeResignType(req.resignType())");
    }

    @Test
    void rehireLocksEmployeeThenAccountAndRechecksBinding() throws Exception {
        String source = read("features/org/employee/EmployeeCommandService.java");
        int rehire = source.indexOf("public void rehire(UUID id)");
        int employeeLock = source.indexOf("empRepo.findByIdForUpdate(id)", rehire);
        int accountId = source.indexOf("userRepo.findIdByEmployeeId(id)", employeeLock);
        int accountLock = source.indexOf("userRepo.findByIdForUpdate(accountId)", accountId);
        int binding = source.indexOf(
                "!Objects.equals(id, lockedAccount.getEmployeeId())", accountLock);
        int employeeActive = source.indexOf("e.setStatus(\"active\")", binding);
        int accountActive = source.indexOf(
                "lockedAccount.setStatus(\"active\")", employeeActive);
        assertThat(employeeLock).isGreaterThan(rehire);
        assertThat(accountId).isGreaterThan(employeeLock);
        assertThat(accountLock).isGreaterThan(accountId);
        assertThat(binding).isGreaterThan(accountLock);
        assertThat(employeeActive).isGreaterThan(binding);
        assertThat(accountActive).isGreaterThan(employeeActive);
    }

    @Test
    void requestAndEmployeeApiExposeSuccessorAndPreviewWithoutBreakingOldJson()
            throws Exception {
        String request = read("features/org/employee/dto/OffboardRequest.java");
        String controller = read("features/org/employee/EmployeeController.java");

        assertThat(request).contains(
                "@NotBlank String resignType",
                "UUID successorEmployeeId",
                "@NotNull UUID requestId",
                "String handoverReason",
                "confirmedChecklistCodes");
        assertThat(controller).contains(
                "@GetMapping(\"/{id}/handover-preview\")",
                "dataHandoverService.previewOffboarding(id, successorEmployeeId)");
    }

    @Test
    void handoverGraphUsesLatestCompletedEdgePerScopeAndBlocksCycles()
            throws Exception {
        String source = read("responsibility/DataHandoverService.java");

        assertThat(source).contains(
                "handoverGraphCycle(source.id(), target.id(), scope)",
                "WITH RECURSIVE ranked_edges AS",
                "row_number() OVER (",
                "PARTITION BY handover.source_employee_id",
                "ORDER BY handover.sequence_no DESC",
                "handover.source_employment_generation=(",
                "WHERE ranked.position=1",
                "ranked.target_employment_generation=(",
                "handover_scope.scope=:scope",
                "DataHandoverAction.BLOCKING",
                "updated_by=:actor");
    }

    private static String read(String relative) throws Exception {
        return Files.readString(MAIN.resolve(relative), StandardCharsets.UTF_8);
    }
}
