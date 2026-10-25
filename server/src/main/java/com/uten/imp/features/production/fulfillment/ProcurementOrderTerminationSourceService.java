package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.ProcurementOrderApprovalPort.RemainingLine;
import com.uten.imp.application.port.ProcurementOrderTerminationSourcePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.*;

/** Approval-bound reductions never rewrite the original order or its frozen source shares. */
@Service
@RequiredArgsConstructor
public class ProcurementOrderTerminationSourceService implements ProcurementOrderTerminationSourcePort {
    private final NamedParameterJdbcTemplate db;
    private final SecurityContextCurrentUser currentUser;
    private final ProductionFulfillmentLedgerService ledger;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void apply(String type, UUID orderId, UUID caseId, List<RemainingLine> lines) {
        Kind kind = Kind.of(type);
        Set<UUID> touched = new LinkedHashSet<>();
        Set<UUID> sources = new LinkedHashSet<>();
        for (RemainingLine line : lines.stream().sorted(Comparator.comparing(RemainingLine::orderItemId)).toList()) {
            var parameters = args("item", line.orderItemId(), "order", orderId);
            List<Map<String,Object>> items = db.queryForList("SELECT * FROM " + kind.prefix
                    + "_order_items WHERE id=:item AND order_id=:order AND NOT is_deleted FOR UPDATE", parameters);
            if (items.size()!=1) throw conflict("结束明细已变化，请刷新订单");
            Map<String,Object> item = items.getFirst();
            BigDecimal remaining = zero(line.remainingQty()), gift = zero(line.remainingGiftQty());
            BigDecimal ordered = amount(item,"qty");
            BigDecimal orderedGift = kind==Kind.PURCHASE && "CHARGED_PLUS_GIFT_V1".equals(item.get("quantity_semantics"))
                    ? amount(item,"gift_qty") : BigDecimal.ZERO;
            if (remaining.signum()<0 || gift.signum()<0 || remaining.compareTo(ordered)>0 || gift.compareTo(orderedGift)>0)
                throw conflict("结束剩余量超出原订货数量");
            List<Map<String,Object>> shares = db.queryForList("""
                    SELECT s.id,s.%2$s AS source_item_id,s.alloc_qty,%3$s AS gift_qty,s.line_no
                    FROM %1$s_order_item_sources s WHERE s.order_item_id=:item ORDER BY s.line_no,s.id FOR UPDATE
                    """.formatted(kind.prefix,kind.sourceColumn,kind==Kind.PURCHASE?"s.allocated_gift_qty":"0::numeric"), parameters);
            if (shares.isEmpty() && item.get(kind.sourceColumn)!=null) {
                shares = List.of(args("id",null,"source_item_id",item.get(kind.sourceColumn),"alloc_qty",ordered,
                        "gift_qty",orderedGift,"line_no",1));
            }
            if (shares.isEmpty()) continue; // A standalone historical order has no invented planning source.
            if (shares.stream().map(s->amount(s,"alloc_qty")).reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(ordered)!=0
                    || shares.stream().map(s->amount(s,"gift_qty")).reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(orderedGift)!=0)
                throw conflict("原订单来源数量不一致，请先核对来源份额");
            BigDecimal retain = ordered.subtract(remaining), retainGift = orderedGift.subtract(gift);
            for (Map<String,Object> share : shares) {
                UUID source = (UUID)share.get("source_item_id");
                BigDecimal paidBefore=amount(share,"alloc_qty"),giftBefore=amount(share,"gift_qty");
                BigDecimal paidRetained=paidBefore.min(retain),giftRetained=giftBefore.min(retainGift);
                retain=retain.subtract(paidRetained);retainGift=retainGift.subtract(giftRetained);
                BigDecimal release=paidBefore.subtract(paidRetained),releaseGift=giftBefore.subtract(giftRetained);
                if (release.signum()==0 && releaseGift.signum()==0) continue;
                db.update("""
                    INSERT INTO procurement_order_termination_sources(case_id,order_type,order_id,order_item_id,
                        source_row_id,source_item_id,line_no,released_qty,released_gift_qty,retained_physical_qty,unit_rate)
                    VALUES (:case,:type,:order,:item,:row,:source,:line,:qty,:gift,:retained,:rate)
                    """,args("case",caseId,"type",type,"order",orderId,"item",line.orderItemId(),"row",share.get("id"),
                        "source",source,"line",share.get("line_no"),"qty",release,"gift",releaseGift,
                        "retained",paidRetained.add(giftRetained),"rate",item.get("unit_rate")));
                String giftUpdate=kind==Kind.PURCHASE?",gift_ordered_qty=COALESCE(gift_ordered_qty,0)-:gift":"";
                String giftCheck=kind==Kind.PURCHASE?" AND COALESCE(gift_ordered_qty,0)>=:gift":"";
                int changed=db.update("UPDATE " + kind.prefix + "_" + kind.sourceType + "_items SET ordered_qty=COALESCE(ordered_qty,0)-:qty"
                    +giftUpdate+" WHERE id=:source AND COALESCE(ordered_qty,0)>=:qty"+giftCheck,
                    args("source",source,"qty",release,"gift",releaseGift));
                if(changed!=1)throw conflict("原申请已订数量与订单来源不一致，不能自动释放，请先核对历史数据");
                releasePegs(kind,caseId,line.orderItemId(),source,MoneyPolicy.quantity(paidRetained.add(giftRetained)
                        .multiply(amount(item,"unit_rate"))),touched);
                sources.add(source);
            }
        }
        for(UUID source:sources)db.update("""
                UPDATE %1$s_%2$ss h SET is_closed=(SELECT COALESCE(bool_and(COALESCE(i.qty,0)
                    %4$s-COALESCE(i.ordered_qty,0)%5$s<=0),true)
                    FROM %1$s_%2$s_items i WHERE i.%3$s=h.id AND NOT i.is_deleted)
                WHERE h.id=(SELECT %3$s FROM %1$s_%2$s_items WHERE id=:source)
                """.formatted(kind.prefix,kind.sourceType,kind.headerColumn,
                    kind==Kind.PURCHASE?"+CASE WHEN i.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN COALESCE(i.gift_qty,0) ELSE 0 END":"",
                    kind==Kind.PURCHASE?"-COALESCE(i.gift_ordered_qty,0)":""),args("source",source));
        ledger.refreshDemandStatuses(touched);
    }

