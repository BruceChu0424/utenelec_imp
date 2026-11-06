package com.uten.imp.common.web;

import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.TaskKeywordSearch;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;

import java.util.*;

/** An explicitly tagged original facet query, retaining its complete business filter/count authority. */
public final class NativeFacetCandidates {
    private NativeFacetCandidates(){}
    private static final ThreadLocal<Scope> CURRENT=new ThreadLocal<>();
    private static final String SEARCH="__nativeFacetKeyword",LIMIT="__nativeFacetLimit",OFFSET="__nativeFacetOffset";
    public record Page(String field,List<Map<String,Object>> items,int page,int size,boolean hasMore,String readScopeVersion,
                       String readSnapshotRevision,String readDataVersion) {
        public Page(String field,List<Map<String,Object>> items,int page,int size,boolean hasMore,String readScopeVersion) {
            this(field,items,page,size,hasMore,readScopeVersion,null,null);
        }
        public Page {items=List.copyOf(items);}
    }
    private record Original(EntityManager em,String field,String sql,boolean labeled){}
    public static boolean active(){return CURRENT.get()!=null;}
    public static Scope current(){return CURRENT.get();}
    public static Scope open(String field,String keyword,long page,int size){return new Scope(field,keyword,page,size);}
    public static Query query(EntityManager em,String field,String sql) {
        return query(em,field,sql,false);
    }
    public static Query query(EntityManager em,String field,String sql,boolean labeled) {
        Query query=em.createNativeQuery(sql);
        Scope scope=CURRENT.get();if(scope!=null)scope.originals.put(query,new Original(em,field,sql,labeled));
        return query;
    }
    static List<Map<String,Object>> rows(Query query) {
        Scope scope=Objects.requireNonNull(CURRENT.get());
        return scope.read(query);
    }
    public static final class Scope implements AutoCloseable {
        private final Scope previous;
        private final Thread owner=Thread.currentThread();
        private final String field,keyword;
        private final int page,size;
        private final long offset;
        private final Map<Query,Original> originals=new IdentityHashMap<>();
        private List<Map<String,Object>> items;
        private boolean hasMore,closed,failed,requiresSnapshot;
        private String snapshotScope,snapshotRevision,dataVersion;
        public boolean wants(String candidateField) {return field.equals(candidateField);}
        public int page() {return page;}
        public int size() {return size;}
        public void requireSnapshot() {requiresSnapshot=true;}
        public void snapshot(String scope,String revision,String data) {
            if(scope==null||revision==null||data==null)throw new IllegalStateException("Candidate snapshot proof missing");
            snapshotScope=scope;snapshotRevision=revision;dataVersion=data;
        }
        private String boundedSql(String applicationSql,boolean labeled) {return boundedSql(applicationSql,labeled,false);}
        private String boundedSql(String applicationSql,boolean labeled,boolean positional) {
            String source=applicationSql.strip();if(source.endsWith(";"))source=source.substring(0,source.length()-1);
            String label=labeled?"COALESCE(raw_candidate.label::text,'')":"COALESCE(raw_candidate.value::text,'')";
            String fields=labeled?"value,label,bucket_count":"value,bucket_count";
            String prefix="SELECT candidate.value,candidate.label,candidate.bucket_count FROM (SELECT COALESCE(raw_candidate.value::text,'') AS value,"
                    +label+" AS label,SUM(raw_candidate.bucket_count) AS bucket_count FROM (";
            String suffix=") raw_candidate("+fields+") GROUP BY 1,2) candidate WHERE "
                    +TaskKeywordSearch.conditionParameter(SEARCH,"CAST(candidate.value AS text)","CAST(candidate.label AS text)")
                    +" ORDER BY CAST(candidate.value AS text) ASC NULLS FIRST,CAST(candidate.label AS text) ASC NULLS FIRST LIMIT :"+LIMIT+" OFFSET :"+OFFSET;
            // Only our generated suffix is rebound; original positional business SQL remains byte-for-byte unchanged.
            if(positional)suffix=suffix.replace(":"+SEARCH,"?").replace(":"+LIMIT,"?").replace(":"+OFFSET,"?");
            return prefix+source+suffix;
        }
        private List<Map<String,Object>> accept(List<Object[]> rows) {
            if(rows.size()>size+1)throw new IllegalStateException("Candidate query ignored its page bound");
            hasMore=rows.size()>size;
            var selected=new ArrayList<Map<String,Object>>(Math.min(size,rows.size()));
            for(Object[] row:rows.subList(0,Math.min(size,rows.size()))) {
                if(row.length!=3||!(row[2] instanceof Number count))throw new IllegalStateException("Candidate query must retain value, label and original grouped count");
                selected.add(NativeFacets.bucket(row[0]==null?"":row[0].toString(),row[1]==null?"":row[1].toString(),count.longValue()));
            }
            items=List.copyOf(selected);return items;
        }
        private Scope(String field,String keyword,long requestedPage,int size) {
            if(field==null||!field.matches("[A-Za-z][A-Za-z0-9]{0,79}"))throw invalid("候选字段无效");
            if(keyword!=null&&keyword.length()>2000)throw invalid("候选关键字过长");
            if(requestedPage<1||requestedPage>Integer.MAX_VALUE||size<1||size>100)throw invalid("候选分页超出范围");
            this.field=field;this.keyword=KeywordSearch.phrase(keyword);this.page=(int)requestedPage;this.size=size;
            try{offset=Math.multiplyExact(requestedPage-1,(long)size);}catch(ArithmeticException overflow){throw invalid("候选分页超出范围");}
            previous=CURRENT.get();CURRENT.set(this);
        }
        private List<Map<String,Object>> read(Query query) {
            if(closed||failed)throw new IllegalStateException("Candidate query scope is closed or failed");
            try {
                if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();
                Original original=originals.remove(query);
                if(original==null)throw new IllegalStateException("Candidate queries require registered application SQL and field");
                if(!field.equals(original.field()))return List.of();
                if(items!=null)throw new IllegalStateException("A candidate field must have one authoritative grouped query");
                Query paged=original.em().createNativeQuery(boundedSql(original.sql(),original.labeled()));
                for(var parameter:query.getParameters()) {
                    String name=parameter.getName();
                    if(name==null||Set.of(SEARCH,LIMIT,OFFSET).contains(name))throw new IllegalStateException("Candidate queries require non-conflicting named application parameters");
                    Object value=query.getParameterValue(parameter);
                    if(value instanceof Set<?> set)value=Set.copyOf(set);else if(value instanceof Collection<?> list)value=List.copyOf(list);
                    paged.setParameter(name,value);
                }
                paged.setParameter(SEARCH,keyword);paged.setParameter(LIMIT,size+1);paged.setParameter(OFFSET,offset);
                paged.setHint("jakarta.persistence.query.timeout",30_000);
                List<Object[]> rows=NativeQueryResults.objectArrayRows(paged);
                return accept(rows);
            }catch(RuntimeException error){failed=true;throw error;}
        }
        public List<Map<String,Object>> jdbcRows(org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate jdbc,
                String candidateField,String sql,org.springframework.jdbc.core.namedparam.SqlParameterSource parameters,boolean labeled) {
            if(closed||failed)throw new IllegalStateException("Candidate query scope is closed or failed");
            if(!field.equals(candidateField))return List.of();
            if(items!=null)throw new IllegalStateException("A candidate field must have one authoritative grouped query");
            try {
                if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();
                var bound=new org.springframework.jdbc.core.namedparam.MapSqlParameterSource();
                String[] names=parameters.getParameterNames();
                if(names==null)throw new IllegalStateException("Candidate JDBC bindings must expose named parameters");
                for(String name:names) {
                    if(Set.of(SEARCH,LIMIT,OFFSET).contains(name))throw new IllegalStateException("Candidate JDBC bindings conflict with read protocol");
                    Object value=parameters.getValue(name);
                    if(value instanceof Set<?> set)value=Set.copyOf(set);else if(value instanceof Collection<?> values)value=List.copyOf(values);
                    bound.addValue(name,value,parameters.getSqlType(name),parameters.getTypeName(name));
                }
                bound.addValue(SEARCH,keyword).addValue(LIMIT,size+1).addValue(OFFSET,offset);
                List<Object[]> rows=jdbc.execute(boundedSql(sql,labeled),bound,statement->{
                    statement.setQueryTimeout(30);
                    try(var result=statement.executeQuery()) {
                        var output=new ArrayList<Object[]>();
                        while(result.next())output.add(new Object[]{result.getObject(1),result.getObject(2),result.getObject(3)});
                        return output;
                    }
                });
                return accept(Objects.requireNonNull(rows));
            }catch(RuntimeException error){failed=true;throw error;}
        }

