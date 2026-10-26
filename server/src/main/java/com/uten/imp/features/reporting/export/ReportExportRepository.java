package com.uten.imp.features.reporting.export;

import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.stereotype.Repository;
import java.time.OffsetDateTime;
import java.util.*;

/** SQL for the durable queue. Every worker update is fenced by its claim attempt. */
@Repository
public class ReportExportRepository {
    private final NamedParameterJdbcTemplate jdbc;
    public ReportExportRepository(NamedParameterJdbcTemplate jdbc) { this.jdbc = jdbc; }
    public record Job(UUID id, UUID owner, long authVersion, long authEpoch, String request,
            String status, boolean cancelRequested, int attempt, int rows, OffsetDateTime createdAt, OffsetDateTime finishedAt,
            OffsetDateTime snapshotAt, OffsetDateTime expiresAt, String error, String sha256, long bytes,
            String contract, String buildIdentity, String accessStamp) { }
    private static final org.springframework.jdbc.core.RowMapper<Job> MAPPER = (r,n) -> new Job(
            r.getObject("id",UUID.class),r.getObject("submitted_by",UUID.class),r.getLong("submitted_auth_version"),
            r.getLong("submitted_auth_epoch"),r.getString("request"),r.getString("status"),r.getBoolean("cancel_requested"),r.getInt("attempt"),
            r.getInt("row_count"),r.getObject("created_at",OffsetDateTime.class),r.getObject("finished_at",OffsetDateTime.class),
            r.getObject("snapshot_at",OffsetDateTime.class),r.getObject("expires_at",OffsetDateTime.class),
            r.getString("error_message"),r.getString("artifact_sha256"),r.getLong("artifact_bytes"),r.getString("read_contract"),r.getString("build_identity"),r.getString("access_stamp"));

