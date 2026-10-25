-- Fresh rebuild: display codes were intentionally resequenced in the input.
-- Advance the normal allocators to those exact imported maxima, so the next
-- online create starts after the imported records rather than colliding.
INSERT INTO master_code_sequences(prefix,last_seq)
SELECT prefix,max(number) FROM (
 SELECT 'YS' AS prefix,substring(code FROM 3)::bigint AS number FROM colors WHERE code ~ '^YS[0-9]+$'
 UNION ALL SELECT 'DW',substring(code FROM 3)::bigint FROM units WHERE code ~ '^DW[0-9]+$'
 UNION ALL SELECT 'WH',substring(code FROM 3)::bigint FROM warehouses WHERE code ~ '^WH[0-9]+$'
 -- WH000009 is an occupied historical identity, never recycled after XW03 retirement.
 UNION ALL SELECT 'WH',9::bigint
 UNION ALL SELECT 'UT',substring(code FROM 3)::bigint FROM employees WHERE code ~ '^UT[0-9]+$'
 UNION ALL SELECT 'ZW',substring(code FROM 3)::bigint FROM positions WHERE code ~ '^ZW[0-9]+$'
 UNION ALL SELECT 'MJ',substring(code FROM 3)::bigint FROM moulds WHERE code ~ '^MJ[0-9]+$'
 UNION ALL SELECT 'GY',substring(code FROM 3)::bigint FROM suppliers WHERE code ~ '^GY[0-9]+$'
) imported GROUP BY prefix
ON CONFLICT(prefix) DO UPDATE SET last_seq=greatest(master_code_sequences.last_seq,excluded.last_seq);

DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM warehouses WHERE is_line_side AND code ~ '^WH[0-9]+$' AND NOT is_deleted) THEN
   RAISE EXCEPTION 'Unified line-side bins must keep their LS identity, not ordinary WH codes';
 END IF;
 IF (SELECT count(*) FROM warehouses WHERE NOT is_deleted AND parent_id IS NULL)<>1
 OR (SELECT count(*) FROM warehouses WHERE NOT is_deleted AND name='五金仓库')<>1 THEN
   RAISE EXCEPTION 'Rehearsal must have one root warehouse and one hardware warehouse';
 END IF;
 IF EXISTS(SELECT 1 FROM units WHERE name IS NULL OR btrim(name) ~ '^[0-9.]+$') THEN
   RAISE EXCEPTION 'Polluted numeric or blank units remain after cleaning';
 END IF;
END $$;
