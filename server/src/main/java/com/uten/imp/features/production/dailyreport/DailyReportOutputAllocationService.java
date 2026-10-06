package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportOutputAllocationLine;
import com.uten.imp.features.production.directtransfer.ProductionWorkshopDirectTransferService;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.BeanUtils;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.*;

/**
 * Converts an actual physical batch into disjoint planned and public facts, routed exactly as the
 * worker allocated it (V736/ADR-127): one WORKSHOP piece per receiving demand, one WAREHOUSE piece for
 * the rest of the need share, and the public/actual-surplus pieces that always go to the warehouse.
 * Every piece shares the input's output batch, unit rate and final flag (public pieces are never final).
 */
@Service
@RequiredArgsConstructor
public class DailyReportOutputAllocationService {
    private final EntityManager em;

    /** 旧页面按单个去向提交时的统一答复(见 {@link #rejectStaleRouteShape})。 */
    public static final String STALE_ROUTE_SHAPE_MESSAGE = "页面版本已更新，请刷新页面后重新填写去向";

    /**
     * 保存入口只认 V736 的去向分配(allocations)。部署前打开的旧页面仍在行上传单个去向
     * (destination / directTransferDemandId)——两种形状不同时接收：整单拒收，请用户刷新后重新填写去向，
     * 绝不按新口径把旧页面想转下一道工序的量悄悄送入仓库(ADR-127 §7)。
     * 只在接收客户端请求的入口调用；服务端回放自己存下的快照不经过这里。
     */
    public static void rejectStaleRouteShape(List<DailyReportItemLine> items) {
        if (items != null && items.stream().anyMatch(line -> line != null && line.carriesStaleRouteShape()))
            throw new ApiException(ErrorCode.MALFORMED_REQUEST, STALE_ROUTE_SHAPE_MESSAGE);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public List<DailyReportItemLine> split(UUID reportId, List<DailyReportItemLine> requested) {
        return route(reportId,requested,List.of(),true);
    }

    /**
     * 追加计划预览/审核回放只算数量(原计划承接多少、超出多少)，与分给哪个上层工单无关：
     * 不在这里核直送资格与分量。直送在保存报工时按当时的判定逐条核对；否则批准追加计划时
     * 会因为某个上层工单在此期间已备齐而被一个与追加无关的直送原因拦住。
     */
    List<DailyReportItemLine> splitForPreview(UUID reportId,List<DailyReportItemLine> requested,List<UUID> previewProofs) {
        return route(reportId,requested,previewProofs,false);
    }

    private List<DailyReportItemLine> route(UUID reportId,List<DailyReportItemLine> requested,List<UUID> previewProofs,boolean forSave) {
        if (requested == null || requested.isEmpty()) return List.of();
        List<Routing> routings=new ArrayList<>(requested.size());
        for(DailyReportItemLine input:requested) {
            if (input == null || input.getQty() == null || input.getQty().signum() <= 0
                    || input.getQty().stripTrailingZeros().scale() > 4) {
                throw validation("本次实际产量必须大于零，最多四位小数");
            }
            Routing routing=Routing.of(input);
            if(!forSave)routing=Routing.warehouseOnly(input.getQty());
            if(routing.hasDirect()&&input.getExecutionSegmentId()==null)throw validation("转下一道工序必须先选择报工来源工单");
            routings.add(routing);
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
        // 先锁全部接收需求(同一需求的并发保存串行累计)，再读库里唯一的直送判定。
        List<UUID> receivers=routings.stream().flatMap(routing->routing.direct().keySet().stream()).distinct().sorted().toList();
        if(!receivers.isEmpty())em.createNativeQuery("SELECT id FROM production_material_demands WHERE id IN (:ids) ORDER BY id FOR UPDATE")
                .setParameter("ids",receivers).getResultList();
        Map<String, Capacity> capacities = new HashMap<>();
        Map<UUID, Capacity> responsibility = new HashMap<>();
        DirectLedger ledger=new DirectLedger();
        List<DailyReportItemLine> result = new ArrayList<>();
        for (int index=0;index<requested.size();index++) {
            DailyReportItemLine input=requested.get(index);
            Routing routing=routings.get(index);
            if (input.getExecutionSegmentId() == null) {
                toWarehouse(input,null);
                input.setAllocations(null);
                result.add(input); // The existing guard rejects new unowned execution lines.
                continue;
            }
            UUID segment=input.getExecutionSegmentId();
            BigDecimal rate=input.getUnitRate()==null?BigDecimal.ONE:input.getUnitRate();
            if(routing.hasDirect()&&rate.signum()<=0)throw validation("报工单位换算率必须大于零");
            // 先说「这个上层工单能不能收」(跨车间、委外件、没有父子关系…)，再核数量与需求份。
            for(UUID demand:routing.direct().keySet())ledger.requireEligible(segment,demand);
            UUID batch = UUID.randomUUID();
            if (input.getFqcRecoveryAuthorizationId() != null) {
                if(routing.direct().size()>1||(routing.hasDirect()&&routing.warehouse().signum()>0))
                    throw validation("品质返工/补产报工整行只能一个去向：全部转给一个上层工单，或全部送入仓库");
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
                if (recovery.isPublicOutput()) {
                    if(routing.hasDirect())throw new ApiException(ErrorCode.CONFLICT,"这批补产属于公共备货，只能送入仓库，不能转下一道工序");
                    warehousePublic(recovery);
                } else if(routing.hasDirect()) {
                    UUID demand=routing.direct().keySet().iterator().next();
                    ledger.claim(segment,input.getPlanItemId(),demand,input.getQty(),rate);
                    toWorkshop(recovery,demand);
                } else {
                    toWarehouse(recovery,forSave?ledger.warehouseReason(segment,input.getPlanItemId()):null);
                }
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
                    """).setParameter("id", segment));
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
                        .setParameter("segment", segment));
                if (selected.size()!=1 || !Objects.equals(input.getSalesOrderItemId(), selected.getFirst()[0]))
                    throw validation("所选销售分摊与原执行工单不一致");
                selectedQuota=number(selected.getFirst()[1]);
            } else if (input.getSalesOrderItemId()!=null) {
                throw validation("报工销售来源必须同时保留精确执行分摊");
            }
            Capacity selected = capacity(capacities, reportId, segment,
                    input.getExecutionSegmentSalesAllocationId(), selectedQuota,previewProofs);
            BigDecimal plannedTake = selected.take(input.getQty());
            BigDecimal left = input.getQty().subtract(plannedTake);
            BigDecimal demandTake = plannedTake;
            if (plannedTake.signum()>0 && input.getExecutionSegmentSalesAllocationId()==null) {
                if (sales.signum()>0 || Boolean.TRUE.equals(context.getFirst()[3])) demandTake=BigDecimal.ZERO;
                else {
                    Capacity remaining=responsibility.computeIfAbsent(input.getPlanItemId(), ignored ->
                            new Capacity(number(context.getFirst()[2]).subtract(existingDemandQuantity(reportId,input.getPlanItemId(),false)).max(BigDecimal.ZERO),
                                number(context.getFirst()[2]).subtract(existingDemandQuantity(reportId,input.getPlanItemId(),true)).max(BigDecimal.ZERO)));
                    demandTake=remaining.take(demandTake);
                }
            }
            // 只有「需求份」能转下一道工序；公共备货与实际超产一律送入仓库(ADR-118 §3)。
            if (routing.directTotal().compareTo(demandTake)>0) throw needShareExceeded(routing.directTotal(),demandTake);
            List<DailyReportItemLine> pieces = new ArrayList<>();
            for (Map.Entry<UUID,BigDecimal> direct:routing.direct().entrySet()) {
                ledger.claim(segment,input.getPlanItemId(),direct.getKey(),direct.getValue(),rate);
                DailyReportItemLine piece=copy(input,direct.getValue(),batch,false,false);
                toWorkshop(piece,direct.getKey());
                pieces.add(piece);
            }
            BigDecimal warehouseDemand=demandTake.subtract(routing.directTotal());
            if(warehouseDemand.signum()>0) {
                DailyReportItemLine warehouse=copy(input,warehouseDemand,batch,false,false);
                toWarehouse(warehouse,forSave?ledger.warehouseReason(segment,input.getPlanItemId()):null);
                pieces.add(warehouse);
            }
            BigDecimal publicTake=plannedTake.subtract(demandTake);
            if(publicTake.signum()>0)pieces.add(copy(input,publicTake,batch,true,false));
            if(left.signum()>0 && input.getExecutionSegmentSalesAllocationId()!=null) {
                BigDecimal extraPlanned=capacity(capacities,reportId,segment,null,publicQuota,previewProofs).take(left);
                if(extraPlanned.signum()>0)pieces.add(copy(input,extraPlanned,batch,true,false));
                left=left.subtract(extraPlanned);
            }
            if(left.signum()>0)pieces.add(copy(input,left,batch,true,true));
            distributeWeight(input,pieces);keepDefectOnFirstSlice(input,pieces);
            result.addAll(pieces);
        }
        for(int index=0;index<result.size();index++)result.get(index).setLineNo(index+1);
        return result;
    }

    /**
     * 一行报工的去向分配(报工单位)：逐个接收需求转多少(同一需求合并)、送入仓库多少。
     * 合计必须等于本行实际产量；不传或空列表 = 整行送入仓库。
     */
    record Routing(Map<UUID,BigDecimal> direct,BigDecimal warehouse) {
        boolean hasDirect(){return !direct.isEmpty();}
        BigDecimal directTotal(){return direct.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add);}

        static Routing warehouseOnly(BigDecimal qty){return new Routing(Map.of(),qty);}

        static Routing of(DailyReportItemLine input) {
            List<DailyReportOutputAllocationLine> allocations=input.getAllocations();
            if(allocations==null||allocations.isEmpty())return warehouseOnly(input.getQty());
            Map<UUID,BigDecimal> direct=new LinkedHashMap<>();
            BigDecimal warehouse=BigDecimal.ZERO;
            for(DailyReportOutputAllocationLine allocation:allocations) {
                if(allocation==null||allocation.qty()==null||allocation.qty().signum()<=0
                        ||allocation.qty().stripTrailingZeros().scale()>4)
                    throw validation("每个产出去向的数量必须大于零，最多四位小数");
                if(allocation.directTransferDemandId()==null)warehouse=warehouse.add(allocation.qty());
                else direct.merge(allocation.directTransferDemandId(),allocation.qty(),BigDecimal::add);
            }
            BigDecimal total=warehouse.add(direct.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add));
            if(total.compareTo(input.getQty())!=0)throw validation("产出去向合计 "+plain(total)+" 与本行实际产量 "
                    +plain(input.getQty())+" 不一致，请重新分配");
            if(direct.size()>RequestLimits.DAILY_REPORT_DIRECT_RECEIVERS)throw validation("一行报工最多同时转给 "
                    +RequestLimits.DAILY_REPORT_DIRECT_RECEIVERS+" 个上层工单；其余请送入仓库或另起一行报工");
            return new Routing(direct,warehouse);
        }
    }

    /**
     * fn_workshop_direct_targets 的一条判定(基本单位)：能不能送、原因、本来源最多可送、接收方还差多少、
     * 原因文案里称呼接收方的那几个字。
     */
    record Target(UUID demandId,boolean eligible,String reasonCode,String reasonText,int reasonRank,
                  BigDecimal remainingQty,BigDecimal shortfallQty,String receiverLabel) {}

    private static final String TARGET_COLUMNS = """
            SELECT target.demand_id,target.eligible,target.reason_code,target.reason_text,target.reason_rank,
                   target.remaining_qty,target.receiver_shortfall_qty,target.receiver_label
            """;

    /**
     * 本张日报内的直送台账：每个生产工单读一次候选列表(先急后缓的全部上层工单与原因)，
     * 逐条扣减「本来源最多可送」(同一计划行拆出的工单共用)与「接收方还差多少」(跨行共用)。
     */
    private final class DirectLedger {
        private final Map<UUID,List<Target>> listed=new HashMap<>();
        private final Map<String,Target> single=new HashMap<>();
        private final Map<UUID,BigDecimal> demandLeft=new HashMap<>();
        private final Map<String,BigDecimal> sourceLeft=new HashMap<>();

        private List<Target> targets(UUID producing) {
            return listed.computeIfAbsent(producing,ignored->read(TARGET_COLUMNS+"FROM fn_workshop_direct_targets(:source) target",
                    producing,null));
        }

        /** 候选列表里没有的需求(已失效、没有父子关系、不在本车间等)按单条校验读出原因。 */
        private Target target(UUID producing,UUID demand) {
            for(Target target:targets(producing))if(demand.equals(target.demandId()))return target;
            return single.computeIfAbsent(producing+":"+demand,ignored->{
                List<Target> rows=read(TARGET_COLUMNS+"FROM fn_workshop_direct_targets(:source,:target) target",producing,demand);
                return rows.size()==1?rows.getFirst():new Target(demand,false,"TARGET_INVALID","所选上层工单已失效，请刷新后重新选择",
                        0,BigDecimal.ZERO,BigDecimal.ZERO,null);
            });
        }

        private List<Target> read(String sql,UUID producing,UUID demand) {
            var query=em.createNativeQuery(sql).setParameter("source",producing);
            if(demand!=null)query.setParameter("target",demand);
            List<Target> rows=new ArrayList<>();
            for(Object[] row:NativeQueryResults.objectArrayRows(query))rows.add(new Target((UUID)row[0],Boolean.TRUE.equals(row[1]),
                    (String)row[2],(String)row[3],row[4]==null?Integer.MAX_VALUE:((Number)row[4]).intValue(),
                    number(row[5]),number(row[6]),(String)row[7]));
            return rows;
        }

        /** 与候选、审核、数据库守卫同一份判定：不能收就当场说原因。 */
        void requireEligible(UUID producing,UUID demand) {
            Target target=target(producing,demand);
            if(!target.eligible())throw new ApiException(ErrorCode.CONFLICT,
                    ProductionWorkshopDirectTransferService.UNAVAILABLE_PREFIX+target.reasonText());
        }

        /** 在本张报工内扣减：超出能收的量当场说清楚，不悄悄改成送仓。 */
        void claim(UUID producing,UUID planItem,UUID demand,BigDecimal qty,BigDecimal rate) {
            requireEligible(producing,demand);
            Target target=target(producing,demand);
            BigDecimal base=transferBaseQuantity(qty,rate);
            String sourceKey=planItem+":"+demand;
            BigDecimal source=sourceLeft.computeIfAbsent(sourceKey,ignored->target.remainingQty());
            BigDecimal receiver=demandLeft.computeIfAbsent(demand,ignored->target.shortfallQty());
            BigDecimal room=source.min(receiver).max(BigDecimal.ZERO);
            if(base.compareTo(room)>0)throw new ApiException(ErrorCode.CONFLICT,
                    ProductionWorkshopDirectTransferService.UNAVAILABLE_PREFIX+exceededText(target.receiverLabel(),base,room));
            sourceLeft.put(sourceKey,source.subtract(base));
            demandLeft.put(demand,receiver.subtract(base));
        }

        /**
         * 需求份里送入仓库那部分的原因：还有能直送的上层工单没分满 = 工人自选；都分满了 = 已分满；
         * 一个能直送的都没有 = 最接近可送的那条不可转原因(与报工页红字同一个)。
         */
        String warehouseReason(UUID producing,UUID planItem) {
            List<Target> rows=targets(producing);
            boolean anyEligible=false;
            BigDecimal room=BigDecimal.ZERO;
            for(Target target:rows) {
                if(!target.eligible())continue;
                anyEligible=true;
                room=room.add(sourceLeft.getOrDefault(planItem+":"+target.demandId(),target.remainingQty())
                        .min(demandLeft.getOrDefault(target.demandId(),target.shortfallQty())).max(BigDecimal.ZERO));
            }
            if(anyEligible)return room.signum()>0?"USER_CHOSEN":"RECEIVERS_FULL";
            return rows.stream().filter(target->target.reasonCode()!=null)
                    .min(java.util.Comparator.comparingInt(Target::reasonRank)).map(Target::reasonCode).orElse("NOT_A_COMPONENT");
        }
    }

    private String exceededText(String receiverLabel,BigDecimal base,BigDecimal room) {
        return (String)em.createNativeQuery("""
                SELECT fn_workshop_direct_reason_text('QTY_EXCEEDS_REMAINING',CAST(:receiver AS text),NULL,NULL,NULL,:qty,:room)
                """).setParameter("receiver",receiverLabel).setParameter("qty",base).setParameter("room",room).getSingleResult();
    }

    private static ApiException needShareExceeded(BigDecimal directTotal,BigDecimal demandTake) {
        return new ApiException(ErrorCode.CONFLICT,demandTake.signum()==0
                ?"本行产量都属于公共备货或超出计划的产量，只能送入仓库，不能转下一道工序"
                :"本行最多 "+plain(demandTake)+" 可以转下一道工序(其余属于公共备货或超出计划的产量，只能送入仓库)；"
                        +"现在分给上层工单合计 "+plain(directTotal));
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
            if(entry.getValue().compareTo(available)>0) {
                // 2026-10-06：可用额度已扣「已批准未续报承接」的固定追加量——若正是它占住了
                // 额度，指路到续报入口，而不是让工人在原工单反复试错或再生成一张追加计划。
                BigDecimal pending=number(em.createNativeQuery("SELECT fn_actual_supplement_pending_qty(:segment,:report)")
                        .setParameter("segment",entry.getKey()).setParameter("report",reportId).getSingleResult());
                throw new ApiException(ErrorCode.CONFLICT,
                        "本单同工单累计公共超产 "+entry.getValue().stripTrailingZeros().toPlainString()
                                +"，已批准剩余超产额度 "+available.stripTrailingZeros().toPlainString()
                                +(pending.signum()>0
                                ?"；已批准的固定追加量还有 "+pending.stripTrailingZeros().toPlainString()
                                +" 未续报，请到「我的车间任务 → 固定追加量·续报」入口申报，不要在原工单直接超额报工"
                                :"；请为本次全部超出原计划的数量提交追加计划，不会减少您填写的实际产量"),
                        List.of(new com.uten.imp.common.web.ApiError.FieldError("overproductionSupplement",entry.getKey().toString())));
            }
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
        target.setAllocations(null);
        target.setQty(qty);target.setOutputBatchId(batch);target.setOutputBatchQty(source.getQty());
        target.setPublicOutput(publicOutput);target.setActualSurplus(actual);
        if(publicOutput)warehousePublic(target);
        return target;
    }
    private static void toWorkshop(DailyReportItemLine piece,UUID demand) {
        piece.setDestination("WORKSHOP");piece.setDirectTransferDemandId(demand);piece.setOutputRouteReason(null);
    }
    private static void toWarehouse(DailyReportItemLine piece,String reason) {
        piece.setDestination("WAREHOUSE");piece.setDirectTransferDemandId(null);piece.setOutputRouteReason(reason);
    }
    private static void warehousePublic(DailyReportItemLine target) {
        target.setSalesOrderItemId(null);target.setSalesOrderNo(null);target.setExecutionSegmentSalesAllocationId(null);
        target.setClientName(null);target.setOrderQty(null);target.setOrderDate(null);
        target.setOutboundNo(null);target.setOutboundQty(null);
        toWarehouse(target,target.isActualSurplus()?"ACTUAL_SURPLUS":"PUBLIC_SHARE");target.setIsFinal(false);
    }
    static void distributeWeight(DailyReportItemLine input,List<DailyReportItemLine> pieces) {
        if(input.getWeight()==null)return;
        BigDecimal previousBoundary=BigDecimal.ZERO;
        BigDecimal cumulativeQty=BigDecimal.ZERO;
        for(int index=0;index<pieces.size();index++) {
            DailyReportItemLine piece=pieces.get(index);
            cumulativeQty=cumulativeQty.add(piece.getQty());
            BigDecimal boundary=index==pieces.size()-1?input.getWeight():
                    com.uten.imp.common.finance.MoneyPolicy.quantitySlice(input.getWeight(),input.getQty(),BigDecimal.ZERO,cumulativeQty);
            piece.setWeight(boundary.subtract(previousBoundary));previousBoundary=boundary;
        }
    }
    /**
     * 一次录入的不良数只记一次(ADR-129)：整笔挂在拆出的第一份上，其余份为 0。
     * 不良数不参与拆分，拆分只按良品数；库里 daily_report_defect_first_slice 同样把关。
     */
    static void keepDefectOnFirstSlice(DailyReportItemLine input,List<DailyReportItemLine> pieces) {
        for(int index=0;index<pieces.size();index++)
            pieces.get(index).setDefectQty(index==0?input.getDefectQty():BigDecimal.ZERO);
    }
    static BigDecimal transferBaseQuantity(BigDecimal qty,BigDecimal rate) {
        return com.uten.imp.common.finance.MoneyPolicy.quantity(qty.multiply(rate));
    }
    private static BigDecimal number(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static String plain(BigDecimal value){return value.stripTrailingZeros().toPlainString();}
    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
