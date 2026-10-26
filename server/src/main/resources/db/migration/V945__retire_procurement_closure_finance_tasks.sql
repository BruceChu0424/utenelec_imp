-- Historical unexecuted closure requests belong to their procurement/subcontract owner.
-- Retain the case and notification evidence; retire only obsolete finance task delivery.
DO $migration$
DECLARE definition text; before_predicate text; after_predicate text;
BEGIN
    definition:=pg_get_functiondef('fn_notice_business_action_visible(uuid,text,text,uuid,text,text,text,text,text,text)'::regprocedure);
    before_predicate:='SELECT 1 FROM procurement_order_approval_cases task WHERE task.id=p_id AND task.status=''PENDING''';
    after_predicate:=before_predicate||' AND task.request_type=''ORDER''';
    IF (length(definition)-length(replace(definition,before_predicate,'')))/length(before_predicate)<>1 THEN
        RAISE EXCEPTION 'Unexpected procurement notice action predicate; review the current source before upgrading';
    END IF;
    EXECUTE replace(definition,before_predicate,after_predicate);
END;
$migration$;

INSERT INTO notice_user_states(notice_id,user_id,read_at)
SELECT n.id,n.audience_user_id,now() FROM notices n
JOIN procurement_order_approval_cases c ON n.aggregate_kind='PROCUREMENT_APPROVAL_CASE' AND n.aggregate_id=c.id
WHERE c.request_type<>'ORDER' AND c.status='PENDING' AND n.resolved_at IS NULL AND n.audience_user_id IS NOT NULL
ON CONFLICT(notice_id,user_id) DO UPDATE SET read_at=COALESCE(notice_user_states.read_at,EXCLUDED.read_at)
WHERE notice_user_states.deleted_at IS NULL;

UPDATE notices n SET resolved_at=now(),resolved_reason='DIRECT_CLOSURE_POLICY'
FROM procurement_order_approval_cases c
WHERE n.aggregate_kind='PROCUREMENT_APPROVAL_CASE' AND n.aggregate_id=c.id
  AND c.request_type<>'ORDER' AND c.status='PENDING' AND n.resolved_at IS NULL;
