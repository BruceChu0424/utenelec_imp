package com.uten.imp.common.review;
import jakarta.persistence.EntityManager;
import java.util.UUID;

/** All observational input used by generic stock reversal checks, without exposing the source rows. */
public final class StockDocumentReversalFacts {
    private StockDocumentReversalFacts() { }
    public static String read(EntityManager em,UUID id) {
        String cost=String.valueOf(em.createNativeQuery("""
            WITH items AS (SELECT * FROM stock_document_items WHERE doc_id=:id),
            movements AS (SELECT * FROM stock_movements WHERE source_doc_type='STOCK_DOC' AND source_doc_id=:id),
            pools AS (SELECT p.* FROM stock_value_pools p WHERE EXISTS(SELECT 1 FROM movements m
                WHERE m.warehouse_id=p.warehouse_id AND m.goods_id=p.goods_id AND m.color_id IS NOT DISTINCT FROM p.color_id)),
            events AS (SELECT e.* FROM stock_value_events e WHERE e.movement_id IN(SELECT id FROM movements)),
            originals AS (SELECT n.* FROM stock_value_nodes n WHERE n.id IN(SELECT result_node_id FROM events)
                OR n.id IN(SELECT result_head_id FROM events))
            SELECT jsonb_build_object(
                'movements',(SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) FROM movements m),
                'pool',(SELECT jsonb_agg(jsonb_build_object('pool',to_jsonb(p),'head',to_jsonb(h)) ORDER BY p.id) FROM pools p LEFT JOIN stock_value_nodes h ON h.id=p.head_node_id),
                'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM events e),
                'originals',(SELECT jsonb_agg(jsonb_build_object('node',to_jsonb(n),'returnHead',to_jsonb(h),'adjustmentHead',to_jsonb(a)) ORDER BY n.id) FROM originals n LEFT JOIN stock_value_nodes h ON h.id=n.return_head_id LEFT JOIN stock_value_nodes a ON a.id=n.adjustment_head_id),
                'balances',(SELECT jsonb_agg(to_jsonb(b) ORDER BY b.id) FROM stock_balances b WHERE b.goods_id IN(SELECT goods_id FROM items)),
                'reservations',(SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM stock_reservations r WHERE r.goods_id IN(SELECT goods_id FROM items)),
                'goods',(SELECT jsonb_agg(to_jsonb(g) ORDER BY g.id) FROM goods g WHERE g.id IN(SELECT goods_id FROM items)),
                'warehouses',(SELECT jsonb_agg(to_jsonb(w) ORDER BY w.id) FROM warehouses w WHERE w.id IN(SELECT warehouse_id FROM movements))
            )::text
            """).setParameter("id",id).getSingleResult());
        return DocumentDraftReview.storedInputs(em,DocumentDraftReview.Kind.STOCK,id)+"\n"+cost;
    }
}
