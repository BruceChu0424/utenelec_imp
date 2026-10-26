package com.uten.imp.audit;

import com.uten.imp.common.export.ExportOperationCheckpoint;
import com.uten.imp.common.export.ExportResourceLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.*;
import jakarta.persistence.criteria.*;
import org.hibernate.query.criteria.JpaExpression;
import org.springframework.beans.BeanWrapperImpl;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.*;
import java.util.function.Consumer;

/** Unmanaged metadata pages; only evidence needed by the existing interpreter is
 * fetched in byte-bounded groups. Raw user-agent is never part of the bulk read. */
@Component
public class AuditExportProjectionReader {
    @PersistenceContext private EntityManager em;
    private static final String[] FIELDS={"id","actorId","actorAccount","sessionId","action","targetType","targetId",
            "ip","result","requestId","eventSource","httpMethod","httpPath","statusCode","durationMs","clientEventId",
            "deviceInstallationId","deviceName","deviceManufacturer","deviceModel","devicePlatform","deviceOsVersion",
            "appVersion","appBuild","deviceFormFactor","deviceBrowser","deviceLocale","deviceTimeZone","deviceTimeZoneOffsetMinutes",
            "deviceIsPhysical","clientEventAt","deviceCaptureStatus","deviceProfileHash","riskLevel","eventCategory","onBehalfOf","createdAt"};
    private record Key(long id,OffsetDateTime createdAt) { }
    private record Metadata(AuditLog row,long bytes) { }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public void read(Specification<AuditLog> specification,long expected,Consumer<List<AuditLog>> consume) {
        Key last=null;long seen=0;
        while(true) {
            ExportOperationCheckpoint.check();
            List<Metadata> page=metadata(specification,last);
            if(page.isEmpty())break;
            List<AuditLog> group=new ArrayList<>(100);long bytes=0;
            for(var value:page) {
                if(value.bytes()>ExportResourceLimits.SOURCE_BATCH_BYTES)
                    throw new ApiException(ErrorCode.VALIDATION_FAILED,"单条审计原始内容超过导出读取预算，请按审计编号查看详情；原文未改变");
                if(!group.isEmpty()&&bytes+value.bytes()>ExportResourceLimits.SOURCE_BATCH_BYTES){deliver(group,consume);group.clear();bytes=0;}
                group.add(value.row());bytes+=value.bytes();
            }
            if(!group.isEmpty())deliver(group,consume);
            seen+=page.size();
            if(seen>expected)throw changed();
            var row=page.getLast().row();
            if(row.getId()==null||row.getCreatedAt()==null)throw changed();
            last=new Key(row.getId(),row.getCreatedAt());
            if(page.size()<100)break;
        }
        if(seen!=expected)throw changed();
    }
    private List<Metadata> metadata(Specification<AuditLog> specification,Key after) {
        var cb=em.getCriteriaBuilder();var query=cb.createTupleQuery();var root=query.from(AuditLog.class);
        List<Selection<?>> fields=new ArrayList<>();
        for(String name:FIELDS)fields.add(root.get(name).alias(name));
        fields.add(size(cb,root,"before").alias("_beforeBytes"));fields.add(size(cb,root,"after").alias("_afterBytes"));
        Predicate predicate=specification.toPredicate(root,query,cb);
        if(after!=null)predicate=cb.and(predicate,cb.or(cb.lessThan(root.get("createdAt"),after.createdAt()),
                cb.and(cb.equal(root.get("createdAt"),after.createdAt()),cb.lessThan(root.get("id"),after.id()))));
        query.select(cb.tuple(fields)).where(predicate).orderBy(cb.desc(root.get("createdAt")),cb.desc(root.get("id")));
        return em.createQuery(query).setMaxResults(100).setHint("org.hibernate.readOnly",true)
                .setHint("jakarta.persistence.query.timeout",60000).getResultList().stream().map(tuple->{
                    var row=new AuditLog();var bean=new BeanWrapperImpl(row);
                    for(String name:FIELDS)bean.setPropertyValue(name,tuple.get(name));
                    return new Metadata(row,((Number)tuple.get("_beforeBytes")).longValue()+((Number)tuple.get("_afterBytes")).longValue());
                }).toList();
    }
    private Expression<Integer> size(CriteriaBuilder cb,Root<AuditLog> root,String field) {
        return cb.coalesce(cb.function("octet_length",Integer.class,((JpaExpression<?>)root.get(field)).cast(String.class)),0);
    }
    private void deliver(List<AuditLog> rows,Consumer<List<AuditLog>> consume) {
        ExportOperationCheckpoint.check();
        var cb=em.getCriteriaBuilder();var query=cb.createTupleQuery();var root=query.from(AuditLog.class);
        List<Predicate> keys=new ArrayList<>();
        for(var row:rows)keys.add(cb.and(cb.equal(root.get("id"),row.getId()),cb.equal(root.get("createdAt"),row.getCreatedAt())));
        query.select(cb.tuple(root.get("id").alias("id"),root.get("createdAt").alias("time"),
                root.get("before").alias("before"),root.get("after").alias("after"))).where(cb.or(keys.toArray(Predicate[]::new)));
        Map<Key,Tuple> evidence=new HashMap<>();
        for(var tuple:em.createQuery(query).setMaxResults(rows.size()+1).setHint("org.hibernate.readOnly",true)
                .setHint("jakarta.persistence.query.timeout",60000).getResultList())
            evidence.put(new Key(((Number)tuple.get("id")).longValue(),tuple.get("time",OffsetDateTime.class)),tuple);
        if(evidence.size()!=rows.size())throw changed();
        try {
            for(var row:rows) {
                Tuple raw=evidence.get(new Key(row.getId(),row.getCreatedAt()));if(raw==null)throw changed();
                row.setBefore(raw.get("before",String.class));row.setAfter(raw.get("after",String.class));
                structure(row.getBefore());structure(row.getAfter());
                ExportOperationCheckpoint.check();
            }
            consume.accept(List.copyOf(rows));
        } finally {
            // These are detached presentation objects, never persistence-managed facts.
            rows.forEach(row->{row.setBefore(null);row.setAfter(null);});
        }
    }
    private static void structure(String value) {
        if(value==null)return;
        try(var parser=new com.fasterxml.jackson.core.JsonFactory().createParser(value)) {
            int tokens=0;
            while(parser.nextToken()!=null){
                if(++tokens>200000)throw new ApiException(ErrorCode.VALIDATION_FAILED,"审计原始内容结构超过导出读取预算，请按编号查看原文");
                if(tokens%1024==0)ExportOperationCheckpoint.check();
            }
        } catch(java.io.IOException invalid) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"审计原始内容无法在受控预算内解释，请按编号查看原文");
        }
    }
    private static ApiException changed(){return new ApiException(ErrorCode.CONFLICT,"审计读取范围已变化，请刷新后重新导出");}
}
