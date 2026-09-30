package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.GoodsActualCostQueryPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.*;

/** A consistent read of immutable allocation plans and their physical output identities. */
@Service
public class GoodsActualCostQueryService implements GoodsActualCostQueryPort {
    private final NamedParameterJdbcTemplate db;
    public GoodsActualCostQueryService(NamedParameterJdbcTemplate db) { this.db = db; }

    static final String OBJECTS_SQL = """
            SELECT o.execution_segment_id cost_object_id,o.source_kind,o.version object_version,o.state,
                   o.business_refresh_pending,r.id revision_id,r.version revision_version,r.target_qty_base,
                   r.output_qty_base,r.scope_complete,
                   COALESCE(to_jsonb(segment)->>'execution_no',to_jsonb(segment)->>'bill_no',to_jsonb(segment)->>'code') execution_no,
                   (CAST(:revision AS uuid) IS NOT NULL) historical,
                   (SELECT count(*) FROM stock_value_production_cost_tasks t WHERE t.revision_id=r.id AND t.status='PENDING') pending_tasks,
                   EXISTS(SELECT 1 FROM stock_value_production_cost_dirty d WHERE d.execution_segment_id=o.execution_segment_id
                          AND d.observed_revision>d.cleared_revision) dirty,
                   EXISTS(SELECT 1 FROM stock_value_jobs job WHERE job.status='PENDING') value_work_pending
            FROM stock_value_production_cost_objects o
            JOIN stock_value_pools pool ON pool.id=o.product_pool_id
            LEFT JOIN production_execution_segments segment ON segment.id=o.execution_segment_id AND o.source_kind='PRODUCTION_EXECUTION'
            LEFT JOIN stock_value_production_cost_revisions r ON r.execution_segment_id=o.execution_segment_id
              AND r.id=COALESCE(CAST(:revision AS uuid),o.current_revision_id)
            WHERE pool.goods_id=:goods
              AND (CAST(:segment AS uuid) IS NULL OR o.execution_segment_id=fn_production_execution_cost_scope(CAST(:segment AS uuid)))
              AND (CAST(:revision AS uuid) IS NULL OR r.id=CAST(:revision AS uuid))
              AND ((CAST(:from AS date) IS NULL AND CAST(:to AS date) IS NULL) OR EXISTS(
                    SELECT 1 FROM stock_value_production_cost_outputs output JOIN stock_movements m ON m.id=output.movement_id
                    WHERE output.execution_segment_id=o.execution_segment_id
                      AND (CAST(:from AS date) IS NULL OR (m.transaction_date AT TIME ZONE :zone)::date>=CAST(:from AS date))
                      AND (CAST(:to AS date) IS NULL OR (m.transaction_date AT TIME ZONE :zone)::date<=CAST(:to AS date))))
            ORDER BY o.created_at DESC,o.execution_segment_id LIMIT 501
            """;

