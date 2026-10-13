package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.*;
import com.uten.imp.application.port.InventoryPositionPort.*;
import com.uten.imp.application.port.InventoryProductionCostPort.*;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.stock.StockService.MovementRequest;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;
import static com.uten.imp.features.stock.valuation.InventoryBusinessValueSupport.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;

/** Company materials retain their issued cost roots; supplier consideration is a separate source. */
@Service
@Transactional(propagation=Propagation.MANDATORY)
public class SubcontractOwnMaterialCostService implements com.uten.imp.application.port.SubcontractMaterialReversalValuePort {
    private final NamedParameterJdbcTemplate db;
    private final InventoryPositionPort positions;
    private final InventoryProductionCostPort costs;
    private final InventoryMutationLock mutex;
    private final InventoryBusinessValueSupport support;
    private final SubcontractLossValueService losses;
    private InventoryValuationPort values;
    @org.springframework.beans.factory.annotation.Autowired
    public void setValuePropagation(InventoryValuationPort values){this.values=values;}

    public SubcontractOwnMaterialCostService(NamedParameterJdbcTemplate db,InventoryPositionPort positions,
            InventoryProductionCostPort costs,InventoryMutationLock mutex,InventoryBusinessValueSupport support,SubcontractLossValueService losses){
        this.db=db;this.positions=positions;this.costs=costs;this.mutex=mutex;this.support=support;
        this.losses=losses;
    }

    public void receiptApproved(UUID receipt,UUID actor){
        var rows=consumptions(receipt);lockSources(rows);
        for(var row:rows){
            UUID fact=(UUID)row.get("id");if(result("SUBCONTRACT_RECEIPT_MATERIAL",fact)!=null)continue;
            var sources=take(Owner.SUBCONTRACT_WIP,(UUID)row.get("issue_item_id"),(BigDecimal)row.get("qty_base"));
            var source=positions.position(sources.getFirst().positionRootId());
            positions.move(new Move(context("SUBCONTRACT_RECEIPT_MATERIAL",fact,receipt,actor),source.pool(),
                    Owner.SUBCONTRACT_WIP,fact,sources));
        }
    }

    public void receiptReversed(UUID receipt,UUID actor){
        var rows=consumptions(receipt);lockSources(rows);
        for(var row:rows){
            UUID fact=(UUID)row.get("id");if(result("SUBCONTRACT_RECEIPT_MATERIAL_REVERSE",fact)!=null)continue;
            UUID root=result("SUBCONTRACT_RECEIPT_MATERIAL",fact);
            if(root==null)throw conflict("原回厂尚无实际发料成本关联，请先核对原来源");
            var sources=take(Owner.SUBCONTRACT_WIP,fact,(BigDecimal)row.get("qty_base"));
            positions.move(new Move(context("SUBCONTRACT_RECEIPT_MATERIAL_REVERSE",fact,receipt,actor),positions.position(root).pool(),
                    Owner.SUBCONTRACT_WIP,(UUID)row.get("issue_item_id"),sources));
        }
    }

    @Transactional(propagation=Propagation.MANDATORY,readOnly=true,noRollbackFor=com.uten.imp.common.web.ApiException.class)
    public String requireUnstoredReceiptReversible(UUID receipt){
        var facts=new ArrayList<String>();
        for(var row:consumptions(receipt)){
            UUID fact=(UUID)row.get("id");if(result("SUBCONTRACT_RECEIPT_MATERIAL_REVERSE",fact)!=null)continue;
            UUID root=result("SUBCONTRACT_RECEIPT_MATERIAL",fact);
            if(root==null)throw conflict("原回厂尚无实际发料成本关联，请先核对原来源");
            var pool=positions.position(root).pool();
            facts.add(positions.requireMoveSourcesAvailable(pool,Owner.SUBCONTRACT_WIP,(UUID)row.get("issue_item_id"),take(Owner.SUBCONTRACT_WIP,fact,(BigDecimal)row.get("qty_base"))));
        }
        return com.uten.imp.common.util.CanonicalFingerprint.sha256(facts);
    }

