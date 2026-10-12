package com.uten.imp.common.review;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.util.UUID;

/** Pure dependency checks for generic draft recovery; original internal report reversal keeps its own contract. */
public final class DailyReportApprovalReturnDependencies {
    private DailyReportApprovalReturnDependencies() { }
    private static final String REQUESTS = """
            WITH commands AS (
                SELECT * FROM production_daily_report_commands
                WHERE report_id=:id AND command_kind='APPROVE'
            ), sources AS (
                SELECT command.id command_id,COALESCE(command.actor_user_id,command.created_by) actor_id,
                       3 protocol,review->>'planId' plan_id,review->>'materialExecutionSegmentId' segment_id,
                       review->>'demandId' demand_id
                FROM commands command
                CROSS JOIN LATERAL jsonb_array_elements(COALESCE(command.material_review_snapshot->'rows','[]'::jsonb)) review
                WHERE command.approval_protocol_version=3
                  AND EXISTS(SELECT 1 FROM jsonb_array_elements(COALESCE(command.material_decisions,'[]'::jsonb)) decision
                    WHERE decision->>'demandId'=review->>'demandId' AND decision->>'action'='RETURN')
                UNION ALL
                SELECT command.id,COALESCE(command.actor_user_id,command.created_by),2,
                       demand.plan_id::text,demand.execution_segment_id::text,demand.id::text
                FROM commands command
                JOIN (SELECT DISTINCT plan_id,material_execution_segment_id
                      FROM production_daily_report_material_usages WHERE report_id=:id) usage ON TRUE
                JOIN production_material_demands demand ON demand.plan_id=usage.plan_id
                    AND demand.execution_segment_id=usage.material_execution_segment_id
                WHERE command.approval_protocol_version IS NULL OR command.approval_protocol_version IN(1,2)
            ), requests AS (
                SELECT request.* FROM production_material_return_requests request
                LEFT JOIN stock_documents document ON document.id=request.id
                WHERE EXISTS(SELECT 1 FROM sources source
                    WHERE request.plan_id::text=source.plan_id AND request.execution_segment_id::text=source.segment_id
                      AND ((source.protocol=3 AND request.idempotency_key ~ ('^DRRET3-' || CAST(:id AS text) || '-'
                            || CAST(request.execution_segment_id AS text) || '-[0-9]+$'))
                           OR (source.protocol=2 AND request.idempotency_key='DRRET-' || CAST(:id AS text) || '-'
                            || CAST(request.execution_segment_id AS text)))
                      AND (source.actor_id=COALESCE(request.created_by,document.created_by)
                           OR source.actor_id IS NULL OR COALESCE(request.created_by,document.created_by) IS NULL)
                      AND EXISTS(SELECT 1 FROM production_material_return_request_items item
                          LEFT JOIN production_material_stock_postings issue ON issue.id=item.issue_posting_id
                          LEFT JOIN production_workshop_direct_transfer_items direct ON direct.id=item.direct_transfer_item_id
                          JOIN production_material_demands demand ON demand.id::text=source.demand_id
                          WHERE item.request_id=request.id AND (issue.demand_id=demand.id
                              OR direct.to_demand_id IN(demand.id,demand.split_root_demand_id))))
            )
            """;

    /** Cancellation is a real immutable command; a completed warehouse reversal also releases the physical dependency. */
    public static void requireResolved(EntityManager em,UUID reportId) {
        var blocked=em.createNativeQuery(REQUESTS+"""
                SELECT document.status FROM requests request
                LEFT JOIN stock_documents document ON document.id=request.id
                LEFT JOIN production_material_return_request_cancellations cancel ON cancel.request_id=request.id
                WHERE NOT COALESCE((cancel.id IS NOT NULL AND document.status=0 AND document.is_deleted)
                    OR (document.status=-1 AND NOT document.is_deleted),FALSE)
                ORDER BY CASE WHEN document.status=1 THEN 0 ELSE 1 END,request.id LIMIT 1
                """).setParameter("id",reportId).getResultList();
        if(blocked.isEmpty())return;
        Object status=blocked.getFirst();
        boolean received=status instanceof Number number && number.intValue()==1;
        throw new ApiException(ErrorCode.CONFLICT,received
                ? "本次审核生成的余料退仓已由仓库实收，请先按原仓库流程撤回退料，再反审日报"
                : "本次审核生成的余料退仓申请尚未撤回，请先取消未实收的退料申请，再反审日报");
    }

    /** Freeze all matching requests, their cancellations and warehouse facts; counts alone are not a source snapshot. */
    public static String facts(EntityManager em,UUID reportId) {
        return String.valueOf(em.createNativeQuery(REQUESTS+"""
                SELECT jsonb_build_object(
                    'commands',(SELECT jsonb_agg(to_jsonb(command) ORDER BY command.id) FROM commands command),
                    'requests',(SELECT jsonb_agg(jsonb_build_object(
                        'request',to_jsonb(request),'document',to_jsonb(document),'cancellation',to_jsonb(cancel),
                        'items',(SELECT jsonb_agg(to_jsonb(item) ORDER BY item.id)
                            FROM production_material_return_request_items item WHERE item.request_id=request.id),
                        'stockItems',(SELECT jsonb_agg(to_jsonb(item) ORDER BY item.id)
                            FROM stock_document_items item WHERE item.doc_id=request.id),
                        'receiving',(SELECT jsonb_agg(to_jsonb(receipt) ORDER BY receipt.id)
                            FROM production_material_return_receiving_confirmations receipt WHERE receipt.stock_document_id=request.id),
                        'movements',(SELECT jsonb_agg(to_jsonb(movement) ORDER BY movement.id)
                            FROM stock_movements movement WHERE movement.source_doc_type='STOCK_DOC' AND movement.source_doc_id=request.id)
                        ) ORDER BY request.id) FROM requests request
                        LEFT JOIN stock_documents document ON document.id=request.id
                        LEFT JOIN production_material_return_request_cancellations cancel ON cancel.request_id=request.id)
                )::text
                """).setParameter("id",reportId).getSingleResult());
    }
}
