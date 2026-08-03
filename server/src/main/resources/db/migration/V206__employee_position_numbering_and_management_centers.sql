-- V206: repair employee/position numbering and make management centers usable
-- as employee-hosting departments.

-- sequence-sync:start
-- Use the real largest numeric suffix, not a row count. Soft-deleted rows remain
-- historical identifiers, so they are deliberately included in the scan.
WITH actual_maxima(prefix, last_seq) AS (
    SELECT 'UT', COALESCE(MAX(substring(code FROM 3)::INTEGER), 0)
    FROM employees
    WHERE code ~ '^UT[0-9]+$'

    UNION ALL

    SELECT 'ZW', COALESCE(MAX(substring(code FROM 3)::INTEGER), 0)
    FROM positions
    WHERE code ~ '^ZW[0-9]+$'
)
INSERT INTO master_code_sequences (prefix, last_seq)
SELECT prefix, last_seq
FROM actual_maxima
ON CONFLICT (prefix) DO UPDATE
SET last_seq = GREATEST(master_code_sequences.last_seq, EXCLUDED.last_seq);
-- sequence-sync:end

-- management-center-position-seed:start
-- These are neutral position master-data entries only. A title or positions.level
-- NEVER grants department authority: authority remains assigned exclusively by
-- departments.manager_id. This migration does not write manager_id or permissions.
WITH templates(code_base, name, level, sort_order) AS (
    VALUES
        ('MGT_HEAD',       '负责人',   '领导层', 1),
        ('MGT_DEPUTY',     '副负责人', '领导层', 2),
        ('MGT_SPECIALIST', '专员',     '员工',   3)
), missing AS (
    SELECT d.id AS department_id,
           t.code_base,
           t.name,
           t.level,
           t.sort_order
    FROM departments d
    CROSS JOIN templates t
    WHERE d.level = '管理中心'
      AND d.is_deleted = FALSE
      AND NOT EXISTS (
          SELECT 1
          FROM positions existing
          WHERE existing.department_id = d.id
            AND existing.is_deleted = FALSE
            AND lower(btrim(existing.name)) = lower(btrim(t.name))
      )
)
INSERT INTO positions (
    code,
    name,
    level,
    department_id,
    sort_order,
    is_deleted,
    deleted_at
)
SELECT available.code,
       m.name,
       m.level,
       m.department_id,
       m.sort_order,
       FALSE,
       NULL
FROM missing m
CROSS JOIN LATERAL (
    -- Prefer the stable template code. If legacy data already occupies it in this
    -- department, choose the smallest free deterministic suffix without rewriting
    -- the existing row. With N existing rows, N+1 candidates guarantee a free code.
    SELECT candidate.code
    FROM (
        SELECT m.code_base AS code, 1 AS ordinal
        UNION ALL
        SELECT m.code_base || '_' || suffix::TEXT, suffix AS ordinal
        FROM generate_series(
            2,
            (
                SELECT COUNT(*)::INTEGER + 2
                FROM positions counted
                WHERE counted.department_id = m.department_id
            )
        ) AS suffix
    ) candidate
    WHERE NOT EXISTS (
        SELECT 1
        FROM positions occupied
        WHERE occupied.department_id = m.department_id
          AND occupied.code = candidate.code
    )
    ORDER BY candidate.ordinal
    LIMIT 1
) available
ON CONFLICT (code, department_id) DO NOTHING;
-- management-center-position-seed:end
