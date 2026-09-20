-- Source dictionaries/schema evidence are part of the exact All inventory.
-- Do not silently ignore them or infer new settlement roles from display text.
CREATE TEMP TABLE payment_style_source (
    legacy_id integer, legacy_code text, name text, remark text, status text
);
\copy payment_style_source FROM '/tmp/b_pstyle.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
CREATE TEMP TABLE worker_column_source (
    pos integer, col text, dtype text, nullable text, len integer
);
\copy worker_column_source FROM '/tmp/b_worker_columns.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
CREATE TEMP TABLE bank_source (
    legacy_id integer, bill_no text, bill_date date, out_acc integer, work_id integer,
    total numeric, make_id integer, approver_id integer, status smallint, status2 smallint,
    remark text, invoices_no text, cancel_date timestamp, source text, cur_id integer,
    crate numeric, cancel boolean
);
\copy bank_source FROM '/tmp/m_bank.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM bank_source) THEN
        RAISE EXCEPTION 'non-empty M_Bank requires a reviewed import mapping';
    END IF;
    IF EXISTS (
        SELECT 1 FROM payment_style_source source
        LEFT JOIN settlement_methods target ON target.legacy_id = source.legacy_id
        WHERE target.id IS NULL OR target.name IS DISTINCT FROM btrim(source.name)
    ) OR EXISTS (
        SELECT legacy_id FROM payment_style_source GROUP BY legacy_id HAVING count(*) <> 1
    ) THEN
        RAISE EXCEPTION 'B_PStyle source differs from reviewed settlement UUID authority; review mapping before import';
    END IF;
END; $$;
