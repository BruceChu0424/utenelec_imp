CREATE TABLE expense_claim_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id UUID NOT NULL REFERENCES expense_claims(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,actor_employee_id UUID REFERENCES employees(id) ON DELETE RESTRICT,
    actor_name_snapshot TEXT NOT NULL,remark TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,created_by UUID,updated_by UUID,
    CONSTRAINT expense_claim_events_type_chk CHECK(event_type IN
        ('CREATED','SUBMITTED','WITHDRAWN','EDITED','APPROVED','REJECTED','PAID')),
    CONSTRAINT expense_claim_events_text_len_chk CHECK(char_length(actor_name_snapshot) BETWEEN 1 AND 100
        AND (remark IS NULL OR char_length(remark)<=1000))
)