    static final String INPUTS_SQL = """
            SELECT o.execution_segment_id cost_object_id,r.id revision_id,i.input_node_id,i.approved_posting_id,i.input_kind,
                   pool.goods_id,identity.evidence->>'goodsCode' goods_code,identity.evidence->>'goodsName' goods_name,
                   (identity.evidence->>'unitId')::uuid unit_id,identity.evidence->>'unitName' unit_name,pool.warehouse_id,pool.color_id,
                   COALESCE(identity.evidence->>'state'='COMPLETE' AND identity.evidence->>'goodsId'=pool.goods_id::text
                     AND NULLIF(identity.evidence->>'goodsCode','') IS NOT NULL AND NULLIF(identity.evidence->>'goodsName','') IS NOT NULL
                     AND NULLIF(identity.evidence->>'unitId','') IS NOT NULL AND NULLIF(identity.evidence->>'unitName','') IS NOT NULL,false) identity_complete,
                   (snap.value->>'revision')::bigint value_revision,(snap.value->>'quantityBasis')::numeric gross_qty,
                   (snap.value->>'returnedQty')::numeric returned_qty,(snap.value->>'value')::numeric basis_value,
                   (snap.value->>'pending')::int pending_parents,COALESCE(snap.value->>'valueModel',n.value_model) value_model,
                   CASE WHEN jsonb_exists(snap.value,'exactLower') THEN (snap.value->>'exactLower')::numeric
                        WHEN (snap.value->>'revision')::bigint=1 THEN n.initial_bound_lower ELSE history.after_bound_lower END exact_lower,
                   CASE WHEN jsonb_exists(snap.value,'exactUpper') THEN (snap.value->>'exactUpper')::numeric
                        WHEN (snap.value->>'revision')::bigint=1 THEN n.initial_bound_upper ELSE history.after_bound_upper END exact_upper,
                   CASE WHEN r.id IS NULL OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks pending
                              WHERE pending.revision_id=r.id AND pending.status='PENDING') THEN NULL
                        ELSE COALESCE((SELECT sum(t.desired_value_local) FROM stock_value_production_cost_tasks t
                             WHERE t.revision_id=r.id AND t.input_node_id=i.input_node_id AND t.status='APPLIED'),0) END allocated,
                   e.source_doc_type,e.source_doc_id,e.source_item_id,e.occurred_at
            FROM stock_value_production_cost_objects o
            LEFT JOIN stock_value_production_cost_revisions r ON r.execution_segment_id=o.execution_segment_id
              AND r.id=COALESCE(CAST(:revision AS uuid),o.current_revision_id)
            JOIN stock_value_production_cost_inputs i ON i.execution_segment_id=o.execution_segment_id
            JOIN stock_value_nodes n ON n.id=i.input_node_id
            JOIN stock_value_events e ON e.id=n.creation_event_id
            JOIN stock_value_pools pool ON pool.id=n.pool_id
            LEFT JOIN LATERAL (SELECT value FROM jsonb_array_elements(r.input_snapshot) value
                               WHERE (value->>'node')::uuid=i.input_node_id LIMIT 1) snap ON true
            LEFT JOIN stock_value_node_revisions history ON history.node_id=n.id AND history.revision=(snap.value->>'revision')::bigint
            LEFT JOIN LATERAL (SELECT COALESCE(NULLIF(snap.value->'identity','null'::jsonb),fn_production_cost_input_identity(n.id,i.approved_posting_id)) evidence) identity ON true
            WHERE o.execution_segment_id IN (:ids) AND (r.id IS NULL OR snap.value IS NOT NULL)
            ORDER BY o.execution_segment_id,i.created_at,i.input_node_id
            """;

    static final String OUTPUTS_SQL = """
            SELECT o.execution_segment_id cost_object_id,r.id revision_id,output.source_node_id,output.movement_id,
                   CASE WHEN CAST(:revision AS uuid) IS NOT NULL THEN (snap.value->>'withdrawnMovement')::uuid
                        ELSE output.withdrawn_movement_id END withdrawn_movement_id,
                   pool.warehouse_id,pool.color_id,(m.transaction_date AT TIME ZONE :zone)::date business_date,
                   m.source_doc_type,m.source_doc_id,m.source_item_id,
                   CASE WHEN CAST(:revision AS uuid) IS NOT NULL THEN (snap.value->>'qty')::numeric ELSE output.qty_base END qty_base,
                   CASE WHEN r.id IS NULL OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks pending
                              WHERE pending.revision_id=r.id AND pending.status='PENDING') THEN NULL
                        ELSE COALESCE((SELECT sum(t.desired_value_local) FROM stock_value_production_cost_tasks t
                             WHERE t.revision_id=r.id AND t.output_source_node_id=output.source_node_id AND t.status='APPLIED'),0) END amount,
                   COALESCE((SELECT max(nr.revision) FROM stock_value_production_cost_tasks t
                             JOIN stock_value_node_revisions nr ON nr.event_id=t.value_event_id AND nr.node_id=output.source_node_id
                             WHERE t.revision_id=r.id AND t.output_source_node_id=output.source_node_id),1) value_revision,
                   (r.id IS NULL OR snap.value IS NULL OR NOT r.scope_complete OR (snap.value->>'qty') IS NULL
                    OR (CAST(:revision AS uuid) IS NULL AND output.withdrawn_movement_id IS DISTINCT FROM (snap.value->>'withdrawnMovement')::uuid)
                    OR EXISTS(
                       SELECT 1 FROM stock_value_production_cost_tasks t WHERE t.revision_id=r.id
                       AND t.output_source_node_id=output.source_node_id AND (t.status='PENDING' OR t.input_pending>0))) pending
            FROM stock_value_production_cost_objects o
            LEFT JOIN stock_value_production_cost_revisions r ON r.execution_segment_id=o.execution_segment_id
              AND r.id=COALESCE(CAST(:revision AS uuid),o.current_revision_id)
            JOIN stock_value_production_cost_outputs output ON output.execution_segment_id=o.execution_segment_id
            JOIN stock_movements m ON m.id=output.movement_id JOIN stock_value_nodes n ON n.id=output.source_node_id
            JOIN stock_value_pools pool ON pool.id=n.pool_id
            LEFT JOIN LATERAL (SELECT value FROM jsonb_array_elements(r.output_snapshot) value
                               WHERE (value->>'source')::uuid=output.source_node_id LIMIT 1) snap ON true
            WHERE o.execution_segment_id IN (:ids)
              AND (CAST(:revision AS uuid) IS NULL OR snap.value IS NOT NULL)
              AND (CAST(:from AS date) IS NULL OR (m.transaction_date AT TIME ZONE :zone)::date>=CAST(:from AS date))
              AND (CAST(:to AS date) IS NULL OR (m.transaction_date AT TIME ZONE :zone)::date<=CAST(:to AS date))
            ORDER BY o.execution_segment_id,output.output_sequence
            """;