    public Optional<Job> find(UUID id) {
        return jdbc.query("SELECT * FROM report_export_jobs WHERE id=:id", Map.of("id",id),MAPPER).stream().findFirst();
    }
    public List<Job> recent(UUID owner) {
        return jdbc.query("SELECT * FROM report_export_jobs WHERE submitted_by=:owner ORDER BY created_at DESC,id LIMIT 50",Map.of("owner",owner),MAPPER);
    }
    public void lockQueue() {
        jdbc.query("SELECT pg_advisory_xact_lock(935,1)",Map.of(),r -> null);
    }
    public int active(UUID owner) {
        return jdbc.queryForObject("SELECT count(*) FROM report_export_jobs WHERE status IN ('PENDING','RUNNING')"
                +(owner==null?"":" AND submitted_by=:owner"),owner==null?Map.of():Map.of("owner",owner),Integer.class);
    }
    public boolean hasRunning() {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM report_export_jobs WHERE status='RUNNING')",Map.of(),Boolean.class));
    }
    public void insert(ReportExportRequest request, UUID owner, long version, long epoch, String json, String buildIdentity, String accessStamp) {
        jdbc.update("""
            INSERT INTO report_export_jobs(id,submitted_by,submitted_auth_version,submitted_auth_epoch,request,read_contract,build_identity,access_stamp)
            VALUES(:id,:owner,:version,:epoch,CAST(:json AS jsonb),:contract,:build,:access)
            """, Map.of("id",request.id(),"owner",owner,"version",version,"epoch",epoch,"json",json,"contract",ReportExportBuildIdentity.CONTRACT,"build",buildIdentity,"access",accessStamp));
    }
    public Optional<Job> claim() {
        lockQueue();
        Boolean free=jdbc.queryForObject("SELECT pg_try_advisory_xact_lock(935,2)",Map.of(),Boolean.class);
        if(!Boolean.TRUE.equals(free)) return Optional.empty();
        // A crashed read cannot recover its PostgreSQL snapshot. Keep the request and report failure;
        // an explicit new task is a new snapshot, never a silent continuation at a different time.
        jdbc.update("""
            UPDATE report_export_jobs SET status='FAILED',finished_at=clock_timestamp(),lease_until=NULL,
                error_message='导出进程中断，请重新创建任务；新任务使用新的读取时点'
            WHERE status='RUNNING' AND lease_until<clock_timestamp()
            """,Map.of());
        Integer running=jdbc.queryForObject("SELECT count(*) FROM report_export_jobs WHERE status='RUNNING'",Map.of(),Integer.class);
        if (running!=null && running>=1) return Optional.empty();
        return jdbc.query("""
            UPDATE report_export_jobs SET status='RUNNING',attempt=attempt+1,started_at=clock_timestamp(),
                lease_until=clock_timestamp()+interval '120 seconds'
            WHERE id=(SELECT id FROM report_export_jobs WHERE status='PENDING' ORDER BY created_at,id
                FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING *
            """,Map.of(),MAPPER).stream().findFirst();
    }
    public boolean heartbeat(Job job, int rows) {
        return jdbc.update("""
            UPDATE report_export_jobs SET row_count=:rows,lease_until=clock_timestamp()+interval '120 seconds'
            WHERE id=:id AND status='RUNNING' AND NOT cancel_requested AND attempt=:attempt
            """,args(job).addValue("rows",rows))==1;
    }
    public void snapshot(Job job, OffsetDateTime time, String identity) {
        jdbc.update("""
            UPDATE report_export_jobs SET snapshot_at=:time,snapshot_identity=:identity
            WHERE id=:id AND status='RUNNING' AND NOT cancel_requested AND attempt=:attempt
            """,args(job).addValue("time",time).addValue("identity",identity));
    }
    public boolean succeed(Job job, int rows, long bytes, String sha) {
        return jdbc.update("""
            UPDATE report_export_jobs SET status='SUCCEEDED',row_count=:rows,artifact_bytes=:bytes,
                artifact_sha256=:sha,finished_at=clock_timestamp(),expires_at=clock_timestamp()+interval '1 hour',lease_until=NULL
            WHERE id=:id AND status='RUNNING' AND NOT cancel_requested AND attempt=:attempt
            """,args(job).addValue("rows",rows).addValue("bytes",bytes).addValue("sha",sha))==1;
    }
    public void fail(Job job, String message) {
        jdbc.update("""
            UPDATE report_export_jobs SET status=CASE WHEN cancel_requested THEN 'CANCELLED' ELSE 'FAILED' END,
                error_message=CASE WHEN cancel_requested THEN NULL ELSE :message END,finished_at=clock_timestamp(),lease_until=NULL
            WHERE id=:id AND status='RUNNING' AND attempt=:attempt
            """,args(job).addValue("message",message));
    }
    public void cancel(UUID id, UUID owner) {
        jdbc.update("""
            UPDATE report_export_jobs SET cancel_requested=true,
                status=CASE WHEN status='PENDING' THEN 'CANCELLED' ELSE status END,
                finished_at=CASE WHEN status='PENDING' THEN clock_timestamp() ELSE finished_at END
            WHERE id=:id AND submitted_by=:owner AND status IN ('PENDING','RUNNING')
            """,Map.of("id",id,"owner",owner));
    }
    public void acknowledgeCancellation(Job job) {
        jdbc.update("""
            UPDATE report_export_jobs SET status='CANCELLED',finished_at=clock_timestamp(),lease_until=NULL
            WHERE id=:id AND status='RUNNING' AND cancel_requested AND attempt=:attempt
            """,args(job));
    }
    public List<Job> expired() {
        return jdbc.query("""
            SELECT * FROM report_export_jobs WHERE status='SUCCEEDED' AND expires_at<clock_timestamp()
            ORDER BY expires_at,id LIMIT 50
            """,Map.of(),MAPPER);
    }
    public void expire(UUID id) {
        jdbc.update("UPDATE report_export_jobs SET status='EXPIRED' WHERE id=:id AND status='SUCCEEDED' AND expires_at<clock_timestamp()",Map.of("id",id));
    }
    private static MapSqlParameterSource args(Job job) {
        return new MapSqlParameterSource("id",job.id()).addValue("attempt",job.attempt());
    }
}
