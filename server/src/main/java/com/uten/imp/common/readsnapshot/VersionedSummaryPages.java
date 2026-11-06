package com.uten.imp.common.readsnapshot;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ReadScopeVersionAuthority;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.transaction.support.ResourceHolderSupport;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;
import java.util.function.BiFunction;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import java.util.concurrent.TimeUnit;

/** Bounded network pages of complete, versioned summaries. Never a total-result/write limit. */
@Service
public class VersionedSummaryPages {
    public record Request(String domain, String authorizationDomain, Object queryIdentity, String scope,
                          int page, int size, int maxReadSize, String expectedReadSnapshotRevision) { }
    public record Page<T>(List<T> items, int page, int size, long total, int totalPages, String scope,
                          String readScopeVersion, String readSnapshotRevision, String readDataVersion) { }
    @com.fasterxml.jackson.databind.annotation.JsonSerialize(using=SnapshotSerializer.class)
    public record Snapshot<T>(T value,
                              String readScopeVersion, String readSnapshotRevision, String readDataVersion) { }
    /** One flat proof envelope for both POJO and Map details; no lossy Map conversion or duplicate keys. */
    public static final class SnapshotSerializer extends com.fasterxml.jackson.databind.JsonSerializer<Snapshot<?>> {
        private static final Set<String> RESERVED=Set.of("readScopeVersion","readSnapshotRevision","readDataVersion");
        private final com.fasterxml.jackson.databind.util.NameTransformer names;
        public SnapshotSerializer() {this(null);}
        private SnapshotSerializer(com.fasterxml.jackson.databind.util.NameTransformer names) {this.names=names;}
        @Override public com.fasterxml.jackson.databind.JsonSerializer<Snapshot<?>> unwrappingSerializer(com.fasterxml.jackson.databind.util.NameTransformer transformer) {
            return new SnapshotSerializer(names==null?transformer:com.fasterxml.jackson.databind.util.NameTransformer.chainedTransformer(transformer,names));
        }
        @Override public boolean isUnwrappingSerializer() {return names!=null;}
        private String name(String raw) {return names==null?raw:names.transform(raw);}
        @Override public void serialize(Snapshot<?> value,com.fasterxml.jackson.core.JsonGenerator out,
                                         com.fasterxml.jackson.databind.SerializerProvider provider) throws java.io.IOException {
            try(var content=new com.fasterxml.jackson.databind.util.TokenBuffer(out.getCodec(),false)) {
                provider.defaultSerializeValue(value.value(),content);
                // Validate the entire root before emitting a byte, including reserved/duplicate fields.
                try(var input=content.asParser(out.getCodec())) {
                    if(input.nextToken()!=com.fasterxml.jackson.core.JsonToken.START_OBJECT)
                        throw com.fasterxml.jackson.databind.JsonMappingException.from(out,"A summary detail must be an object");
                    Set<String> fields=new HashSet<>();
                    while(input.nextToken()!=com.fasterxml.jackson.core.JsonToken.END_OBJECT) {
                        if(input.currentToken()!=com.fasterxml.jackson.core.JsonToken.FIELD_NAME)
                            throw com.fasterxml.jackson.databind.JsonMappingException.from(out,"Invalid summary detail fields");
                        String field=input.currentName();
                        if(RESERVED.contains(field)||!fields.add(field))
                            throw com.fasterxml.jackson.databind.JsonMappingException.from(out,"Summary detail contains a reserved or duplicate proof field");
                        input.nextToken();input.skipChildren();
                    }
                }
                if(!isUnwrappingSerializer())out.writeStartObject();
                try(var input=content.asParser(out.getCodec())) {
                    input.nextToken();
                    while(input.nextToken()!=com.fasterxml.jackson.core.JsonToken.END_OBJECT) {
                        out.writeFieldName(name(input.currentName()));input.nextToken();out.copyCurrentStructure(input);
                    }
                }
                out.writeStringField(name("readScopeVersion"),value.readScopeVersion());
                out.writeStringField(name("readSnapshotRevision"),value.readSnapshotRevision());
                out.writeStringField(name("readDataVersion"),value.readDataVersion());
                if(!isUnwrappingSerializer())out.writeEndObject();
            }
        }
    }
    private record Stamp(String authorization, String revision, String dataVersion) { }
    public record ReadProof(String readScopeVersion, String readSnapshotRevision, String readDataVersion) {
        public <T> Snapshot<T> snapshot(T value) {
            return new Snapshot<>(value, readScopeVersion, readSnapshotRevision, readDataVersion);
        }
    }
    private final JdbcTemplate jdbc;
    private final ReadScopeVersionAuthority authorization;
    private final SecurityContextCurrentUser current;
    private final ObjectMapper identityJson;
    private final PlatformTransactionManager transactions;

