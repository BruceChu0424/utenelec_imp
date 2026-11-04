-- Explicitly confirming receipt also means the recipient read the notice.
-- Repair historical acknowledgments without changing an existing read timestamp,
-- deletion, popup acknowledgment, snooze, or business task completion state.
INSERT INTO notice_user_states (notice_id, user_id, read_at)
SELECT ack.notice_id, ack.user_id, ack.acked_at
FROM notice_acknowledgments ack
WHERE true
ON CONFLICT (notice_id, user_id) DO UPDATE
SET read_at = COALESCE(notice_user_states.read_at, EXCLUDED.read_at)
WHERE notice_user_states.deleted_at IS NULL;
