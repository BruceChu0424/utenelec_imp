-- V794: AI use auditing records accepted questions separately from temporary job input/result bytes.
-- Billing prices are administrator estimates, snapshotted per attempt; never rewrite old costs.
ALTER TABLE ai_providers
    ADD COLUMN billing_mode varchar(20) NOT NULL DEFAULT 'UNKNOWN'
        CHECK (billing_mode IN ('UNKNOWN','METERED','SUBSCRIPTION')),
    ADD COLUMN billing_currency varchar(3),
    ADD COLUMN billing_input_per_million numeric(24,10),
    ADD COLUMN billing_output_per_million numeric(24,10),
    ADD COLUMN billing_model varchar(128),
    ADD CONSTRAINT ck_ai_provider_billing CHECK (
        (billing_currency IS NULL OR billing_currency ~ '^[A-Z]{3}$')
        AND (billing_input_per_million IS NULL OR billing_input_per_million >= 0)
        AND (billing_output_per_million IS NULL OR billing_output_per_million >= 0)
        AND (billing_mode <> 'METERED' OR (billing_currency IS NOT NULL
            AND billing_input_per_million IS NOT NULL AND billing_output_per_million IS NOT NULL
            AND billing_model IS NOT NULL)));

ALTER TABLE ai_call_logs
    ADD COLUMN employee_id uuid,
    ADD COLUMN usage_capture_version smallint NOT NULL DEFAULT 0,
    ADD COLUMN billing_mode varchar(20) NOT NULL DEFAULT 'UNKNOWN',
    ADD COLUMN billing_currency varchar(3),
    ADD COLUMN billing_provider_version bigint,
    ADD COLUMN billing_input_per_million numeric(24,10),
    ADD COLUMN billing_output_per_million numeric(24,10),
    ADD COLUMN estimated_cost numeric(38,18),
    ADD COLUMN actual_cost numeric(38,18),
    ADD COLUMN actual_cost_source varchar(64),
    ADD CONSTRAINT ck_ai_call_billing_amounts CHECK (
        (estimated_cost IS NULL OR (estimated_cost >= 0 AND billing_currency IS NOT NULL))
        AND (actual_cost IS NULL OR (actual_cost >= 0 AND billing_currency IS NOT NULL AND actual_cost_source IS NOT NULL)));
CREATE INDEX idx_ai_call_logs_job ON ai_call_logs(job_id,created_at);
CREATE INDEX idx_ai_call_logs_user_created ON ai_call_logs(user_id,created_at DESC);
COMMENT ON COLUMN ai_call_logs.usage_capture_version IS
    '0 means legacy SDK usage: a saved zero may have been an absent field. Version 1 preserves absent/invalid usage as NULL.';
COMMENT ON COLUMN ai_call_logs.estimated_cost IS
    'Estimate using the model-matched administrator price captured before the logical call. Includes each retry attempt; not a supplier invoice.';
COMMENT ON COLUMN ai_call_logs.actual_cost IS
    'Only for a verified supplier-reported charge with actual_cost_source. Current integrations do not populate it.';

ALTER TABLE ai_jobs
    ADD COLUMN audit_question varchar(2000),
    ADD COLUMN audit_question_state varchar(24) NOT NULL DEFAULT 'UNAVAILABLE'
        CHECK (audit_question_state IN ('CAPTURED','REDACTED','UNAVAILABLE','NOT_APPLICABLE')),
    ADD COLUMN audit_intent varchar(48),
    ADD COLUMN audit_tool varchar(48);
COMMENT ON COLUMN ai_jobs.audit_question IS
    'Bounded credential-redacted user question captured at accepted enqueue; not a system prompt, provider reply, or uploaded file content. No legacy backfill.';

-- Configuration changes retain the existing secret-safe column-scoped audit policy.
SELECT fn_audit_track_table('ai_providers','COLUMN_SCOPED','system',false,
    ARRAY['name','preset','region','protocol','base_url','model','json_mode','thinking_control',
          'send_temperature','supports_vision','max_output_tokens','timeout_seconds','enabled','is_default',
          'billing_mode','billing_currency','billing_input_per_million','billing_output_per_million','billing_model'],false);
CREATE OR REPLACE FUNCTION fn_ai_provider_public_history(snapshot jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $function$
SELECT jsonb_build_object('name',snapshot->'name','preset',snapshot->'preset','region',snapshot->'region',
    'protocol',snapshot->'protocol','baseUrl',snapshot->'base_url','model',snapshot->'model',
    'jsonMode',snapshot->'json_mode','thinkingControl',snapshot->'thinking_control','sendTemperature',snapshot->'send_temperature',
    'supportsVision',snapshot->'supports_vision','maxOutputTokens',snapshot->'max_output_tokens','timeoutSeconds',snapshot->'timeout_seconds',
    'enabled',snapshot->'enabled','isDefault',snapshot->'is_default','deleted',snapshot->'is_deleted',
    'deletedAt',snapshot->'deleted_at','deletedBy',snapshot->'deleted_by','deletedReason',snapshot->'deleted_reason',
    'apiKeyConfigured',snapshot->>'secret' IS NOT NULL,'version',snapshot->'version',
    'billingMode',snapshot->'billing_mode','billingCurrency',snapshot->'billing_currency',
    'billingInputPerMillion',snapshot->'billing_input_per_million','billingOutputPerMillion',snapshot->'billing_output_per_million',
    'billingModel',snapshot->'billing_model')
$function$;
