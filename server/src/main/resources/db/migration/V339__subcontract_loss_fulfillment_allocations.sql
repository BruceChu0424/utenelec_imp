-- V339: exact physical-document line allocation for non-cash subcontract loss
-- compensation. A document header or evidence string alone cannot close a claim.

CREATE TABLE subcontract_loss_fulfillment_allocations (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resolution_id       UUID NOT NULL REFERENCES subcontract_loss_resolutions(id) ON DELETE RESTRICT,
    case_line_id        UUID NOT NULL REFERENCES subcontract_loss_case_lines(id) ON DELETE RESTRICT,
    document_type       TEXT NOT NULL CHECK (document_type IN (
        'SUBCONTRACT_RECEIPT', 'SUBCONTRACT_MATERIAL_RETURN')),
    document_id         UUID NOT NULL,
    document_item_id    UUID NOT NULL,
    quantity            NUMERIC(18,4) NOT NULL CHECK (quantity > 0),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          UUID REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT subcontract_loss_fulfillment_resolution_uk UNIQUE (resolution_id),
    CONSTRAINT subcontract_loss_fulfillment_document_item_uk
        UNIQUE (document_type, document_item_id)
);

CREATE INDEX idx_subcontract_loss_fulfillment_case_line
    ON subcontract_loss_fulfillment_allocations(case_line_id, id);

COMMENT ON TABLE subcontract_loss_fulfillment_allocations IS
    'Exact approved receipt/material-return line consumed once as physical fulfillment of one loss resolution';