        public List<Map<String,Object>> jdbcRows(org.springframework.jdbc.core.JdbcTemplate jdbc,
                String candidateField,String sql,Object[] arguments,boolean labeled) {
            if(closed||failed)throw new IllegalStateException("Candidate query scope is closed or failed");
            if(!field.equals(candidateField))return List.of();
            if(items!=null)throw new IllegalStateException("A candidate field must have one authoritative grouped query");
            try {
                if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();
                Object[] bound=Arrays.copyOf(arguments,arguments.length+3);bound[arguments.length]=keyword;bound[arguments.length+1]=size+1;bound[arguments.length+2]=offset;
                List<Object[]> rows=jdbc.execute((org.springframework.jdbc.core.PreparedStatementCreator)connection->connection.prepareStatement(boundedSql(sql,labeled,true)),statement->{
                    var setter=new org.springframework.jdbc.core.ArgumentPreparedStatementSetter(bound);
                    try {
                        setter.setValues(statement);statement.setQueryTimeout(30);
                        try(var result=statement.executeQuery()) {
                            var output=new ArrayList<Object[]>();
                            while(result.next()) {
                                output.add(new Object[]{result.getObject(1),result.getObject(2),result.getObject(3)});
                            }
                            return output;
                        }
                    } finally {setter.cleanupParameters();}
                });
                return accept(Objects.requireNonNull(rows));
            }catch(RuntimeException error){failed=true;throw error;}
        }