    public VersionedSummaryPages(JdbcTemplate jdbc, ReadScopeVersionAuthority authorization,
                                 SecurityContextCurrentUser current, ObjectMapper mapper,
                                 PlatformTransactionManager transactions) {
        this.jdbc=jdbc; this.authorization=authorization; this.current=current;
        identityJson=mapper.copy().enable(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS);
        this.transactions=transactions;
    }

    public <T> Page<T> page(Request request, LongSupplier count, BiFunction<Integer,Integer,List<T>> batch) {
        return page(request, () -> { }, count, batch);
    }

    public <T> Page<T> page(Request request, Runnable authorize, LongSupplier count,
                             BiFunction<Integer,Integer,List<T>> batch) {
        Snapshot<Page<T>> result=read(request, authorize, () -> {
            long total=count.getAsLong();
            if(total<0)throw unavailable();
            long pages=total==0?0:1+(total-1)/request.size();
            if(pages>Integer.MAX_VALUE)throw unavailable();
            List<T> items=Objects.requireNonNull(batch.apply(request.page(),request.size()));
            long offset=Math.multiplyExact((long)request.page()-1,request.size());
            long expected=Math.max(0,Math.min(request.size(),total-offset));
            if(items.size()!=expected)throw unavailable();
            return new Page<>(List.copyOf(items),request.page(),request.size(),total,(int)pages,request.scope(),null,null,null);
        });
        Page<T> value=result.value();
        return new Page<>(value.items(),value.page(),value.size(),value.total(),value.totalPages(),value.scope(),
                result.readScopeVersion(),result.readSnapshotRevision(),result.readDataVersion());
    }

    /** Detail readers can reuse a summary's exact query/size token without returning all summary rows. */
    public <T> Snapshot<T> read(Request request, Runnable authorize, Supplier<T> reader) {
        return read(request,authorize,reader,false);
    }

    /** Task candidate readers retain the original fresh-task audience in both RR phases. */
    public <T> Snapshot<T> read(Request request, Runnable authorize, Supplier<T> reader, boolean businessTasks) {
        return readStamped(request, authorize, (proof, checkpoint) -> reader.get(), businessTasks);
    }

    /** A complete stream reuses one RR stamp across its bounded batches. The
     * caller may publish completion only after this method's fresh final fence. */
    public <T> Snapshot<T> readWithProof(Request request, Runnable authorize,
            BiFunction<ReadProof, Runnable, T> reader) {
        return readStamped(request, authorize, reader, false);
    }

    private <T> Snapshot<T> readStamped(Request request, Runnable authorize,
            BiFunction<ReadProof, Runnable, T> reader, boolean businessTasks) {
        validate(request);
        long deadline=deadline();
        AuthUser subject=current.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        Snapshot<T> result=Objects.requireNonNull(snapshot(deadline).execute(status -> {
            authorize.run();
            Stamp stamp=stamp(request,subject,businessTasks);
            if(request.expectedReadSnapshotRevision()!=null && !request.expectedReadSnapshotRevision().equals(stamp.revision()))
                throw changed();
            T value=reader.apply(new ReadProof(stamp.authorization(), stamp.revision(), stamp.dataVersion()), () -> {
                remaining(deadline);
                if (Thread.currentThread().isInterrupted()) throw new java.util.concurrent.CancellationException("Complete summary read interrupted");
            });
            return new Snapshot<>(value,stamp.authorization(),stamp.revision(),stamp.dataVersion());
        }));
        remaining(deadline);
        // A fresh committed snapshot is a publication fence, separate from the data RR transaction.
        // No implicit retry or partial publication is allowed after a mutation/permission/reset.
        Stamp latest=Objects.requireNonNull(snapshot(deadline).execute(status -> { authorize.run();return stamp(request,subject,businessTasks); }));
        remaining(deadline);
        if(!result.readScopeVersion().equals(latest.authorization()))
            throw new ApiException(ErrorCode.READ_SCOPE_CHANGED,"身份或可见范围已变化，请重新读取");
        if(!result.readSnapshotRevision().equals(latest.revision()))throw changed();
        return result;
    }

