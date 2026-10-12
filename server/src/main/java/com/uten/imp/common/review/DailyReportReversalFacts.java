package com.uten.imp.common.review;

import jakarta.persistence.EntityManager;
import java.util.List;
import java.util.UUID;

/** Stored daily-report inputs and the exact source/custody facts used by its pure reversal guards. */
public final class DailyReportReversalFacts {
    private DailyReportReversalFacts() { }
    public static String read(EntityManager em,UUID id) {
        String dependencies=String.valueOf(em.createNativeQuery("""
            WITH items AS (SELECT * FROM production_daily_report_items WHERE report_id=:id),
            segments AS (SELECT s.* FROM production_execution_segments s WHERE s.id IN(SELECT execution_segment_id FROM items)),
            links AS (SELECT l.* FROM plan_order_item_links l WHERE l.plan_item_id IN(SELECT plan_item_id FROM items)),
            authorizations AS (SELECT a.* FROM production_fqc_recovery_authorizations a WHERE a.source_report_item_id IN(SELECT id FROM items) OR a.id IN(SELECT fqc_recovery_authorization_id FROM items)),
            cycles AS (SELECT c.* FROM production_fqc_replenishment_cycles c WHERE c.authorization_id IN(SELECT id FROM authorizations)),
            demands AS (SELECT d.* FROM production_material_demands d WHERE d.execution_segment_id IN(SELECT id FROM segments)
                OR d.id IN(SELECT demand_id FROM production_daily_report_material_usages WHERE report_id=:id)
                OR d.fqc_recovery_authorization_id IN(SELECT id FROM authorizations)),
            settlements AS (SELECT e.* FROM production_material_settlement_events e WHERE e.daily_report_id=:id),
            postings AS (SELECT p.* FROM production_material_settlement_postings p WHERE p.event_id IN(SELECT id FROM settlements)
                OR p.source_posting_id IN(SELECT original.id FROM production_material_settlement_postings original WHERE original.event_id IN(SELECT id FROM settlements))),
            cost_roots AS (SELECT root.* FROM stock_value_nodes root WHERE root.id IN(SELECT event.result_node_id FROM stock_value_events event WHERE event.source_event_id IN(SELECT id FROM postings))),
            generated_docs AS (SELECT d.* FROM stock_documents d WHERE d.source_daily_report_id=:id)
            SELECT jsonb_build_object(
                'planItems',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM production_plan_items p WHERE p.id IN(SELECT plan_item_id FROM items)),
                'planHeaders',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM production_plans p WHERE p.id IN(SELECT plan_id FROM production_plan_items WHERE id IN(SELECT plan_item_id FROM items)) OR p.source_daily_report_id=:id),
                'links',(SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM links l),
                'orders',(SELECT jsonb_agg(jsonb_build_object('line',to_jsonb(o),'header',to_jsonb(h)) ORDER BY o.id) FROM sales_order_items o JOIN sales_orders h ON h.id=o.order_id WHERE o.id IN(SELECT order_item_id FROM links)),
                'segments',(SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) FROM segments s),
                'allocations',(SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) FROM execution_segment_sales_allocations a WHERE a.execution_segment_id IN(SELECT id FROM segments)),
                'demands',(SELECT jsonb_agg(to_jsonb(d) ORDER BY d.id) FROM demands d),
                'reservations',(SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id) FROM stock_reservations r WHERE r.demand_id IN(SELECT id FROM demands)),
                'periodicBindings',(SELECT jsonb_agg(to_jsonb(b) ORDER BY b.id) FROM production_execution_periodic_materials b WHERE b.execution_segment_id IN(SELECT id FROM segments)),
                'periods',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM workshop_material_periods p WHERE p.bin_warehouse_id IN(SELECT bin_warehouse_id FROM production_execution_periodic_materials WHERE execution_segment_id IN(SELECT id FROM segments))),
                'settlements',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM settlements e),
                'postings',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM postings p),
                'costRoots',(SELECT jsonb_agg(jsonb_build_object('root',to_jsonb(r),'returnHead',to_jsonb(h),'consumptionHead',to_jsonb(c)) ORDER BY r.id) FROM cost_roots r LEFT JOIN stock_value_nodes h ON h.id=r.return_head_id LEFT JOIN stock_value_nodes c ON c.id=r.consumption_return_head_id),
                'stockDocuments',(SELECT jsonb_agg(to_jsonb(d) ORDER BY d.id) FROM generated_docs d),
                'stockItems',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM stock_document_items i WHERE i.doc_id IN(SELECT id FROM generated_docs)),
                'FQC',(SELECT jsonb_agg(to_jsonb(q) ORDER BY q.id) FROM production_fqc_inspections q WHERE q.source_report_id=:id),
                'recovery',(SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) FROM authorizations a),
                'recoveryAllocations',(SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) FROM production_fqc_recovery_allocation_events a WHERE a.authorization_id IN(SELECT id FROM authorizations)),
                'cycles',(SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id) FROM cycles c),
                'recoveryDraw',(SELECT jsonb_agg(jsonb_build_object('link',to_jsonb(l),'header',to_jsonb(d),'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM stock_document_items i WHERE i.doc_id=d.id)) ORDER BY l.cycle_id) FROM production_fqc_replenishment_draw_links l JOIN stock_documents d ON d.id=l.stock_document_id WHERE l.cycle_id IN(SELECT id FROM cycles)),
                'caps',(SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id) FROM production_daily_report_target_events c WHERE c.report_id=:id),
                'materialReleases',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM production_daily_report_material_release_events e WHERE e.report_id=:id),
                'transfers',(SELECT jsonb_agg(jsonb_build_object('header',to_jsonb(t),'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM production_workshop_direct_transfer_items i WHERE i.transfer_id=t.id)) ORDER BY t.id) FROM production_workshop_direct_transfers t WHERE t.source_report_id=:id)
            )::text
            """).setParameter("id",id).getSingleResult());
        return String.join("\n",List.of(DocumentDraftReview.storedInputs(em,DocumentDraftReview.Kind.DAILY_REPORT,id),dependencies,
                DailyReportApprovalReturnDependencies.facts(em,id)));
    }
}
