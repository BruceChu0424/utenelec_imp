package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.*;
import com.uten.imp.application.port.InventoryPositionPort.*;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.stock.StockService.MovementRequest;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;
import static com.uten.imp.features.stock.valuation.InventoryBusinessValueSupport.*;

/** Exact material ISSUE facts are the common source for physical returns and confirmed consumption. */
@Service
@Transactional(propagation=Propagation.MANDATORY)
public class ProductionInventoryValueService implements ProductionCostTargetPort {
    private final NamedParameterJdbcTemplate db;
    private final InventoryPositionPort positions;
    private final InventoryProductionCostPort production;
    private final InventoryMutationLock mutex;
    private final InventoryBusinessValueSupport support;
    public ProductionInventoryValueService(NamedParameterJdbcTemplate db,InventoryPositionPort positions,
            InventoryProductionCostPort production,InventoryMutationLock mutex,InventoryBusinessValueSupport support){
        this.db=db;this.positions=positions;this.production=production;this.mutex=mutex;this.support=support;
    }
    /** Resolve only through the immutable split proof; never infer a cost pool from a plan or goods match. */
    public UUID costScope(UUID segment) {
        UUID scope=db.queryForObject("SELECT fn_production_execution_cost_scope(:segment)",Map.of("segment",segment),UUID.class);
        if(scope==null)throw conflict("生产成本缺少有效的原工单或分批来源证明");
        return scope;
    }
    @Override public void targetChangedByReport(UUID reportId,UUID actor){
        db.update("""
                UPDATE stock_value_production_cost_objects object
                SET business_refresh_event_id=:report,business_refresh_actor_id=:actor,business_refresh_pending=true
                WHERE object.source_kind='PRODUCTION_EXECUTION' AND EXISTS(
                    SELECT 1 FROM production_daily_reports report
                    JOIN production_daily_report_items item ON item.report_id=report.id
                    JOIN production_execution_segments segment ON segment.id=item.execution_segment_id
                    JOIN production_execution_segments cost_root ON cost_root.id=fn_production_execution_cost_scope(segment.id)
                    LEFT JOIN stock_value_production_cost_revisions revision ON revision.id=object.current_revision_id
                    WHERE report.id=:report AND report.status IN(1,-1) AND NOT report.is_deleted
                        AND (item.is_final OR item.is_actual_surplus) AND NOT item.is_deleted
                        AND cost_root.id=object.execution_segment_id
                        AND (revision.id IS NULL OR revision.target_qty_base<>fn_production_execution_cost_target(cost_root.id)))
                """,Map.of("report",reportId,"actor",actor));
    }
    public void bound(UUID event,Map<UUID,UUID> movements){
        for(var movement:movements.entrySet()){
            var postings=db.queryForList("""
                    SELECT p.*,e.event_type,e.stock_document_id FROM production_material_stock_postings p
                    JOIN production_material_stock_events e ON e.id=p.event_id
                    WHERE p.event_id=:event AND p.stock_document_item_id=:item ORDER BY p.id
                    """,Map.of("event",event,"item",movement.getKey()));
            for(var p:postings){
                String kind=(String)p.get("posting_type");
                if(!Set.of("ISSUE","GOOD_RETURN_REVERSE").contains(kind))continue;
                UUID posting=(UUID)p.get("id");
                if(has("PRODUCTION_ISSUE_VALUE",posting))continue;
                if("GOOD_RETURN_REVERSE".equals(kind)){
                    var restored=db.queryForList("""
                            SELECT value.id FROM stock_value_events value
                            WHERE value.movement_id=:movement AND value.operation='POSITION_STORE_REVERSE'
                            """,Map.of("movement",movement.getValue()),UUID.class);
                    if(!restored.isEmpty()){
                        UUID originalIssue=db.queryForObject("SELECT source_posting_id FROM production_material_stock_postings WHERE id=:id",
                                Map.of("id",p.get("source_posting_id")),UUID.class);
                        BigDecimal qty=db.queryForObject("""
                                SELECT COALESCE(SUM(transfer.qty_base),0) FROM stock_value_position_transfers transfer
                                JOIN stock_value_nodes restored ON restored.id=transfer.target_node_id
                                WHERE transfer.event_id=:event AND restored.owner_kind='WIP' AND restored.owner_id=:issue
                                """,Map.of("event",restored.getFirst(),"issue",originalIssue),BigDecimal.class);
                        if(qty.compareTo((BigDecimal)p.get("qty_base"))!=0)throw conflict("退料红冲价值未精确恢复原领料来源");
                        continue;
                    }
                }
                var nodes=db.queryForList("SELECT result_node_id FROM stock_value_events WHERE movement_id=:id AND operation='ISSUE'",Map.of("id",movement.getValue()),UUID.class);
                if(nodes.size()!=1)throw conflict("实际领料流水尚无唯一成本来源");
                var source=positions.position(nodes.getFirst());
                UUID owner=posting;
                if("GOOD_RETURN_REVERSE".equals(kind))owner=db.queryForObject("SELECT source_posting_id FROM production_material_stock_postings WHERE id=:id",Map.of("id",p.get("source_posting_id")),UUID.class);
                positions.move(new Move(support.context("PRODUCTION_ISSUE_VALUE",posting,event,posting,(UUID)p.get("created_by"),time(p.get("created_at"))),
                        source.pool(),Owner.WIP,owner,List.of(new Slice(source.rootId(),(BigDecimal)p.get("qty_base"),posting))));
            }
        }
    }
    public MovementValue returned(MovementRequest request,UUID movement,PoolKey pool,BigDecimal before,EventContext context){
        UUID originalItem=request.movementType()==5?request.sourceItemId():db.queryForObject(
                "SELECT upstream_item_id FROM stock_document_items WHERE id=:id",Map.of("id",request.sourceItemId()),UUID.class);
        if(originalItem==null)throw conflict("生产退料缺少原领料明细");
        BigDecimal left=request.qty();List<Slice> sources=new ArrayList<>();
        var requested=db.queryForList("SELECT issue_posting_id FROM production_material_return_request_items WHERE stock_document_item_id=:item AND issue_posting_id IS NOT NULL",
                Map.of("item",request.sourceItemId()),UUID.class);
        Map<String,Object> sourceArgs=new HashMap<>();sourceArgs.put("item",originalItem);sourceArgs.put("exactIssue",requested.isEmpty()?null:requested.getFirst());
        for(var issue:db.queryForList("""
                SELECT id,fn_material_issue_unsettled(id) qty FROM production_material_stock_postings
                WHERE stock_document_item_id=:item AND posting_type='ISSUE' AND fn_material_issue_unsettled(id)>0
                  AND (CAST(:exactIssue AS uuid) IS NULL OR id=CAST(:exactIssue AS uuid))
                ORDER BY created_at,id
                """,sourceArgs)){
            if(left.signum()==0)break;
            BigDecimal qty=left.min((BigDecimal)issue.get("qty"));
            sources.addAll(takeIssue((UUID)issue.get("id"),qty));left=left.subtract(qty);
        }
        if(left.signum()!=0)throw conflict("本次退料超过原领料未耗用数量");
        return positions.store(new Store(context,movement,pool,before,sources));
    }

