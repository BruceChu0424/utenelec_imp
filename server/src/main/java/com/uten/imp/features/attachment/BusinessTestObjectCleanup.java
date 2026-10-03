package com.uten.imp.features.attachment;

import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort.*;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.NoSuchFileException;
import java.io.FileNotFoundException;
import java.security.MessageDigest;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Explicit super-admin test reset only. Ordinary outbox workers never consume these intents.
 * The database trusts this server process to verify its HMAC and physically delete the exact object;
 * neither actor GUCs nor SECURITY DEFINER alone prove physical deletion against arbitrary runtime SQL compromise.
 */
@Service
final class BusinessTestObjectCleanup {
    private static final int BATCH_SIZE=100;
    private static final String PURPOSE="CLEAR_TEST_BUSINESS_WITH_HISTORY";
    private static final String SOURCE_COLUMNS="source_type,source_id,owner_type,owner_id,file_name,source_state,object_location,storage_provider,storage_key,storage_version,size_bytes,sha256,wait_until,source_fingerprint";
    private static final String INTENT_COLUMNS="id,purpose,attempt_id,generation,actor_id,actor_account,database_name,source_type,source_id,source_fingerprint,object_location,storage_provider,storage_key,storage_version,object_exists,size_bytes,sha256,signature,authorized_until,claim_number";
    private final JdbcTemplate jdbc;
    private final StorageProviderRegistry storage;
    private final StorageProperties properties;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final AuditService audit;
    private final BusinessTestObjectSignature signatures;
    private final TransactionTemplate transactions;

