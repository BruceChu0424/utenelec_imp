package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.ProcurementOrderSourceRevisionPort;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension;
import com.uten.imp.common.finance.ProcurementOrderQuantityBounds;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.*;

/** Exact source accounting for an approved quantity change. Original demand and transfer facts stay intact. */
@Service
@RequiredArgsConstructor
public class ProcurementOrderSourceRevisionService implements ProcurementOrderSourceRevisionPort {
    private final NamedParameterJdbcTemplate db;
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final FulfillmentMutationLocks mutationLocks;
    private final ProductionFulfillmentLedgerService ledger;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void prepare(String orderType, UUID orderId, List<Line> changes) {
        Kind kind = Kind.of(orderType);
        if (changes == null || changes.isEmpty() || changes.size() > 500) throw invalid("改量明细须为1至500行");
        List<Line> sorted = changes.stream().sorted(Comparator.comparing(Line::orderItemId)).toList();
        if (sorted.stream().map(Line::orderItemId).distinct().count() != sorted.size()
                || sorted.stream().map(Line::changeLogId).distinct().count() != sorted.size()) throw invalid("同一明细不能重复改量");
        List<Map<String, Object>> items = db.queryForList("""
                SELECT i.*,h.status AS header_status, h.is_deleted AS header_deleted
                FROM %1$s_order_items i JOIN %1$s_orders h ON h.id=i.order_id
                WHERE h.id=:order AND i.id IN (:items) ORDER BY i.id
                """.formatted(kind.prefix), args("order",orderId,"items",sorted.stream().map(Line::orderItemId).toList()));
        if (items.size() != sorted.size()) throw conflict("改量明细已变化或不属于本订单");
        Map<UUID,Map<String,Object>> byId = new HashMap<>();
        items.forEach(item -> byId.put(id(item,"id"),item));
        // The outer coordinator must already have declared every header before entering inventory.
        List<Map<String,Object>> sources = db.queryForList("""
                SELECT s.id,s.%2$s AS source_item_id,r.%3$s AS source_header_id
                FROM %1$s_order_item_sources s JOIN %1$s_%4$s_items r ON r.id=s.%2$s
                WHERE s.order_item_id IN (:items) ORDER BY r.id,s.id
                """.formatted(kind.prefix,kind.sourceColumn,kind.sourceHeaderColumn,kind.sourceType),
                args("items",sorted.stream().map(Line::orderItemId).toList()));
        if (sources.size()>5000) throw invalid("本次关联来源过多，请按订单分批改量");
        Set<CommercialSource> neededSources=new HashSet<>();
        neededSources.add(new CommercialSource(kind==Kind.PURCHASE?CommercialType.PURCHASE_ORDER:CommercialType.SUBCONTRACT_ORDER,orderId));
        CommercialType sourceType=kind==Kind.PURCHASE?CommercialType.PURCHASE_REQUEST:CommercialType.SUBCONTRACT_APPLICATION;
        sources.forEach(source->neededSources.add(new CommercialSource(sourceType,id(source,"source_header_id"))));
        Set<InventoryDimension> neededInventory=new HashSet<>();
        items.forEach(item->neededInventory.add(new InventoryDimension(id(item,"goods_id"),id(item,"color_id"))));
        mutationLocks.requireCovered(new FulfillmentMutationLockPlan(neededSources,neededInventory,Set.of(),Set.of(),
                "PROCUREMENT-SOURCE-REVISION:"+orderType+":"+orderId));
        db.queryForList("SELECT id FROM "+kind.prefix+"_order_items WHERE id IN (:items) ORDER BY id FOR UPDATE",
                args("items",sorted.stream().map(Line::orderItemId).toList()));
        if(!sources.isEmpty())db.queryForList("""
                SELECT s.id FROM %1$s_order_item_sources s JOIN %1$s_%2$s_items r ON r.id=s.%3$s
                WHERE s.id IN (:ids) ORDER BY r.id,s.id FOR UPDATE OF r,s
                """.formatted(kind.prefix,kind.sourceType,kind.sourceColumn),args("ids",sources.stream().map(source->id(source,"id")).toList()));
        Map<UUID,BigDecimal> workingOrdered = new HashMap<>();
        for (Line line : sorted) {
            Objects.requireNonNull(line.changeLogId(),"changeLogId");
            BigDecimal oldQty=positive(line.oldQty()),newQty=positive(line.newQty());
            Map<String,Object> item=byId.get(line.orderItemId());
            if (number(item,"header_status").intValue()!=1 || Boolean.TRUE.equals(item.get("header_deleted"))
                    || Boolean.TRUE.equals(item.get("is_deleted")) || amount(item,"qty").compareTo(oldQty)!=0
                    || rate(item).compareTo(line.unitRate())!=0 || oldQty.compareTo(newQty)==0) throw conflict("只能按已批准订单的当前数量和原单位改量");
            if (Boolean.TRUE.equals(db.queryForObject("""
                    SELECT EXISTS(SELECT 1 FROM procurement_order_approval_cases
                    WHERE order_type=:type AND order_id=:order AND status='PENDING')
                    """,args("type",orderType,"order",orderId),Boolean.class))) throw conflict("订单正在财务复核，不能再次改量");
            var receiptBound=ProcurementOrderQuantityBounds.receipts(em,orderType,line.orderItemId());
            if(newQty.compareTo(receiptBound.minimumOrderedQty(line.unitRate()))<0)
                throw conflict("新数量不能低于原订单当前保留的实收量，请先处理实际退货");
            db.update("""
                    INSERT INTO procurement_order_source_revisions(id,order_type,order_id,order_item_id,old_qty,new_qty,
                        unit_rate,before_item,approval_attempt_before,actor_user_id,actor_employee_id)
                    SELECT :id,:type,:order,i.id,:old,:new,:rate,to_jsonb(i),
                        (SELECT COALESCE(MAX(attempt),0) FROM procurement_order_approval_cases WHERE order_type=:type AND order_id=:order),:user,:employee
                    FROM %s_order_items i WHERE i.id=:item
                    """.formatted(kind.prefix),args("id",line.changeLogId(),"type",orderType,"order",orderId,
                    "item",line.orderItemId(),"old",oldQty,"new",newQty,"rate",line.unitRate(),
                    "user",currentUser.requireId(),"employee",currentUser.requireEmployeeId()));
            prepareAllocations(kind,line,item,workingOrdered,receiptBound);
        }
    }

