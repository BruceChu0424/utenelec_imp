package com.uten.imp.features.production.quality;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.application.port.ProductionMutationFootprintPort.WarehouseDimension;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Source discovery only: no inspection, report, authorization or execution lock is taken here. */
@Service
@RequiredArgsConstructor
@Transactional(propagation=Propagation.MANDATORY)
public class ProductionQualityMutationFootprintService {
    private final EntityManager em;
    private final FulfillmentMutationLocks locks;
    private final ProductionPlanMutationFootprintService plans;
    private final ProductionMutationFootprintPort production;

    public FulfillmentMutationLocks.Guard beginReport(UUID reportId) {
        return locks.acquire(() -> discover(Kind.REPORT,List.of(reportId),false));
    }
    public FulfillmentMutationLocks.Guard beginInspections(Collection<UUID> inspectionIds) {
        List<UUID> ids=ids(inspectionIds);
        return locks.acquire(() -> discover(Kind.INSPECTION,ids,false));
    }
    public FulfillmentMutationLocks.Guard beginAuthorization(UUID authorizationId,boolean createsAnalysis) {
        return locks.acquire(() -> discover(Kind.AUTHORIZATION,List.of(authorizationId),createsAnalysis));
    }
    public void requireInspection(UUID inspectionId) {
        locks.requireCovered(discover(Kind.INSPECTION,List.of(inspectionId),false));
    }
    public void requireAuthorization(UUID authorizationId) {
        locks.requireCovered(discover(Kind.AUTHORIZATION,List.of(authorizationId),false));
    }

