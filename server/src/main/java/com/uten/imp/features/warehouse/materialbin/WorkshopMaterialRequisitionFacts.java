package com.uten.imp.features.warehouse.materialbin;

/** Request lines remain command identities; completed physical rows are immutable posting identities. */
public final class WorkshopMaterialRequisitionFacts {
    private WorkshopMaterialRequisitionFacts() {}

    /** Requires the original requisition line alias {@code line}; exposes one row per real posting. */
    public static String physicalJoin() {
        return """
                JOIN LATERAL (
                    SELECT line.id::text AS line_key,line.id AS item_id,
                           line.suggested_leaf_warehouse_id AS leaf_warehouse_id,
                           line.requested_qty AS quantity,line.requested_qty,line.fulfilled_qty,
                           NULL::uuid AS posting_id,NULL::uuid AS document_id,NULL::text AS bill_no
                    WHERE line.fulfilled_qty=0
                    UNION ALL
                    SELECT line.id::text || '~' || posting.id::text,posting.id,posting.leaf_warehouse_id,
                           posting.qty,NULL::numeric,posting.qty,posting.id,item.doc_id,document.bill_no
                    FROM workshop_material_requisition_postings posting
                    JOIN stock_document_items item ON item.id=posting.stock_document_item_id
                    JOIN stock_documents document ON document.id=item.doc_id
                    WHERE posting.line_id=line.id
                ) physical ON TRUE
                """;
    }
}
