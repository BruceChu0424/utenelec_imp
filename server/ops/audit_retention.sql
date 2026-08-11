-- =====================================================================
-- 审计日志保留策略执行脚本（手动/定时执行均可，幂等）
-- =====================================================================
-- 策略（对标大厂，详见 docs/数据迁移/38-运维-审计与日志保留.md）：
--   · audit_log 在线热保留 180 天（可用 psql -v retention_days=N 调整）；
--   · 超期先归档到 audit_log_archive（同构表，冷数据，查询走 AuditQueryService 之外的运维口径）；
--   · 归档后从热表分批提交删除（默认每批 5000 行），最后 VACUUM ANALYZE。
-- 用法：
--   docker exec -i uten-imp-postgres psql -U uten -d uten_imp -v retention_days=180 \
--       -v batch_size=5000 -v reindex=false \
--       -v ON_ERROR_STOP=1 < server/ops/audit_retention.sql
-- =====================================================================

\if :{?retention_days}
\else
    \set retention_days 180
\endif
\if :{?batch_size}
\else
    \set batch_size 5000
\endif
\if :{?reindex}
\else
    \set reindex false
\endif

SELECT set_config('app.audit_retention_days', :'retention_days', false);
SELECT set_config('app.audit_batch_size', :'batch_size', false);

DO $$
DECLARE
    retention_days_value INTEGER :=
        current_setting('app.audit_retention_days')::INTEGER;
    batch_size_value INTEGER :=
        current_setting('app.audit_batch_size')::INTEGER;
BEGIN
    IF retention_days_value < 30 OR retention_days_value > 3650 THEN
        RAISE EXCEPTION 'retention_days must be between 30 and 3650';
    END IF;
    IF batch_size_value < 100 OR batch_size_value > 50000 THEN
        RAISE EXCEPTION 'batch_size must be between 100 and 50000';
    END IF;
END
$$;

BEGIN;

-- ① 归档表（不存在则按热表结构建，含主键/时间索引）
CREATE TABLE IF NOT EXISTS audit_log_archive (LIKE audit_log INCLUDING DEFAULTS INCLUDING INDEXES);

-- ② 超期数据归档
INSERT INTO audit_log_archive
SELECT * FROM audit_log
WHERE created_at < now() - make_interval(days => :'retention_days'::INTEGER)
ON CONFLICT (id) DO NOTHING;

COMMIT;

-- ③ 热表分批删除。CALL 在顶层执行，过程内每批真实 COMMIT，避免一个
--    巨型事务长时间持锁/占 WAL；且只删除已存在于归档表的行。
CREATE OR REPLACE PROCEDURE uten_prune_audit_log_batches(
    cutoff TIMESTAMPTZ,
    requested_batch_size INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    deleted_rows INTEGER;
BEGIN
    LOOP
        WITH doomed AS (
            SELECT hot.ctid
            FROM audit_log hot
            WHERE hot.created_at < cutoff
              AND EXISTS (
                  SELECT 1 FROM audit_log_archive cold WHERE cold.id = hot.id
              )
            ORDER BY hot.created_at, hot.id
            LIMIT requested_batch_size
            FOR UPDATE SKIP LOCKED
        )
        DELETE FROM audit_log hot
        USING doomed
        WHERE hot.ctid = doomed.ctid;

        GET DIAGNOSTICS deleted_rows = ROW_COUNT;
        COMMIT;
        EXIT WHEN deleted_rows = 0;
    END LOOP;
END
$$;

CALL uten_prune_audit_log_batches(
    now() - make_interval(days => :'retention_days'::INTEGER),
    :'batch_size'::INTEGER
);
DROP PROCEDURE uten_prune_audit_log_batches(TIMESTAMPTZ, INTEGER);

VACUUM (ANALYZE) audit_log;
ANALYZE audit_log_archive;

\if :reindex
    -- 大量历史删除后可在低峰显式开启；CONCURRENTLY 避免阻断线上写入。
    REINDEX TABLE CONCURRENTLY audit_log;
\endif

-- ④ 执行报告
SELECT '热表剩余 ' || count(*) FROM audit_log
UNION ALL SELECT '归档表累计 ' || count(*) FROM audit_log_archive;