    private void releasePegs(Kind kind,UUID caseId,UUID item,UUID source,BigDecimal retained,Set<UUID> touched) {
        List<UUID> demands=db.queryForList("SELECT DISTINCT demand_id FROM production_material_supply_pegs"
                +" WHERE supply_type=:type AND supply_item_id=:source ORDER BY demand_id",
                args("type",kind.requestPegType,"source",source),UUID.class);
        if(demands.isEmpty())return;
        db.queryForList("SELECT id FROM production_material_demands WHERE id IN (:ids) ORDER BY id FOR UPDATE",args("ids",demands));
        db.queryForList("SELECT id FROM production_material_supply_pegs WHERE demand_id IN (:ids) ORDER BY id FOR UPDATE",args("ids",demands));
        List<Map<String,Object>> transfers=db.queryForList("""
                SELECT t.*,p.allocated_qty-p.consumed_qty-p.released_qty AS available,
                    fn_procurement_transfer_net_qty(:type,t.id) AS net_qty
                FROM %1$s t JOIN production_material_supply_pegs p ON p.id=t.to_peg_id
                WHERE t.order_item_id=:item AND t.%2$s=:source AND t.status='EFFECTIVE'
                ORDER BY t.created_at DESC,t.id DESC FOR UPDATE OF t
                """.formatted(kind.transferTable,kind.sourceColumn),args("type",kind.name(),"item",item,"source",source));
        BigDecimal release=transfers.stream().map(t->amount(t,"net_qty")).reduce(BigDecimal.ZERO,BigDecimal::add)
                .subtract(retained).max(BigDecimal.ZERO);
        for(Map<String,Object> transfer:transfers) {
            BigDecimal quantity=release.min(amount(transfer,"available")).min(amount(transfer,"net_qty"));
            if(quantity.signum()<=0)continue;
            UUID actor=currentUser.requireId();
            db.update("""
                    INSERT INTO procurement_order_termination_peg_changes(case_id,order_type,transfer_id,source_peg_id,target_peg_id,qty_base)
                    VALUES (:case,:type,:transfer,:source,:target,:qty)
                    """,args("case",caseId,"type",kind.name(),"transfer",transfer.get("id"),"source",transfer.get("from_peg_id"),
                        "target",transfer.get("to_peg_id"),"qty",quantity));
            int target=db.update("""
                    UPDATE production_material_supply_pegs SET released_qty=released_qty+:qty,
                        status=CASE WHEN consumed_qty+released_qty+:qty=allocated_qty THEN 'RELEASED' ELSE 'EFFECTIVE' END,
                        lock_version=lock_version+1,updated_at=now(),updated_by=:actor
                    WHERE id=:id AND status<>'REVERSED' AND allocated_qty>=consumed_qty+released_qty+:qty
                    """,args("id",transfer.get("to_peg_id"),"qty",quantity,"actor",actor));
            int origin=db.update("""
                    UPDATE production_material_supply_pegs SET released_qty=released_qty-:qty,
                        status=CASE WHEN consumed_qty+released_qty-:qty=allocated_qty THEN 'RELEASED' ELSE 'EFFECTIVE' END,
                        lock_version=lock_version+1,updated_at=now(),updated_by=:actor
                    WHERE id=:id AND status<>'REVERSED' AND released_qty>=:qty
                    """,args("id",transfer.get("from_peg_id"),"qty",quantity,"actor",actor));
            if(target!=1||origin!=1)throw conflict("原订单供给已使用，不能结束该来源剩余量");
            touched.add((UUID)transfer.get("demand_id"));release=release.subtract(quantity);
        }
        if(release.signum()>0)throw conflict("剩余来源已被实物使用，请先核对原来源流转");
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void linkReplacement(String type, UUID orderId, UUID replacementOrderId, UUID caseId) {
        Kind kind=Kind.of(type);
        List<Map<String,Object>> replacementLines=db.queryForList("SELECT id,line_no,qty,"+
                (kind==Kind.PURCHASE?"CASE WHEN quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN gift_qty ELSE 0 END":"0::numeric")
                +" AS gift_qty FROM "+kind.prefix+"_order_items WHERE order_id=:order AND NOT is_deleted",
                args("order",replacementOrderId));
        if(replacementLines.stream().anyMatch(row->row.get("line_no")==null)
                || replacementLines.stream().map(row->row.get("line_no")).distinct().count()!=replacementLines.size())
            throw conflict("重建单的原明细行号不唯一，请先核对原订单");
        List<Map<String,Object>> shares=db.queryForList("""
                SELECT s.*,old_item.line_no AS order_line,new_item.id AS replacement_item_id
                FROM procurement_order_termination_sources s
                JOIN %1$s_order_items old_item ON old_item.id=s.order_item_id
                JOIN %1$s_order_items new_item ON new_item.order_id=:replacement AND new_item.line_no=old_item.line_no
                    AND new_item.goods_id=old_item.goods_id AND new_item.color_id IS NOT DISTINCT FROM old_item.color_id
                    AND new_item.unit_id IS NOT DISTINCT FROM old_item.unit_id AND new_item.unit_rate=old_item.unit_rate
                    AND NOT new_item.is_deleted
                WHERE s.case_id=:case AND s.order_type=:type AND s.order_id=:order
                ORDER BY old_item.line_no,s.line_no,s.id
                """.formatted(kind.prefix),args("replacement",replacementOrderId,"case",caseId,"type",type,"order",orderId));
        Long expected=db.queryForObject("SELECT COUNT(*) FROM procurement_order_termination_sources WHERE case_id=:case",
                args("case",caseId),Long.class);
        if(expected==null||shares.size()!=expected)throw conflict("重建单的原行对应关系已变化，不能猜测来源");
        for(Map<String,Object> replacement:replacementLines) {
            UUID item=(UUID)replacement.get("id");
            List<Map<String,Object>> itemShares=shares.stream().filter(share->item.equals(share.get("replacement_item_id"))).toList();
            if(itemShares.isEmpty())continue; // A standalone historical line still has no manufactured source.
            if(itemShares.stream().map(share->amount(share,"released_qty")).reduce(BigDecimal.ZERO,BigDecimal::add)
                    .compareTo(amount(replacement,"qty"))!=0
                    || itemShares.stream().map(share->amount(share,"released_gift_qty")).reduce(BigDecimal.ZERO,BigDecimal::add)
                    .compareTo(amount(replacement,"gift_qty"))!=0)
                throw conflict("重建明细与原单释放的收费量、赠品量不一致");
        }
        Set<UUID> items=new LinkedHashSet<>();
        for(Map<String,Object> share:shares) {
            UUID item=(UUID)share.get("replacement_item_id");
            if(items.add(item)) {
                db.update("DELETE FROM "+kind.prefix+"_order_item_sources WHERE order_item_id=:item",args("item",item));
                db.update("UPDATE "+kind.prefix+"_order_items SET "+kind.sourceColumn+"=:source WHERE id=:item",
                        args("item",item,"source",share.get("source_item_id")));
            }
            String giftColumn=kind==Kind.PURCHASE?",allocated_gift_qty":"";
            String giftValue=kind==Kind.PURCHASE?",:gift":"";
            db.update("INSERT INTO "+kind.prefix+"_order_item_sources(order_item_id,"+kind.sourceColumn
                    +",alloc_qty,line_no,created_by"+giftColumn+") VALUES (:item,:source,:qty,:line,:actor"+giftValue+")",
                    args("item",item,"source",share.get("source_item_id"),"qty",share.get("released_qty"),
                        "gift",share.get("released_gift_qty"),"line",share.get("line_no"),"actor",currentUser.requireId()));
        }
    }

    private enum Kind {
        PURCHASE("purchase","request","request_id","request_item_id","production_material_peg_transfers","PURCHASE_REQUEST_ITEM"),
        SUBCONTRACT("subcontract","application","application_id","application_item_id","production_material_subcontract_peg_transfers","SUBCONTRACT_APPLICATION_ITEM");
        final String prefix,sourceType,headerColumn,sourceColumn,transferTable,requestPegType;
        Kind(String prefix,String sourceType,String headerColumn,String sourceColumn,String transferTable,String requestPegType) {
            this.prefix=prefix;this.sourceType=sourceType;this.headerColumn=headerColumn;this.sourceColumn=sourceColumn;
            this.transferTable=transferTable;this.requestPegType=requestPegType;
        }
        static Kind of(String value) {if("PURCHASE".equals(value))return PURCHASE;if("SUBCONTRACT".equals(value))return SUBCONTRACT;throw conflict("未知订单类型");}
    }
    private static Map<String,Object> args(Object...pairs) {Map<String,Object> result=new HashMap<>();for(int i=0;i<pairs.length;i+=2)result.put((String)pairs[i],pairs[i+1]);return result;}
    private static BigDecimal amount(Map<String,Object> row,String name) {Object value=row.get(name);return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static BigDecimal zero(BigDecimal value) {return value==null?BigDecimal.ZERO:value;}
    private static ApiException conflict(String message) {return new ApiException(ErrorCode.CONFLICT,message);}
}
