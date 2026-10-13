package com.uten.imp.features.production;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.DocumentPlatformColumnAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.features.production.plan.ProductionPlan;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.dailyreport.ProductionDailyReport;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.*;
import java.util.function.Function;

@Configuration
@RequiredArgsConstructor
public class ProductionPlatformColumnResources {
    private final EntityManager em;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionPlanService plans;
    private final ProductionDailyReportService reports;

    @Bean PlatformColumnResourceAdapter productionPlanFields() {
        return resource("production_plan", "生产计划", ProductionPlan.class, null, plans::detail)
                .history(plans::history, null);
    }
    @Bean PlatformColumnResourceAdapter productionPlanLineFields() {
        return resource("production_plan_item", "生产计划明细", ProductionPlan.class,
                "SELECT id, plan_id FROM production_plan_items WHERE id IN (:ids)", plans::detail)
                .history(plans::history, historicalParent("production_plan_items", "production_plans", "plan_id"))
                .documentRows("SELECT id FROM production_plan_items WHERE plan_id=:document")
                .documentSaveLocks(com.uten.imp.features.production.plan.dto.PlanSaveRequest.class,plans::lockPlatformColumnSave);
    }
    @Bean PlatformColumnResourceAdapter productionReportFields() {
        return resource("production_daily_report", "生产报工", ProductionDailyReport.class, null, reports::detail)
                .history(reports::history, null);
    }
    @Bean PlatformColumnResourceAdapter productionReportLineFields() {
        return resource("production_daily_report_item", "生产报工明细", ProductionDailyReport.class,
                "SELECT id, report_id FROM production_daily_report_items WHERE id IN (:ids)", reports::detail)
                .history(reports::history, historicalParent("production_daily_report_items", "production_daily_reports", "report_id"))
                .documentRows("SELECT id FROM production_daily_report_items WHERE report_id=:document");
    }

    private DocumentPlatformColumnAdapter resource(String scope, String label, Class<?> entity,
            String parents, Function<UUID,Object> loader) {
        String permission = scope.endsWith("_item") ? scope.substring(0, scope.length()-5) : scope;
        return new DocumentPlatformColumnAdapter(scope, label, current, em, json,
                Set.of(permission + ":view"), Set.of(permission + ":edit"), Set.of(), entity, parents, loader,
                (id, header) -> DocumentPlatformColumnAdapter.draft(header)
                        && access.canWrite(DocumentPlatformColumnAdapter.uuid(header, "makerId")),
                List.of(new FactDefinition("qty", "数量", false), new FactDefinition("goodQty", "良品数量", false),
                        new FactDefinition("oqty", "订货数量", false),
                        new FactDefinition("defectQty", "不良数量", false), new FactDefinition("weight", "重量(kg)", false)))
                .documentCreateAuthorities(Set.of(permission + ":create"));
    }

    /** Fixed registrations only. Both old existing rows and permanently retired rows keep their exact parent. */
    private static String historicalParent(String table, String parentTable, String parentColumn) {
        String uuid = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";
        return "SELECT id," + parentColumn + " FROM " + table + " WHERE id IN (:ids)"
                + " UNION SELECT identity.record_id,identity.parent_record_id FROM ("
                + " SELECT CASE WHEN source_id ~ '" + uuid + "' THEN source_id::uuid END AS record_id,"
                + " CASE WHEN parent_id ~ '" + uuid + "' THEN parent_id::uuid END AS parent_record_id"
                + " FROM business_record_identities WHERE source_table='" + table + "' AND parent_table='" + parentTable + "'"
                + ") identity WHERE identity.record_id IN (:ids)";
    }
}
