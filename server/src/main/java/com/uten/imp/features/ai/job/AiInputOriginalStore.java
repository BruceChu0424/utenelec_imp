package com.uten.imp.features.ai.job;

import com.uten.imp.application.port.AiJobHandler.AiJobInput;
import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.util.*;

/** Exact originals and append-only formal lineage; never follows disposable AI-job retention. */
@Service
public class AiInputOriginalStore {
    private static final int MAX_BYTES=15*1024*1024;
    private static final String KIND="SALES_DOCUMENT_INTAKE";
    private static final String METADATA="job_id,actor_user_id,original_name,input_kind,content_type,availability,storage_provider,storage_key,storage_version,storage_size,storage_sha256,captured_at,lifecycle_state";
    private static String metadata(String alias){return alias.isEmpty()?METADATA:alias+"."+METADATA.replace(",",","+alias+".");}
    private final NamedParameterJdbcTemplate jdbc;
    private final ImmutableDocumentStore objects;
    private final StorageService storage;
    private final SecurityContextCurrentUser current;
    private final AuditService audit;
    private final Map<String,AttachmentOwnerAccessPolicy> policies;
    public AiInputOriginalStore(NamedParameterJdbcTemplate jdbc,ImmutableDocumentStore objects,StorageService storage,
            SecurityContextCurrentUser current,AuditService audit,List<AttachmentOwnerAccessPolicy> policies) {
        this.jdbc=jdbc;this.objects=objects;this.storage=storage;this.current=current;this.audit=audit;
        this.policies=new HashMap<>();for(var policy:policies)if(this.policies.putIfAbsent(policy.ownerType(),policy)!=null)
            throw new IllegalStateException("Duplicate attachment owner policy");
    }
    public void requireCaptureAvailable(String kind) {
        if(KIND.equals(kind)&&(!storage.isEnabled()||!("internal".equals(storage.backend())||"local".equals(storage.backend()))))
            throw new ApiException(ErrorCode.BUSINESS,"内部原件存储未启用，文件尚未保全，不能提交识别");
    }
    @Transactional(propagation=Propagation.MANDATORY)
    public void capture(UUID id,UUID actor,String kind,AiJobInput input) {
        if(!KIND.equals(kind))return;
        requireCaptureAvailable(kind);
        if(!current.requireId().equals(actor))throw new ApiException(ErrorCode.FORBIDDEN);
        if(input.bytes()==null||input.bytes().length<1||input.bytes().length>MAX_BYTES||input.size()!=input.bytes().length
                ||!Objects.equals(input.sha256(),ImmutableDocumentStore.digest(input.bytes())))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"原文件大小或内容与上传时不一致，请重新上传");
        ImmutableDocumentStore.Reference reference;
        try {reference=objects.save("AI_INPUT_ORIGINAL",input.fileName(),contentType(input.kind()),input.bytes());}
        catch(RuntimeException failed){throw new ApiException(ErrorCode.BUSINESS,"原文件尚未保存，识别没有提交，请稍后重新上传");}
        if(reference.size()!=input.size()||!Objects.equals(reference.sha256(),input.sha256()))throw new ApiException(ErrorCode.CONFLICT,"原文件保存后与上传时不一致，识别没有提交");
        jdbc.update("""
                INSERT INTO ai_input_originals(job_id,actor_user_id,original_name,input_kind,content_type,declared_size,declared_sha256,
                    availability,storage_provider,storage_key,storage_version,storage_size,storage_sha256,captured_at)
                VALUES(:id,:actor,:name,:kind,:mime,:size,:sha,'AVAILABLE',:provider,:key,:version,:size,:sha,now())
                """,new org.springframework.jdbc.core.namedparam.MapSqlParameterSource("id",id).addValue("actor",actor)
                .addValue("name",input.fileName()).addValue("kind",input.kind()).addValue("mime",contentType(input.kind()))
                .addValue("size",reference.size()).addValue("sha",reference.sha256()).addValue("provider",reference.provider())
                .addValue("key",reference.key()).addValue("version",reference.version()));
        jdbc.update("""
                INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key)
                VALUES('DELETE_STAGING',:provider,:key,:version,:dedupe) ON CONFLICT(dedupe_key) DO NOTHING
                """,new org.springframework.jdbc.core.namedparam.MapSqlParameterSource("provider",reference.provider())
                .addValue("key",reference.key()).addValue("version",reference.version())
                .addValue("dedupe",reference.provider()+"|DELETE_STAGING|"+reference.key()+"|"+Objects.toString(reference.version(),"<local>")));
    }
    @Transactional(propagation=Propagation.MANDATORY)
    public void bind(UUID job,UUID actor,String type,UUID doc) {
        if(!("quote".equals(type)||"order".equals(type)))return;
        var kinds=jdbc.queryForList("SELECT kind FROM ai_jobs WHERE id=:job",Map.of("job",job),String.class);
        if(!kinds.isEmpty()&&!"SALES_DOCUMENT_INTAKE".equals(kinds.getFirst()))return;
        Original original=jdbc.query("SELECT "+metadata("")+" FROM ai_input_originals WHERE job_id=:job FOR UPDATE",Map.of("job",job),this::row)
                .stream().findFirst().orElseThrow(()->new ApiException(ErrorCode.CONFLICT,"识别原文件没有保全，请重新上传"));
        boolean prior=Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM ai_input_original_bindings WHERE job_id=:job AND doc_type=:type AND doc_id=:doc)",Map.of("job",job,"type",type,"doc",doc),Boolean.class));
        if(!actor.equals(original.actor()))throw new ApiException(ErrorCode.FORBIDDEN);
        if(prior)return; // Historical unavailable evidence stays explicit; replay cannot fabricate an original.
        if(!readable(original)||!"AVAILABLE".equals(original.lifecycle()))throw new ApiException(ErrorCode.CONFLICT,
                "LEGACY_CONFLICT".equals(original.availability())?"历史原文件内容不一致，请重新上传":"原识别文件不可用，请重新上传");
        jdbc.update("""
                INSERT INTO ai_input_original_bindings(job_id,doc_type,doc_id,source_doc_type,source_doc_id)
                VALUES(:job,:type,:doc,:type,:doc) ON CONFLICT DO NOTHING
                """,Map.of("job",job,"type",type,"doc",doc));
        // Conversion may have committed before a deferred legacy source binding.
        if("quote".equals(type))jdbc.update("""
                INSERT INTO ai_input_original_bindings(job_id,doc_type,doc_id,source_doc_type,source_doc_id)
                SELECT :job,'order',id,'quote',:doc FROM sales_orders WHERE source_quote_id=:doc ON CONFLICT DO NOTHING
                """,Map.of("job",job,"doc",doc));
        audit.logCommitted(actor,null,"bind_ai_input_original","ai_input_originals",job+";"+type+":"+doc,"success");
    }
    public record Download(byte[] bytes,String filename,String contentType,String sha256) { }
    private record Original(UUID id,UUID actor,String name,String kind,String mime,String availability,String provider,String key,
            String version,Long size,String sha,Instant captured,String lifecycle) { }
    private Original row(ResultSet rs,int ignored) throws SQLException {
        return new Original(rs.getObject("job_id",UUID.class),rs.getObject("actor_user_id",UUID.class),rs.getString("original_name"),
                rs.getString("input_kind"),rs.getString("content_type"),rs.getString("availability"),rs.getString("storage_provider"),
                rs.getString("storage_key"),rs.getString("storage_version"),rs.getObject("storage_size",Long.class),rs.getString("storage_sha256"),
                rs.getTimestamp("captured_at")==null?null:rs.getTimestamp("captured_at").toInstant(),rs.getString("lifecycle_state"));
    }
    private AttachmentOwnerAccessPolicy authorize(String type,UUID doc,boolean sensitive) {
        var actor=current.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        if(actor.isVisitor())throw new ApiException(ErrorCode.FORBIDDEN);
        String owner=switch(type){case "quote"->"SALES_QUOTE";case "order"->"SALES_ORDER";default->throw new ApiException(ErrorCode.NOT_FOUND);};
        AttachmentOwnerAccessPolicy policy=policies.get(owner);
        if(policy==null)throw new ApiException(ErrorCode.FORBIDDEN);
        if(sensitive)policy.requireCanViewSensitiveOriginalHistory(doc,actor);else policy.requireCanViewHistory(doc,actor);
        return policy;
    }
    @Transactional(readOnly=true)
    public Download download(String type,UUID doc,UUID job) {
        authorize(type,doc,true);
        if(current.get().orElseThrow().getImpersonatedBy()!=null)throw new ApiException(ErrorCode.IMPERSONATION_READ_ONLY);
        Original original=jdbc.query("SELECT "+metadata("original")+"\n"+"""
                FROM ai_input_originals original JOIN ai_input_original_bindings binding ON binding.job_id=original.job_id
                WHERE original.job_id=:job AND binding.doc_type=:type AND binding.doc_id=:doc
                """,Map.of("job",job,"type",type,"doc",doc),this::row).stream().findFirst().orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND));
        if(!readable(original)||!"AVAILABLE".equals(original.lifecycle()))throw new ApiException(ErrorCode.CONFLICT,"历史原文件不可用或内容异常，不能下载");
        if(original.size()==null||original.size()<1||original.size()>MAX_BYTES)throw new ApiException(ErrorCode.CONFLICT,"原文件大小不正确，不能下载");
        byte[] bytes;
        try {
            bytes="LEGACY_DB".equals(original.availability())
                    ?jdbc.queryForObject("SELECT legacy_bytes FROM ai_input_originals WHERE job_id=:job",Map.of("job",job),byte[].class)
                    :objects.read(new ImmutableDocumentStore.Reference(original.provider(),original.key(),original.version(),original.size(),original.sha()));
            if(bytes==null||bytes.length!=original.size()||!Objects.equals(ImmutableDocumentStore.digest(bytes),original.sha()))throw new IllegalStateException("Original mismatch");
        } catch(RuntimeException mismatch){throw new ApiException(ErrorCode.CONFLICT,"原文件读取或核对失败，请联系管理员处理");}
        var actor=current.get().orElseThrow();audit.logExplicit(actor.getId(),actor.getLoginAccount(),"download_ai_input_original","ai_input_originals",job.toString(),"success");
        return new Download(bytes,original.name().replaceAll("[\\p{Cntrl}\\\\/]","_"),contentType(original.kind()),original.sha());
    }
    private static boolean readable(Original original){return "AVAILABLE".equals(original.availability())||"LEGACY_DB".equals(original.availability());}
    @Transactional
    public int purgeExpiredTemporary() {
        return jdbc.update("""
                WITH candidates AS (
                    SELECT original.job_id FROM ai_input_originals original LEFT JOIN ai_jobs job ON job.id=original.job_id
                    WHERE original.archived_at IS NULL AND original.availability IN('AVAILABLE','LEGACY_DB')
                      AND original.temporary_until<now()
                      AND NOT EXISTS(SELECT 1 FROM ai_input_original_bindings binding WHERE binding.job_id=original.job_id)
                      AND (job.id IS NULL OR (job.status IN('SUCCEEDED','FAILED','CANCELLED')
                          AND (job.learning_retry_until IS NULL OR job.learning_retry_until<now())))
                      AND NOT EXISTS(SELECT 1 FROM sales_document_learning_receipts receipt
                          WHERE receipt.actor_user_id=original.actor_user_id
                            AND (receipt.request_payload->>'intakeJobId'=CAST(original.job_id AS text)
                                OR jsonb_exists(receipt.request_payload->'additionalIntakeJobIds',CAST(original.job_id AS text)))
                            AND EXISTS(SELECT 1 FROM jsonb_each(receipt.steps) step WHERE step.value->>'status'='RUNNING'))
                    ORDER BY original.temporary_until,original.job_id LIMIT 1000 FOR UPDATE OF original SKIP LOCKED
                ) UPDATE ai_input_originals original
                SET archived_at=now(),archived_by='system:ai-original-retention',archive_reason='UNADOPTED_RETENTION_WINDOW'
                FROM candidates WHERE original.job_id=candidates.job_id
                """,Map.of());
    }
    private static String contentType(String kind) {return switch(kind){
        case "XLSX"->"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";case "XLS"->"application/vnd.ms-excel";
        case "PDF"->"application/pdf";case "PNG"->"image/png";case "JPEG"->"image/jpeg";case "WEBP"->"image/webp";
        case "CSV"->"text/csv";default->"application/octet-stream";};}
}
