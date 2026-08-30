package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionDailyReportWorkersMigrationContractTest {

    @Test
    void createsOrderedAuditedEmployeeRelationsAndBackfillsLegacyWorker() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create table production_daily_report_workers")
                .contains("references production_daily_reports(id) on delete cascade")
                .contains("references employees(id) on delete restrict")
                .contains("unique (report_id, employee_id)")
                .contains("unique (report_id, sort_order)")
                .contains("check (sort_order between 1 and 100)")
                .contains("create index idx_production_daily_report_worker_employee")
                .contains("select report.id, report.worker_id, 1")
                .contains("join employees employee on employee.id = report.worker_id")
                .contains("where report.worker_id is not null")
                .contains("after insert or update or delete")
                .contains("for each row execute function fn_audit()")
                .contains("not line contribution or piece-rate/payroll evidence");
    }

    private static String compact() throws Exception {
        Path direct = Path.of("src/main/resources/db/migration/"
                + "V427__production_daily_report_workers.sql");
        Path path = Files.exists(direct)
                ? direct : Path.of("server").resolve(direct);
        return Files.readString(path, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
