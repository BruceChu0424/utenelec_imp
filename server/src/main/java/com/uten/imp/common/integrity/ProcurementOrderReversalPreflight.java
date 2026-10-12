package com.uten.imp.common.integrity;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;

/** Fixed purchase/subcontract source checks; caller owns authorization and the final lock order. */
public final class ProcurementOrderReversalPreflight {
    private ProcurementOrderReversalPreflight() { }
    private record Tables(String header,String items,String receipt,String receiptItems,String sources,String sourceKey,
                          String requests,String requestKey,String transfers) { }
    private static Tables tables(String type) {
        return switch(type) {
            case "PURCHASE" -> new Tables("purchase_orders","purchase_order_items","purchase_receipts","purchase_receipt_items",
                "purchase_order_item_sources","request_item_id","purchase_request_items","request_item_id","production_material_peg_transfers");
            case "SUBCONTRACT" -> new Tables("subcontract_orders","subcontract_order_items","subcontract_receipts","subcontract_receipt_items",
                "subcontract_order_item_sources","application_item_id","subcontract_application_items","application_item_id","production_material_subcontract_peg_transfers");
            default -> throw new IllegalArgumentException("Unsupported procurement family");
        };
    }
    private static boolean exists(EntityManager em,String sql,UUID id,String type) {
        var query=em.createNativeQuery(sql).setParameter("id",id);
        if(sql.contains(":type")) query.setParameter("type",type);
        if(sql.contains(":now")) query.setParameter("now",OffsetDateTime.now());
        return Boolean.TRUE.equals(query.getSingleResult());
    }
    public static void require(EntityManager em,String type,UUID id) {
        Tables t=tables(type);
        if(exists(em,"""
            SELECT EXISTS(SELECT 1 FROM procurement_order_approval_cases c JOIN task_claims claim
              ON claim.target_type='PROCUREMENT_FINANCE_APPROVE' AND claim.target_key=CAST(c.id AS text)
              WHERE c.order_type=:type AND c.order_id=:id AND c.status='PENDING'
                AND claim.released_at IS NULL AND claim.lease_until>:now)
            """,id,type)) throw conflict("财务审核已被认领，请先退出或完成这次审核，再反审订货单");
        if(exists(em,"""
            SELECT EXISTS(SELECT 1 FROM procurement_arrival_exceptions WHERE order_type=:type AND order_id=:id
              AND status NOT IN('CLOSED','CANCELED'))
            """,id,type)) throw conflict("仍有未办结到货异常，请先完成接收或供应商退回任务");
        if(exists(em,"SELECT EXISTS(SELECT 1 FROM "+t.receipt()+" r JOIN "+t.receiptItems()+" ri ON ri.receipt_id=r.id JOIN "+t.items()+" oi ON oi.id=ri.order_item_id WHERE oi.order_id=:id AND NOT r.is_deleted AND NOT ri.is_deleted AND r.status<>-1)",id,type))
            throw conflict("存在有效收货草稿或已审核收货，请先撤销下游收货单");
        String net="fn_procurement_transfer_net_qty('"+type+"',transfer.id)";
        if(exists(em,"SELECT EXISTS(SELECT 1 FROM "+t.transfers()+" transfer JOIN "+t.items()+" oi ON oi.id=transfer.order_item_id JOIN production_material_supply_pegs original ON original.id=transfer.from_peg_id JOIN production_material_supply_pegs target ON target.id=transfer.to_peg_id WHERE oi.order_id=:id AND transfer.status='EFFECTIVE' AND (target.consumed_qty>0 OR original.released_qty<"+net+"))",id,type))
            throw conflict("生产供给已被收货使用或来源迁移账不一致，请先处理下游并核对供给记录");
        String sourceAmounts=sourceAmounts(t,type);
        String giftCounter="PURCHASE".equals(type) ? "COALESCE(request.gift_ordered_qty,0)<release.gift" : "FALSE";
        if(exists(em,"SELECT EXISTS(SELECT 1 FROM (SELECT source_id,SUM(qty) qty,SUM(gift) gift FROM ("+sourceAmounts+") a GROUP BY source_id) release LEFT JOIN "+t.requests()+" request ON request.id=release.source_id WHERE request.id IS NULL OR COALESCE(request.ordered_qty,0)<release.qty OR "+giftCounter+")",id,type))
            throw conflict("申请来源已下单数量不足或来源行已不存在，请先核对联动数据");

    }
    private static String sourceAmounts(Tables t,String type) {
        String explicitGift="PURCHASE".equals(type)?"COALESCE(src.allocated_gift_qty,0)":"0::numeric";
        String legacyGift="PURCHASE".equals(type)?"CASE WHEN oi.quantity_semantics='CHARGED_PLUS_GIFT_V1' THEN COALESCE(oi.gift_qty,0) ELSE 0 END":"0::numeric";
        return "SELECT src."+t.sourceKey()+" source_id,src.alloc_qty qty,"+explicitGift+" gift FROM "+t.sources()+" src JOIN "+t.items()+" oi ON oi.id=src.order_item_id WHERE oi.order_id=:id AND oi."+t.sourceKey()+" IS NOT NULL "
          +"UNION ALL SELECT oi."+t.sourceKey()+",oi.qty,"+legacyGift+" FROM "+t.items()+" oi WHERE oi.order_id=:id AND oi."+t.sourceKey()+" IS NOT NULL AND NOT EXISTS(SELECT 1 FROM "+t.sources()+" src WHERE src.order_item_id=oi.id)";
    }
    public static String facts(EntityManager em,String type,UUID id) {
        Tables t=tables(type);
        String sql="SELECT jsonb_build_object('header',to_jsonb(h),'items',COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM "+t.items()+" i WHERE i.order_id=h.id),'[]'::jsonb),"
            +"'receipts',COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM "+t.receipt()+" r WHERE r.id IN(SELECT ri.receipt_id FROM "+t.receiptItems()+" ri JOIN "+t.items()+" oi ON oi.id=ri.order_item_id WHERE oi.order_id=h.id)),'[]'::jsonb),"
            +"'cases',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id) FROM procurement_order_approval_cases c WHERE c.order_id=h.id AND c.order_type=:type),'[]'::jsonb),"
            +"'claims',COALESCE((SELECT jsonb_agg(to_jsonb(claim) ORDER BY claim.id) FROM task_claims claim WHERE claim.target_type='PROCUREMENT_FINANCE_APPROVE' AND claim.target_key IN(SELECT CAST(c.id AS text) FROM procurement_order_approval_cases c WHERE c.order_id=h.id AND c.order_type=:type)),'[]'::jsonb),"
            +"'exceptions',COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM procurement_arrival_exceptions e WHERE e.order_id=h.id AND e.order_type=:type),'[]'::jsonb),"
            +"'sources',COALESCE((SELECT jsonb_agg(jsonb_build_object('source',to_jsonb(src),'request',to_jsonb(r)) ORDER BY to_jsonb(src)::text) FROM "+t.sources()+" src JOIN "+t.items()+" oi ON oi.id=src.order_item_id LEFT JOIN "+t.requests()+" r ON r.id=src."+t.sourceKey()+" WHERE oi.order_id=h.id),'[]'::jsonb),"
            +"'fallbackSources',COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM "+t.requests()+" r WHERE r.id IN(SELECT oi."+t.sourceKey()+" FROM "+t.items()+" oi WHERE oi.order_id=h.id)),'[]'::jsonb),"
            +("SUBCONTRACT".equals(type)?"'materialFacts',jsonb_build_object('issue',COALESCE((SELECT jsonb_agg(jsonb_build_object('line',to_jsonb(i),'header',to_jsonb(d)) ORDER BY i.id) FROM subcontract_material_issue_items i JOIN subcontract_material_issues d ON d.id=i.issue_id JOIN subcontract_order_items o ON o.id=i.order_item_id WHERE o.order_id=h.id),'[]'::jsonb),'return',COALESCE((SELECT jsonb_agg(jsonb_build_object('line',to_jsonb(i),'header',to_jsonb(d)) ORDER BY i.id) FROM subcontract_material_return_items i JOIN subcontract_material_returns d ON d.id=i.material_return_id JOIN subcontract_order_items o ON o.id=i.order_item_id WHERE o.order_id=h.id),'[]'::jsonb),'waste',COALESCE((SELECT jsonb_agg(jsonb_build_object('line',to_jsonb(i),'header',to_jsonb(d)) ORDER BY i.id) FROM subcontract_waste_items i JOIN subcontract_wastes d ON d.id=i.waste_id JOIN subcontract_material_issue_items source_issue ON source_issue.id=i.material_issue_item_id JOIN subcontract_order_items o ON o.id=source_issue.order_item_id WHERE o.order_id=h.id),'[]'::jsonb)),":"")
            +"'pegs',COALESCE((SELECT jsonb_agg(jsonb_build_object('transfer',to_jsonb(tr),'source',to_jsonb(s),'target',to_jsonb(d)) ORDER BY tr.id) FROM "+t.transfers()+" tr JOIN "+t.items()+" oi ON oi.id=tr.order_item_id JOIN production_material_supply_pegs s ON s.id=tr.from_peg_id JOIN production_material_supply_pegs d ON d.id=tr.to_peg_id WHERE oi.order_id=h.id),'[]'::jsonb))::text FROM "+t.header()+" h WHERE h.id=:id";
        return String.valueOf(em.createNativeQuery(sql).setParameter("id",id).setParameter("type",type).getSingleResult());
    }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT,message); }
}
