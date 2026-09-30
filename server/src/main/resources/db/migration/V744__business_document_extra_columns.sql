-- New optional document terms; never modify physical quantities or historical amounts.
CREATE TABLE business_column_definitions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    scope text NOT NULL CHECK (scope IN ('sales_quote','sales_order','purchase_order','subcontract_order')),
    name varchar(80) NOT NULL,
    normalized_name text NOT NULL,
    value_type text NOT NULL CHECK (value_type IN ('TEXT','NUMBER','AMOUNT')),
    operation text NOT NULL CHECK (operation IN ('NONE','ADD','SUBTRACT','MULTIPLY','DIVIDE')),
    usage_count bigint NOT NULL DEFAULT 0 CHECK (usage_count >= 0),
    last_used_at timestamptz,
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (value_type <> 'TEXT' OR operation = 'NONE'),
    UNIQUE(scope, normalized_name, value_type, operation)
);
SELECT fn_audit_track_table('business_column_definitions', 'FULL', 'data_change', false);

ALTER TABLE sales_quote_items ADD COLUMN extra_columns jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(extra_columns) = 'array' AND jsonb_array_length(extra_columns) <= 32);
ALTER TABLE sales_order_items ADD COLUMN extra_columns jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(extra_columns) = 'array' AND jsonb_array_length(extra_columns) <= 32);
ALTER TABLE purchase_order_items ADD COLUMN extra_columns jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(extra_columns) = 'array' AND jsonb_array_length(extra_columns) <= 32);
ALTER TABLE subcontract_order_items ADD COLUMN extra_columns jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(extra_columns) = 'array' AND jsonb_array_length(extra_columns) <= 32);

-- Same bounded ordered operations as ExtraColumnCalculator. SQL numeric division is normally
-- rounded; reduce an integer fraction first so only exact finite decimal division is accepted.
CREATE FUNCTION fn_business_columns_amount(base numeric, columns jsonb) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE amount numeric := base; col jsonb; val numeric; op text;
        numerator numeric; denominator numeric; left_gcd numeric; right_gcd numeric; remainder numeric;
        twos integer; fives integer; digits integer; coefficient numeric;
BEGIN
    IF base IS NULL THEN RETURN NULL; END IF;
    IF columns IS NULL THEN RETURN base; END IF;
    IF jsonb_typeof(columns) <> 'array' OR jsonb_array_length(columns) > 32 THEN
        RAISE EXCEPTION 'Invalid business columns' USING ERRCODE = '23514';
    END IF;
    FOR col IN SELECT value FROM jsonb_array_elements(columns) LOOP
        op := col->>'operation';
        IF op = 'NONE' OR NULLIF(btrim(col->>'value'), '') IS NULL THEN CONTINUE; END IF;
        IF length(col->>'value') > 120 OR (col->>'value') !~ '^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$'
                OR col->>'type' = 'TEXT' THEN
            RAISE EXCEPTION 'Invalid business-column decimal' USING ERRCODE = '23514';
        END IF;
        val := (col->>'value')::numeric;
        IF abs(val) >= 1e40::numeric OR scale(trim_scale(val)) > 30 THEN
            RAISE EXCEPTION 'Business-column value exceeds exact amount range' USING ERRCODE = '23514';
        END IF;
        CASE op
        WHEN 'ADD' THEN amount := amount + val;
        WHEN 'SUBTRACT' THEN amount := amount - val;
        WHEN 'MULTIPLY' THEN amount := amount * val;
        WHEN 'DIVIDE' THEN
            IF val = 0 THEN RAISE EXCEPTION 'Business column cannot divide by zero' USING ERRCODE = '23514'; END IF;
            numerator := trim_scale(amount) * power(10::numeric, scale(trim_scale(amount)) + scale(trim_scale(val)));
            denominator := trim_scale(val) * power(10::numeric, scale(trim_scale(val)) + scale(trim_scale(amount)));
            IF denominator < 0 THEN numerator := -numerator; denominator := -denominator; END IF;
            left_gcd := abs(numerator); right_gcd := denominator;
            WHILE right_gcd <> 0 LOOP
                remainder := mod(left_gcd, right_gcd); left_gcd := right_gcd; right_gcd := remainder;
            END LOOP;
            numerator := div(numerator, left_gcd); denominator := div(denominator, left_gcd);
            twos := 0; fives := 0;
            WHILE mod(denominator, 2) = 0 LOOP denominator := div(denominator, 2); twos := twos + 1; END LOOP;
            WHILE mod(denominator, 5) = 0 LOOP denominator := div(denominator, 5); fives := fives + 1; END LOOP;
            IF denominator <> 1 THEN RAISE EXCEPTION 'Business-column division is not an exact finite decimal' USING ERRCODE = '23514'; END IF;
            digits := greatest(twos, fives);
            IF digits > 30 THEN RAISE EXCEPTION 'Business-column division exceeds exact amount range' USING ERRCODE = '23514'; END IF;
            coefficient := numerator * power(2::numeric, digits-twos) * power(5::numeric, digits-fives);
            amount := (trim_scale(coefficient)::text || 'e-' || digits::text)::numeric;
        ELSE RAISE EXCEPTION 'Invalid business-column operation' USING ERRCODE = '23514';
        END CASE;
        IF abs(amount) >= 1e40::numeric OR scale(trim_scale(amount)) > 30 THEN
            RAISE EXCEPTION 'Business-column result exceeds exact amount range' USING ERRCODE = '23514';
        END IF;
    END LOOP;
    IF amount < 0 THEN RAISE EXCEPTION 'Business columns cannot produce a negative document amount' USING ERRCODE = '23514'; END IF;
    RETURN amount;
END;
$$;

DO $reset_policy$
DECLARE definition text; anchor text := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V744 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor, anchor || E',\n            (''business_column_definitions'', ''PRESERVE'')');
END;
$reset_policy$;