    private record UnusedReceiptPlan(List<Map<String,Object>> scopes,List<UUID> scopeIds,List<Map<String,Object>> materials,boolean prepared){}
    private UnusedReceiptPlan readUnusedReceiptPlan(UUID receipt,boolean lock){
        var scopes=db.queryForList("""
                SELECT DISTINCT object.execution_segment_id,object.product_pool_id,p.goods_id,p.color_id
                FROM stock_value_production_cost_objects object
                JOIN subcontract_receipt_items item ON item.id=object.execution_segment_id AND item.receipt_id=:receipt
                JOIN stock_value_pools p ON p.id=object.product_pool_id
                WHERE object.source_kind='SUBCONTRACT_RECEIPT_ITEM' ORDER BY object.execution_segment_id
                """,Map.of("receipt",receipt));
        if(scopes.isEmpty())throw conflict("委外回厂缺少独立的自有材料成本批次，不能直接按供应商费用撤回");
        var scopeIds=scopes.stream().map(row->(UUID)row.get("execution_segment_id")).toList();
        boolean prepared=Boolean.TRUE.equals(db.queryForObject("""
                SELECT NOT EXISTS(SELECT 1 FROM stock_value_production_cost_objects object WHERE object.execution_segment_id IN(:ids)
                    AND NOT EXISTS(SELECT 1 FROM stock_value_production_cost_revisions revision
                        WHERE revision.execution_segment_id=object.execution_segment_id AND revision.source_doc_type='SUBCONTRACT_RECEIPT_COST_REVERSE'
                            AND revision.source_doc_id=:receipt))
                """,Map.of("ids",scopeIds,"receipt",receipt),Boolean.class));
        if(prepared)return new UnusedReceiptPlan(scopes,scopeIds,consumptions(receipt),true);
        var materials=consumptions(receipt);List<InventoryKey> keys=new ArrayList<>();
        materials.forEach(row->keys.add(new InventoryKey((UUID)row.get("goods_id"),(UUID)row.get("color_id"))));
        scopes.forEach(row->keys.add(new InventoryKey((UUID)row.get("goods_id"),(UUID)row.get("color_id"))));if(lock)mutex.lockAll(keys);
        var stored=db.queryForList("""
                SELECT event.id,event.pool_id,event.result_head_id,pool.head_node_id
                FROM procurement_iqc_stock_in_batch_items item JOIN procurement_inspection_items inspection ON inspection.id=item.inspection_item_id
                JOIN stock_value_events event ON event.movement_id=item.stock_movement_id AND event.operation='POSITION_STORE'
                JOIN stock_value_nodes head ON head.id=event.result_head_id JOIN stock_value_pools pool ON pool.id=event.pool_id
                WHERE inspection.receipt_type='SUBCONTRACT' AND inspection.receipt_id=:receipt ORDER BY head.node_sequence DESC
                """,Map.of("receipt",receipt));
        Map<UUID,UUID> expectedHeads=new HashMap<>();
        for(var stock:stored){
            UUID pool=(UUID)stock.get("pool_id"),head=expectedHeads.containsKey(pool)?expectedHeads.get(pool):(UUID)stock.get("head_node_id");
            if(head==null||!Boolean.TRUE.equals(db.queryForObject("SELECT fn_stock_value_unused_receipt_head(:current,:original)",
                    Map.of("current",head,"original",stock.get("result_head_id")),Boolean.class)))
                throw conflict("该委外回厂之后已有出库、领用或其它未撤回入库，请先处理真实下游");
            var previous=db.queryForList("""
                    SELECT parent.id FROM stock_value_edges edge JOIN stock_value_nodes parent ON parent.id=edge.parent_node_id
                    WHERE edge.child_node_id=:head AND parent.kind='POOL'
                    """,Map.of("head",stock.get("result_head_id")),UUID.class);
            if(previous.size()>1)throw conflict("原委外回厂前置库存来源不唯一");expectedHeads.put(pool,previous.isEmpty()?null:previous.getFirst());
        }
        if(Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_outputs output
                    JOIN stock_value_events event ON event.movement_id=output.movement_id
                    JOIN procurement_iqc_stock_in_batch_items stock ON stock.stock_movement_id=output.movement_id
                    JOIN procurement_inspection_items inspection ON inspection.id=stock.inspection_item_id
                    WHERE output.execution_segment_id IN(:ids) AND inspection.receipt_id<>:receipt)
                OR EXISTS(SELECT 1 FROM stock_value_production_cost_outputs output
                    JOIN stock_value_production_cost_objects object ON object.execution_segment_id=output.execution_segment_id
                    JOIN procurement_iqc_stock_in_batch_items stock ON stock.stock_movement_id=output.movement_id
                    JOIN procurement_inspection_items inspection ON inspection.id=stock.inspection_item_id
                    WHERE inspection.receipt_id=:receipt AND object.source_kind='SUBCONTRACT_ORDER_NORMAL_LOSS'
                        AND EXISTS(SELECT 1 FROM stock_value_production_cost_inputs input WHERE input.execution_segment_id=object.execution_segment_id))
                """,Map.of("ids",scopeIds,"receipt",receipt),Boolean.class)))
            throw conflict("委外回厂已有跨补回批次或损耗成本归属，请先按专用来源完成更正");
        return new UnusedReceiptPlan(scopes,scopeIds,materials,prepared);
    }
    @Transactional(propagation=Propagation.MANDATORY,readOnly=true,noRollbackFor=com.uten.imp.common.web.ApiException.class)
    public ProcurementInventoryValuePort.CostWithdrawalPreview requireUnusedReceiptReversible(UUID receipt){
        var plan=readUnusedReceiptPlan(receipt,false);
        for(var row:plan.materials()){
            UUID fact=(UUID)row.get("id"),root=result("SUBCONTRACT_CONSUMED_MATERIAL",fact);
            if(root==null||result("SUBCONTRACT_RECEIPT_MATERIAL_UNCONSUME",fact)!=null)continue;
            var position=positions.position(root);
            positions.requireReturnConsumedAvailable(position.pool(),root,(BigDecimal)row.get("qty_base"),Owner.SUBCONTRACT_WIP,fact);
        }
        var pins=db.queryForList("SELECT execution_segment_id,version FROM stock_value_production_cost_objects WHERE execution_segment_id IN(:ids) ORDER BY execution_segment_id",Map.of("ids",plan.scopeIds()))
            .stream().map(row->new ProcurementInventoryValuePort.CostScopePin((UUID)row.get("execution_segment_id"),((Number)row.get("version")).longValue())).toList();
        return new ProcurementInventoryValuePort.CostWithdrawalPreview(receipt,pins,receiptReversalFacts(receipt,plan.scopeIds()));
    }
    private String receiptReversalFacts(UUID receipt,List<UUID> scopeIds){
        String facts=db.queryForObject("""
            SELECT jsonb_build_object(
                'objects',(SELECT jsonb_agg(to_jsonb(object) ORDER BY object.execution_segment_id) FROM stock_value_production_cost_objects object WHERE object.execution_segment_id IN(:ids)),
                'revisions',(SELECT jsonb_agg(to_jsonb(revision) ORDER BY revision.id) FROM stock_value_production_cost_revisions revision WHERE revision.id IN(SELECT current_revision_id FROM stock_value_production_cost_objects WHERE execution_segment_id IN(:ids))),
                'inputs',(SELECT jsonb_agg(jsonb_build_object('input',to_jsonb(input),'node',to_jsonb(node)) ORDER BY input.input_node_id) FROM stock_value_production_cost_inputs input JOIN stock_value_nodes node ON node.id=input.input_node_id WHERE input.execution_segment_id IN(:ids)),
                'outputs',(SELECT jsonb_agg(jsonb_build_object('output',to_jsonb(output),'node',to_jsonb(node),'pool',to_jsonb(pool)) ORDER BY output.source_node_id) FROM stock_value_production_cost_outputs output JOIN stock_value_nodes node ON node.id=output.source_node_id JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE output.execution_segment_id IN(:ids)),
                'shares',(SELECT jsonb_agg(to_jsonb(share) ORDER BY share.input_node_id,share.output_source_node_id) FROM stock_value_production_cost_shares share WHERE share.output_source_node_id IN(SELECT source_node_id FROM stock_value_production_cost_outputs WHERE execution_segment_id IN(:ids))),
                'tasks',(SELECT jsonb_agg(to_jsonb(task) ORDER BY task.id) FROM stock_value_production_cost_tasks task WHERE task.execution_segment_id IN(:ids)),
                'materials',(SELECT jsonb_agg(to_jsonb(material) ORDER BY material.id) FROM subcontract_receipt_material_consumptions material JOIN subcontract_receipt_items item ON item.id=material.receipt_item_id WHERE item.receipt_id=:receipt))::text
            """,Map.of("ids",scopeIds,"receipt",receipt),String.class);
        return com.uten.imp.common.util.CanonicalFingerprint.sha256(List.of(facts));
    }

    /** Withdraw only an unused original receipt; material and supplier fee remain separate. */
    public void prepareUnusedReceiptReversal(UUID receipt,UUID actor){
        UnusedReceiptPlan readiness=readUnusedReceiptPlan(receipt,true);
        if(readiness.prepared())return;
        var scopeIds=readiness.scopeIds();var materials=readiness.materials();
        drainReceiptCost(scopeIds);
        for(var row:materials){
            UUID fact=(UUID)row.get("id"),root=result("SUBCONTRACT_CONSUMED_MATERIAL",fact);
            if(root==null)continue;
            if(result("SUBCONTRACT_RECEIPT_MATERIAL_UNCONSUME",fact)!=null)continue;
            var position=positions.position(root);
            positions.returnConsumed(new ReturnConsumed(context("SUBCONTRACT_RECEIPT_MATERIAL_UNCONSUME",fact,receipt,actor),
                    position.pool(),root,(BigDecimal)row.get("qty_base"),Owner.SUBCONTRACT_WIP,fact));
        }
        for(UUID scope:scopeIds){
            var plan=db.queryForMap("""
                    SELECT object.version,revision.target_qty_base,revision.approval_evidence_id,revision.approval_evidence_hash
                    FROM stock_value_production_cost_objects object JOIN stock_value_production_cost_revisions revision ON revision.id=object.current_revision_id
                    WHERE object.execution_segment_id=:id
                    """,Map.of("id",scope));
            costs.revise(new Revision(context("SUBCONTRACT_RECEIPT_COST_REVERSE",scope,receipt,actor),scope,costs.scope(scope).productPool(),
                    ((Number)plan.get("version")).longValue(),(BigDecimal)plan.get("target_qty_base"),false,
                    (UUID)plan.get("approval_evidence_id"),(String)plan.get("approval_evidence_hash"),List.of(),List.of()));
            db.update("UPDATE stock_value_production_cost_objects SET business_refresh_pending=false WHERE execution_segment_id=:id",Map.of("id",scope));
        }
        drainReceiptCost(scopeIds);
    }

    /** Bounded work for these exact receipt scopes only; unrelated cost jobs are never drained here. */
    private void drainReceiptCost(List<UUID> scopes){
        int budget=5000;
        while(budget-->0){
            var tasks=db.queryForList("SELECT id FROM stock_value_production_cost_tasks WHERE execution_segment_id IN(:ids) AND status='PENDING' ORDER BY task_sequence LIMIT 1",Map.of("ids",scopes),UUID.class);
            if(tasks.isEmpty())break;costs.apply(tasks.getFirst());
        }
        while(budget-->0){
            var tasks=db.queryForList("""
                    SELECT task.id,p.goods_id,p.color_id FROM stock_value_tasks task JOIN stock_value_jobs job ON job.event_id=task.event_id
                    JOIN stock_value_edges edge ON edge.id=task.edge_id JOIN stock_value_nodes node ON node.id=edge.child_node_id
                    JOIN stock_value_pools p ON p.id=node.pool_id
                    WHERE task.status='PENDING' AND EXISTS(SELECT 1 FROM stock_value_production_cost_outputs output
                        WHERE output.source_node_id=job.source_node_id AND output.execution_segment_id IN(:ids))
                    ORDER BY task.task_sequence LIMIT 1
                    """,Map.of("ids",scopes));
            if(tasks.isEmpty())return;
            var task=tasks.getFirst();mutex.requireHeld(new InventoryKey((UUID)task.get("goods_id"),(UUID)task.get("color_id")));
            if(!values.propagate((UUID)task.get("id")).applied())throw conflict("原委外成本尚有前序任务，请先完成原成本处理后重试");
        }
        throw conflict("本收货成本待处理量超过即时撤回范围，请先完成原成本处理后重试");
    }

    /** A replacement follows the exact original receipt generation through its frozen funding slices. */
    public UUID sourceReceiptItem(UUID stockItem){
        var rows=db.queryForList("""
                SELECT DISTINCT CASE WHEN part.billing_mode='STANDARD' THEN part.receipt_item_id
                    ELSE funding.root_receipt_item_id END source
                FROM procurement_iqc_stock_consideration_parts stocked
                JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=stocked.quality_part_id
                JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
                LEFT JOIN procurement_iqc_funding_slices funding ON funding.id=part.funding_slice_id
                WHERE stocked.stock_in_item_id=:item AND part.receipt_type='SUBCONTRACT'
                """,Map.of("item",stockItem),UUID.class);
        if(rows.isEmpty())return null;
        if(rows.size()!=1||rows.getFirst()==null)
            throw conflict("一次委外入库须保持原回厂材料成本批次，请按原失败来源分批确认");
        return rows.getFirst();
    }

    /** Called in the physical stock transaction. Future corrections use the ordinary bounded cost worker. */
    public void stockStored(UUID receiptItem,MovementValue output,PoolKey physicalPool,EventContext physical){
        var receipt=db.queryForMap("""
                SELECT i.id,i.receipt_id,i.order_item_id,i.goods_id,i.color_id,r.warehouse_id,
                    COALESCE((SELECT SUM(p.base_qty) FROM procurement_receipt_consideration_parts p
                        WHERE p.receipt_item_id=i.id AND p.receipt_type='SUBCONTRACT' AND p.billing_mode='STANDARD'),0) target
                FROM subcontract_receipt_items i JOIN subcontract_receipts r ON r.id=i.receipt_id WHERE i.id=:id
                """,Map.of("id",receiptItem));
        PoolKey product=pool(receipt);
        if(physicalPool==null)physicalPool=product;
        var materials=db.queryForList("""
                SELECT c.*,issue.goods_id,issue.color_id FROM subcontract_receipt_material_consumptions c
                JOIN subcontract_material_issue_items issue ON issue.id=c.issue_item_id
                WHERE c.receipt_item_id=:item AND c.reversal_of IS NULL
                  AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions reversed WHERE reversed.reversal_of=c.id)
                ORDER BY c.id
                """,Map.of("item",receiptItem));
        List<InventoryKey> keys=new ArrayList<>();keys.add(new InventoryKey(physicalPool.goodsId(),physicalPool.colorId()));
        materials.forEach(row->keys.add(new InventoryKey((UUID)row.get("goods_id"),(UUID)row.get("color_id"))));mutex.lockAll(keys);
        if(output!=null)losses.registerOutput(receiptItem,output,physicalPool,physical);
        costs.registerScope(new Scope(receiptItem,ScopeKind.SUBCONTRACT_RECEIPT_ITEM,product));
        // Replacement provenance stays on the original receipt, while its output may enter another real warehouse.
        if(output!=null)costs.registerOutput(receiptItem,physicalPool,new Output(output.valueNodeId(),output.movementId()));
        var current=db.queryForMap("SELECT version,state FROM stock_value_production_cost_objects WHERE execution_segment_id=:id",Map.of("id",receiptItem));
        if("APPLYING".equals(current.get("state"))){
            db.update("""
                    UPDATE stock_value_production_cost_objects SET business_refresh_pending=TRUE,
                        business_refresh_event_id=:event,business_refresh_actor_id=:actor WHERE execution_segment_id=:id
                    """,Map.of("id",receiptItem,"event",physical.sourceEventId(),"actor",physical.actorUserId()));
            return;
        }
        List<Input> inputs=new ArrayList<>();
        for(var row:materials){
            UUID fact=(UUID)row.get("id"),root=result("SUBCONTRACT_CONSUMED_MATERIAL",fact);
            if(root==null){
                var sources=take(Owner.SUBCONTRACT_WIP,fact,(BigDecimal)row.get("qty_base"));
                var source=positions.position(sources.getFirst().positionRootId());
                root=positions.move(new Move(context("SUBCONTRACT_CONSUMED_MATERIAL",fact,(UUID)receipt.get("receipt_id"),physical.actorUserId()),
                        source.pool(),Owner.COST_WIP,receiptItem,sources)).positionRootId();
            }
            if(!Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_production_cost_inputs WHERE input_node_id=:id)",Map.of("id",root),Boolean.class)))
                inputs.add(new Input(root,fact,InputKind.CONSUMED));
        }
        BigDecimal target=(BigDecimal)receipt.get("target");
        boolean complete=materialScopeComplete(receiptItem,target);
        long version=db.queryForObject("SELECT version FROM stock_value_production_cost_objects WHERE execution_segment_id=:id",Map.of("id",receiptItem),Long.class);
        String basis=receiptItem+"|"+target.toPlainString()+"|"+complete+"|"+materials.stream().map(row->row.get("id").toString()).toList();
        costs.revise(new Revision(support.context("SUBCONTRACT_COST_BUSINESS",physical.sourceEventId(),receiptItem,receiptItem,
                physical.actorUserId(),physical.occurredAt()),receiptItem,product,version,target,complete,receiptItem,hash(basis),inputs,List.of()));
        db.update("UPDATE stock_value_production_cost_objects SET business_refresh_pending=FALSE WHERE execution_segment_id=:id",Map.of("id",receiptItem));
    }

    /**
     * ADR-143 §三.8 成本完整性(与 fn_check_subcontract_cost_scope_facts 同口径，宁严勿宽)：
     * 本回厂明细的物料口径回厂量就是全部计费基数(没有委外商自带料份额)，且订货明细的每一种
     * 冻结物料(计划行)都有本行仍有效的核销切片。没有计划行的明细不认完整。
     */
    private boolean materialScopeComplete(UUID receiptItem,BigDecimal target){
        if(target==null||target.signum()<=0)return false;
        return Boolean.TRUE.equals(db.queryForObject("""
                SELECT item.material_basis_qty IS NOT NULL
                   AND item.material_basis_qty*COALESCE(item.unit_rate,1)=:target
                   AND EXISTS(SELECT 1 FROM subcontract_material_plan_items plan
                       WHERE plan.order_item_id=item.order_item_id AND plan.is_deleted=FALSE)
                   AND NOT EXISTS(SELECT 1 FROM subcontract_material_plan_items plan
                       WHERE plan.order_item_id=item.order_item_id AND plan.is_deleted=FALSE
                         AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions c
                             JOIN subcontract_material_issue_items issue ON issue.id=c.issue_item_id
                             WHERE c.receipt_item_id=item.id AND issue.plan_item_id=plan.id
                               AND c.reversal_of IS NULL AND c.qty_doc>0
                               AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions reversed
                                   WHERE reversed.reversal_of=c.id)))
                FROM subcontract_receipt_items item WHERE item.id=:id
                """,Map.of("id",receiptItem,"target",target),Boolean.class));
    }

    public void refresh(UUID receiptItem,UUID event,UUID actor){
        if(costs.scope(receiptItem).kind()==ScopeKind.SUBCONTRACT_ORDER_NORMAL_LOSS){losses.refresh(receiptItem,event,actor);return;}
        var source=db.queryForMap("SELECT occurred_at FROM stock_value_events WHERE movement_id=:id OR id=:id",Map.of("id",event));
        stockStored(receiptItem,null,null,support.context("SUBCONTRACT_COST_BUSINESS",event,receiptItem,receiptItem,actor,time(source.get("occurred_at"))));
    }

    /** Unprocessed material comes back from the original issue, never from today's average or a selling price. */
    public MovementValue materialReturned(MovementRequest request,UUID movement,PoolKey product,BigDecimal before,EventContext context){
        UUID issue="SUBCONTRACT_MATERIAL_ISSUE".equals(request.sourceDocType())?request.sourceItemId():
                db.queryForObject("SELECT material_issue_item_id FROM subcontract_material_return_items WHERE id=:id",Map.of("id",request.sourceItemId()),UUID.class);
        if(issue==null)throw conflict("材料退回须关联原委外实发明细");
        return positions.store(new Store(context,movement,product,before,take(Owner.SUBCONTRACT_WIP,issue,request.qty())));
    }

    @Override
    @Transactional(readOnly=true,propagation=Propagation.MANDATORY,noRollbackFor=com.uten.imp.common.web.ApiException.class)
    public String requireIssueReversible(UUID issueId) {
        List<String> snapshots=new ArrayList<>();Set<UUID> seenItems=new HashSet<>();
        for(var item:db.queryForList("""
            SELECT item.id,item.goods_id,item.color_id,document.warehouse_id,original.qty
            FROM subcontract_material_issue_items item JOIN subcontract_material_issues document ON document.id=item.issue_id
            JOIN stock_movements original ON original.source_doc_type='SUBCONTRACT_MATERIAL_ISSUE'
              AND original.source_doc_id=document.id AND original.source_item_id=item.id AND original.direction=-1 AND original.movement_type=15
            WHERE document.id=:id AND NOT item.is_deleted ORDER BY item.line_no,item.id
            """,Map.of("id",issueId))) {
            UUID id=(UUID)item.get("id");if(!seenItems.add(id))throw conflict("同一发料明细存在多个原实发库存来源");PoolKey pool=new PoolKey((UUID)item.get("warehouse_id"),(UUID)item.get("goods_id"),(UUID)item.get("color_id"));
            snapshots.add(positions.requireStoreSourcesAvailable(pool,take(Owner.SUBCONTRACT_WIP,id,(BigDecimal)item.get("qty"))));
        }
        Long itemCount=db.queryForObject("SELECT COUNT(*) FROM subcontract_material_issue_items WHERE issue_id=:id AND NOT is_deleted",Map.of("id",issueId),Long.class);
        if(itemCount==null||itemCount==0||snapshots.size()!=itemCount)throw conflict("原委外发料缺少每行唯一实发库存与成本来源");
        return com.uten.imp.common.util.CanonicalFingerprint.sha256(snapshots);
    }

    @Override
    @Transactional(readOnly=true,propagation=Propagation.MANDATORY,noRollbackFor=com.uten.imp.common.web.ApiException.class)
    public String requireReturnReversible(UUID returnId) {
        var rows=db.queryForList("""
            SELECT item.id,item.goods_id,item.color_id,document.warehouse_id,original.id movement_id
            FROM subcontract_material_return_items item JOIN subcontract_material_returns document ON document.id=item.material_return_id
            JOIN stock_movements original ON original.source_doc_type='SUBCONTRACT_MATERIAL_RETURN'
              AND original.source_doc_id=document.id AND original.source_item_id=item.id AND original.direction=1 AND original.movement_type=16
            WHERE document.id=:id AND NOT item.is_deleted ORDER BY item.line_no,item.id
            """,Map.of("id",returnId));
        Long itemCount=db.queryForObject("SELECT COUNT(*) FROM subcontract_material_return_items WHERE material_return_id=:id AND NOT is_deleted",Map.of("id",returnId),Long.class);
        if(itemCount==null||itemCount==0||rows.size()!=itemCount||rows.stream().map(row->row.get("id")).distinct().count()!=itemCount)throw conflict("原委外退料缺少每行唯一入库与成本来源");
        return positions.requireStoresReversible(rows.stream().map(row->new StoreWithdrawal(
            new PoolKey((UUID)row.get("warehouse_id"),(UUID)row.get("goods_id"),(UUID)row.get("color_id")),(UUID)row.get("movement_id"),true)).toList());
    }

    /** Withdraw the exact original return store; later inbound values remain whole. */
    public MovementValue reverseMaterialReturn(EventContext context,UUID movement,PoolKey pool,
            BigDecimal before,UUID originalMovement) {
        return positions.reverseMaterialStore(new ReverseStore(context,movement,pool,before,originalMovement));
    }

    public UUID materialReturnIssue(UUID returnItem){
        UUID issue=db.queryForObject("SELECT material_issue_item_id FROM subcontract_material_return_items WHERE id=:id",Map.of("id",returnItem),UUID.class);
        if(issue==null)throw conflict("材料退回红冲缺少原委外实发明细");return issue;
    }

    private List<Map<String,Object>> consumptions(UUID receipt){return db.queryForList("""
            SELECT c.*,issue.goods_id,issue.color_id FROM subcontract_receipt_material_consumptions c
            JOIN subcontract_receipt_items item ON item.id=c.receipt_item_id
            JOIN subcontract_material_issue_items issue ON issue.id=c.issue_item_id
            WHERE item.receipt_id=:id AND c.reversal_of IS NULL ORDER BY c.id
            """,Map.of("id",receipt));}
    private void lockSources(List<Map<String,Object>> rows){mutex.lockAll(rows.stream().map(row->new InventoryKey((UUID)row.get("goods_id"),(UUID)row.get("color_id"))).toList());}
    private List<Slice> take(Owner owner,UUID ownerId,BigDecimal qty){
        BigDecimal left=qty;List<Slice> slices=new ArrayList<>();
        for(var row:InventoryOwnerPositions.remaining(db,owner,List.of(ownerId))){
            if(left.signum()==0)break;BigDecimal amount=left.min(row.quantity());
            slices.add(new Slice(row.rootId(),amount,row.rootId()));left=left.subtract(amount);
        }
        if(left.signum()!=0)throw conflict("原委外材料位置不足，须完成同源成本反向后重试，不能借用其它回厂批次");
        return List.copyOf(slices);
    }
    private UUID result(String type,UUID fact){var rows=db.queryForList("SELECT result_node_id FROM stock_value_events WHERE source_doc_type=:type AND source_item_id=:id",Map.of("type",type,"id",fact),UUID.class);
        if(rows.size()>1)throw conflict("委外材料来源对应多笔成本事件");return rows.isEmpty()?null:rows.getFirst();}
    private EventContext context(String type,UUID fact,UUID doc,UUID actor){return support.context(type,
            UUID.nameUUIDFromBytes((type+":"+fact).getBytes(StandardCharsets.UTF_8)),doc,fact,actor,
            db.queryForObject("SELECT transaction_timestamp()",Map.of(),java.time.OffsetDateTime.class));}
    private static String hash(String value){try{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));}
        catch(NoSuchAlgorithmException e){throw new IllegalStateException(e);}}
}