    public MovementValue workshopReturn(MovementRequest request,UUID movement,PoolKey pool,BigDecimal before,
            EventContext context,InventoryMovementCostReference.WorkshopReturn ref,InventoryValuationPort values){
        var rows=db.queryForList("""
                SELECT item.issue_posting_id,item.direct_transfer_item_id,item.qty_base,
                       request.warehouse_id AS source_warehouse,document.warehouse_id AS received_warehouse,
                       line.goods_id,line.color_id
                FROM production_material_return_request_items item
                JOIN production_material_return_requests request ON request.id=item.request_id
                JOIN stock_document_items line ON line.id=item.stock_document_item_id
                JOIN stock_documents document ON document.id=item.request_id AND document.doc_type='WDRAW'
                WHERE item.id=:requestItem AND item.stock_document_item_id=:item AND item.request_id=:doc
                """,Map.of("requestItem",ref.requestItemId(),"item",request.sourceItemId(),"doc",request.sourceDocId()));
        if(rows.size()!=1||ref.kind()==null)throw conflict("车间退仓价值缺少唯一真实申请明细");
        var row=rows.getFirst();boolean direct=row.get("direct_transfer_item_id")!=null;
        boolean directKind=ref.kind().name().startsWith("DIRECT_");
        boolean sourceLeg=ref.kind()==InventoryMovementCostReference.WorkshopReturnKind.DIRECT_OUT
                ||ref.kind()==InventoryMovementCostReference.WorkshopReturnKind.DIRECT_OUT_REVERSE;
        short expectedType=switch(ref.kind()) {
            case RETURN_IN,RETURN_REVERSE -> 6;
            case DIRECT_OUT,DIRECT_OUT_REVERSE -> 8;
            case DIRECT_IN,DIRECT_IN_REVERSE -> 7;
        };
        short expectedDirection=switch(ref.kind()) {
            case RETURN_IN,DIRECT_IN,DIRECT_OUT_REVERSE -> 1;
            case DIRECT_OUT,RETURN_REVERSE,DIRECT_IN_REVERSE -> -1;
        };
        if(direct!=directKind||request.qty().compareTo((BigDecimal)row.get("qty_base"))!=0
                ||request.movementType()!=expectedType||request.direction()!=expectedDirection
                ||!"STOCK_DOC".equals(request.sourceDocType())
                ||!Objects.equals(pool.goodsId(),row.get("goods_id"))||!Objects.equals(pool.colorId(),row.get("color_id"))
                ||!Objects.equals(pool.warehouseId(),row.get(sourceLeg?"source_warehouse":"received_warehouse")))
            throw conflict("退仓价值的原来源、实际仓与基本量不一致");
        return switch(ref.kind()){
            case RETURN_IN -> returned(request,movement,pool,before,context);
            case DIRECT_OUT -> values.issue(new Issue(context,movement,pool,request.qty(),before,Destination.IN_TRANSIT,request.sourceItemId()));
            case DIRECT_IN -> {
                var roots=db.queryForList("""
                        SELECT result_node_id FROM stock_value_events WHERE movement_id=:movement AND operation='ISSUE'
                          AND source_doc_type='STOCK_DOC' AND source_doc_id=:doc AND source_item_id=:item
                        """,Map.of("movement",Objects.requireNonNull(ref.linkedMovementId()),"doc",request.sourceDocId(),"item",request.sourceItemId()),UUID.class);
                if(roots.size()!=1)throw conflict("移入正常仓必须保留本次真实技术位移出价值UUID");
                var original=positions.position(roots.getFirst());
                if(original.owner()!=Owner.IN_TRANSIT||!Objects.equals(original.ownerId(),request.sourceItemId()))
                    throw conflict("技术位移出价值不属于本次退仓");
                yield positions.store(new Store(context,movement,pool,before,List.of(new Slice(roots.getFirst(),request.qty(),ref.requestItemId()))));
            }
            case RETURN_REVERSE,DIRECT_IN_REVERSE -> {
                Integer count=db.queryForObject("""
                        SELECT count(*) FROM stock_value_events WHERE movement_id=:movement AND operation='POSITION_STORE'
                          AND source_doc_type='STOCK_DOC' AND source_doc_id=:doc AND source_item_id=:item
                        """,Map.of("movement",Objects.requireNonNull(ref.linkedMovementId()),"doc",request.sourceDocId(),"item",request.sourceItemId()),Integer.class);
                if(count==null||count!=1)throw conflict("退仓撤回缺少原正常仓实收的精确成本来源");
                yield positions.reverseMaterialStore(new ReverseStore(context,movement,pool,before,ref.linkedMovementId()));
            }
            case DIRECT_OUT_REVERSE -> {
                var parts=db.queryForList("""
                        SELECT transfer.target_node_id,transfer.qty_base,transfer.source_slice_id
                        FROM stock_value_events reversed JOIN stock_value_position_transfers transfer ON transfer.event_id=reversed.id
                        JOIN stock_value_nodes restored ON restored.id=transfer.target_node_id
                        WHERE reversed.movement_id=:movement AND reversed.operation='POSITION_STORE_REVERSE'
                          AND reversed.source_doc_type='STOCK_DOC' AND reversed.source_doc_id=:doc AND reversed.source_item_id=:item
                          AND restored.owner_kind='IN_TRANSIT' AND restored.owner_id=:item
                        ORDER BY transfer.id
                        """,Map.of("movement",Objects.requireNonNull(ref.linkedMovementId()),"doc",request.sourceDocId(),"item",request.sourceItemId()));
                List<Slice> slices=parts.stream().map(part->new Slice((UUID)part.get("target_node_id"),(BigDecimal)part.get("qty_base"),(UUID)part.get("source_slice_id"))).toList();
                if(slices.stream().map(Slice::qtyBase).reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(request.qty())!=0)
                    throw conflict("正常仓反向价值未完整恢复到原移出切片");
                yield positions.store(new Store(context,movement,pool,before,slices));
            }
        };
    }
    public void settled(UUID event,UUID actor){
        var postings=db.queryForList("""
                SELECT p.*,d.execution_segment_id FROM production_material_settlement_postings p
                JOIN production_material_demands d ON d.id=p.demand_id WHERE p.event_id=:id ORDER BY p.id
                """,Map.of("id",event));
        Set<UUID> segments=new LinkedHashSet<>();
        for(var row:postings){
            UUID posting=(UUID)row.get("id"),issue=(UUID)row.get("issue_posting_id"),segment=(UUID)row.get("execution_segment_id");
            if(segment==null)throw conflict("旧物料清账尚无明确执行段，不能猜测成品成本");
            segment=costScope(segment);
            if("LEGAL_WIP".equals(row.get("settlement_type")))continue;
            if(row.get("source_posting_id")!=null){
                var original=db.queryForMap("""
                        SELECT event.result_node_id,posting.qty_base FROM stock_value_events event
                        JOIN production_material_settlement_postings posting ON posting.id=event.source_event_id
                        WHERE event.source_doc_type='PRODUCTION_CONSUMED_VALUE' AND posting.id=:id
                        """,Map.of("id",row.get("source_posting_id")));
                var originalPosition=positions.position((UUID)original.get("result_node_id"));
                mutex.lock(new InventoryKey(originalPosition.pool().goodsId(),originalPosition.pool().colorId()));
                positions.returnConsumed(new ReturnConsumed(support.context("PRODUCTION_CONSUMED_REVERSE",posting,event,posting,actor,time(row.get("created_at"))),
                        originalPosition.pool(),originalPosition.rootId(),(BigDecimal)row.get("qty_base"),Owner.WIP,issue));
                segments.add(segment);
                continue;
            }
            if(has("PRODUCTION_CONSUMED_VALUE",posting))continue;
            var sources=takeIssue(issue,(BigDecimal)row.get("qty_base"));
            var source=positions.position(sources.getFirst().positionRootId());
            mutex.lock(new InventoryKey(source.pool().goodsId(),source.pool().colorId()));
            positions.move(new Move(support.context("PRODUCTION_CONSUMED_VALUE",posting,event,posting,actor,time(row.get("created_at"))),
                    source.pool(),Owner.COST_WIP,segment,sources));
            segments.add(segment);
        }
        for(UUID segment:segments)refresh(segment,event,actor);
    }
    public void refresh(UUID segment,UUID event,UUID actor){
        segment=costScope(segment);
        var objects=db.queryForList("""
                SELECT object.version,object.state,p.warehouse_id,p.goods_id,p.color_id,fn_production_execution_cost_target(segment.id) target,
                       segment.bom_fingerprint,segment.lock_version,segment.updated_at
                FROM stock_value_production_cost_objects object JOIN stock_value_pools p ON p.id=object.product_pool_id
                JOIN production_execution_segments segment ON segment.id=object.execution_segment_id
                WHERE object.execution_segment_id=:id
                """,Map.of("id",segment));
        if(objects.isEmpty())return; // Physical output registration later discovers the durable consumed positions.
        var object=objects.getFirst();PoolKey product=pool(object);
        var rows=db.queryForList("""
                SELECT e.result_node_id,p.id,p.settlement_type,pool.goods_id,pool.color_id
                FROM production_material_settlement_postings p
                JOIN production_material_demands demand ON demand.id=p.demand_id
                JOIN stock_value_events e ON e.source_event_id=p.id AND e.source_doc_type='PRODUCTION_CONSUMED_VALUE'
                JOIN stock_value_nodes n ON n.id=e.result_node_id JOIN stock_value_pools pool ON pool.id=n.pool_id
                WHERE demand.execution_segment_id IN (SELECT segment_id FROM fn_production_execution_cost_members(:id))
                    AND n.active AND NOT EXISTS(
                    SELECT 1 FROM stock_value_production_cost_inputs i WHERE i.approved_posting_id=p.id)
                ORDER BY p.id LIMIT 100
                """,Map.of("id",segment));
        List<InventoryKey> keys=new ArrayList<>();keys.add(new InventoryKey(product.goodsId(),product.colorId()));
        rows.forEach(row->keys.add(new InventoryKey((UUID)row.get("goods_id"),(UUID)row.get("color_id"))));mutex.lockAll(keys);
        db.update("UPDATE stock_value_production_cost_objects SET business_refresh_event_id=:event,business_refresh_actor_id=:actor,business_refresh_pending=true WHERE execution_segment_id=:segment",
                Map.of("event",event,"actor",actor,"segment",segment));
        if("APPLYING".equals(object.get("state")))return;
        var inputs=rows.stream().map(row->new InventoryProductionCostPort.Input((UUID)row.get("result_node_id"),(UUID)row.get("id"),
                "CONSUMED".equals(row.get("settlement_type"))?InventoryProductionCostPort.InputKind.CONSUMED:InventoryProductionCostPort.InputKind.NORMAL_LOSS)).toList();
        boolean complete=Boolean.TRUE.equals(db.queryForObject("""
                SELECT NOT EXISTS(SELECT 1 FROM v_production_material_clearance clearance
                    JOIN production_material_demands demand ON demand.id=clearance.demand_id
                    WHERE demand.execution_segment_id IN (SELECT segment_id FROM fn_production_execution_cost_members(:id))
                        AND (clearance.uncleared_qty<>0 OR clearance.legal_wip_qty<>0))
                AND NOT EXISTS(SELECT 1 FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
                    WHERE item.execution_segment_id IN (SELECT segment_id FROM fn_production_execution_cost_members(:id))
                        AND report.status=1 AND NOT item.is_deleted AND NOT report.is_deleted
                        AND NOT EXISTS(SELECT 1 FROM production_fqc_legacy_exemptions exempt WHERE exempt.source_report_item_id=item.id)
                        AND (item.qty>coalesce((SELECT sum(inspection.passed_qty+inspection.failed_qty) FROM production_fqc_inspections inspection
                                WHERE inspection.source_report_item_id=item.id AND inspection.status<>'CANCELLED'),0)
                            OR EXISTS(SELECT 1 FROM production_fqc_inspections inspection WHERE inspection.source_report_item_id=item.id
                                AND inspection.status<>'CANCELLED' AND inspection.failed_qty>0)))
                AND ((NOT EXISTS(SELECT 1 FROM production_execution_segment_splits split WHERE split.source_segment_id=:id)
                      AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs proof
                          WHERE fn_production_execution_cost_scope(proof.source_execution_segment_id)=:id
                            AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id)))
                    OR (SELECT COALESCE(sum(output.qty_base),0) FROM stock_value_production_cost_outputs output
                        WHERE output.execution_segment_id=:id AND output.withdrawn_movement_id IS NULL)
                       =fn_production_execution_cost_target(:id))
                """,Map.of("id",segment),Boolean.class));
        UUID sourceItem=rows.isEmpty()?segment:(UUID)rows.getFirst().get("id");
        EventContext sourceContext=support.context("PRODUCTION_COST_BUSINESS",event,segment,sourceItem,actor,time(object.get("updated_at")));
        UUID approval=segment;String approvalHash=(String)object.get("bom_fingerprint");
        var reports=db.queryForList("SELECT status,updated_at FROM production_daily_reports WHERE id=:id AND status IN(1,-1) AND NOT is_deleted",Map.of("id",event));
        if(!reports.isEmpty()){
            var report=reports.getFirst();UUID phase=UUID.nameUUIDFromBytes(("PRODUCTION_TARGET_REPORT:"+event+":"+report.get("status")+":"+segment)
                    .getBytes(java.nio.charset.StandardCharsets.UTF_8));
            sourceContext=support.context("PRODUCTION_TARGET_REPORT",phase,segment,event,actor,time(report.get("updated_at")));
            approval=event;approvalHash=hash("PRODUCTION_REPORT_TARGET|"+event+"|"+report.get("status")+"|"+segment+"|"+object.get("target")+"|"+object.get("lock_version"));
        } else {
            var supplement=db.queryForList("""
                    SELECT id,created_at,'APPROVED' AS phase FROM production_actual_output_supplement_proofs WHERE id=:event
                    UNION ALL
                    SELECT id,created_at,'REVERSED' AS phase FROM production_actual_output_supplement_reversals WHERE id=:event
                    """,Map.of("event",event));
            if(!supplement.isEmpty()) {
                var evidence=supplement.getFirst();
                sourceContext=support.context("PRODUCTION_TARGET_SUPPLEMENT",event,segment,event,actor,time(evidence.get("created_at")));
                approval=event;
                approvalHash=hash("PRODUCTION_SUPPLEMENT_TARGET|"+event+"|"+evidence.get("phase")+"|"+segment+"|"+object.get("target")+"|"+object.get("lock_version"));
            }
        }
        production.revise(new InventoryProductionCostPort.Revision(sourceContext,
                segment,product,((Number)object.get("version")).longValue(),(BigDecimal)object.get("target"),complete,
                approval,approvalHash,inputs,List.of()));
        db.update("""
                UPDATE stock_value_production_cost_objects SET business_refresh_pending=EXISTS(
                    SELECT 1 FROM production_material_settlement_postings posting
                    JOIN production_material_demands demand ON demand.id=posting.demand_id
                    JOIN stock_value_events cost ON cost.source_event_id=posting.id AND cost.source_doc_type='PRODUCTION_CONSUMED_VALUE'
                    JOIN stock_value_nodes node ON node.id=cost.result_node_id
                    WHERE demand.execution_segment_id IN (SELECT segment_id FROM fn_production_execution_cost_members(:segment))
                        AND node.active AND NOT EXISTS(
                        SELECT 1 FROM stock_value_production_cost_inputs input WHERE input.approved_posting_id=posting.id))
                WHERE execution_segment_id=:segment AND business_refresh_event_id=:event
                """,
                Map.of("segment",segment,"event",event));
    }
    private List<Slice> takeIssue(UUID issue,BigDecimal qty){
        BigDecimal left=qty;List<Slice> result=new ArrayList<>();
        for(var row:db.queryForList("""
                SELECT root.id,head.range_to-head.range_from qty FROM stock_value_nodes root
                JOIN stock_value_nodes head ON head.id=root.return_head_id
                WHERE root.root_issue_id=root.id AND head.owner_kind='WIP' AND head.owner_id=:issue
                    AND head.range_to>head.range_from ORDER BY root.created_at,root.id
                """,Map.of("issue",issue))){
            if(left.signum()==0)break;BigDecimal take=left.min((BigDecimal)row.get("qty"));
            result.add(new Slice((UUID)row.get("id"),take,(UUID)row.get("id")));left=left.subtract(take);
        }
        if(left.signum()!=0)throw conflict("原领料切片缺少足额未耗用成本位置");
        return result.size()==1?List.of(new Slice(result.getFirst().positionRootId(),qty,issue)):result;
    }
    private boolean has(String type,UUID event){return Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_events WHERE source_doc_type=:type AND source_event_id=:id)",Map.of("type",type,"id",event),Boolean.class));}
    private static String hash(String value){
        try{return java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(value.getBytes(java.nio.charset.StandardCharsets.UTF_8)));}
        catch(java.security.NoSuchAlgorithmException impossible){throw new IllegalStateException(impossible);}
    }
}
