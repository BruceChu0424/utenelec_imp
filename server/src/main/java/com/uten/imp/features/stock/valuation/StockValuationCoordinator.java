package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.*;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.stock.StockService.MovementRequest;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;

/** The single physical posting boundary. Outbound prices never enter valuation. */
@Service
@Transactional(propagation=Propagation.MANDATORY)
public class StockValuationCoordinator {
    private final NamedParameterJdbcTemplate db;
    private final InventoryValuationPort values;
    private final InventoryProductionCostPort production;
    private final ProcurementInventoryValueService procurement;
    private final InventoryBusinessValueSupport support;
    private final ProductionInventoryValueService material;
    private final SubcontractOwnMaterialCostService subcontractMaterials;
    private final SalesReturnInventoryValueService salesReturns;
    public StockValuationCoordinator(NamedParameterJdbcTemplate db,InventoryValuationPort values,
            InventoryProductionCostPort production,ProcurementInventoryValueService procurement,InventoryBusinessValueSupport support,
            ProductionInventoryValueService material,SubcontractOwnMaterialCostService subcontractMaterials,
            SalesReturnInventoryValueService salesReturns){
        this.db=db;this.values=values;this.production=production;this.procurement=procurement;this.support=support;this.material=material;
        this.subcontractMaterials=subcontractMaterials;
        this.salesReturns=salesReturns;
    }
    public MovementValue value(UUID movement,MovementRequest request,BigDecimal before,OffsetDateTime at){
        PoolKey pool=new PoolKey(request.warehouseId(),request.goodsId(),request.colorId());
        EventContext context=support.context(request.sourceDocType(),movement,request.sourceDocId(),request.sourceItemId(),null,at);
        support.ensureActive(pool,context);
        if(request.costReference() instanceof InventoryMovementCostReference.SalesReturnQuality ref){
            return salesReturns.movement(ref,movement,pool,request.qty(),before,context,request.direction());
        }
        if(request.direction()==StockService.DIR_OUT&&request.costReference() instanceof InventoryMovementCostReference.ProcurementStockIn ref){
            return procurement.reverseStock(ref.stockInItemId(),movement,pool,before,context);
        }
        if(request.direction()==StockService.DIR_OUT){
            Destination destination=switch(request.movementType()){
                case 3,20 -> Destination.COGS;
                case 5,6 -> Destination.WIP;
                case 15,16 -> Destination.SUBCONTRACT_WIP;
                case 8 -> Destination.IN_TRANSIT;
                case 10,19 -> Destination.LOSS;
                default -> Destination.EXTERNAL;
            };
            UUID destinationId=request.movementType()==16?subcontractMaterials.materialReturnIssue(request.sourceItemId()):request.sourceItemId();
            return values.issue(new Issue(context,movement,pool,request.qty(),before,destination,destinationId));
        }
        if(request.movementType()==15||request.movementType()==16){
            return subcontractMaterials.materialReturned(request,movement,pool,before,context);
        }
        if(request.movementType()==18){
            var originals=db.queryForList("""
                    SELECT movement.id FROM stock_movements movement
                    WHERE movement.source_doc_type='SUBCONTRACT_RETURN' AND movement.source_doc_id=:doc
                        AND movement.source_item_id=:item AND movement.movement_type=18 AND movement.direction=-1
                    """,Map.of("doc",request.sourceDocId(),"item",request.sourceItemId()),UUID.class);
            if(originals.size()!=1)throw conflict("委外成品退回红冲必须关联唯一原实物退回流水");
            return originalReturn(context,movement,pool,request.qty(),before,originals.getFirst());
        }
        if(request.costReference() instanceof InventoryMovementCostReference.ProcurementStockIn ref){
            return procurement.store(ref.stockInItemId(),movement,pool,before,context);
        }
        if("STOCK_DOC".equals(request.sourceDocType())&&(request.movementType()==5||request.movementType()==6)){
            return material.returned(request,movement,pool,before,context);
        }
        if(request.costReference() instanceof InventoryMovementCostReference.OriginalIssueMovement ref){
            return originalReturn(context,movement,pool,request.qty(),before,ref.originalMovementId());
        }
        if(request.movementType()==7){
            var rows=db.queryForList("""
                    SELECT id FROM stock_movements WHERE source_doc_type=:type AND source_doc_id=:doc
                      AND source_item_id=:item AND movement_type=8 AND direction=-1
                    ORDER BY created_at DESC,id DESC LIMIT 2
                    """,Map.of("type",request.sourceDocType(),"doc",request.sourceDocId(),"item",request.sourceItemId()),UUID.class);
            if(rows.size()!=1)throw conflict("调入必须关联唯一原调出流水");
            return originalReturn(context,movement,pool,request.qty(),before,rows.getFirst());
        }
        UUID segment=request.costReference() instanceof InventoryMovementCostReference.FinishedProduction ref?ref.executionSegmentId():null;
        BigDecimal actual=null;
        if("STOCK_DOC".equals(request.sourceDocType())){
            var rows=db.queryForList("""
                    SELECT document.doc_type,item.amount_local,item.execution_segment_id,
                           item.goods_id,item.color_id,document.warehouse_id
                    FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id
                    WHERE item.id=:item AND document.id=:doc AND NOT item.is_deleted AND NOT document.is_deleted
                    """,Map.of("item",request.sourceItemId(),"doc",request.sourceDocId()));
            if(rows.size()!=1)throw conflict("仓库成本缺少实际来源单据明细");
            var row=rows.getFirst();
            if(!Objects.equals(row.get("goods_id"),pool.goodsId())||!Objects.equals(row.get("color_id"),pool.colorId()))
                throw conflict("库存成本货品与实际单据不一致");
            if("OTHER_IN".equals(row.get("doc_type")))actual=(BigDecimal)row.get("amount_local");
            if("FINISHED_IN".equals(row.get("doc_type")))segment=(UUID)row.get("execution_segment_id");
        }
        // Unpriced physical receipts retain pending cost; absence is never confirmed free inventory.
        MovementValue result=values.receive(new Receive(context,movement,pool,request.qty(),before,actual,actual!=null));
        if(segment!=null){
            production.registerOutput(segment,pool,new InventoryProductionCostPort.Output(result.valueNodeId(),movement));
            material.refresh(segment,movement,context.actorUserId());
        }
        return result;
    }
    public void bindProductionMovements(UUID event,Map<UUID,UUID> movements){material.bound(event,movements);}
    private MovementValue originalReturn(EventContext context,UUID movement,PoolKey pool,BigDecimal qty,BigDecimal before,UUID original){
        var roots=db.queryForList("SELECT result_node_id FROM stock_value_events WHERE movement_id=:id AND operation='ISSUE'",Map.of("id",original),UUID.class);
        if(roots.size()!=1)throw conflict("退回缺少原出库实际成本，请核对原来源");
        return values.returnIssue(new ReturnIssue(context,movement,pool,qty,before,roots.getFirst()));
    }
}
