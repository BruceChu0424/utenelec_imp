-- V406: persist each recipient's explicit acknowledgement of a strong notice popup.
--
-- read_at remains the notification-center read state. popup_acknowledged_at only
-- suppresses replay of the foreground arrival popup across logins/devices; it does
-- not delete the notice or complete a business TODO.

ALTER TABLE notice_user_states
    ADD COLUMN IF NOT EXISTS popup_acknowledged_at TIMESTAMPTZ;

COMMENT ON COLUMN notice_user_states.popup_acknowledged_at IS
    'Recipient explicitly closed/opened the persistent notice popup; independent of notification read/task completion state';

CREATE INDEX IF NOT EXISTS idx_notice_user_states_popup_pending
    ON notice_user_states (user_id, notice_id)
    WHERE read_at IS NULL
      AND popup_acknowledged_at IS NULL
      AND deleted_at IS NULL;
