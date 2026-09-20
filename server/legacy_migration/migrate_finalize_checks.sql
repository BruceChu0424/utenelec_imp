-- Resolve deferred checks before publishing SUCCESS. Only static PostgreSQL
-- identifiers may leave the exception boundary; source values, messages,
-- details, SQL statements and raw exception context are never printed/stored.
CREATE TEMP TABLE bootstrap_deferred_check_result (
    sqlstate text, constraint_name text, function_name text) ON COMMIT DROP;
DO $verify$
DECLARE failure_state text; failure_constraint text; failure_context text; failure_function text;
BEGIN
    SET CONSTRAINTS ALL IMMEDIATE;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS failure_state=RETURNED_SQLSTATE,
        failure_constraint=CONSTRAINT_NAME,failure_context=PG_EXCEPTION_CONTEXT;
    failure_function:=substring(failure_context FROM 'function (?:[a-z_][a-z0-9_]*[.])?([a-z_][a-z0-9_]*)');
    INSERT INTO bootstrap_deferred_check_result
    SELECT CASE WHEN failure_state ~ '^[A-Z0-9]{5}$' THEN failure_state ELSE 'UT798' END,
        CASE WHEN failure_constraint ~ '^[a-z_][a-z0-9_]{0,62}$' THEN failure_constraint END,
        CASE WHEN failure_function ~ '^[a-z_][a-z0-9_]{0,62}$' THEN failure_function END;
END;
$verify$;
SELECT sqlstate,constraint_name,function_name FROM bootstrap_deferred_check_result;
DO $reject$
DECLARE failure_state text;
BEGIN
    SELECT sqlstate INTO failure_state FROM bootstrap_deferred_check_result;
    IF failure_state IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE=failure_state,
            MESSAGE='bootstrap deferred constraints failed; safe identifiers were emitted';
    END IF;
END;
$reject$;