    private void prepareAllocations(Kind kind, Line line, Map<String,Object> item, Map<UUID,BigDecimal> workingOrdered,
                                    ProcurementOrderQuantityBounds.ReceiptBound bound) {
        List<Map<String,Object>> rows=db.queryForList("""
                SELECT s.id,s.%2$s AS source_item_id,s.alloc_qty,s.line_no,r.qty AS requested_qty,
                    COALESCE(r.ordered_qty,0) AS ordered_qty,r.unit_id,COALESCE(r.unit_rate,1) AS unit_rate,
                    r.goods_id,r.color_id,r.is_deleted,h.status AS header_status,h.is_deleted AS header_deleted,
                    COALESCE((SELECT SUM(p.alloc_qty) FROM %1$s_order_item_sources p
                        JOIN %1$s_order_items oi ON oi.id=p.order_item_id
                        JOIN %1$s_orders oh ON oh.id=oi.order_id
                        WHERE p.%2$s=r.id AND oh.status=0 AND oh.is_deleted=FALSE AND oi.is_deleted=FALSE
                          AND EXISTS(SELECT 1 FROM procurement_order_approval_cases c WHERE c.order_type=:type
                            AND c.order_id=oh.id AND c.status='PENDING')),0) AS pending_qty,
                    COALESCE((SELECT SUM(target.consumed_qty) FROM %5$s t
                        JOIN production_material_supply_pegs target ON target.id=t.to_peg_id
                        WHERE t.order_item_id=s.order_item_id AND t.%2$s=r.id AND t.status='EFFECTIVE'),0) AS consumed_base,
                    COALESCE((SELECT SUM(fn_procurement_transfer_net_qty(:type,t.id)) FROM %5$s t
                        WHERE t.order_item_id=s.order_item_id AND t.%2$s=r.id AND t.status='EFFECTIVE'),0) AS peg_base,
                    EXISTS(SELECT 1 FROM production_material_supply_pegs p WHERE p.supply_type=:requestPeg AND p.supply_item_id=r.id) AS production_source
                FROM %1$s_order_item_sources s
                JOIN %1$s_%3$s_items r ON r.id=s.%2$s
                JOIN %1$s_%3$ss h ON h.id=r.%4$s
                WHERE s.order_item_id=:item ORDER BY s.line_no,s.id
                """.formatted(kind.prefix,kind.sourceColumn,kind.sourceType,kind.sourceHeaderColumn,kind.transferTable),
                args("item",line.orderItemId(),"type",kind.name(),"requestPeg",kind.requestPegType));
        if (rows.isEmpty()) {
            if (item.get(kind.sourceColumn)!=null) throw conflict("历史订单缺少来源份额，需先核对原来源，不能猜测分摊");
            return; // Explicit legacy/manual subcontract item, with no manufactured provenance.
        }
        BigDecimal total=rows.stream().map(r->amount(r,"alloc_qty")).reduce(BigDecimal.ZERO,BigDecimal::add);
        if (total.compareTo(line.oldQty())!=0) throw conflict("来源份额合计与原订单数量不一致，请先核对历史分配");
        BigDecimal retained=bound.retainedBase().subtract(bound.postedExcessBase()).max(BigDecimal.ZERO);
        BigDecimal delta=line.newQty().subtract(line.oldQty()),remaining=delta.abs(),prefix=BigDecimal.ZERO;
        List<Allocation> allocations=new ArrayList<>();
        for (int index=0;index<rows.size();index++) {
            Map<String,Object> row=rows.get(index);UUID source=id(row,"source_item_id");
            if (Boolean.TRUE.equals(row.get("is_deleted")) || Boolean.TRUE.equals(row.get("header_deleted"))
                    || number(row,"header_status").intValue()!=1 || !Objects.equals(item.get("goods_id"),row.get("goods_id"))
                    || !Objects.equals(item.get("color_id"),row.get("color_id")) || !Objects.equals(item.get("unit_id"),row.get("unit_id"))
                    || rate(row).compareTo(line.unitRate())!=0) throw conflict("来源已失效或单位与原订单不一致，不能改写来源份额");
            BigDecimal before=amount(row,"alloc_qty"),base=base(before,line.unitRate());
            BigDecimal receivedShare=retained.subtract(prefix).max(BigDecimal.ZERO).min(base);
            prefix=prefix.add(base);
            BigDecimal minimum=receivedShare.max(amount(row,"consumed_base")).divide(line.unitRate(),4,RoundingMode.CEILING);
            workingOrdered.putIfAbsent(source,amount(row,"ordered_qty"));
            allocations.add(new Allocation(row,before,before,minimum));
        }
        List<Allocation> selection=new ArrayList<>(allocations);
        if (delta.signum()<0) Collections.reverse(selection); // Inverse of the frozen source FIFO.
        for (Allocation a:selection) {
            BigDecimal capacity=delta.signum()<0 ? a.before.subtract(a.minimum).max(BigDecimal.ZERO)
                    : amount(a.row,"requested_qty").subtract(workingOrdered.get(a.source()))
                        .subtract(amount(a.row,"pending_qty")).max(BigDecimal.ZERO);
            BigDecimal part=remaining.min(capacity);
            a.after=a.before.add(delta.signum()<0?part.negate():part);
            remaining=remaining.subtract(part);
            if (remaining.signum()==0) break;
        }
        if (remaining.signum()>0) throw conflict(delta.signum()<0
                ?"减少部分已收货或已转备料，不能退回来源；请先处理对应实物流转"
                :"原申请剩余可订数量不足；需要追加需求时请另行确认来源，不能自动增加BOM需求或公共超量");
        for (Allocation a:allocations) {
            BigDecimal beforeOrdered=workingOrdered.get(a.source());
            BigDecimal afterOrdered=beforeOrdered.add(a.after.subtract(a.before));
            if(afterOrdered.signum()<0)throw conflict("来源已订数量不足以按原份额退回");
            BigDecimal beforePeg=amount(a.row,"peg_base");
            BigDecimal beforeBase=base(a.before,line.unitRate()),afterBase=base(a.after,line.unitRate());
            if(beforePeg.compareTo(beforeBase)>0)throw conflict("历史生产订货挂接超过原来源份额，不能继续改量");
            BigDecimal afterPeg=afterBase.compareTo(beforeBase)<0 ? beforePeg.min(afterBase)
                    : Boolean.TRUE.equals(a.row.get("production_source")) ? beforePeg.add(afterBase.subtract(beforeBase)) : beforePeg;
            db.update("""
                    INSERT INTO procurement_order_source_revision_allocations(revision_id,source_row_id,source_item_id,
                        line_no,before_alloc_qty,after_alloc_qty,before_ordered_qty,after_ordered_qty,protected_base_qty,
                        before_peg_qty_base,after_peg_qty_base)
                    VALUES (:revision,:row,:source,:line,:before,:after,:oldOrdered,:newOrdered,:protected,:beforePeg,:afterPeg)
                    """,args("revision",line.changeLogId(),"row",id(a.row,"id"),"source",a.source(),
                    "line",a.row.get("line_no"),"before",a.before,"after",a.after,"oldOrdered",beforeOrdered,
                    "newOrdered",afterOrdered,"protected",base(a.minimum,line.unitRate()),"beforePeg",beforePeg,"afterPeg",afterPeg));
            workingOrdered.put(a.source(),afterOrdered);
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void apply(String orderType, UUID orderId, List<UUID> changeLogIds) {
        Kind kind=Kind.of(orderType);
        List<Map<String,Object>> revisions=db.queryForList("""
                SELECT r.*,i.qty AS current_qty FROM procurement_order_source_revisions r
                JOIN %s_order_items i ON i.id=r.order_item_id
                WHERE r.id IN (:ids) AND r.order_type=:type AND r.order_id=:order AND r.created_txid=txid_current()
                ORDER BY r.revision_sequence FOR UPDATE OF i
                """.formatted(kind.prefix),args("ids",changeLogIds,"type",orderType,"order",orderId));
        if(revisions.size()!=changeLogIds.size())throw conflict("来源改量必须在原准备事务内完成");
        Set<UUID> touched=new LinkedHashSet<>(),sourceHeaders=new LinkedHashSet<>();
        for(Map<String,Object> revision:revisions){
            if(amount(revision,"current_qty").compareTo(amount(revision,"new_qty"))!=0)throw conflict("请先保存对应的新订单数量再对账来源");
            UUID revisionId=id(revision,"id");
            List<Map<String,Object>> allocations=db.queryForList("""
                    SELECT * FROM procurement_order_source_revision_allocations WHERE revision_id=:id ORDER BY allocation_sequence
                    """,args("id",revisionId));
            for(Map<String,Object> a:allocations){
                BigDecimal before=amount(a,"before_alloc_qty"),after=amount(a,"after_alloc_qty");
                if(before.compareTo(after)==0)continue;
                int sourceUpdated=db.update("UPDATE "+kind.prefix+"_order_item_sources SET alloc_qty=:after WHERE id=:row AND alloc_qty=:before",
                        args("row",id(a,"source_row_id"),"before",before,"after",after));
                int orderedUpdated=db.update("UPDATE "+kind.prefix+"_"+kind.sourceType+"_items SET ordered_qty=:after WHERE id=:source AND COALESCE(ordered_qty,0)=:before",
                        args("source",id(a,"source_item_id"),"before",a.get("before_ordered_qty"),"after",a.get("after_ordered_qty")));
                if(sourceUpdated!=1||orderedUpdated!=1)throw conflict("来源数量并发变化，整次改量已撤回");
                reconcilePegs(kind,revision,a,touched);
                sourceHeaders.add(id(a,"source_item_id"));
            }
        }
        for(UUID source:sourceHeaders)db.update("""
                UPDATE %1$s_%2$ss h SET is_closed=(SELECT COALESCE(bool_and(COALESCE(i.qty,0)-COALESCE(i.ordered_qty,0)<=0),true)
                    FROM %1$s_%2$s_items i WHERE i.%3$s=h.id AND i.is_deleted=FALSE)
                WHERE h.id=(SELECT %3$s FROM %1$s_%2$s_items WHERE id=:id)
                """.formatted(kind.prefix,kind.sourceType,kind.sourceHeaderColumn),args("id",source));
        ledger.refreshDemandStatuses(touched);
    }

    private void reconcilePegs(Kind kind,Map<String,Object> revision,Map<String,Object> allocation,Set<UUID> touched){
        UUID item=id(revision,"order_item_id"),source=id(allocation,"source_item_id"),revisionId=id(revision,"id");
        // All contenders for a source hold its row; acquire demands before peg rows.
        List<UUID> demandIds=db.queryForList("SELECT DISTINCT demand_id FROM production_material_supply_pegs WHERE supply_type=:requestType AND supply_item_id=:source ORDER BY demand_id",
                args("requestType",kind.requestPegType,"source",source),UUID.class);
        if(demandIds.isEmpty())return;
        db.queryForList("SELECT id FROM production_material_demands WHERE id IN (:ids) ORDER BY id FOR UPDATE",args("ids",demandIds));
        db.queryForList("SELECT id FROM production_material_supply_pegs WHERE demand_id IN (:ids) ORDER BY id FOR UPDATE",args("ids",demandIds));
        List<Map<String,Object>> transfers=db.queryForList("""
                SELECT t.*,p.allocated_qty AS target_allocated,p.released_qty AS target_released,p.consumed_qty AS target_consumed,
                    s.allocated_qty AS source_allocated,s.released_qty AS source_released,s.consumed_qty AS source_consumed,
                    fn_procurement_transfer_net_qty(:type,t.id) AS net_qty
                FROM %s t JOIN production_material_supply_pegs p ON p.id=t.to_peg_id
                JOIN production_material_supply_pegs s ON s.id=t.from_peg_id
                WHERE t.order_item_id=:item AND t.%s=:source AND t.status='EFFECTIVE'
                ORDER BY t.created_at,t.id FOR UPDATE OF t
                """.formatted(kind.transferTable,kind.sourceColumn),args("type",kind.name(),"item",item,"source",source));
        BigDecimal net=transfers.stream().map(t->amount(t,"net_qty")).reduce(BigDecimal.ZERO,BigDecimal::add);
        BigDecimal afterBase=base(amount(allocation,"after_alloc_qty"),amount(revision,"unit_rate"));
        BigDecimal deltaBase=afterBase.subtract(base(amount(allocation,"before_alloc_qty"),amount(revision,"unit_rate")));
        if(deltaBase.signum()<0){
            BigDecimal remaining=net.subtract(afterBase).max(BigDecimal.ZERO);
            Collections.reverse(transfers);
            for(Map<String,Object> transfer:transfers){
                BigDecimal available=amount(transfer,"target_allocated").subtract(amount(transfer,"target_released"))
                        .subtract(amount(transfer,"target_consumed")).min(amount(transfer,"net_qty"));
                BigDecimal part=remaining.min(available.max(BigDecimal.ZERO));
                if(part.signum()>0){adjustTransfer(kind,revisionId,transfer,part.negate());touched.add(id(transfer,"demand_id"));remaining=remaining.subtract(part);}
                if(remaining.signum()==0)break;
            }
            if(remaining.signum()>0)throw conflict("减少的生产供给已被收货使用，不能退回原申请");
            return;
        }
        if(deltaBase.signum()==0)return;
        List<Map<String,Object>> pegs=db.queryForList("""
                SELECT p.*,d.need_date FROM production_material_supply_pegs p
                JOIN production_material_demands d ON d.id=p.demand_id AND d.is_deleted=FALSE
                JOIN production_planning_packages pkg ON pkg.id=d.package_id AND pkg.is_deleted=FALSE AND pkg.status='CONFIRMED'
                WHERE p.supply_type=:type AND p.supply_item_id=:source AND p.status<>'REVERSED'
                  AND p.allocated_qty-p.consumed_qty-p.released_qty>0
                ORDER BY d.need_date NULLS LAST,d.id,p.id
                """,args("type",kind.requestPegType,"source",source));
        BigDecimal remaining=deltaBase;
        for(Map<String,Object> peg:pegs){
            BigDecimal part=remaining.min(amount(peg,"allocated_qty").subtract(amount(peg,"consumed_qty")).subtract(amount(peg,"released_qty")));
            if(part.signum()<=0)continue;
            Map<String,Object> existing=transfers.stream().filter(t->id(t,"from_peg_id").equals(id(peg,"id"))).findFirst().orElse(null);
            if(existing!=null)adjustTransfer(kind,revisionId,existing,part);
            else createTransfer(kind,revisionId,item,source,peg,part);
            touched.add(id(peg,"demand_id"));remaining=remaining.subtract(part);if(remaining.signum()==0)break;
        }
        if(remaining.signum()>0)throw conflict("原生产申请的待订供给不足，不能把订单增量伪装成新的BOM需求");
    }

    private void adjustTransfer(Kind kind,UUID revision,Map<String,Object> transfer,BigDecimal delta){
        UUID source=id(transfer,"from_peg_id"),target=id(transfer,"to_peg_id"),actor=currentUser.requireId();
        recordPegChange(kind,revision,id(transfer,"id"),"ADJUST",delta,source,target);
        // A reduction releases the target before restoring source demand coverage; an increase does the opposite.
        if(delta.signum()>0)changeSourcePeg(source,delta,actor);
        int updated=db.update("""
                UPDATE production_material_supply_pegs SET allocated_qty=allocated_qty+:increase,released_qty=released_qty+:release,
                    status=CASE WHEN allocated_qty+:increase=consumed_qty+released_qty+:release THEN 'RELEASED' ELSE 'EFFECTIVE' END,
                    lock_version=lock_version+1,updated_at=now(),updated_by=:actor
                WHERE id=:id AND status<>'REVERSED' AND allocated_qty+:increase>=consumed_qty+released_qty+:release
                """,args("id",target,"increase",delta.max(BigDecimal.ZERO),"release",delta.negate().max(BigDecimal.ZERO),"actor",actor));
        if(updated!=1)throw conflict("原订单供给已使用，不能调整该份额");
        if(delta.signum()<0)changeSourcePeg(source,delta,actor);
    }

    private void createTransfer(Kind kind,UUID revision,UUID item,UUID sourceItem,Map<String,Object> source,BigDecimal quantity){
        UUID actor=currentUser.requireId(),target=UUID.randomUUID(),transfer=UUID.randomUUID(),sourceId=id(source,"id");
        recordPegChange(kind,revision,transfer,"CREATE",quantity,sourceId,target);
        changeSourcePeg(sourceId,quantity,actor);
        db.update("""
                INSERT INTO production_material_supply_pegs(id,demand_id,supply_type,supply_item_id,allocated_qty,
                    consumed_qty,released_qty,expected_date,status,idempotency_key,lock_version,created_by,updated_by)
                VALUES (:id,:demand,:type,:item,:qty,0,0,:date,'EFFECTIVE',:key,0,:actor,:actor)
                """,args("id",target,"demand",id(source,"demand_id"),"type",kind.orderPegType,"item",item,"qty",quantity,
                "date",source.get("expected_date"),"key","QTY-REV-PEG:"+revision+":"+sourceId,"actor",actor));
        db.update("""
                INSERT INTO %s(id,demand_id,from_peg_id,to_peg_id,%s,order_item_id,transferred_qty,status,idempotency_key,created_by,updated_by)
                VALUES (:id,:demand,:sourcePeg,:target,:sourceItem,:item,:qty,'EFFECTIVE',:key,:actor,:actor)
                """.formatted(kind.transferTable,kind.sourceColumn),args("id",transfer,"demand",id(source,"demand_id"),"sourcePeg",sourceId,
                "target",target,"sourceItem",sourceItem,"item",item,"qty",quantity,"key","QTY-REV-TRANSFER:"+revision+":"+sourceId,"actor",actor));
    }

    private void recordPegChange(Kind kind,UUID revision,UUID transfer,String changeKind,BigDecimal delta,UUID source,UUID target){
        db.update("""
                INSERT INTO procurement_order_source_revision_peg_changes(revision_id,order_type,transfer_id,source_peg_id,target_peg_id,change_kind,qty_delta_base,
                    before_source_released,after_source_released,before_target_allocated,after_target_allocated,before_target_released,after_target_released)
                SELECT :revision,:type,:transfer,:source,:target,:kind,:delta,s.released_qty,s.released_qty+:delta,
                    COALESCE(t.allocated_qty,0),COALESCE(t.allocated_qty,0)+GREATEST(:delta,0),
                    COALESCE(t.released_qty,0),COALESCE(t.released_qty,0)+GREATEST(-:delta,0)
                FROM production_material_supply_pegs s LEFT JOIN production_material_supply_pegs t ON t.id=:target WHERE s.id=:source
                """,args("revision",revision,"type",kind.name(),"transfer",transfer,"kind",changeKind,"delta",delta,"source",source,"target",target));
    }

    private void changeSourcePeg(UUID source,BigDecimal delta,UUID actor){
        int updated=db.update("""
                UPDATE production_material_supply_pegs SET released_qty=released_qty+:delta,
                    status=CASE WHEN consumed_qty+released_qty+:delta=allocated_qty THEN 'RELEASED' ELSE 'EFFECTIVE' END,
                    lock_version=lock_version+1,updated_at=now(),updated_by=:actor
                WHERE id=:id AND status<>'REVERSED' AND released_qty+:delta>=0
                  AND allocated_qty>=consumed_qty+released_qty+:delta
                """,args("id",source,"delta",delta,"actor",actor));
        if(updated!=1)throw conflict("原申请供给剩余量不足，整次改量已撤回");
    }

    private enum Kind {
        PURCHASE("purchase","request","request_id","request_item_id","production_material_peg_transfers","PURCHASE_REQUEST_ITEM","PURCHASE_ORDER_ITEM"),
        SUBCONTRACT("subcontract","application","application_id","application_item_id","production_material_subcontract_peg_transfers","SUBCONTRACT_APPLICATION_ITEM","SUBCONTRACT_ORDER_ITEM");
        final String prefix,sourceType,sourceHeaderColumn,sourceColumn,transferTable,requestPegType,orderPegType;
        Kind(String prefix,String sourceType,String sourceHeaderColumn,String sourceColumn,String transferTable,String requestPegType,String orderPegType){
            this.prefix=prefix;this.sourceType=sourceType;this.sourceHeaderColumn=sourceHeaderColumn;this.sourceColumn=sourceColumn;
            this.transferTable=transferTable;this.requestPegType=requestPegType;this.orderPegType=orderPegType;
        }
        static Kind of(String value){try{return valueOf(value);}catch(RuntimeException e){throw invalid("未知订货类型");}}
    }
    private static final class Allocation {
        final Map<String,Object> row;final BigDecimal before,minimum;BigDecimal after;
        Allocation(Map<String,Object> row,BigDecimal before,BigDecimal after,BigDecimal minimum){this.row=row;this.before=before;this.after=after;this.minimum=minimum;}
        UUID source(){return id(row,"source_item_id");}
    }
    private static Map<String,Object> args(Object...pairs){Map<String,Object> result=new HashMap<>();for(int i=0;i<pairs.length;i+=2)result.put((String)pairs[i],pairs[i+1]);return result;}
    private static UUID id(Map<String,Object> row,String name){return (UUID)row.get(name);}
    private static Number number(Map<String,Object> row,String name){return (Number)row.get(name);}
    private static BigDecimal amount(Map<String,Object> row,String name){Object value=row.get(name);return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static BigDecimal rate(Map<String,Object> row){return row.get("unit_rate")==null?BigDecimal.ONE:amount(row,"unit_rate");}
    private static BigDecimal base(BigDecimal qty,BigDecimal rate){return qty.multiply(rate).setScale(4,RoundingMode.HALF_UP);}
    private static BigDecimal positive(BigDecimal value){if(value==null||value.signum()<=0)throw invalid("新旧数量必须大于0");try{return value.setScale(4,RoundingMode.UNNECESSARY);}catch(ArithmeticException e){throw invalid("数量最多4位小数");}}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
