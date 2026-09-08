package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.*;
import com.uten.imp.application.port.InventoryPositionPort.*;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;
import static com.uten.imp.features.stock.valuation.InventoryBusinessValueSupport.*;

/** Actual receipt, quality, supplier custody and credit value, in the original business transaction. */
@Service
@Transactional(propagation=Propagation.MANDATORY)
public class ProcurementInventoryValueService implements ProcurementInventoryValuePort {
    private final NamedParameterJdbcTemplate db;
    private final ProcurementReceiptConsiderationPort consideration;
    private final InventoryCostSourceEvidencePort evidence;
    private final InventoryPositionPort positions;
    private final InventoryMutationLock mutex;
    private final InventoryBusinessValueSupport support;
    private final SubcontractOwnMaterialCostService subcontractMaterials;
    public ProcurementInventoryValueService(NamedParameterJdbcTemplate db,ProcurementReceiptConsiderationPort consideration,
            InventoryCostSourceEvidencePort evidence,InventoryPositionPort positions,InventoryMutationLock mutex,
            InventoryBusinessValueSupport support,SubcontractOwnMaterialCostService subcontractMaterials){
        this.db=db;this.consideration=consideration;this.evidence=evidence;this.positions=positions;this.mutex=mutex;this.support=support;
        this.subcontractMaterials=subcontractMaterials;
    }
    @Override public void receiptApproved(String type,UUID receipt,UUID actor){
        var parts=consideration.receipt(type,receipt);
        if(parts.isEmpty())throw conflict("收货尚无真实计款份额，不能建立成本");
        var proofs=parts.stream().map(p->evidence.approved(p.id(),1).orElseThrow(()->conflict("收货成本依据尚未批准"))).toList();
        mutex.lockAll(proofs.stream().map(p->new InventoryKey(p.pool().goodsId(),p.pool().colorId())).toList());
        for(int i=0;i<parts.size();i++){
            var part=parts.get(i);var proof=proofs.get(i);
            if(has("PROCUREMENT_ACQUIRE",part.id()))continue;
            var acquisitionContext=context("PROCUREMENT_ACQUIRE",part.id(),receipt,actor);
            support.ensureActive(proof.pool(),acquisitionContext);
            List<Slice> carried=part.billingMode()==ProcurementReceiptConsiderationPort.BillingMode.NO_CHARGE
                    ?takeOwner(Owner.SUPPLIER_CUSTODY,part.fundingSliceId(),part.baseQty(),part.id()):List.of();
            positions.acquire(new Acquire(acquisitionContext,proof.pool(),part.id(),1,
                    Owner.QUALITY_PENDING,part.id(),carried));
        }
        if("SUBCONTRACT".equals(type))subcontractMaterials.receiptApproved(receipt,actor);
    }
    @Override public void qualityRecorded(UUID event,UUID actor){
        var parts=consideration.quality(event);
        if(parts.isEmpty())throw conflict("品质事件尚无真实计款切片");
        for(var part:parts){
            if(has("PROCUREMENT_QUALITY",part.id()))continue;
            UUID root=acquisition(part.considerationPartId());var current=positions.position(root);lock(current.pool());
            positions.move(new Move(context("PROCUREMENT_QUALITY",part.id(),event,actor),current.pool(),
                    "PASS".equals(part.action())?Owner.QUALITY_PASSED:Owner.REJECTED_HOLD,part.id(),
                    takeOwner(Owner.QUALITY_PENDING,part.considerationPartId(),part.baseQty(),part.id())));
        }
    }
    public MovementValue store(UUID item,UUID movement,PoolKey key,BigDecimal before,EventContext context){
        List<Slice> sources=new ArrayList<>();
        for(var part:consideration.stock(item)){
            UUID root=result("PROCUREMENT_QUALITY",part.qualityPartId());
            sources.add(new Slice(root,part.baseQty(),part.id()));
        }
        if(sources.isEmpty())throw conflict("合格入库尚无准确的品质成本来源");
        UUID materialReceipt=subcontractMaterials.sourceReceiptItem(item);
        MovementValue stored=positions.store(new Store(context,movement,key,before,sources,materialReceipt!=null));
        if(materialReceipt!=null)subcontractMaterials.stockStored(materialReceipt,stored,key,context);
        return stored;
    }
    public MovementValue reverseStock(UUID item,UUID movement,PoolKey key,BigDecimal before,EventContext context){
        var rows=db.queryForList("""
                SELECT stocked.stock_movement_id,inspection.receipt_type,inspection.receipt_id FROM procurement_iqc_stock_in_batch_items stocked
                JOIN procurement_inspection_items inspection ON inspection.id=stocked.inspection_item_id WHERE stocked.id=:id
                """,Map.of("id",item));
        if(rows.size()!=1)throw conflict("原合格入库来源不存在");
        boolean subcontract="SUBCONTRACT".equals(rows.getFirst().get("receipt_type"));
        if(subcontract)subcontractMaterials.prepareUnusedReceiptReversal((UUID)rows.getFirst().get("receipt_id"),context.actorUserId());
        else if(!"PURCHASE".equals(rows.getFirst().get("receipt_type")))throw conflict("未核来源入库不能直接撤回");
        MovementValue reversed=positions.reverseStore(new ReverseStore(context,movement,key,before,(UUID)rows.getFirst().get("stock_movement_id")));
        if(subcontract)db.update("""
                UPDATE stock_value_production_cost_outputs SET withdrawn_movement_id=:reverse
                WHERE movement_id=:original AND withdrawn_movement_id IS NULL
                """,Map.of("reverse",movement,"original",rows.getFirst().get("stock_movement_id")));
        return reversed;
    }
    @Override public void qualityReversed(UUID event,UUID actor){
        for(var row:db.queryForList("SELECT id,consideration_part_id,base_qty FROM procurement_iqc_quality_consideration_parts WHERE inspection_event_id=:id ORDER BY id",Map.of("id",event))){
            UUID id=(UUID)row.get("id");if(has("PROCUREMENT_QUALITY_REVERSE",id))continue;
            UUID root=result("PROCUREMENT_QUALITY",id);var current=positions.position(root);lock(current.pool());
            positions.move(new Move(context("PROCUREMENT_QUALITY_REVERSE",id,event,actor),current.pool(),Owner.QUALITY_PENDING,
                    (UUID)row.get("consideration_part_id"),takeOwner(current.owner(),id,(BigDecimal)row.get("base_qty"),id)));
        }
    }
    @Override public void receiptReversed(String type,UUID receipt,UUID actor){
        if("SUBCONTRACT".equals(type))subcontractMaterials.receiptReversed(receipt,actor);
        for(var row:db.queryForList("SELECT id,base_qty,billing_mode,funding_slice_id FROM procurement_receipt_consideration_parts WHERE receipt_type=:type AND receipt_id=:id ORDER BY id",Map.of("type",type,"id",receipt))){
            UUID part=(UUID)row.get("id");if(has("PROCUREMENT_RECEIPT_REVERSE",part))continue;
            var root=positions.position(acquisition(part));lock(root.pool());
            var sources=takeOwner(Owner.QUALITY_PENDING,part,(BigDecimal)row.get("base_qty"),part);
            boolean carried="NO_CHARGE".equals(row.get("billing_mode"));
            positions.move(new Move(context("PROCUREMENT_RECEIPT_REVERSE",part,receipt,actor),root.pool(),
                    carried?Owner.SUPPLIER_CUSTODY:Owner.EXTERNAL,carried?(UUID)row.get("funding_slice_id"):part,sources));
        }
    }
    @Override public void returnedToSupplier(UUID caseId,UUID actor){
        var action=caseAction(caseId,"RETURN_RECORDED");UUID actionId=(UUID)action.get("id");
        for(var row:funding(caseId)){
            UUID funding=(UUID)row.get("id");if(has("PROCUREMENT_SUPPLIER_RETURN",actionId,funding))continue;
            var sources=takeOwner(Owner.REJECTED_HOLD,(UUID)row.get("quality_part_id"),(BigDecimal)row.get("base_qty"),funding);
            var current=positions.position(sources.getFirst().positionRootId());lock(current.pool());
            positions.move(new Move(support.context("PROCUREMENT_SUPPLIER_RETURN",actionId,caseId,funding,actor,time(action.get("created_at"))),current.pool(),Owner.SUPPLIER_CUSTODY,
                    funding,sources));
        }
    }
    @Override public void returnReversed(UUID caseId,UUID actor){
        var action=caseAction(caseId,"RETURN_REVERSED");UUID actionId=(UUID)action.get("id");
        for(var row:funding(caseId)){
            UUID funding=(UUID)row.get("id");if(has("PROCUREMENT_SUPPLIER_RETURN_REVERSE",actionId,funding))continue;
            var sources=takeOwner(Owner.SUPPLIER_CUSTODY,funding,(BigDecimal)row.get("base_qty"),funding);
            var current=positions.position(sources.getFirst().positionRootId());lock(current.pool());
            positions.move(new Move(support.context("PROCUREMENT_SUPPLIER_RETURN_REVERSE",actionId,caseId,funding,actor,time(action.get("created_at"))),current.pool(),Owner.REJECTED_HOLD,
                    (UUID)row.get("quality_part_id"),sources));
        }
    }
    @Override public void creditConfirmed(UUID document,UUID actor){
        for(var row:credit(document)){
            UUID slice=(UUID)row.get("id");if(has("PROCUREMENT_CREDIT",slice))continue;
            UUID fund=(UUID)row.get("funding_slice_id");
            var sources=takeOwner(Owner.SUPPLIER_CUSTODY,fund,(BigDecimal)row.get("base_qty"),slice);
            var current=positions.position(sources.getFirst().positionRootId());lock(current.pool());
            positions.move(new Move(context("PROCUREMENT_CREDIT",slice,document,actor),current.pool(),Owner.EXTERNAL,slice,sources));
        }
    }
    @Override public void creditReversed(UUID document,UUID actor){
        for(var row:credit(document)){
            UUID slice=(UUID)row.get("id");if(has("PROCUREMENT_CREDIT_REVERSE",slice))continue;
            UUID root=result("PROCUREMENT_CREDIT",slice);var current=positions.position(root);lock(current.pool());
            positions.move(new Move(context("PROCUREMENT_CREDIT_REVERSE",slice,document,actor),current.pool(),Owner.SUPPLIER_CUSTODY,
                    (UUID)row.get("funding_slice_id"),List.of(new Slice(root,(BigDecimal)row.get("base_qty"),slice))));
        }
    }
    private List<Map<String,Object>> funding(UUID id){return db.queryForList("SELECT id,quality_part_id,base_qty FROM procurement_iqc_funding_slices WHERE case_id=:id ORDER BY id",Map.of("id",id));}
    private Map<String,Object> caseAction(UUID caseId,String kind){
        var rows=db.queryForList("""
                SELECT id,created_at FROM procurement_iqc_rejection_events WHERE case_id=:id AND event_type=:kind
                  AND xmin::text=pg_current_xact_id()::text ORDER BY id
                """,Map.of("id",caseId,"kind",kind));
        if(rows.size()!=1)throw conflict("供应商托管成本必须关联本次真实退回事件");return rows.getFirst();
    }
    private List<Map<String,Object>> credit(UUID id){return db.queryForList("SELECT id,funding_slice_id,base_qty FROM procurement_iqc_credit_slices WHERE credit_document_id=:id ORDER BY id",Map.of("id",id));}
    private List<Slice> takeOwner(Owner owner,UUID id,BigDecimal qty,UUID fact){
        List<Slice> result=new ArrayList<>();BigDecimal left=qty;
        for(var row:db.queryForList("""
                SELECT root.id,head.range_to-head.range_from qty
                FROM stock_value_nodes root JOIN stock_value_nodes head ON head.id=root.return_head_id
                WHERE root.root_issue_id=root.id AND head.owner_kind=:owner AND head.owner_id=:id
                  AND head.range_to>head.range_from ORDER BY root.created_at,root.id
                """,Map.of("owner",owner.name(),"id",id))){
            if(left.signum()==0)break;BigDecimal take=left.min((BigDecimal)row.get("qty"));
            result.add(new Slice((UUID)row.get("id"),take,(UUID)row.get("id")));left=left.subtract(take);
        }
        if(left.signum()!=0)throw conflict("实际来源尚未在对应价值位置，不能猜测补回或冲销成本");
        return result.size()==1?List.of(new Slice(result.getFirst().positionRootId(),qty,fact)):List.copyOf(result);
    }
    private UUID acquisition(UUID id){return one("SELECT e.result_node_id FROM stock_value_acquisition_sources a JOIN stock_value_events e ON e.id=a.event_id WHERE a.evidence_id=:id",Map.of("id",id));}
    private UUID result(String type,UUID id){return one("SELECT result_node_id FROM stock_value_events WHERE source_doc_type=:type AND source_event_id=:id",Map.of("type",type,"id",id));}
    private UUID one(String sql,Map<String,?> params){var rows=db.queryForList(sql,params,UUID.class);if(rows.size()!=1)throw conflict("业务来源尚无唯一已核成本位置");return rows.getFirst();}
    private boolean has(String type,UUID id){return Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_events WHERE source_doc_type=:type AND source_event_id=:id)",Map.of("type",type,"id",contextEvent(type,id)),Boolean.class));}
    private boolean has(String type,UUID id,UUID item){return Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_events WHERE source_doc_type=:type AND source_event_id=:id AND source_item_id=:item)",Map.of("type",type,"id",id,"item",item),Boolean.class));}
    private static UUID contextEvent(String kind,UUID fact){return kind.endsWith("REVERSE")
            ?UUID.nameUUIDFromBytes((kind+":"+fact).getBytes(java.nio.charset.StandardCharsets.UTF_8)):fact;}
    private EventContext context(String kind,UUID fact,UUID doc,UUID actor){return support.context(kind,contextEvent(kind,fact),doc,fact,actor,
            db.queryForObject("SELECT transaction_timestamp()",Map.of(),java.time.OffsetDateTime.class));}
    private void lock(PoolKey key){mutex.lock(new InventoryKey(key.goodsId(),key.colorId()));}
}
