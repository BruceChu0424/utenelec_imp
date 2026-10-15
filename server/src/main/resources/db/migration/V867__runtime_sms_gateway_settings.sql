-- Company-local SMS configuration. ENV seed preserves existing deployment behavior.
-- Credentials are encrypted in Java using separate table/column/row-bound AES-GCM contexts.
CREATE TABLE sms_gateway_settings (
    id uuid PRIMARY KEY CHECK(id='7f08141b-021b-4f46-9d42-d1db854d1198'::uuid),
    version bigint NOT NULL DEFAULT 0 CHECK(version>=0),
    mode text NOT NULL CHECK(mode IN ('ENV','OVERRIDE')),
    provider text NOT NULL CHECK(provider IN ('DISABLED','ALIYUN','LOG')),
    endpoint varchar(253), sign_name varchar(64), template_code varchar(64),
    access_key_id_cipher text, access_key_secret_cipher text, access_key_id_hint varchar(16),
    updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid REFERENCES users(id),
    CHECK((access_key_id_cipher IS NULL)=(access_key_secret_cipher IS NULL)),
    CHECK(mode<>'ENV' OR (provider='DISABLED' AND endpoint IS NULL AND sign_name IS NULL AND template_code IS NULL
          AND access_key_id_cipher IS NULL AND access_key_secret_cipher IS NULL AND access_key_id_hint IS NULL)),
    CHECK(mode<>'OVERRIDE' OR ((endpoint IS NULL AND provider IN ('DISABLED','LOG')) OR endpoint IN (
        'dysmsapi.aliyuncs.com',
        'dysmsapi.ap-southeast-1.aliyuncs.com',
        'dysmsapi.ap-southeast-5.aliyuncs.com',
        'dysmsapi.eu-central-1.aliyuncs.com',
        'dysmsapi-xman.vpc-proxy.aliyuncs.com',
        'dysmsapi-xman-vpc.ap-southeast-5.aliyuncs.com',
        'dysmsapi-xman-vpc.eu-central-1.aliyuncs.com'))),
    CHECK(mode<>'OVERRIDE' OR provider<>'ALIYUN' OR (endpoint IS NOT NULL AND access_key_id_cipher IS NOT NULL
          AND access_key_secret_cipher IS NOT NULL AND sign_name IS NOT NULL AND template_code IS NOT NULL))
);
INSERT INTO sms_gateway_settings(id,version,mode,provider)
VALUES('7f08141b-021b-4f46-9d42-d1db854d1198',0,'ENV','DISABLED');

-- Resetting to ENV must not recreate revision zero or revive a stale edited form.
CREATE FUNCTION fn_guard_sms_gateway_settings_revision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'SMS configuration must return to ENV through a new revision, never deletion' USING ERRCODE='23514';
    END IF;
    IF NEW.id<>OLD.id OR NEW.version<>OLD.version+1 THEN
        RAISE EXCEPTION 'SMS configuration revision must advance exactly once' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_guard_sms_gateway_settings_revision BEFORE UPDATE OR DELETE ON sms_gateway_settings
FOR EACH ROW EXECUTE FUNCTION fn_guard_sms_gateway_settings_revision();
ALTER TABLE sms_gateway_settings ENABLE ALWAYS TRIGGER trg_guard_sms_gateway_settings_revision;
COMMENT ON TABLE sms_gateway_settings IS 'Company SMS runtime configuration; encrypted credentials never enter public responses or audit snapshots';
COMMENT ON COLUMN sms_gateway_settings.access_key_id_cipher IS 'SecretCipher AES-GCM; AAD sms_gateway_settings|access_key_id|singleton UUID';
COMMENT ON COLUMN sms_gateway_settings.access_key_secret_cipher IS 'SecretCipher AES-GCM; AAD sms_gateway_settings|access_key_secret|singleton UUID';

-- No INSERT/DELETE snapshots and no credential/hint columns in row audit.
SELECT public.fn_audit_track_table('sms_gateway_settings','COLUMN_SCOPED','system',false,
    ARRAY['mode','provider','endpoint','sign_name','template_code','version'],false,NULL::text);

DO $sms_reset_policy$
DECLARE definition text; anchor text := '(''system_settings'', ''PRESERVE'')';
BEGIN
    SELECT pg_get_functiondef('public.business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V867 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''sms_gateway_settings'', ''PRESERVE'')');
END $sms_reset_policy$;
