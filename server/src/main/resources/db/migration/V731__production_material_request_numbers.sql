-- A material request precedes physical-warehouse allocation. Its LQ identity
-- remains on the request; each later real DRAW keeps its independent SL number.
-- Reuse V279's namespace, Shanghai-day sequence and lifetime reservation registry.
INSERT INTO business_identifier_namespaces(namespace_key,identifier_family,fixed_prefix,
    source_table,identifier_column,discriminator_value)
VALUES('PRODUCTION_MATERIAL_REQUEST','DOCUMENT','LQ',
    'production_material_discovery_requests','request_no',NULL);

ALTER TABLE production_material_discovery_requests ADD COLUMN request_no TEXT;

DO $request_numbers$
DECLARE guard_definition TEXT; backfill_guard TEXT; numbered RECORD; identifier TEXT;
        business_day DATE; sequence_value BIGINT;
BEGIN
    SELECT pg_get_functiondef('fn_guard_material_discovery_history()'::regprocedure) INTO guard_definition;
    IF position(E'BEGIN\n' IN guard_definition)=0 THEN
        RAISE EXCEPTION 'V731 discovery-history guard anchor changed';
    END IF;
    -- This exception exists only within this migration transaction. It permits
    -- exactly a missing display number to be filled, with every other byte fixed.
    backfill_guard:=replace(guard_definition,E'BEGIN\n',E'BEGIN\n'||$guard$
        IF TG_OP='UPDATE' AND TG_TABLE_NAME='production_material_discovery_requests'
           AND to_jsonb(OLD)->>'request_no' IS NULL
           AND NULLIF(to_jsonb(NEW)->>'request_no','') IS NOT NULL
           AND (to_jsonb(OLD)-'request_no')=(to_jsonb(NEW)-'request_no') THEN
            RETURN NEW;
        END IF;
    $guard$);
    EXECUTE backfill_guard;

    -- Seed from permanent reservations too; cancelled or reset source rows must
    -- never make their old number reusable. A conflicting identity fails closed.
    FOR identifier IN SELECT normalized_identifier FROM business_identifier_reservations
        WHERE normalized_identifier ~ '^LQ[0-9]{14}$' ORDER BY normalized_identifier LOOP
        business_day:=to_date(substring(identifier FROM 3 FOR 8),'YYYYMMDD');
        sequence_value:=right(identifier,6)::bigint;
        IF to_char(business_day,'YYYYMMDD')<>substring(identifier FROM 3 FOR 8)
           OR sequence_value NOT BETWEEN 1 AND 999999 THEN
            RAISE EXCEPTION 'V731 invalid reserved material-request number';
        END IF;
        INSERT INTO business_document_sequences(namespace_key,sequence_date,last_seq)
        VALUES('PRODUCTION_MATERIAL_REQUEST',business_day,sequence_value)
        ON CONFLICT(namespace_key,sequence_date) DO UPDATE
        SET last_seq=GREATEST(business_document_sequences.last_seq,EXCLUDED.last_seq);
    END LOOP;
    FOR numbered IN SELECT id,(created_at AT TIME ZONE 'Asia/Shanghai')::date business_date
        FROM production_material_discovery_requests WHERE request_no IS NULL ORDER BY created_at,id LOOP
        INSERT INTO business_document_sequences(namespace_key,sequence_date,last_seq)
        VALUES('PRODUCTION_MATERIAL_REQUEST',numbered.business_date,1)
        ON CONFLICT(namespace_key,sequence_date) DO UPDATE SET last_seq=business_document_sequences.last_seq+1
        RETURNING last_seq INTO sequence_value;
        identifier:='LQ'||to_char(numbered.business_date,'YYYYMMDD')||lpad(sequence_value::text,6,'0');
        PERFORM fn_claim_global_business_identifier(identifier,'PRODUCTION_MATERIAL_REQUEST',numbered.id,NULL,
            'production_material_discovery_requests');
        UPDATE production_material_discovery_requests SET request_no=identifier WHERE id=numbered.id;
    END LOOP;

    -- Restore the full append-only guard and add permanent request-number immutability.
    EXECUTE replace(guard_definition,E'BEGIN\n',E'BEGIN\n'||$guard$
        IF TG_OP='UPDATE' AND TG_TABLE_NAME='production_material_discovery_requests'
           AND (to_jsonb(NEW)->>'request_no') IS DISTINCT FROM (to_jsonb(OLD)->>'request_no') THEN
            RAISE EXCEPTION 'Material-request number is immutable' USING ERRCODE='55000';
        END IF;
    $guard$);
END;
$request_numbers$;

-- Validate (do not disable) deferred source guards queued by backfill before
-- changing this table's constraints. PostgreSQL forbids ALTER with pending events.
SET CONSTRAINTS trg_material_discovery_request_source IMMEDIATE;

ALTER TABLE production_material_discovery_requests
    ALTER COLUMN request_no SET NOT NULL,
    ADD CONSTRAINT material_discovery_request_no_uk UNIQUE(request_no),
    ADD CONSTRAINT material_discovery_request_no_shape_chk CHECK(request_no ~ '^LQ[0-9]{14}$');
CREATE TRIGGER trg_business_document_material_discovery_request
    BEFORE INSERT OR UPDATE OF request_no ON production_material_discovery_requests
    FOR EACH ROW EXECUTE FUNCTION fn_reserve_business_document_identifier(
        'PRODUCTION_MATERIAL_REQUEST','request_no','');
COMMENT ON COLUMN production_material_discovery_requests.request_no IS
    'Immutable LQ material-request number, allocated by the global V279 registry; later real warehouse DRAW documents keep separate SL identities.';