    @Override
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public ActualCostSnapshot snapshot(Query query) {
        if (query == null || query.goodsId() == null) throw invalid("实际成本查询必须指定货品");
        if (query.from() != null && query.to() != null && query.from().isAfter(query.to())) throw invalid("实际成本开始日期不能晚于结束日期");
        var args = new MapSqlParameterSource().addValue("goods",query.goodsId()).addValue("segment",query.executionSegmentId())
                .addValue("from",query.from()).addValue("to",query.to()).addValue("revision",query.revisionId()).addValue("zone",BusinessTime.ZONE.getId());
        var objectRows = db.queryForList(OBJECTS_SQL,args);
        if (objectRows.size()>500) throw invalid("实际成本对象超过500个，请缩小期间或选择工单");
        List<Gap> gaps = new ArrayList<>();
        gaps.add(new Gap("LABOR_ACTUAL_NOT_LINKED",null,null,"LABOR"));
        gaps.add(new Gap("OVERHEAD_ACTUAL_NOT_LINKED",null,null,"OVERHEAD"));
        if (objectRows.isEmpty()) {
            gaps.add(new Gap("NO_VALUATION_EVIDENCE",null,query.goodsId(),"INVENTORY_PRODUCTION_COST"));
            return result(query,new Summary(null,null,null,null,null,null,null,null,null,true,false,"INVENTORY_PRODUCTION_COST_ONLY",0),List.of(),List.of(),List.of(),List.of(),gaps);
        }
        args.addValue("ids",objectRows.stream().map(row->uuid(row,"cost_object_id")).toList());
        var inputs = db.queryForList(INPUTS_SQL,args).stream().map(GoodsActualCostQueryService::input).toList();
        for(var line:inputs) {
            if(line.goodsCode()==null||line.goodsName()==null||line.unitId()==null||line.unitName()==null)
                gaps.add(new Gap("ORIGINAL_INPUT_IDENTITY_MISSING",line.costObjectId(),line.inputNodeId(),"IDENTITY"));
            if(line.grossQtyBase()==null||line.returnedQtyBase()==null||line.knownAmountLocal()==null)
                gaps.add(new Gap("INPUT_REVISION_EVIDENCE_MISSING",line.costObjectId(),line.inputNodeId(),"INVENTORY_PRODUCTION_COST"));
        }
        var outputs = db.queryForList(OUTPUTS_SQL,args).stream().map(GoodsActualCostQueryService::output).toList();
        var revisions = db.queryForList("""
                SELECT r.*,(SELECT count(*) FROM stock_value_production_cost_tasks t WHERE t.revision_id=r.id AND t.status='PENDING') pending_tasks
                FROM stock_value_production_cost_revisions r WHERE r.execution_segment_id IN (:ids)
                ORDER BY r.execution_segment_id,r.version DESC
                """,args).stream().map(row->new Revision(uuid(row,"execution_segment_id"),uuid(row,"id"),number(row,"version"),time(row,"occurred_at"),bool(row,"scope_complete"),decimal(row,"target_qty_base"),decimal(row,"output_qty_base"),number(row,"pending_tasks"),text(row,"source_doc_type"),uuid(row,"source_doc_id"),uuid(row,"source_item_id"))).toList();
        List<CostObject> objects = new ArrayList<>();
        for (var row:objectRows) {
            UUID id=uuid(row,"cost_object_id");
            var own=inputs.stream().filter(line->id.equals(line.costObjectId())).toList();
            BigDecimal known=sumNullable(own.stream().map(InputLine::knownAmountLocal).toList());
            BigDecimal allocated=sumNullable(own.stream().map(InputLine::allocatedAmountLocal).toList());
            BigDecimal target=decimal(row,"target_qty_base");
            BigDecimal held=known==null||allocated==null?null:known.subtract(allocated).max(BigDecimal.ZERO);
            BigDecimal adjustment=known==null||allocated==null?null:known.subtract(allocated).min(BigDecimal.ZERO);
            List<String> reasons=new ArrayList<>();
            if(uuid(row,"revision_id")==null)reasons.add("NO_APPROVED_COST_REVISION");
            if(number(row,"pending_tasks")>0)reasons.add("ALLOCATION_APPLYING");
            if(!bool(row,"historical")&&(bool(row,"business_refresh_pending")||bool(row,"dirty")||bool(row,"value_work_pending")))reasons.add("SOURCE_REFRESH_PENDING");
            if(!bool(row,"historical")&&!"FINAL".equals(text(row,"state")))reasons.add("COST_STATE_"+text(row,"state"));
            if(!bool(row,"scope_complete"))reasons.add("SCOPE_NOT_COMPLETE");
            if(target==null||target.signum()==0)reasons.add("OUTPUT_BASIS_PENDING");
            if(own.isEmpty())reasons.add("NO_INPUT_COST_EVIDENCE");
            if(own.stream().anyMatch(InputLine::pending))reasons.add("INPUT_COST_PENDING");
            String status=reasons.contains("ALLOCATION_APPLYING")||reasons.contains("SOURCE_REFRESH_PENDING")?"APPLYING":reasons.contains("OUTPUT_BASIS_PENDING")?"PENDING_BASIS":reasons.contains("COST_STATE_PENDING_CLASSIFICATION")?"PENDING_CLASSIFICATION":reasons.isEmpty()?"FINAL":"PROVISIONAL";
            objects.add(new CostObject(id,text(row,"source_kind"),"PRODUCTION_EXECUTION".equals(text(row,"source_kind"))?id:null,text(row,"execution_no"),uuid(row,"revision_id"),number(row,"revision_version"),status,target,decimal(row,"output_qty_base"),known,allocated,target!=null&&target.signum()>0?held:BigDecimal.ZERO,adjustment,target==null||target.signum()==0?held:BigDecimal.ZERO,!reasons.isEmpty(),bool(row,"historical"),List.copyOf(reasons)));
            reasons.forEach(reason->gaps.add(new Gap(reason,id,uuid(row,"revision_id"),"INVENTORY_PRODUCTION_COST")));
        }
        BigDecimal outputQty=sumNullable(outputs.stream().map(OutputLine::effectiveQtyBase).toList());
        BigDecimal outputAmount=sumNullable(outputs.stream().map(OutputLine::knownAmountLocal).toList());
        BigDecimal scopeAllocated=sumNullable(objects.stream().map(CostObject::allocatedOutputCostLocal).toList());
        boolean pending=objects.stream().anyMatch(CostObject::pending)||outputs.stream().anyMatch(OutputLine::pending)||outputs.isEmpty();
        BigDecimal unit=!pending&&outputAmount!=null&&outputQty!=null&&outputQty.signum()>0?outputAmount.divide(outputQty,12,RoundingMode.HALF_UP):null;
        Summary summary=new Summary(sumNullable(objects.stream().map(CostObject::knownInputCostLocal).toList()),outputs.isEmpty()?null:outputAmount,
                scopeAllocated,scopeAllocated==null||outputAmount==null?null:scopeAllocated.subtract(outputAmount),
                sumNullable(objects.stream().map(CostObject::heldWipLocal).toList()),sumNullable(objects.stream().map(CostObject::pendingReallocationLocal).toList()),
                sumNullable(objects.stream().map(CostObject::unclassifiedLocal).toList()),outputQty,unit,pending,false,"INVENTORY_PRODUCTION_COST_ONLY",inputs.stream().filter(InputLine::pending).count());
        return result(query,summary,objects,inputs,outputs,revisions,gaps);
    }

