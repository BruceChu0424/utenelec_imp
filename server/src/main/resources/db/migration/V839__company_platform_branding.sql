-- One branding aggregate per connected company database. Small sanitized PNGs follow database backups.
CREATE TABLE platform_branding (
    id integer PRIMARY KEY CHECK (id=1),
    version integer NOT NULL DEFAULT 0 CHECK (version>=0),
    company_name varchar(120) NOT NULL CHECK (char_length(btrim(company_name)) BETWEEN 1 AND 120),
    company_aliases varchar(500) NOT NULL DEFAULT '',
    platform_name varchar(80) NOT NULL CHECK (char_length(btrim(platform_name)) BETWEEN 1 AND 80),
    tagline varchar(160) NOT NULL DEFAULT '',
    primary_color varchar(7) NOT NULL CHECK (primary_color ~ '^#[0-9A-F]{6}$'),
    secondary_color varchar(7) NOT NULL CHECK (secondary_color ~ '^#[0-9A-F]{6}$'),
    login_notice varchar(500) NOT NULL DEFAULT '',
    support_phone varchar(50) NOT NULL DEFAULT '',
    support_email varchar(120) NOT NULL DEFAULT '',
    website varchar(200) NOT NULL DEFAULT '',
    logo_png bytea CHECK (logo_png IS NULL OR octet_length(logo_png) BETWEEN 1 AND 524288),
    logo_sha256 varchar(64),
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by uuid REFERENCES users(id),
    CHECK ((logo_png IS NULL AND logo_sha256 IS NULL)
        OR (logo_png IS NOT NULL AND logo_sha256 IS NOT NULL AND logo_sha256 ~ '^[0-9a-f]{64}$'
            AND substring(logo_png for 8)=decode('89504e470d0a1a0a','hex')
            AND encode(digest(logo_png,'sha256'),'hex')=logo_sha256))
);
INSERT INTO platform_branding(id,company_name,platform_name,tagline,primary_color,secondary_color)
VALUES(1,'中山市优腾电器有限公司','优腾综合管理平台','德国工匠 · 质造开关','#0F766E','#2DD4BF');
COMMENT ON TABLE platform_branding IS '当前公司平台品牌；仅公开白名单展示字段；小型规范化 PNG 与文字/颜色按版本原子保存';
COMMENT ON COLUMN platform_branding.logo_png IS '服务端 PNG/JPEG 解码并重编码后的 PNG，最多 512 KiB；原图及元信息不保存、不进入审计';

-- INSERT/DELETE snapshots would duplicate image bytes. The immutable singleton is seeded above;
-- updates audit only public decisions and the digest, with a transaction-bound semantic save event.
-- Select V830's seven-argument entry explicitly: older databases can retain V670's six-argument
-- overload. NULL keeps the generic audit function and its scoped column arguments.
SELECT public.fn_audit_track_table('platform_branding', 'COLUMN_SCOPED', 'system', false,
    ARRAY['company_name','company_aliases','platform_name','tagline','primary_color','secondary_color','login_notice',
          'support_phone','support_email','website','logo_sha256','updated_by'], false, NULL::text);

-- A test business reset must preserve the connected company's platform identity and logo.
DO $branding_reset_policy$
DECLARE definition text; anchor text := '(''system_settings'', ''PRESERVE'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V839 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n            (''platform_branding'', ''PRESERVE'')');
END $branding_reset_policy$;