    private FulfillmentMutationLockPlan discover(Kind kind,List<UUID> ids,boolean createsAnalysis) {
        var result=new Scope(); result.parts.add("quality-root:"+kind+":"+ids);
        if(kind==Kind.REPORT) {
            for(var row:rows("""
                    SELECT report.id,item.id,COALESCE(plan_item.plan_id,segment.plan_id),item.goods_id,item.color_id,
                           item.fqc_recovery_authorization_id,md5(to_jsonb(report)::text),md5(to_jsonb(item)::text)
                    FROM production_daily_reports report LEFT JOIN production_daily_report_items item
                      ON item.report_id=report.id AND item.is_deleted=FALSE
                    LEFT JOIN production_plan_items plan_item ON plan_item.id=item.plan_item_id
                    LEFT JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
                    WHERE report.id IN (:ids) ORDER BY report.id,item.id
                    """,ids)) {
                result.row("report",row); result.plan((UUID)row[2]); result.inventory((UUID)row[3],(UUID)row[4]);
                result.authorization((UUID)row[5]);
            }
            // Reversing the source report cancels only its actual, still-live
            // recovery authorizations; do not expand unrelated matching SKUs.
            for(var row:rows("""
                    SELECT recovery_auth.id,md5(to_jsonb(recovery_auth)::text)
                    FROM production_fqc_recovery_authorizations recovery_auth
                    JOIN production_daily_report_items item ON item.id=recovery_auth.source_report_item_id
                    WHERE item.report_id IN (:ids) AND NOT EXISTS (
                      SELECT 1 FROM production_fqc_recovery_cancellation_events event WHERE event.authorization_id=recovery_auth.id)
                    ORDER BY recovery_auth.id
                    """,ids)) {result.row("report-recovery",row);result.authorization((UUID)row[0]);}
            for(var row:rows("""
                    SELECT inspection.id,md5(to_jsonb(inspection)::text)
                    FROM production_fqc_inspections inspection WHERE inspection.source_report_id IN (:ids)
                    ORDER BY inspection.id
                    """,ids)) result.row("report-inspection",row);
        } else if(kind==Kind.INSPECTION) {
            for(var row:rows("""
                    SELECT inspection.id,COALESCE(item.plan_id,segment.plan_id),inspection.goods_id,inspection.color_id,
                           md5(to_jsonb(inspection)::text)
                    FROM production_fqc_inspections inspection
                    LEFT JOIN production_plan_items item ON item.id=inspection.source_plan_item_id
                    LEFT JOIN production_execution_segments segment ON segment.id=inspection.execution_segment_id
                    WHERE inspection.id IN (:ids) ORDER BY inspection.id
                    """,ids)) {result.row("inspection",row);result.plan((UUID)row[1]);result.inventory((UUID)row[2],(UUID)row[3]);}
        } else result.authorizations.addAll(ids);

        if(!result.authorizations.isEmpty()) {
            for(var row:rows("""
                    SELECT recovery_auth.id,COALESCE(item.plan_id,segment.plan_id),recovery_auth.warehouse_id,
                           recovery_auth.goods_id,recovery_auth.color_id,md5(to_jsonb(recovery_auth)::text),
                           task.id,md5(to_jsonb(task)::text)
                    FROM production_fqc_recovery_authorizations recovery_auth
                    LEFT JOIN production_plan_items item ON item.id=recovery_auth.source_plan_item_id
                    LEFT JOIN production_execution_segments segment ON segment.id=recovery_auth.execution_segment_id
                    LEFT JOIN production_fqc_replenishment_tasks task ON task.authorization_id=recovery_auth.id
                    WHERE recovery_auth.id IN (:ids) ORDER BY recovery_auth.id,task.id
                    """,result.authorizations)) {
                result.row("authorization",row);result.plan((UUID)row[1]);result.inventory((UUID)row[3],(UUID)row[4]);
                if(createsAnalysis&&row[2]!=null&&row[3]!=null)result.manualRoots.add(new WarehouseDimension((UUID)row[2],(UUID)row[3],(UUID)row[4]));
            }
            for(var row:rows("""
                    SELECT link.id,link.material_analysis_id,md5(to_jsonb(link)::text)
                    FROM production_fqc_replenishment_analysis_links link WHERE link.authorization_id IN (:ids)
                    ORDER BY link.id
                    """,result.authorizations)) {result.row("recovery-analysis",row);result.analyses.add((UUID)row[1]);}
        }
        var parts=new ArrayList<FulfillmentMutationLockPlan>();
        parts.add(new FulfillmentMutationLockPlan(Set.of(),result.inventory,Set.of(),Set.of(),CanonicalFingerprint.sha256(result.parts)));
        if(!result.plans.isEmpty()) parts.add(plans.discoverPlans(result.plans));
        if(!result.analyses.isEmpty()) parts.add(production.forAnalyses(result.analyses));
        if(!result.manualRoots.isEmpty()) parts.add(production.forPreview(List.of(),List.of(),result.manualRoots,
                result.manualRoots.stream().map(WarehouseDimension::warehouseId).distinct().toList(),List.of()));
        return FulfillmentMutationLockPlan.merge(CanonicalFingerprint.sha256(parts.stream()
                .map(FulfillmentMutationLockPlan::fingerprint).toList()),parts);
    }

    private List<Object[]> rows(String sql,Collection<UUID> ids) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery(sql).setParameter("ids",ids));
    }
    private static List<UUID> ids(Collection<UUID> values) {
        return values==null?List.of():values.stream().filter(java.util.Objects::nonNull).distinct()
                .sorted(Comparator.comparing(UUID::toString)).toList();
    }
    private enum Kind {REPORT,INSPECTION,AUTHORIZATION}
    private static final class Scope {
        final Set<UUID> plans=new LinkedHashSet<>(),authorizations=new LinkedHashSet<>(),analyses=new LinkedHashSet<>();
        final Set<InventoryDimension> inventory=new LinkedHashSet<>();
        final Set<WarehouseDimension> manualRoots=new LinkedHashSet<>();
        final List<String> parts=new ArrayList<>();
        void plan(UUID id){if(id!=null)plans.add(id);}
        void authorization(UUID id){if(id!=null)authorizations.add(id);}
        void inventory(UUID goods,UUID color){if(goods!=null)inventory.add(new InventoryDimension(goods,color));}
        void row(String kind,Object[] row){parts.add(kind+":"+java.util.Arrays.toString(row));}
    }
}