    private static InputLine input(Map<String,Object> row) {
        BigDecimal gross=decimal(row,"gross_qty"),returned=decimal(row,"returned_qty"),basis=decimal(row,"basis_value");
        boolean legacy=!"EXACT_SOURCE_SHARES".equals(text(row,"value_model"));
        boolean evidenceMissing=gross==null||returned==null||basis==null||row.get("value_revision")==null||row.get("pending_parents")==null;
        BigDecimal amount=legacy||evidenceMissing?null:basis.subtract(gross.signum()==0?BigDecimal.ZERO:basis.multiply(returned).divide(gross,4,RoundingMode.HALF_UP));
        BigDecimal allocated=decimal(row,"allocated");
        String kind=text(row,"input_kind");
        String quantityBasis="PERIODIC_MATERIAL".equals(kind)?"PERIODIC_ALLOCATION":"CONFIRMED_PROCESSING_FEE".equals(kind)?"FEE_EVIDENCE":"DIRECT_CONSUMPTION";
        return new InputLine(uuid(row,"cost_object_id"),uuid(row,"revision_id"),uuid(row,"input_node_id"),number(row,"value_revision"),uuid(row,"approved_posting_id"),kind,quantityBasis,
                uuid(row,"goods_id"),text(row,"goods_code"),text(row,"goods_name"),uuid(row,"unit_id"),text(row,"unit_name"),uuid(row,"warehouse_id"),uuid(row,"color_id"),
                gross,returned,gross==null||returned==null?null:gross.subtract(returned),amount,allocated,amount==null||allocated==null?null:amount.subtract(allocated),returned!=null&&returned.signum()==0?decimal(row,"exact_lower"):null,returned!=null&&returned.signum()==0?decimal(row,"exact_upper"):null,
                legacy?"LEGACY_UNVERIFIED":"VALUATION_BOOKED_LOCAL",text(row,"source_doc_type"),uuid(row,"source_doc_id"),uuid(row,"source_item_id"),time(row,"occurred_at"),legacy||evidenceMissing||!bool(row,"identity_complete")||number(row,"pending_parents")>0,number(row,"value_revision")>1);
    }
    private static OutputLine output(Map<String,Object> row) {
        boolean withdrawn=uuid(row,"withdrawn_movement_id")!=null;
        return new OutputLine(uuid(row,"cost_object_id"),uuid(row,"revision_id"),uuid(row,"source_node_id"),number(row,"value_revision"),uuid(row,"movement_id"),uuid(row,"withdrawn_movement_id"),uuid(row,"warehouse_id"),uuid(row,"color_id"),date(row,"business_date"),text(row,"source_doc_type"),uuid(row,"source_doc_id"),uuid(row,"source_item_id"),decimal(row,"qty_base"),withdrawn?BigDecimal.ZERO:decimal(row,"qty_base"),withdrawn?BigDecimal.ZERO:decimal(row,"amount"),withdrawn,bool(row,"pending"),number(row,"value_revision")>1);
    }
    static BigDecimal sumNullable(List<BigDecimal> amounts) { return amounts.stream().filter(Objects::nonNull).reduce(BigDecimal::add).orElse(null); }
    private static ActualCostSnapshot result(Query query,Summary summary,List<CostObject> objects,List<InputLine> inputs,List<OutputLine> outputs,List<Revision> revisions,List<Gap> gaps) {
        return new ActualCostSnapshot(query.goodsId(),OffsetDateTime.now(),"LOCAL","PHYSICAL_OUTPUT_BUSINESS_DATE","FULL_ORIGINAL_COST_OBJECT",query,summary,List.copyOf(objects),List.copyOf(inputs),List.copyOf(outputs),List.copyOf(revisions),List.copyOf(gaps));
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED,message); }
    private static UUID uuid(Map<String,Object> row,String key) { Object value=row.get(key);return value==null?null:value instanceof UUID id?id:UUID.fromString(value.toString()); }
    private static String text(Map<String,Object> row,String key) { Object value=row.get(key);return value==null?null:value.toString(); }
    private static BigDecimal decimal(Map<String,Object> row,String key) { Object value=row.get(key);return value==null?null:value instanceof BigDecimal amount?amount:new BigDecimal(value.toString()); }
    private static long number(Map<String,Object> row,String key) { Object value=row.get(key);return value==null?0:((Number)value).longValue(); }
    private static boolean bool(Map<String,Object> row,String key) { return Boolean.TRUE.equals(row.get(key)); }
    private static OffsetDateTime time(Map<String,Object> row,String key) { Object value=row.get(key);return value==null?null:value instanceof OffsetDateTime time?time:((java.sql.Timestamp)value).toInstant().atOffset(java.time.ZoneOffset.UTC); }
    private static LocalDate date(Map<String,Object> row,String key) { Object value=row.get(key);return value==null?null:value instanceof LocalDate date?date:((java.sql.Date)value).toLocalDate(); }
}
