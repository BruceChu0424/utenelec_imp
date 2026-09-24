package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.BeanUtils;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.*;

/** Converts an actual physical batch into disjoint planned and public facts. */
@Service
@RequiredArgsConstructor
public class DailyReportOutputAllocationService {
    private final EntityManager em;

    @Transactional(propagation = Propagation.MANDATORY)
    public List<DailyReportItemLine> split(UUID reportId, List<DailyReportItemLine> requested) {
        return splitForPreview(reportId,requested,List.of());
    }

    List<DailyReportItemLine> splitForPreview(UUID reportId,List<DailyReportItemLine> requested,List<UUID> previewProofs) {
        if (requested == null || requested.isEmpty()) return List.of();
        for(DailyReportItemLine input:requested) {
            if (input == null || input.getQty() == null || input.getQty().signum() <= 0
                    || input.getQty().stripTrailingZeros().scale() > 4) {
                throw validation("本次实际产量必须大于零，最多四位小数");
            }
        }
        List<UUID> segments = requested.stream().map(DailyReportItemLine::getExecutionSegmentId)
                .filter(Objects::nonNull).distinct().sorted().toList();
        if (!segments.isEmpty()) em.createNativeQuery("""
                SELECT id FROM production_execution_segments WHERE id IN (:ids) ORDER BY id FOR UPDATE
                """).setParameter("ids", segments).getResultList();
        List<UUID> planItems=requested.stream().map(DailyReportItemLine::getPlanItemId)
                .filter(Objects::nonNull).distinct().sorted().toList();
        if(!planItems.isEmpty())em.createNativeQuery("SELECT id FROM production_plan_items WHERE id IN (:ids) ORDER BY id FOR UPDATE")
                .setParameter("ids",planItems).getResultList();
        Map<String, Capacity> capacities = new HashMap<>();
        Map<UUID, Capacity> responsibility = new HashMap<>();
        Map<UUID, BigDecimal> directRemaining = new HashMap<>();
        Map<String, BigDecimal> directSourceRemaining = new HashMap<>();
        List<DailyReportItemLine> result = new ArrayList<>();
        for (DailyReportItemLine input : requested) {
            if (input.getExecutionSegmentId() == null) {
                result.add(input); // The existing guard rejects new unowned execution lines.
                continue;
            }
            String destination=input.getDestination()==null?"WAREHOUSE":input.getDestination().strip().toUpperCase(Locale.ROOT);
            if(!List.of("WAREHOUSE","WORKSHOP").contains(destination))throw validation("报工明细的产出去向无效");
            if("WORKSHOP".equals(destination)) {
                if(input.getDirectTransferDemandId()==null)throw validation("转下一工序必须选择接收工单");
                if(!Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_workshop_direct_relationship_allows(:source,:target)")
                        .setParameter("source",input.getExecutionSegmentId()).setParameter("target",input.getDirectTransferDemandId()).getSingleResult()))
                    throw validation("直送必须保留同车间的真实上下层供给责任；跨车间或无对应责任请走正常仓库交接");
            }
            UUID batch = UUID.randomUUID();
            if (input.getFqcRecoveryAuthorizationId() != null) {
                DailyReportItemLine recovery = copy(input, input.getQty(), batch, false, false);
                List<Object[]> source = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT fn_daily_report_is_public_output(source.id), source.is_actual_surplus,source.supplement_proof_id
                        FROM production_fqc_recovery_authorizations authority
                        JOIN production_daily_report_items source ON source.id=authority.source_report_item_id
                        WHERE authority.id=:id
                        """).setParameter("id", input.getFqcRecoveryAuthorizationId()));
                if (source.size() != 1) throw validation("补产报工缺少原品质处置来源");
                recovery.setPublicOutput(Boolean.TRUE.equals(source.getFirst()[0]));
                recovery.setActualSurplus(Boolean.TRUE.equals(source.getFirst()[1]));
                recovery.setSupplementProofId((UUID)source.getFirst()[2]);
                if (recovery.isPublicOutput()) warehousePublic(recovery);
                result.add(recovery);
                continue;
            }
            List<Object[]> context = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT segment.planned_qty, COALESCE((SELECT SUM(allocated_qty)
                            FROM execution_segment_sales_allocations WHERE execution_segment_id=segment.id),0),
                           COALESCE((SELECT SUM(link.submitted_qty)
                            FROM production_material_analysis_plan_links link
                            WHERE link.plan_id=segment.plan_id AND link.allocation_status='APPROVED'),plan_item.qty),
                           EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof WHERE proof.supplement_execution_segment_id=segment.id)
                    FROM production_execution_segments segment
                    JOIN production_plan_items plan_item ON plan_item.id=segment.source_plan_item_id
                    WHERE segment.id=:id AND NOT segment.is_deleted
                    """).setParameter("id", input.getExecutionSegmentId()));
            if (context.size() != 1) throw validation("报工来源执行工单不存在");
            BigDecimal planned = number(context.getFirst()[0]);
            BigDecimal sales = number(context.getFirst()[1]);
            BigDecimal publicQuota = planned.subtract(sales).max(BigDecimal.ZERO);
            BigDecimal selectedQuota = publicQuota;
            if (input.getExecutionSegmentSalesAllocationId() != null) {
                List<Object[]> selected = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT sales_order_item_id, allocated_qty FROM execution_segment_sales_allocations
                        WHERE id=:allocation AND execution_segment_id=:segment
                        """).setParameter("allocation", input.getExecutionSegmentSalesAllocationId())
                        .setParameter("segment", input.getExecutionSegmentId()));
                if (selected.size()!=1 || !Objects.equals(input.getSalesOrderItemId(), selected.getFirst()[0]))
                    throw validation("所选销售分摊与原执行工单不一致");
                selectedQuota=number(selected.getFirst()[1]);
            } else if (input.getSalesOrderItemId()!=null) {
                throw validation("报工销售来源必须同时保留精确执行分摊");
            }
            Capacity selected = capacity(capacities, reportId, input.getExecutionSegmentId(),
                    input.getExecutionSegmentSalesAllocationId(), selectedQuota,previewProofs);
            BigDecimal plannedTake = selected.take(input.getQty());
            BigDecimal left = input.getQty().subtract(plannedTake);
            List<DailyReportItemLine> pieces = new ArrayList<>();
            if (plannedTake.signum()>0) {
                BigDecimal demandTake = plannedTake;
                if (input.getExecutionSegmentSalesAllocationId()==null) {
                    if (sales.signum()>0 || Boolean.TRUE.equals(context.getFirst()[3])) demandTake=BigDecimal.ZERO;
                    else {
                        Capacity remaining=responsibility.computeIfAbsent(input.getPlanItemId(), ignored ->
                                new Capacity(number(context.getFirst()[2]).subtract(existingDemandQuantity(reportId,input.getPlanItemId(),false)).max(BigDecimal.ZERO),
                                    number(context.getFirst()[2]).subtract(existingDemandQuantity(reportId,input.getPlanItemId(),true)).max(BigDecimal.ZERO)));
                        demandTake=remaining.take(demandTake);
                    }
                }
                BigDecimal warehouseDemand=BigDecimal.ZERO;
                if ("WORKSHOP".equals(destination)) {
                    String sourceKey=input.getPlanItemId()+":"+input.getDirectTransferDemandId();
                    BigDecimal sourceRemaining=directSourceRemaining.computeIfAbsent(sourceKey, ignored -> {
                        em.createNativeQuery("SELECT id FROM production_material_demands WHERE id=:id FOR UPDATE")
                                .setParameter("id",input.getDirectTransferDemandId()).getResultList();
                        return number(em.createNativeQuery("SELECT fn_workshop_direct_remaining_for_source(:source,:target)")
                                .setParameter("source",input.getExecutionSegmentId())
                                .setParameter("target",input.getDirectTransferDemandId()).getSingleResult());
                    });
                    BigDecimal targetRemaining=directRemaining.computeIfAbsent(input.getDirectTransferDemandId(),ignored ->
                            number(em.createNativeQuery("SELECT GREATEST(required_qty-fn_workshop_direct_covered_base_qty(id),0) FROM production_material_demands WHERE id=:id")
                                    .setParameter("id",input.getDirectTransferDemandId()).getSingleResult()));
                    BigDecimal baseRemaining=sourceRemaining.min(targetRemaining);
                    BigDecimal rate=input.getUnitRate()==null?BigDecimal.ONE:input.getUnitRate();
                    if(rate.signum()<=0)throw validation("报工单位换算率必须大于零");
                    BigDecimal transferable=baseRemaining.divide(rate,4,RoundingMode.DOWN);
                    BigDecimal directTake=demandTake.min(transferable);
                    warehouseDemand=demandTake.subtract(directTake);
                    BigDecimal baseDirect=transferBaseQuantity(directTake,rate);
                    directRemaining.put(input.getDirectTransferDemandId(),targetRemaining.subtract(baseDirect));
                    directSourceRemaining.put(sourceKey,sourceRemaining.subtract(baseDirect));
                }
                if(demandTake.subtract(warehouseDemand).signum()>0)
                    pieces.add(copy(input,demandTake.subtract(warehouseDemand),batch,false,false));
                if(warehouseDemand.signum()>0) {
                    DailyReportItemLine warehouse=copy(input,warehouseDemand,batch,false,false);
                    warehouse.setDestination("WAREHOUSE");warehouse.setDirectTransferDemandId(null);
                    pieces.add(warehouse);
                }
                BigDecimal publicTake=plannedTake.subtract(demandTake);
                if(publicTake.signum()>0)pieces.add(copy(input,publicTake,batch,true,false));
            }
            if(left.signum()>0 && input.getExecutionSegmentSalesAllocationId()!=null) {
                BigDecimal extraPlanned=capacity(capacities,reportId,input.getExecutionSegmentId(),null,publicQuota,previewProofs).take(left);
                if(extraPlanned.signum()>0)pieces.add(copy(input,extraPlanned,batch,true,false));
                left=left.subtract(extraPlanned);
            }
            if(left.signum()>0)pieces.add(copy(input,left,batch,true,true));
            distributeWeight(input,pieces);
            result.addAll(pieces);
        }
        for(int index=0;index<result.size();index++)result.get(index).setLineNo(index+1);
        return result;
    }

    private Capacity capacity(Map<String,Capacity> cache,UUID report,UUID segment,UUID allocation,BigDecimal quota,List<UUID> previewProofs) {
        String key=segment+":"+allocation;
        return cache.computeIfAbsent(key,ignored -> {
            Object[] row=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT COALESCE(SUM(item.qty) FILTER (WHERE report.status=1),0),COALESCE(SUM(item.qty),0),
                           fn_actual_supplement_reserved_original_qty(:segment,CAST(:allocation AS uuid),:report,CAST(string_to_array(:proofs,',') AS uuid[]))
                    FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
                    WHERE item.execution_segment_id=:segment
                      AND item.execution_segment_sales_allocation_id IS NOT DISTINCT FROM CAST(:allocation AS uuid)
                      AND item.fqc_recovery_authorization_id IS NULL AND NOT item.is_actual_surplus
                      AND item.report_id<>:report AND NOT item.is_deleted AND NOT report.is_deleted AND report.status IN(0,1)
                    """).setParameter("segment",segment).setParameter("allocation",allocation)
                    .setParameter("report",report).setParameter("proofs",previewProofs.stream().map(UUID::toString).collect(java.util.stream.Collectors.joining(",")))).getFirst();
            return new Capacity(quota.subtract(number(row[0])).max(BigDecimal.ZERO),
                    quota.subtract(number(row[1])).subtract(number(row[2])).max(BigDecimal.ZERO));
        });
    }

    public void requireAllowance(UUID reportId,List<DailyReportItemLine> lines) {
        Map<UUID,BigDecimal> requested=new LinkedHashMap<>();
        for(var line:lines)if(line.isActualSurplus()&&line.getFqcRecoveryAuthorizationId()==null)
            requested.merge(line.getExecutionSegmentId(),line.getQty(),BigDecimal::add);
        for(var entry:requested.entrySet()) {
            BigDecimal available=number(em.createNativeQuery("SELECT fn_execution_actual_surplus_available(:segment,:report)")
                    .setParameter("segment",entry.getKey()).setParameter("report",reportId).getSingleResult());
            if(entry.getValue().compareTo(available)>0)throw new ApiException(ErrorCode.CONFLICT,
                    "本单同工单累计公共超产 "+entry.getValue().stripTrailingZeros().toPlainString()+"，已批准剩余超产额度 "+available.stripTrailingZeros().toPlainString()+"；请为本次全部超出原计划的数量提交追加计划，不会减少您填写的实际产量",
                    List.of(new com.uten.imp.common.web.ApiError.FieldError("overproductionSupplement",entry.getKey().toString())));
        }
    }
    public void requirePersistedAllowance(UUID reportId) {
        em.createNativeQuery("SELECT fn_assert_actual_output_policy_limit_for_report(:report)").setParameter("report",reportId).getSingleResult();
    }

    private BigDecimal existingDemandQuantity(UUID report,UUID planItem,boolean drafts) {
        return number(em.createNativeQuery("""
                SELECT COALESCE(SUM(item.qty),0) FROM production_daily_report_items item
                JOIN production_daily_reports report ON report.id=item.report_id
                WHERE item.plan_item_id=:planItem AND item.report_id<>:report
                  AND NOT item.is_public_output AND NOT item.is_actual_surplus
                  AND item.fqc_recovery_authorization_id IS NULL
                  AND NOT item.is_deleted AND NOT report.is_deleted
                  AND (report.status=1 OR (:drafts AND report.status=0))
                """).setParameter("planItem",planItem).setParameter("report",report)
                .setParameter("drafts",drafts).getSingleResult());
    }

    /** A physical report records actual use against real ISSUE sources, never a BOM percentage. */
    public void requireMaterialDeclarations(UUID reportId) {
        Object invalid=em.createNativeQuery("""
                SELECT EXISTS(
                    SELECT 1 FROM production_daily_report_items item
                    JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
                    WHERE item.report_id=:report AND NOT item.is_deleted
                      AND item.fqc_recovery_authorization_id IS NULL
                      AND segment.material_requirement_mode<>'ZERO_MATERIAL'
                      AND NOT (NOT item.is_actual_surplus AND (fn_split_batch_empty_issued(segment.id)
                          OR (item.supplement_proof_id IS NULL AND fn_report_has_prior_same_segment_consumption(segment.id,:report))))
                      AND (NOT EXISTS(
                          SELECT 1 FROM production_daily_report_material_usages usage
                          JOIN production_material_demands demand ON demand.id=usage.demand_id
                          WHERE usage.report_id=:report AND usage.qty_base>0
                            AND demand.execution_segment_id IN(
                                SELECT segment_id FROM fn_production_material_usage_source_segments(segment.id)))
                        OR NOT EXISTS(
                          SELECT 1 FROM fn_production_material_usage_source_segments(segment.id) source
                          JOIN production_material_demands demand ON demand.execution_segment_id=source.segment_id
                          JOIN production_material_stock_postings issue ON issue.demand_id=demand.id AND issue.posting_type='ISSUE'
                          WHERE NOT demand.is_deleted AND demand.status NOT IN('RELEASED','REVERSED'))
                        OR EXISTS(
                          SELECT 1 FROM fn_production_material_usage_source_segments(segment.id) source
                          JOIN production_material_demands demand ON demand.execution_segment_id=source.segment_id
                          WHERE NOT demand.is_deleted AND demand.status NOT IN('RELEASED','REVERSED')
                            AND EXISTS(SELECT 1 FROM production_material_stock_postings issue WHERE issue.demand_id=demand.id AND issue.posting_type='ISSUE')
                            AND NOT EXISTS(SELECT 1 FROM production_daily_report_material_usages usage
                                WHERE usage.report_id=:report AND usage.demand_id=demand.id))))
                """).setParameter("report",reportId).getSingleResult();
        if(Boolean.TRUE.equals(invalid))throw validation("请逐项填写本批实际用料。计划内续批可引用本工单此前已审日报的真实已耗材料；新增超产或追加批次须有本次正实耗，零增耗补登记须提供明确更正证明，不能只借旧领料记录");
    }

    static final class Capacity {
        private BigDecimal approvedRemaining;
        private BigDecimal availableRemaining;
        Capacity(BigDecimal approvedRemaining,BigDecimal availableRemaining) {
            this.approvedRemaining=approvedRemaining;this.availableRemaining=availableRemaining;
        }
        BigDecimal take(BigDecimal requested) {
            BigDecimal take=requested.min(approvedRemaining);
            if(take.compareTo(availableRemaining)>0)throw new ApiException(ErrorCode.CONFLICT,
                    "本工单需求份已有其他未审核日报占用，请先处理原草稿；不能把重复占用自动改成公共超产");
            approvedRemaining=approvedRemaining.subtract(take);
            availableRemaining=availableRemaining.subtract(take);
            return take;
        }
    }

    private static DailyReportItemLine copy(DailyReportItemLine source,BigDecimal qty,UUID batch,boolean publicOutput,boolean actual) {
        DailyReportItemLine target=new DailyReportItemLine();BeanUtils.copyProperties(source,target);
        target.setQty(qty);target.setOutputBatchId(batch);target.setOutputBatchQty(source.getQty());
        target.setPublicOutput(publicOutput);target.setActualSurplus(actual);
        if(publicOutput)warehousePublic(target);
        return target;
    }
    private static void warehousePublic(DailyReportItemLine target) {
        target.setSalesOrderItemId(null);target.setSalesOrderNo(null);target.setExecutionSegmentSalesAllocationId(null);
        target.setClientName(null);target.setOrderQty(null);target.setOrderDate(null);
        target.setOutboundNo(null);target.setOutboundQty(null);
        target.setDestination("WAREHOUSE");target.setDirectTransferDemandId(null);target.setIsFinal(false);
    }
    static void distributeWeight(DailyReportItemLine input,List<DailyReportItemLine> pieces) {
        if(input.getWeight()==null)return;
        BigDecimal previousBoundary=BigDecimal.ZERO;
        BigDecimal cumulativeQty=BigDecimal.ZERO;
        for(int index=0;index<pieces.size();index++) {
            DailyReportItemLine piece=pieces.get(index);
            cumulativeQty=cumulativeQty.add(piece.getQty());
            BigDecimal boundary=index==pieces.size()-1?input.getWeight():
                    input.getWeight().multiply(cumulativeQty).divide(input.getQty(),4,RoundingMode.HALF_UP);
            piece.setWeight(boundary.subtract(previousBoundary));previousBoundary=boundary;
        }
    }
    static BigDecimal transferBaseQuantity(BigDecimal qty,BigDecimal rate) {
        return qty.multiply(rate).setScale(4,RoundingMode.HALF_UP);
    }
    private static BigDecimal number(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
