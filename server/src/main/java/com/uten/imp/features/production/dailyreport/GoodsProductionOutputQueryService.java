package com.uten.imp.features.production.dailyreport;

import com.uten.imp.application.port.GoodsProductionOutputQueryPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.*;

/** Read-side composition of existing family identity and workbench progress; never changes report or cost facts. */
@Service
@RequiredArgsConstructor
public class GoodsProductionOutputQueryService implements GoodsProductionOutputQueryPort {
    private final NamedParameterJdbcTemplate db;
    private final ProductionDocumentAccessPolicy access;
    private static final UUID NIL=new UUID(0,0);
    private static final List<String> SOURCES=List.of("APPROVED_DAILY_REPORT","EXECUTION_FAMILY",
            "WORKBENCH_EFFECTIVE_PROGRESS","FROZEN_REPORTING_UNIT","INITIAL_REPORT_DEFECTS");

    @Override
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Summary summary(Query query) {
        if(query==null||query.goodsId()==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"生产产量摘要必须指定货品");
        var visibility=access.scope();
        var args=new MapSqlParameterSource().addValue("goods",query.goodsId()).addValue("segment",query.executionSegmentId())
                .addValue("seeAll",visibility.seeAll()).addValue("owners",visibility.visibleOwners().isEmpty()?Set.of(NIL):visibility.visibleOwners());
        String selection=query.executionSegmentId()==null?"LATEST_APPROVED_REPORT":"EXPLICIT_EXECUTION_SCOPE";
        if(query.executionSegmentId()!=null&&!Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM production_execution_segments segment
                    JOIN production_execution_segments root ON root.id=fn_production_execution_cost_scope(segment.id)
                    WHERE segment.id=:segment AND segment.product_goods_id=:goods AND root.product_goods_id=:goods)
                """,args,Boolean.class)))throw new ApiException(ErrorCode.VALIDATION_FAILED,"生产批次不存在或与所选货品不匹配");
        // Choose by approved reporting activity, not cost-object creation or warehouse arrival.
        // A partially visible family is never presented as a complete smaller production batch.
        var candidates=db.queryForList("""
                SELECT root.id,root.segment_code,root.product_unit_id,unit.name unit_name,
                       report.bill_date,COALESCE(command.created_at,report.updated_at) approved_at
                FROM production_daily_report_items item
                JOIN production_daily_reports report ON report.id=item.report_id AND report.status=1 AND NOT report.is_deleted
                JOIN production_execution_segments member ON member.id=item.execution_segment_id
                JOIN production_execution_segments root ON root.id=fn_production_execution_cost_scope(member.id)
                LEFT JOIN units unit ON unit.id=root.product_unit_id
                LEFT JOIN production_daily_report_commands command ON command.report_id=report.id AND command.command_kind='APPROVE'
                WHERE item.goods_id=:goods AND root.product_goods_id=:goods AND NOT item.is_deleted
                  AND (CAST(:segment AS uuid) IS NULL OR root.id=fn_production_execution_cost_scope(CAST(:segment AS uuid)))
                  AND (:seeAll OR NOT EXISTS(
                    SELECT 1 FROM fn_production_execution_cost_members(root.id) family
                    JOIN production_execution_segments segment ON segment.id=family.segment_id
                    JOIN production_plans plan ON plan.id=segment.plan_id
                    WHERE plan.maker_id IS NULL OR plan.maker_id NOT IN (:owners)))
                  AND (:seeAll OR NOT EXISTS(
                    SELECT 1 FROM fn_production_execution_cost_members(root.id) family
                    JOIN production_daily_report_items other ON other.execution_segment_id=family.segment_id AND NOT other.is_deleted
                    JOIN production_daily_reports owner_report ON owner_report.id=other.report_id AND NOT owner_report.is_deleted
                    WHERE owner_report.status IN(0,1) AND (owner_report.maker_id IS NULL OR owner_report.maker_id NOT IN (:owners))))
                ORDER BY report.bill_date DESC,COALESCE(command.created_at,report.updated_at) DESC,report.id DESC,item.id DESC
                LIMIT 1
                """,args);
        if(candidates.isEmpty())return new Summary(query.goodsId(),"NONE",selection,null,null,null,null,null,null,null,
                null,null,null,null,0,0,false,SOURCES,List.of());
        var selected=candidates.getFirst();UUID scope=(UUID)selected.get("id");args.addValue("scope",scope);
        var members=db.queryForList("""
                SELECT segment.id,segment.product_goods_id,segment.product_unit_id,segment.product_unit_rate,
                       segment.status,segment.is_deleted,progress.reported_qty,
                       EXISTS(SELECT 1 FROM production_execution_segment_splits split WHERE split.source_segment_id=segment.id) retired,
                       EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof
                              JOIN production_actual_output_supplement_reversals reversed ON reversed.proof_id=proof.id
                              WHERE proof.supplement_execution_segment_id=segment.id) supplement_reversed
                FROM fn_production_execution_cost_members(:scope) family
                JOIN production_execution_segments segment ON segment.id=family.segment_id
                LEFT JOIN v_production_execution_workbench_segments progress ON progress.segment_id=segment.id
                ORDER BY segment.id
                """,args);
        var facts=db.queryForMap("""
                SELECT min(report.bill_date) FILTER(WHERE report.status=1) first_date,
                       max(report.bill_date) FILTER(WHERE report.status=1) last_date,
                       count(DISTINCT report.id) FILTER(WHERE report.status=1) report_count,
                       COALESCE(bool_or(report.status=0),false) drafts,
                       COALESCE(sum(item.qty) FILTER(WHERE report.status=1),0) raw_qty,
                       COALESCE(sum(item.defect_qty) FILTER(WHERE report.status=1 AND item.fqc_recovery_authorization_id IS NULL),0) defect_qty,
                       COALESCE(sum((SELECT COALESCE(sum(adjustment.adjusted_qty),0)
                                     FROM production_fqc_contribution_adjustments adjustment
                                     WHERE adjustment.source_report_item_id=item.id)) FILTER(WHERE report.status=1),0) fqc_qty,
                       COALESCE(bool_and(COALESCE(item.goods_id=segment.product_goods_id AND item.unit_id=segment.product_unit_id
                                   AND item.unit_rate=segment.product_unit_rate AND item.unit_rate>0,false))
                                FILTER(WHERE report.status=1),false) report_units_valid
                FROM fn_production_execution_cost_members(:scope) family
                JOIN production_execution_segments segment ON segment.id=family.segment_id
                JOIN production_daily_report_items item ON item.execution_segment_id=segment.id AND NOT item.is_deleted
                JOIN production_daily_reports report ON report.id=item.report_id AND NOT report.is_deleted AND report.status IN(0,1)
                """,args);
        UUID unit=(UUID)selected.get("product_unit_id");BigDecimal rate=null,effective=BigDecimal.ZERO;
        boolean valid=!members.isEmpty()&&unit!=null&&selected.get("unit_name")!=null&&Boolean.TRUE.equals(facts.get("report_units_valid"));
        boolean open=Boolean.TRUE.equals(facts.get("drafts"));
        for(var member:members) {
            BigDecimal ownRate=(BigDecimal)member.get("product_unit_rate");
            if(rate==null)rate=ownRate;
            valid&=query.goodsId().equals(member.get("product_goods_id"))&&Objects.equals(unit,member.get("product_unit_id"))
                    &&ownRate!=null&&ownRate.signum()>0&&rate!=null&&rate.compareTo(ownRate)==0;
            if(member.get("reported_qty") instanceof BigDecimal qty)effective=effective.add(qty);
            else valid=false;
            if(!Boolean.TRUE.equals(member.get("retired"))&&!Boolean.TRUE.equals(member.get("supplement_reversed"))
                    &&!Boolean.TRUE.equals(member.get("is_deleted"))
                    &&!Set.of("COMPLETED","CANCELLED","REVERSED").contains(Objects.toString(member.get("status"),"")))open=true;
        }
        BigDecimal raw=(BigDecimal)facts.get("raw_qty"),deducted=(BigDecimal)facts.get("fqc_qty");
        // The workbench remains authoritative. This reconciliation only detects incomplete source projections.
        boolean progressValid=raw.subtract(deducted).compareTo(effective)==0&&effective.signum()>=0;
        List<String> issues=new ArrayList<>();
        if(!valid)issues.add("REPORTING_UNIT_IDENTITY_UNPROVEN");
        if(!progressValid)issues.add("WORKBENCH_PROGRESS_NOT_RECONCILED");
        boolean complete=valid&&progressValid;
        return new Summary(query.goodsId(),!complete?"PENDING_UNIT":open?"IN_PROGRESS":"READY",selection,scope,
                (String)selected.get("segment_code"),date(facts.get("first_date")),date(facts.get("last_date")),
                time(selected.get("approved_at")),unit,(String)selected.get("unit_name"),
                complete?raw:null,complete?effective:null,complete?deducted:null,complete?(BigDecimal)facts.get("defect_qty"):null,
                members.size(),((Number)facts.get("report_count")).longValue(),Boolean.TRUE.equals(facts.get("drafts")),SOURCES,List.copyOf(issues));
    }
    private static LocalDate date(Object value){return value instanceof LocalDate d?d:value instanceof java.sql.Date d?d.toLocalDate():null;}
    private static OffsetDateTime time(Object value){return value instanceof OffsetDateTime t?t:value instanceof java.sql.Timestamp t?t.toInstant().atOffset(java.time.ZoneOffset.UTC):null;}
}