        /** An original list Specification can provide an explicit grouped String attribute without copying its business predicate into SQL. */
        public <T> List<Map<String,Object>> criteriaRows(EntityManager em,String candidateField,Class<T> entity,
                org.springframework.data.jpa.domain.Specification<T> predicate,String valueAttribute) {
            if(closed||failed)throw new IllegalStateException("Candidate query scope is closed or failed");
            if(!field.equals(candidateField))return List.of();
            if(items!=null)throw new IllegalStateException("A candidate field must have one authoritative grouped query");
            try {
                if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();
                var cb=em.getCriteriaBuilder();var query=cb.createQuery(Object[].class);var root=query.from(entity);
                jakarta.persistence.criteria.Expression<String> value=root.get(valueAttribute);
                var conditions=new ArrayList<jakarta.persistence.criteria.Predicate>();
                var original=predicate.toPredicate(root,query,cb);if(original!=null)conditions.add(original);
                for(String term:KeywordSearch.terms(keyword))conditions.add(cb.greaterThan(cb.locate(cb.lower(cb.coalesce(value,"")),term),0));
                query.select(cb.array(value,value,cb.count(root))).where(cb.and(conditions.toArray(jakarta.persistence.criteria.Predicate[]::new))).groupBy(value).orderBy(cb.asc(value));
                var bounded=em.createQuery(query);bounded.setHint("jakarta.persistence.query.timeout",30_000);
                // JPA's existing offset API uses an int. Overflow fails explicitly rather than publishing a wrapped/wrong prefix.
                bounded.setFirstResult(Math.toIntExact(offset));bounded.setMaxResults(size+1);
                return accept(bounded.getResultList());
            }catch(RuntimeException error){failed=true;throw error;}
        }

        /** Empty authority inputs may return an empty map without creating any query. */
        public void completeRecords(Map<String,Long> counts) {
            if(closed||failed||items!=null)throw new IllegalStateException("Candidate scope already completed");
            var selected=counts.entrySet().stream()
                    .filter(entry->entry.getKey()!=null&&!entry.getKey().isBlank()&&KeywordSearch.matches(keyword,entry.getKey()))
                    .sorted(Map.Entry.comparingByKey()).skip(offset).limit((long)size+1)
                    .map(entry->NativeFacets.bucket(entry.getKey(),entry.getValue())).toList();
            hasMore=selected.size()>size;items=List.copyOf(selected.subList(0,Math.min(size,selected.size())));
        }

        /** Empty authority inputs may return an empty map without creating any query. */
        public Page result(Object originalBody,String readScopeVersion) {
            if(closed||failed)throw new IllegalStateException("Candidate query scope is closed or failed");
            if(items==null) {
                if(!(originalBody instanceof Map<?,?> map) || (!map.isEmpty() && (!(map.get(field) instanceof List<?> values) || !values.isEmpty())))
                    throw new IllegalStateException("Candidate field did not use its tagged query authority");
                items=List.of();hasMore=false;
            }
            if(requiresSnapshot&&snapshotRevision==null)throw new IllegalStateException("Candidate handler did not enter its owning snapshot");
            if(snapshotScope!=null&&!snapshotScope.equals(readScopeVersion))throw new ApiException(ErrorCode.READ_SCOPE_CHANGED);
            return new Page(field,items,page,size,hasMore,readScopeVersion,snapshotRevision,dataVersion);
        }
        @Override public void close() {
            if(Thread.currentThread()!=owner)throw new IllegalStateException("Candidate query scope belongs to another thread");
            if(closed)return;closed=true;originals.clear();
            if(previous==null)CURRENT.remove();else CURRENT.set(previous);
        }
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
