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
            String contract, String buildIdentity, String accessStamp,String precisionChoices,String precisionRequirement,
            Long totalRows) {
        public Job(UUID id,UUID owner,long authVersion,long authEpoch,String request,String status,boolean cancelRequested,int attempt,int rows,OffsetDateTime createdAt,OffsetDateTime finishedAt,
                OffsetDateTime snapshotAt,OffsetDateTime expiresAt,String error,String sha256,long bytes,String contract,String buildIdentity,String accessStamp,
                String precisionChoices,String precisionRequirement){
            this(id,owner,authVersion,authEpoch,request,status,cancelRequested,attempt,rows,createdAt,finishedAt,snapshotAt,expiresAt,error,sha256,bytes,contract,buildIdentity,accessStamp,precisionChoices,precisionRequirement,null);
        }
        public Job(UUID id,UUID owner,long authVersion,long authEpoch,String request,String status,boolean cancelRequested,int attempt,int rows,OffsetDateTime createdAt,OffsetDateTime finishedAt,
                OffsetDateTime snapshotAt,OffsetDateTime expiresAt,String error,String sha256,long bytes,String contract,String buildIdentity,String accessStamp){
            this(id,owner,authVersion,authEpoch,request,status,cancelRequested,attempt,rows,createdAt,finishedAt,snapshotAt,expiresAt,error,sha256,bytes,contract,buildIdentity,accessStamp,"{\"version\":1,\"choices\":{}}",null,null);
        }
    }
    private static final org.springframework.jdbc.core.RowMapper<Job> MAPPER = (r,n) -> new Job(
            r.getObject("id",UUID.class),r.getObject("submitted_by",UUID.class),r.getLong("submitted_auth_version"),
            r.getLong("submitted_auth_epoch"),r.getString("request"),r.getString("status"),r.getBoolean("cancel_requested"),r.getInt("attempt"),
            r.getInt("row_count"),r.getObject("created_at",OffsetDateTime.class),r.getObject("finished_at",OffsetDateTime.class),
            r.getObject("snapshot_at",OffsetDateTime.class),r.getObject("expires_at",OffsetDateTime.class),
            r.getString("error_message"),r.getString("artifact_sha256"),r.getLong("artifact_bytes"),r.getString("read_contract"),r.getString("build_identity"),r.getString("access_stamp"),r.getString("precision_choices"),r.getString("precision_requirement"),
            r.getObject("total_rows",Long.class));

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
        return jdbc.queryForObject("SELECT count(*) FROM report_export_jobs WHERE status IN ('PENDING','RUNNING','WAITING_PRECISION')"
                +(owner==null?"":" AND submitted_by=:owner"),owner==null?Map.of():Map.of("owner",owner),Integer.class);
    }
    public boolean hasRunning() {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM report_export_jobs WHERE status='RUNNING')",Map.of(),Boolean.class));
    }
    public void insert(ReportExportRequest request, UUID owner, long version, long epoch, String json, String buildIdentity, String accessStamp) {
        jdbc.update("""
            INSERT INTO report_export_jobs(id,submitted_by,submitted_auth_version,submitted_auth_epoch,request,read_contract,build_identity,access_stamp,precision_choices)
            VALUES(:id,:owner,:version,:epoch,CAST(:json AS jsonb),:contract,:build,:access,CAST(:precision AS jsonb))
            """, new MapSqlParameterSource("id",request.id()).addValue("owner",owner).addValue("version",version).addValue("epoch",epoch).addValue("json",json).addValue("contract",ReportExportBuildIdentity.CONTRACT).addValue("build",buildIdentity).addValue("access",accessStamp).addValue("precision",com.uten.imp.common.finance.BusinessPrecisionContext.json()));
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
        return heartbeat(job, rows, null);
    }
    /** 心跳顺带记下读取开始时的权威总行数(已知时); 只写一次, 之后保持不变。 */
    public boolean heartbeat(Job job, int rows, Long total) {
        return jdbc.update("""
            UPDATE report_export_jobs SET row_count=:rows,lease_until=clock_timestamp()+interval '120 seconds',
                total_rows=COALESCE(total_rows,CAST(:total AS bigint))
            WHERE id=:id AND status='RUNNING' AND NOT cancel_requested AND attempt=:attempt
            """,args(job).addValue("rows",rows).addValue("total",total))==1;
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
    public boolean waitForPrecision(Job job,String requirement){return jdbc.update("""
        UPDATE report_export_jobs SET status=CASE WHEN cancel_requested THEN 'CANCELLED' ELSE 'WAITING_PRECISION' END,
          precision_requirement=CASE WHEN cancel_requested THEN NULL ELSE CAST(:requirement AS jsonb) END,
          error_message=CASE WHEN cancel_requested THEN NULL ELSE '尚未生成文件，请选择本次精度后继续原任务；重新读取会使用新的读取时点' END,
          finished_at=clock_timestamp(),expires_at=clock_timestamp()+interval '1 hour',lease_until=NULL
        WHERE id=:id AND status='RUNNING' AND attempt=:attempt AND artifact_sha256 IS NULL AND COALESCE(artifact_bytes,0)=0
        """,args(job).addValue("requirement",requirement))==1;}
    public Optional<Map<String,Object>> precisionReceipt(UUID request){return jdbc.queryForList("SELECT job_id,actor_id,expected_attempt,precision_choices::text AS precision_choices FROM report_export_precision_resumes WHERE request_id=:request",Map.of("request",request)).stream().findFirst();}
    public boolean resumePrecision(Job job,UUID request,UUID actor,String choices){
        jdbc.update("INSERT INTO report_export_precision_resumes(request_id,job_id,actor_id,expected_attempt,precision_choices) VALUES(:request,:id,:actor,:attempt,CAST(:choices AS jsonb))",args(job).addValue("request",request).addValue("actor",actor).addValue("choices",choices));
        int updated=jdbc.update("""
          UPDATE report_export_jobs SET status='PENDING',precision_choices=CAST(:choices AS jsonb),precision_requirement=NULL,
            row_count=0,snapshot_at=NULL,snapshot_identity=NULL,finished_at=NULL,expires_at=NULL,error_message=NULL
          WHERE id=:id AND status='WAITING_PRECISION' AND attempt=:attempt AND NOT cancel_requested
            AND artifact_sha256 IS NULL AND COALESCE(artifact_bytes,0)=0 AND expires_at>clock_timestamp()
          """,args(job).addValue("choices",choices));
        if(updated!=1)throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,"原导出等待状态已变化，本次未重新进入队列");return true;
    }
    public void cancel(UUID id, UUID owner) {
        jdbc.update("""
            UPDATE report_export_jobs SET cancel_requested=true,
                status=CASE WHEN status IN('PENDING','WAITING_PRECISION') THEN 'CANCELLED' ELSE status END,
                finished_at=CASE WHEN status IN('PENDING','WAITING_PRECISION') THEN clock_timestamp() ELSE finished_at END
            WHERE id=:id AND submitted_by=:owner AND status IN ('PENDING','RUNNING','WAITING_PRECISION')
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
            SELECT * FROM report_export_jobs WHERE status IN('SUCCEEDED','WAITING_PRECISION') AND expires_at<clock_timestamp()
            ORDER BY expires_at,id LIMIT 50
            """,Map.of(),MAPPER);
    }
    public void expire(UUID id) {
        jdbc.update("UPDATE report_export_jobs SET status='EXPIRED' WHERE id=:id AND status IN('SUCCEEDED','WAITING_PRECISION') AND expires_at<clock_timestamp()",Map.of("id",id));
    }
    private static MapSqlParameterSource args(Job job) {
        return new MapSqlParameterSource("id",job.id()).addValue("attempt",job.attempt());
    }
}
