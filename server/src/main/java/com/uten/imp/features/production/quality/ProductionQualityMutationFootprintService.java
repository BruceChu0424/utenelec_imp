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
        locks.requireDiscoveredCovered(() -> discover(Kind.INSPECTION,List.of(inspectionId),false));
    }
    public void requireAuthorization(UUID authorizationId) {
        locks.requireDiscoveredCovered(() -> discover(Kind.AUTHORIZATION,List.of(authorizationId),false));
    }

    private FulfillmentMutationLockPlan discover(Kind kind,List<UUID> ids,boolean createsAnalysis) {
        var result=new Scope(); result.parts.add("quality-root:"+kind+":"+ids);
        if(kind==Kind.REPORT) {
            for(var row:rows("""
                    SELECT report.id,item.id,COALESCE(plan_item.plan_id,segment.plan_id),item.goods_id,item.color_id,
                           item.fqc_recovery_authorization_id,report.xmin::text,item.xmin::text
                    FROM production_daily_reports report LEFT JOIN production_daily_report_items item
                      ON item.report_id=report.id AND item.is_deleted=FALSE
                    LEFT JOIN production_plan_items plan_item ON plan_item.id=item.plan_item_id
                    LEFT JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
                    WHERE report.id IN (:ids) ORDER BY report.id,item.id
                    """,ids)) {
                result.row("report",row); result.plan((UUID)row[2]); result.inventory((UUID)row[3],(UUID)row[4]);
                result.authorization((UUID)row[5]);
            }
            // Additional actual-output plans settle the original issue owner's
            // material. Include that exact plan before taking any inventory lock.
            for(var row:rows("""
                    SELECT usage.id,demand.plan_id,demand.goods_id,demand.color_id,
                           usage.xmin::text,demand.xmin::text
                    FROM production_daily_report_material_usages usage
                    JOIN production_material_demands demand ON demand.id=usage.demand_id
                    WHERE usage.report_id IN (:ids) ORDER BY demand.plan_id,demand.id,usage.id
                    """,ids)) {
                result.row("report-material-source",row);
                result.plan((UUID)row[1]);result.inventory((UUID)row[2],(UUID)row[3]);
            }
            // A workshop handoff also mutates the receiving task and its material
            // ownership. Discover that plan before any report/stock lock, even
            // when it belongs to another analysis in the same workshop.
            for(var row:rows("""
                    SELECT item.id,demand.id,receiving.plan_id,demand.goods_id,demand.color_id,
                           demand.xmin::text,receiving.xmin::text,fn_warehouse_main_id(demand.warehouse_id)
                    FROM production_daily_report_items item
                    JOIN production_material_demands demand ON demand.id=item.direct_transfer_demand_id
                    JOIN production_execution_segments receiving ON receiving.id=demand.execution_segment_id
                    WHERE item.report_id IN (:ids) AND NOT item.is_deleted AND item.destination='WORKSHOP'
                    ORDER BY receiving.plan_id,receiving.id,demand.id,item.id
                    """,ids)) {
                result.row("report-direct-receiver",row);
                result.plan((UUID)row[2]); result.inventory((UUID)row[3],(UUID)row[4]);
                // 直送会在线边仓(挂收料主仓下)就地入库并登记成本; 首笔入库的成本对象
                // 只有写入时才存在, 预读发现看不到它, 收料主仓的协调锁必须在此预先声明。
                result.mainWarehouse((UUID)row[7]);
            }
            // Reversing the source report cancels only its actual, still-live
            // recovery authorizations; do not expand unrelated matching SKUs.
            for(var row:rows("""
                    SELECT recovery_auth.id,recovery_auth.xmin::text
                    FROM production_fqc_recovery_authorizations recovery_auth
                    JOIN production_daily_report_items item ON item.id=recovery_auth.source_report_item_id
                    WHERE item.report_id IN (:ids) AND NOT EXISTS (
                      SELECT 1 FROM production_fqc_recovery_cancellation_events event WHERE event.authorization_id=recovery_auth.id)
                    ORDER BY recovery_auth.id
                    """,ids)) {result.row("report-recovery",row);result.authorization((UUID)row[0]);}
            for(var row:rows("""
                    SELECT inspection.id,inspection.xmin::text
                    FROM production_fqc_inspections inspection WHERE inspection.source_report_id IN (:ids)
                    ORDER BY inspection.id
                    """,ids)) result.row("report-inspection",row);
        } else if(kind==Kind.INSPECTION) {
            // V597 先入库后质检：登记时已承诺「合格自动点收」的行，本次判定会在同事务里
            // 新建并确认一张 FINISHED_IN，落仓唤醒与父需求必须现在就进预锁集合。
            for(var row:rows("""
                    SELECT inspection.id,COALESCE(item.plan_id,segment.plan_id),inspection.goods_id,inspection.color_id,
                           inspection.xmin::text,inspection.source_plan_item_id,
                           CASE WHEN registration.stock_in_before_inspection
                                THEN inspection.warehouse_id END
                    FROM production_fqc_inspections inspection
                    LEFT JOIN production_plan_items item ON item.id=inspection.source_plan_item_id
                    LEFT JOIN production_execution_segments segment ON segment.id=inspection.execution_segment_id
                    LEFT JOIN production_finished_arrival_registration_items registration_item
                      ON registration_item.source_report_item_id=inspection.source_report_item_id
                     AND registration_item.reversal_id IS NULL
                    LEFT JOIN production_finished_arrival_registrations registration
                      ON registration.id=registration_item.registration_id
                    WHERE inspection.id IN (:ids) ORDER BY inspection.id
                    """,ids)) {
                result.row("inspection",row);result.plan((UUID)row[1]);result.inventory((UUID)row[2],(UUID)row[3]);
                if(row[6]!=null&&row[2]!=null) {
                    result.preStocked.add(new WarehouseDimension((UUID)row[6],(UUID)row[2],(UUID)row[3]));
                    if(row[5]!=null) result.preStockedPlanItems.add((UUID)row[5]);
                }
            }
        } else result.authorizations.addAll(ids);

        if(!result.authorizations.isEmpty()) {
            for(var row:rows("""
                    SELECT recovery_auth.id,COALESCE(item.plan_id,segment.plan_id),recovery_auth.warehouse_id,
                           recovery_auth.goods_id,recovery_auth.color_id,recovery_auth.xmin::text,
                           task.id,task.xmin::text
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
                    SELECT link.id,link.material_analysis_id,link.xmin::text
                    FROM production_fqc_replenishment_analysis_links link WHERE link.authorization_id IN (:ids)
                    ORDER BY link.id
                    """,result.authorizations)) {result.row("recovery-analysis",row);result.analyses.add((UUID)row[1]);}
        }
        var parts=new ArrayList<FulfillmentMutationLockPlan>();
        parts.add(new FulfillmentMutationLockPlan(Set.of(),result.inventory,result.mainWarehouses,Set.of(),CanonicalFingerprint.sha256(result.parts)));
        if(!result.plans.isEmpty()) parts.add(plans.discoverPlans(result.plans));
        if(!result.analyses.isEmpty()) parts.add(production.forAnalyses(result.analyses));
        if(!result.manualRoots.isEmpty()) parts.add(production.forPreview(List.of(),List.of(),result.manualRoots,
                result.manualRoots.stream().map(WarehouseDimension::warehouseId).distinct().toList(),List.of()));
        if(!result.preStocked.isEmpty()) parts.add(
                production.forFutureFinishedInbound(result.preStocked,result.preStockedPlanItems));
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
        /** 直送行收料主仓的协调锁: 线边仓入库/成本登记在其名下, 预读时对象尚不存在。 */
        final Set<UUID> mainWarehouses=new LinkedHashSet<>();
        /** V597 先入库后质检行的落仓维度与计划行：合格自动点收的等价预锁前像。 */
        final Set<WarehouseDimension> preStocked=new LinkedHashSet<>();
        final Set<UUID> preStockedPlanItems=new LinkedHashSet<>();
        final List<String> parts=new ArrayList<>();
        void plan(UUID id){if(id!=null)plans.add(id);}
        void authorization(UUID id){if(id!=null)authorizations.add(id);}
        void mainWarehouse(UUID id){if(id!=null)mainWarehouses.add(id);}
        void inventory(UUID goods,UUID color){if(goods!=null)inventory.add(new InventoryDimension(goods,color));}
        void row(String kind,Object[] row){parts.add(kind+":"+java.util.Arrays.toString(row));}
    }
}
