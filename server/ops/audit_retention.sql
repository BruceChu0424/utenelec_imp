-- =====================================================================
-- 审计日志保留策略执行脚本（手动/定时执行均可，幂等）
-- =====================================================================
-- 策略（对标大厂，详见 docs/数据迁移/38-运维-审计与日志保留.md）：
--   · audit_log 在线热保留 180 天（可用 psql -v retention_days=N 调整）；
--   · 超期先归档到 audit_log_archive（同构表，冷数据，查询走 AuditQueryService 之外的运维口径）；
--   · 归档后从热表分批删除（每批 5000 行，控锁与 WAL 压力），最后 ANALYZE。
-- 用法：
--   docker exec -i uten-imp-postgres psql -U uten -d uten_imp -v retention_days=180 \
--       -v ON_ERROR_STOP=1 < server/ops/audit_retention.sql
-- =====================================================================

\set retention_days 180

BEGIN;

-- ① 归档表（不存在则按热表结构建，含主键/时间索引）
CREATE TABLE IF NOT EXISTS audit_log_archive (LIKE audit_log INCLUDING DEFAULTS INCLUDING INDEXES);

-- ② 超期数据归档
INSERT INTO audit_log_archive
SELECT * FROM audit_log
WHERE created_at < now() - make_interval(days => :retention_days)
ON CONFLICT (id) DO NOTHING;

-- ③ 热表分批删除（循环至删尽；每批 COMMIT 由调用方按需拆分，此处单事务内分批控制行锁时长）
-- psql :变量 不展开 $$ 块，先 set_config 传截止时刻
SELECT set_config('app.audit_cutoff', (now() - make_interval(days => :retention_days))::text, true);
DO $$
DECLARE batch int;
BEGIN
    LOOP
        DELETE FROM audit_log WHERE id IN (
            SELECT id FROM audit_log
            WHERE created_at < current_setting('app.audit_cutoff')::timestamptz
            ORDER BY id LIMIT 5000);
        GET DIAGNOSTICS batch = ROW_COUNT;
        EXIT WHEN batch = 0;
    END LOOP;
END $$;

COMMIT;
ANALYZE audit_log;
ANALYZE audit_log_archive;

-- ④ 执行报告
SELECT '热表剩余 ' || count(*) FROM audit_log
UNION ALL SELECT '归档表累计 ' || count(*) FROM audit_log_archive;