    private static long deadline() {
        long budget=TimeUnit.SECONDS.toNanos(60);
        // Preserve an already-running outer transaction's remaining budget before suspending it.
        for(Object resource:TransactionSynchronizationManager.getResourceMap().values())
            if(resource instanceof ResourceHolderSupport holder && holder.hasTimeout())
                budget=Math.min(budget,TimeUnit.MILLISECONDS.toNanos(holder.getTimeToLiveInMillis()));
        return System.nanoTime()+budget;
    }
    private static long remaining(long deadline) {
        long value=deadline-System.nanoTime();
        if(value<=0)throw new org.springframework.transaction.TransactionTimedOutException("Complete summary read exhausted its original transaction budget");
        return value;
    }
    private TransactionTemplate snapshot(long deadline) {
        TransactionTemplate local=new TransactionTemplate(transactions);
        // Per-call objects: neither requests nor the two phases mutate another request's timeout.
        local.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        local.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
        local.setReadOnly(true);
        local.setTimeout((int)Math.max(1,(remaining(deadline)+TimeUnit.SECONDS.toNanos(1)-1)/TimeUnit.SECONDS.toNanos(1)));
        return local;
    }

    private Stamp stamp(Request request,AuthUser subject,boolean businessTasks) {
        String auth=businessTasks?authorization.scopeForCurrentSnapshot(request.authorizationDomain(),subject,true)
                :authorization.scopeForCurrentSnapshot(request.authorizationDomain(),subject);
        List<Map<String,Object>> rows=jdbc.queryForList("""
                SELECT a.business_dataset_id,a.business_reset_generation,d.epoch,
                       (d.compacted_markers+(SELECT count(*) FROM summary_read_markers m WHERE m.domain=d.domain))::text AS revision
                FROM summary_read_domains d CROSS JOIN authorization_state a
                WHERE d.domain=? AND a.singleton_id=1
                """,request.domain());
        if(rows.size()!=1)throw unavailable();
        Map<String,Object> row=rows.getFirst();
        try {
            String dataVersion=hash("summary-data-v1",request.domain(),
                    Objects.requireNonNull(row.get("business_dataset_id")),Objects.requireNonNull(row.get("business_reset_generation")),
                    Objects.requireNonNull(row.get("epoch")),Objects.requireNonNull(row.get("revision")));
            String revision=hash("summary-read-v1",request.domain(),request.authorizationDomain(),request.scope(),
                    request.size(),identityJson.writeValueAsString(request.queryIdentity()),auth,dataVersion);
            return new Stamp(auth,revision,dataVersion);
        } catch(JsonProcessingException invalid) { throw new ApiException(ErrorCode.VALIDATION_FAILED,"读取条件无法确认"); }
    }

    private static String hash(Object... values) {
        try {
            MessageDigest hash=MessageDigest.getInstance("SHA-256");
            for(Object value:values) {
                byte[] bytes=value.toString().getBytes(StandardCharsets.UTF_8);
                hash.update(ByteBuffer.allocate(4).putInt(bytes.length).array());hash.update(bytes);
            }
            return HexFormat.of().formatHex(hash.digest());
        } catch(NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }

    private static void validate(Request r) {
        if(r==null||r.domain()==null||r.authorizationDomain()==null||r.queryIdentity()==null||r.scope()==null
                ||!Set.of("active","history","all").contains(r.scope())||r.page()<1||r.size()<1
                ||r.maxReadSize()<1||r.maxReadSize()>1000||r.size()>r.maxReadSize()
                ||(r.expectedReadSnapshotRevision()!=null&&!r.expectedReadSnapshotRevision().matches("[0-9a-f]{64}")))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"摘要读取条件无效");
    }
    public static String scope(String scope) {
        if(scope==null)return "all"; // Compatibility; new daily callers explicitly select active/history.
        if(!Set.of("active","history","all").contains(scope))throw new ApiException(ErrorCode.VALIDATION_FAILED,"办理范围无效");
        return scope;
    }
    private static ApiException changed() { return new ApiException(ErrorCode.SNAPSHOT_CHANGED,"数据已变化，请重新读取完整摘要"); }
    private static ApiException unavailable() { return new ApiException(ErrorCode.PRIMARY_UNAVAILABLE,"完整摘要读取未完成"); }
}
