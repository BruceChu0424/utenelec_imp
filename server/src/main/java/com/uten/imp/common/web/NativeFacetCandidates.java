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
    public record Page(String field,List<Map<String,Object>> items,int page,int size,boolean hasMore,String readScopeVersion) {
        public Page {items=List.copyOf(items);}
    }
    private record Original(EntityManager em,String field,String sql){}
    public static boolean active(){return CURRENT.get()!=null;}
    public static Scope current(){return CURRENT.get();}
    public static Scope open(String field,String keyword,long page,int size){return new Scope(field,keyword,page,size);}
    public static Query query(EntityManager em,String field,String sql) {
        Query query=em.createNativeQuery(sql);
        Scope scope=CURRENT.get();if(scope!=null)scope.originals.put(query,new Original(em,field,sql));
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
        private boolean hasMore,closed,failed;
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
                String source=original.sql().strip();if(source.endsWith(";"))source=source.substring(0,source.length()-1);
                Query paged=original.em().createNativeQuery("SELECT candidate.value,candidate.bucket_count FROM (SELECT COALESCE(raw_candidate.value::text,'') AS value,SUM(raw_candidate.bucket_count) AS bucket_count FROM ("+source
                        +") raw_candidate(value,bucket_count) GROUP BY 1) candidate WHERE "
                        +TaskKeywordSearch.conditionParameter(SEARCH,"CAST(candidate.value AS text)")
                        +" ORDER BY CAST(candidate.value AS text) ASC NULLS FIRST LIMIT :"+LIMIT+" OFFSET :"+OFFSET);
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
                if(rows.size()>size+1)throw new IllegalStateException("Candidate query ignored its page bound");
                hasMore=rows.size()>size;
                var selected=new ArrayList<Map<String,Object>>(Math.min(size,rows.size()));
                for(Object[] row:rows.subList(0,Math.min(size,rows.size()))) {
                    if(row.length!=2||!(row[1] instanceof Number count))throw new IllegalStateException("Candidate query must retain value and original grouped count");
                    selected.add(NativeFacets.bucket(row[0]==null?"":row[0].toString(),count.longValue()));
                }
                items=List.copyOf(selected);return items;
            }catch(RuntimeException error){failed=true;throw error;}
        }
        /** Empty authority inputs may return an empty map without creating any query. */
        public Page result(Object originalBody,String readScopeVersion) {
            if(closed||failed)throw new IllegalStateException("Candidate query scope is closed or failed");
            if(items==null) {
                if(!(originalBody instanceof Map<?,?> map) || (!map.isEmpty() && (!(map.get(field) instanceof List<?> values) || !values.isEmpty())))
                    throw new IllegalStateException("Candidate field did not use its tagged query authority");
                items=List.of();hasMore=false;
            }
            return new Page(field,items,page,size,hasMore,readScopeVersion);
        }
        @Override public void close() {
            if(Thread.currentThread()!=owner)throw new IllegalStateException("Candidate query scope belongs to another thread");
            if(closed)return;closed=true;originals.clear();
            if(previous==null)CURRENT.remove();else CURRENT.set(previous);
        }
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