    BusinessTestObjectCleanup(JdbcTemplate jdbc,StorageProviderRegistry storage,StorageProperties properties,
        SecurityContextCurrentUser current,TxSessionVars tx,AuditService audit,BusinessTestObjectSignature signatures,
        PlatformTransactionManager manager) {
        this.jdbc=jdbc;this.storage=storage;this.properties=properties;this.current=current;this.tx=tx;this.audit=audit;this.signatures=signatures;
        transactions=new TransactionTemplate(manager);transactions.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }
    Preview preview(UUID actorId) {
        return transactions.execute(status->{AuthUser actor=requireActor(actorId);tx.bind();return previewInside(actor);});
    }
    List<UnpurgeableGroup> blockers(UUID actorId) {
        return transactions.execute(status->{requireActor(actorId);tx.bind();
            return jdbc.query("""
                WITH blocked AS (
                    SELECT CASE WHEN storage_provider NOT IN('internal','local') OR storage_provider IS NULL
                            THEN '历史存储来源未核定或不支持自动测试清理'
                        WHEN wait_until>now() THEN '上传凭证仍有效，请到期后重试'
                        WHEN source_type='DELETE_OPERATION' AND owner_type='UNKNOWN' AND NOT EXISTS(
                            SELECT 1 FROM v_business_test_object_sources known WHERE known.source_type<>'DELETE_OPERATION'
                                AND known.storage_provider=s.storage_provider AND known.storage_key=s.storage_key
                                AND known.object_location=s.object_location
                                AND (known.storage_version IS NULL OR known.storage_version IS NOT DISTINCT FROM s.storage_version))
                            THEN '无业务来源的旧对象任务需要先对账'
                        ELSE NULL END reason,file_name
                    FROM fn_business_test_object_sources() s)
                SELECT reason,count(*) total,(array_agg(file_name ORDER BY file_name))[1:5] samples
                FROM blocked WHERE reason IS NOT NULL GROUP BY reason ORDER BY reason
                """,(row,n)->new UnpurgeableGroup(row.getString("reason"),row.getLong("total"),samples(row)),new Object[0]);
        });
    }
    Preview prepare(UUID actorId,String account,UUID attemptId,Confirmation confirmation) {
        if(attemptId==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"测试清理须保留本次受理标识");
        return transactions.execute(status->{
            AuthUser actor=requireActor(actorId);tx.bind();
            if(!Objects.equals(account,actor.getLoginAccount()))throw new ApiException(ErrorCode.FORBIDDEN);
            lockSources();
            Preview reviewed=previewInside(actor);
            if(confirmation==null || !reviewed.database().equals(confirmation.database()) || !reviewed.fingerprint().equals(confirmation.fingerprint()))
                throw new ApiException(ErrorCode.CONFLICT,"数据库或原件状态已变化，请重新预览确认");
            long generation=generation();
            for(Source source:readSources()) {
                requireSource(source);
                Exact exact=inspect(source,null);
                Intent intent=new Intent(UUID.randomUUID(),PURPOSE,attemptId,generation,actorId,account,reviewed.database(),
                    source.type(),source.id(),source.fingerprint(),source.location(),source.provider(),source.key(),exact.version(),
                    exact.exists(),exact.size(),exact.sha(),null,Instant.now().plusSeconds(300).truncatedTo(ChronoUnit.MICROS),0);
                String signature=signatures.sign(intent.canonical());
                jdbc.queryForObject("SELECT fn_test_object_prepare(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)::text",String.class,
                    intent.id(),attemptId,generation,actorId,account,reviewed.database(),source.type(),source.id(),source.fingerprint(),
                    source.location(),source.provider(),source.key(),exact.version(),exact.exists(),exact.size(),exact.sha(),signature,Timestamp.from(intent.until()));
            }
            audit.logExplicit(actorId,account,"business_test_object_cleanup_prepare","system_test",reviewed.database(),
                "attempt="+attemptId+",generation="+generation+",reviewed="+reviewed.items().size()+",fingerprint="+reviewed.fingerprint());
            return previewInside(actor);
        });
    }
    boolean drain(UUID attemptId) {
        if(attemptId==null)throw new ApiException(ErrorCode.VALIDATION_FAILED);
        return Boolean.TRUE.equals(transactions.execute(status->{
            AuthUser actor=requireActor(null);tx.bind();lockSources();long generation=generation();
            Intent ticket=jdbc.query("SELECT "+INTENT_COLUMNS+" FROM fn_test_object_claim(?,?,?)",r->r.next()?intent(r):null,
                attemptId,actor.getId(),generation);
            if(ticket==null)return false;
            try {
                if(!PURPOSE.equals(ticket.purpose()) || !ticket.database().equals(database()) || ticket.generation()!=generation
                    || !ticket.actorId().equals(actor.getId()) || !ticket.account().equals(actor.getLoginAccount())
                    || ticket.until().isBefore(Instant.now()) || !signatures.matches(ticket.canonical(),ticket.signature()))
                    throw new ApiException(ErrorCode.CONFLICT,"测试原件清理签名或受理身份已失效");
                Source source=jdbc.query("SELECT "+SOURCE_COLUMNS+" FROM v_business_test_object_sources WHERE source_type=? AND source_id=? AND object_location=?",
                    r->r.next()?source(r):null,ticket.type(),ticket.sourceId(),ticket.location());
                if(source==null || !source.fingerprint().equals(ticket.fingerprint()))throw new ApiException(ErrorCode.CONFLICT,"原件源身份已变化");
                requireSource(source);
                if(Boolean.TRUE.equals(jdbc.queryForObject("SELECT fn_business_test_object_protected(?,?,?,?)",Boolean.class,
                    ticket.provider(),ticket.location(),ticket.key(),ticket.version())))throw new ApiException(ErrorCode.CONFLICT,"原件已被保留主档引用");
                Exact observed=inspect(source,ticket.version());
                // A previous physical deletion may have succeeded before its database commit failed.
                // Retry can record absence only for this same signed generation/source/object identity.
                if(observed.exists() && (!ticket.exists() || observed.size()!=ticket.size() || !observed.sha().equals(ticket.sha())
                    || !Objects.equals(observed.version(),ticket.version())))throw new ApiException(ErrorCode.CONFLICT,"原件内容或精确版本已变化");
                StorageService provider=storage.require(ticket.provider());
                if("STAGING".equals(ticket.location()))provider.deleteStaging(ticket.key(),ticket.version());
                else provider.delete(ticket.key(),ticket.version());
                if(inspect(source,ticket.version()).exists())throw new ApiException(ErrorCode.CONFLICT,"原件物理清理尚未完成");
                if(!complete(ticket,true,null))throw new ApiException(ErrorCode.CONFLICT,"本次清理已被更新的执行取代");
            } catch(RuntimeException error) {
                if(!complete(ticket,false,error.getClass().getSimpleName()))throw error;
                audit.logExplicit(actor.getId(),actor.getLoginAccount(),"business_test_object_cleanup_failed","system_test",database(),
                    "attempt="+attemptId+",generation="+generation+",intent="+ticket.id()+",failure="+error.getClass().getSimpleName());
            }
            return true;
        }));
    }
    long succeeded(UUID attemptId) {
        return transactions.execute(status->{AuthUser actor=requireActor(null);tx.bind();return jdbc.queryForObject("""
            SELECT count(DISTINCT (storage_provider,object_location,storage_key,storage_version))
            FROM business_test_object_cleanup_intents WHERE attempt_id=? AND actor_id=? AND generation=?
              AND status='SUCCEEDED' AND completed_at IS NOT NULL AND object_exists
            """,Long.class,attemptId,actor.getId(),generation());});
    }
    private boolean complete(Intent ticket,boolean success,String error) {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT fn_test_object_complete(?,?,?,?,?,?,?,?)",Boolean.class,
            ticket.id(),ticket.attempt(),ticket.actorId(),ticket.generation(),ticket.claim(),ticket.signature(),success,error));
    }
    private void lockSources(){jdbc.queryForObject("SELECT fn_test_object_lock_sources()::text",String.class);}
    private long generation(){return jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1",Long.class);}
    private String database(){return jdbc.queryForObject("SELECT current_database()",String.class);}
    private List<Source> readSources(){return jdbc.query("SELECT "+SOURCE_COLUMNS+" FROM fn_business_test_object_sources() ORDER BY source_type,source_id,object_location LIMIT ?",(r,n)->source(r),BATCH_SIZE);}
    private Preview previewInside(AuthUser actor) {
        List<Source> sources=readSources();String database=database();long generation=generation();
        long total=jdbc.queryForObject("SELECT count(*) FROM fn_business_test_object_sources()",Long.class);
        List<String> fingerprint=new ArrayList<>(List.of("database="+database,"actor="+actor.getId(),"generation="+generation,"total="+total));
        sources.forEach(s->fingerprint.add(s.type()+":"+s.id()+":"+s.location()+":"+s.fingerprint()));
        List<Item> items=sources.stream().map(s->new Item(s.type()+"_"+s.location(),displayId(s),s.ownerType(),s.ownerId(),s.name(),s.state(),s.waitUntil(),
            "需精确原件物理完成证明（测试清空例外）")).toList();
        return new Preview(database,CanonicalFingerprint.sha256(fingerprint),total,items,total>sources.size());
    }
    private AuthUser requireActor(UUID expected) {
        AuthUser actor=current.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        if(!actor.isSuperAdmin() || actor.getImpersonatedBy()!=null || (expected!=null&&!expected.equals(actor.getId()))
            || !Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM users WHERE id=? AND login_account=? AND is_super_admin AND status='active' AND NOT is_deleted)",Boolean.class,actor.getId(),actor.getLoginAccount())))throw new ApiException(ErrorCode.FORBIDDEN,"测试原件清理仅限超级管理员本人");
        return actor;
    }
    private void requireSource(Source source) {
        if(source.provider()==null || !List.of("internal","local").contains(source.provider()))throw new ApiException(ErrorCode.CONFLICT,"历史存储来源需先对账");
        if(source.waitUntil()!=null&&source.waitUntil().isAfter(Instant.now()))throw new ApiException(ErrorCode.CONFLICT,"上传凭证仍有效，请到期后重试");
        if("DELETE_OPERATION".equals(source.type())&&"UNKNOWN".equals(source.ownerType())) {
            Boolean known=jdbc.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM v_business_test_object_sources WHERE source_type<>'DELETE_OPERATION'
                    AND storage_provider=? AND storage_key=? AND object_location=?
                    AND (storage_version IS NULL OR storage_version IS NOT DISTINCT FROM ?))
                """,Boolean.class,source.provider(),source.key(),source.location(),source.version());
            if(!Boolean.TRUE.equals(known))throw new ApiException(ErrorCode.CONFLICT,"无业务来源的原件任务需先对账");
        }
    }
    private Exact inspect(Source source,String pinnedVersion) {
        StorageService provider=storage.require(source.provider());String version=pinnedVersion==null?source.version():pinnedVersion;
        if("STAGING".equals(source.location())&&version==null) {
            StorageService.StoredObject staged=provider.describe(source.key());
            if(staged.exists())version=staged.versionId();
        }
        try(InputStream stream="STAGING".equals(source.location())?provider.openForValidation(source.key(),version):provider.openFinal(source.key(),version)) {
            MessageDigest sha=MessageDigest.getInstance("SHA-256");byte[] buffer=new byte[64*1024];long length=0;int count;
            while((count=stream.read(buffer))!=-1) {
                length+=count;if(length>Math.max(properties.getMaxBytes(),15*1024*1024L))throw new ApiException(ErrorCode.CONFLICT,"原件超出有界清理校验上限，请先对账");
                sha.update(buffer,0,count);
            }
            String hash=HexFormat.of().formatHex(sha.digest());
            if((!"UPLOAD_SESSION".equals(source.type())&&source.size()!=null&&length!=source.size()) || source.sha()!=null&&!source.sha().isBlank()&&!hash.equals(source.sha()))
                throw new ApiException(ErrorCode.CONFLICT,"原件大小或摘要与持久来源不符");
            if("internal".equals(source.provider())&&(version==null||version.isBlank()))throw new ApiException(ErrorCode.CONFLICT,"内部原件缺少精确版本，请先对账");
            return new Exact(true,version,length,hash);
        } catch(Exception error) {
            if(absent(error))return new Exact(false,version,0,CanonicalFingerprint.sha256(List.of("ABSENT")));
            if(error instanceof RuntimeException runtime)throw runtime;
            throw new IllegalStateException("Unable to verify exact test original",error);
        }
    }
    private static boolean absent(Throwable error) {
        for(Throwable cause=error;cause!=null;cause=cause.getCause())if(cause instanceof NoSuchFileException||cause instanceof FileNotFoundException)return true;
        return false;
    }
    private static UUID displayId(Source s){try{return UUID.fromString(s.id());}catch(IllegalArgumentException ignored){return UUID.nameUUIDFromBytes((s.type()+":"+s.id()).getBytes(StandardCharsets.UTF_8));}}
    private static List<String> samples(ResultSet r)throws SQLException {var array=r.getArray("samples");if(array==null)return List.of();return java.util.Arrays.stream((Object[])array.getArray()).map(String::valueOf).toList();}
    private static Source source(ResultSet r)throws SQLException {return new Source(r.getString("source_type"),r.getString("source_id"),r.getString("owner_type"),r.getObject("owner_id",UUID.class),r.getString("file_name"),r.getString("source_state"),r.getString("object_location"),r.getString("storage_provider"),r.getString("storage_key"),r.getString("storage_version"),r.getObject("size_bytes",Long.class),r.getString("sha256"),instant(r,"wait_until"),r.getString("source_fingerprint"));}
    private static Intent intent(ResultSet r)throws SQLException {return new Intent(r.getObject("id",UUID.class),r.getString("purpose"),r.getObject("attempt_id",UUID.class),r.getLong("generation"),r.getObject("actor_id",UUID.class),r.getString("actor_account"),r.getString("database_name"),r.getString("source_type"),r.getString("source_id"),r.getString("source_fingerprint"),r.getString("object_location"),r.getString("storage_provider"),r.getString("storage_key"),r.getString("storage_version"),r.getBoolean("object_exists"),r.getLong("size_bytes"),r.getString("sha256"),r.getString("signature"),instant(r,"authorized_until"),r.getLong("claim_number"));}
    private static Instant instant(ResultSet r,String name)throws SQLException {Timestamp value=r.getTimestamp(name);return value==null?null:value.toInstant();}
    private record Source(String type,String id,String ownerType,UUID ownerId,String name,String state,String location,String provider,String key,String version,Long size,String sha,Instant waitUntil,String fingerprint){}
    private record Exact(boolean exists,String version,long size,String sha){}
    private static String canonicalParts(List<String> parts) {
        StringBuilder canonical=new StringBuilder();
        for(String part:parts) canonical.append(part.getBytes(StandardCharsets.UTF_8).length).append(':').append(part).append('\n');
        return canonical.toString();
    }
    record Intent(UUID id,String purpose,UUID attempt,long generation,UUID actorId,String account,String database,String type,String sourceId,String fingerprint,String location,String provider,String key,String version,boolean exists,long size,String sha,String signature,Instant until,long claim) {
        String canonical(){return canonicalParts(List.of("BUSINESS_TEST_OBJECT_V1",id.toString(),purpose,attempt.toString(),Long.toString(generation),actorId.toString(),account,database,type,sourceId,fingerprint,location,provider,key,version==null?"NULL":"VALUE:"+version,Boolean.toString(exists),Long.toString(size),sha,until.toString()));}
    }
}
