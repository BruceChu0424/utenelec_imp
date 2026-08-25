-- V394: append-only business reason for customer owner/read-sharing changes.
-- V393 supplies the aggregate access version and active visibility grants;
-- this event stream records why each before/after access decision was made.

CREATE TABLE client_access_change_events (
    id                         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id                  UUID NOT NULL,
    previous_owner_employee_id UUID,
    new_owner_employee_id      UUID NOT NULL,
    previous_viewer_ids        UUID[] NOT NULL DEFAULT ARRAY[]::UUID[],
    new_viewer_ids             UUID[] NOT NULL DEFAULT ARRAY[]::UUID[],
    resulting_access_version   BIGINT NOT NULL,
    reason                     TEXT NOT NULL,
    actor_user_id              UUID NOT NULL,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT client_access_change_events_client_fk
        FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE RESTRICT,
    CONSTRAINT client_access_change_events_previous_owner_fk
        FOREIGN KEY (previous_owner_employee_id) REFERENCES employees(id) ON DELETE RESTRICT,
    CONSTRAINT client_access_change_events_new_owner_fk
        FOREIGN KEY (new_owner_employee_id) REFERENCES employees(id) ON DELETE RESTRICT,
    CONSTRAINT client_access_change_events_actor_fk
        FOREIGN KEY (actor_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT client_access_change_events_version_chk
        CHECK (resulting_access_version >= 1),
    CONSTRAINT client_access_change_events_reason_chk
        CHECK (btrim(reason) <> '' AND char_length(reason) <= 1000)
);

CREATE INDEX idx_client_access_change_events_client
    ON client_access_change_events(client_id, created_at DESC, id DESC);

COMMENT ON TABLE client_access_change_events IS
    'Append-only reason and before/after responsibility evidence for customer owner and read-sharing changes';

CREATE OR REPLACE FUNCTION fn_reject_client_access_change_event_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'client access change events are append-only'
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_client_access_change_events_append_only
BEFORE UPDATE OR DELETE ON client_access_change_events
FOR EACH ROW EXECUTE FUNCTION fn_reject_client_access_change_event_mutation();

CREATE TRIGGER trg_audit_client_access_change_events
AFTER INSERT OR UPDATE OR DELETE ON client_access_change_events
FOR EACH ROW EXECUTE FUNCTION fn_audit();
