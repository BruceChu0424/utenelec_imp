package com.uten.imp.features.quality.pending;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.QualityPendingSourcePort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.SqlColumnSearch;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.TaskKeywordSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.annotation.Isolation;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;

/** One complete authorized document queue; source domains still own every fact and payload. */
@Service @RequiredArgsConstructor
public class QualityPendingQueueService {
    private final EntityManager em;
    private final List<QualityPendingSourcePort> sources;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper json;
    public record Request(Integer page,Integer size,String keyword,String docType,String status,
            Map<String,String> columns,String sort,String order,Map<String,String> draftStatuses) { }
    public record Facet(String value,String label,long count) { }
    public record Row(String source,String identity,String kind,String status,Map<String,Object> values,Object payload) { }
    public record Page(List<Row> items,int page,int size,long total,int totalPages,
            Map<String,List<Facet>> facets,Map<String,Long> sourceCounts) { }
    private static final Map<String,SqlColumnSearch.Field> FIELDS=Map.ofEntries(
            Map.entry("billNo",SqlColumnSearch.Field.text("bill_no")),Map.entry("party",SqlColumnSearch.Field.text("party")),
            Map.entry("goods",SqlColumnSearch.Field.text("goods")),Map.entry("goodsCode",SqlColumnSearch.Field.text("goods_code")),
            Map.entry("colorName",SqlColumnSearch.Field.text("color_name")),Map.entry("warehouse",SqlColumnSearch.Field.text("warehouse")),
            Map.entry("place",SqlColumnSearch.Field.text("place")),Map.entry("pendingQty",SqlColumnSearch.Field.text("pending_qty")),
            Map.entry("enteredAt",SqlColumnSearch.Field.instant("entered_at")));
    // 2026-11-09 行粒度（一料一行）：IQC 行 = 检验明细、检查单行 = 实物批；item_count 检索字段随「待检行数」
    // 列退役，新增 pre_stocked（本行先入库标红）与 status_code（行级状态色）两个非检索行值。
    private static final Map<String,String> VALUE_KEYS=Map.ofEntries(Map.entry("billNo","bill_no"),Map.entry("party","party"),
            Map.entry("goods","goods"),Map.entry("goodsCode","goods_code"),Map.entry("colorName","color_name"),
            Map.entry("warehouse","warehouse"),Map.entry("place","place"),
            Map.entry("pendingQty","pending_qty"),Map.entry("enteredAt","entered_at"),
            Map.entry("preStocked","pre_stocked"),Map.entry("statusCode","status_code"));

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Page query(Request request) {
        var actor=currentUser.get().filter(user->!user.isVisitor()).orElseThrow(()->new ApiException(ErrorCode.FORBIDDEN));
        if(request==null)throw invalid("查询条件不能为空");
        Map<String,QualityPendingSourcePort> owners=new LinkedHashMap<>();
        List<QualityPendingSourcePort.Plan> plans=new ArrayList<>();
        for(var source:sources){
            if(!actor.isSuperAdmin()&&!actor.getPermissions().contains(source.readAuthority()))continue;
            for(var plan:source.pendingPlans()){
                if(!Set.of("IQC","FQC_SHEET","FQC").contains(plan.key())||owners.putIfAbsent(plan.key(),source)!=null)
                    throw new IllegalStateException("Duplicate or invalid quality source");
                plans.add(plan);
            }
        }
        if(plans.isEmpty())throw new ApiException(ErrorCode.FORBIDDEN);
        int size=Math.max(1,Math.min(Pageables.MAX_PAGE_SIZE,request.size()==null?10:request.size()));
        int wanted=Math.max(1,request.page()==null?1:request.page());
        String keyword=KeywordSearch.phrase(request.keyword());
        if(keyword.length()>500)throw invalid("搜索内容过长");
        String kind=blank(request.docType()),status=blank(request.status());
        if(kind!=null&&!Set.of("PURCHASE","SUBCONTRACT","FQC").contains(kind))throw invalid("待检来源无效");
        if(status!=null&&status.length()>100)throw invalid("待检状态无效");
        var headers=SqlColumnSearch.criteria(request.columns()==null?Map.of():request.columns(),FIELDS);
        Map<String,String> drafts=request.draftStatuses()==null?Map.of():request.draftStatuses();
        if(drafts.size()>10_000)throw invalid("本地草稿上下文过大");
        drafts.forEach((identity,label)->{
            if(identity==null||identity.length()>256||!(identity.startsWith("iqc:")||identity.startsWith("sheet:")||identity.startsWith("fqc:"))
                    ||label==null||!Set.of("草稿","提交待核对").contains(label))throw invalid("本地草稿上下文无效");
        });
        Map<String,Object> bindings=new LinkedHashMap<>();
        List<String> union=new ArrayList<>();
        for(var plan:plans){
            union.add("SELECT '"+plan.key()+"'::text AS source_key,source_row.* FROM ("+plan.sql()+") source_row");
            plan.bindings().forEach((key,value)->{if(bindings.containsKey(key)&&!bindings.get(key).equals(value))throw new IllegalStateException("Source parameter collision");bindings.put(key,value);});
        }
        String prefix="""
            WITH candidates AS MATERIALIZED (%s), labeled AS MATERIALIZED (
              SELECT candidates.*,
                (CASE kind WHEN 'SUBCONTRACT' THEN '委外' WHEN 'FQC' THEN '成品' ELSE '采购' END)
                || COALESCE(draft.label,CASE status_code WHEN 'PARTIAL' THEN '部分已决定' ELSE '待检' END) AS status
              FROM candidates LEFT JOIN jsonb_each_text(CAST(:queue_drafts AS jsonb)) draft(identity,label)
              ON draft.identity=candidates.draft_identity
            ), eligible AS MATERIALIZED (SELECT * FROM labeled WHERE %s AND (%s))
            """.formatted(String.join(" UNION ALL ",union),TaskKeywordSearch.conditionParameter("queue_keyword",
                    "bill_no","party","goods","goods_code","color_name","warehouse","place"),headers.predicate());
        bindings.put("queue_keyword",keyword);bindings.put("queue_drafts",write(drafts));
        String kindWhere=kind==null?"TRUE":"kind=:queue_kind",statusWhere=status==null?"TRUE":"status=:queue_status";
        if (kind != null) {
            bindings.put("queue_kind", kind);
        }
        if (status != null) {
            bindings.put("queue_status", status);
        }
        String ordering="CASE source_key WHEN 'IQC' THEN 0 WHEN 'FQC_SHEET' THEN 1 ELSE 2 END,sequence_at ASC NULLS LAST,identity";
        if(request.sort()!=null&&!request.sort().isBlank()){
            var field=FIELDS.get(request.sort());
            if(field==null||"pendingQty".equals(request.sort())||request.order()!=null&&!Set.of("asc","desc").contains(request.order().toLowerCase(java.util.Locale.ROOT)))
                throw invalid("待检排序字段或方向无效");
            ordering=field.expression()+("desc".equalsIgnoreCase(request.order())?" DESC":" ASC")+" NULLS LAST,identity";
        }else if(!keyword.isEmpty())ordering=TaskKeywordSearch.rankNamesFirstParameter("queue_keyword",new String[]{"goods"},new String[]{"goods_names"},new String[]{"bill_no","party","goods_code","color_name"})+", "+ordering;
        // One statement shares the materialized three-source UNION between the page
        // window, the exact total and the facets; metadata rides the first page row
        // or the synthetic row of an empty page, following FulfillmentWorkbenchPageRead.
        String pageSql=prefix+"""
            , page_source AS (SELECT * FROM eligible WHERE %s AND %s)
            , page_rows AS (
              SELECT row_to_json(page_row)::text AS row_json,ROW_NUMBER() OVER (ORDER BY %s) AS page_position
              FROM (SELECT * FROM page_source) page_row ORDER BY %s LIMIT :queue_limit OFFSET :queue_offset
            ), page_summary AS (SELECT COUNT(*) AS total FROM page_source)
            , page_metadata AS (
              SELECT (SELECT COALESCE(jsonb_agg(jsonb_build_object('value',status,'label',status,'count',qty) ORDER BY status),'[]'::jsonb)::text
                FROM (SELECT status,COUNT(*) AS qty FROM eligible WHERE %s GROUP BY status) facet_values) AS status_facets,
              (SELECT COALESCE(jsonb_agg(jsonb_build_object('value',kind,'label',CASE kind WHEN 'PURCHASE' THEN '采购收货' WHEN 'SUBCONTRACT' THEN '委外回厂' ELSE '自制产成品' END,'count',qty) ORDER BY kind),'[]'::jsonb)::text
                FROM (SELECT kind,COUNT(*) AS qty FROM eligible WHERE %s GROUP BY kind) facet_values) AS kind_facets,
              (SELECT COALESCE(jsonb_object_agg(kind,qty),'{}'::jsonb)::text FROM (SELECT kind,COUNT(*) AS qty FROM labeled GROUP BY kind) facet_values) AS kind_counts
            )
            SELECT page_rows.row_json,page_summary.total,
              CASE WHEN page_rows.page_position IS NULL OR page_rows.page_position=:queue_offset+1 THEN page_metadata.status_facets END AS meta_status,
              CASE WHEN page_rows.page_position IS NULL OR page_rows.page_position=:queue_offset+1 THEN page_metadata.kind_facets END AS meta_kind,
              CASE WHEN page_rows.page_position IS NULL OR page_rows.page_position=:queue_offset+1 THEN page_metadata.kind_counts END AS meta_counts
            FROM page_summary CROSS JOIN page_metadata LEFT JOIN page_rows ON TRUE
            ORDER BY page_rows.page_position NULLS LAST
            """.formatted(kindWhere,statusWhere,ordering,ordering,kindWhere,statusWhere);
        java.util.function.IntFunction<List<Object[]>> readPage=pageNumber->{
            Query statement=em.createNativeQuery(pageSql);bind(statement,bindings,headers);
            statement.setParameter("queue_limit",size).setParameter("queue_offset",(long)(pageNumber-1)*size);
            return NativeQueryResults.objectArrayRows(statement);
        };
        List<Object[]> pageRows=readPage.apply(wanted);
        Object[] head=pageRows.getFirst();
        long total=((Number)head[1]).longValue();int totalPages=total==0?0:(int)Math.min(Integer.MAX_VALUE,(total+size-1)/size);
        int page=totalPages==0?1:Math.min(wanted,totalPages);
        String statusFacets=null,kindFacets=null,kindCounts=null;
        List<JsonNode> selected=new ArrayList<>();
        for(Object[] row:pageRows){
            if(row[2]!=null)statusFacets=String.valueOf(row[2]);
            if(row[3]!=null)kindFacets=String.valueOf(row[3]);
            if(row[4]!=null)kindCounts=String.valueOf(row[4]);
            if(row[0]!=null)selected.add(tree(row[0]));
        }
        if(statusFacets==null||kindFacets==null||kindCounts==null)
            throw new IllegalStateException("Quality queue metadata was not loaded");
        if(selected.isEmpty()&&total>0&&wanted>1){
            // A page requested past the end still returns the last real page (original clamping).
            for(Object[] row:readPage.apply(page))if(row[0]!=null)selected.add(tree(row[0]));
        }
        Map<String,List<Facet>> facets=Map.of("status",facets(statusFacets),"docType",facets(kindFacets));
        Map<String,Long> counts=new LinkedHashMap<>();tree(kindCounts).properties().forEach(entry->counts.put(entry.getKey(),entry.getValue().asLong()));
        Map<String,Set<String>> ids=new LinkedHashMap<>();for(var row:selected)ids.computeIfAbsent(row.path("source_key").asText(),key->new LinkedHashSet<>()).add(row.path("identity").asText());
        Map<String,Object> payloads=new LinkedHashMap<>();ids.forEach((key,identities)->payloads.putAll(owners.get(key).pendingPayloads(key,identities)));
        List<Row> items=new ArrayList<>();for(var row:selected){
            String identity=row.path("identity").asText();Object payload=payloads.get(identity);
            if(payload==null)throw new ApiException(ErrorCode.CONFLICT,"待检任务状态已变化，请刷新后重试");
            Map<String,Object> values=new LinkedHashMap<>();VALUE_KEYS.forEach((key,column)->{
                JsonNode value=row.path(column);values.put(key,value.isNull()?null:value.isNumber()?value.numberValue():value.asText());
            });
            items.add(new Row(row.path("source_key").asText(),identity,row.path("kind").asText(),row.path("status").asText(),values,payload));
        }
        return new Page(List.copyOf(items),page,size,total,totalPages,facets,Map.copyOf(counts));
    }
    private static void bind(Query query,Map<String,Object> values,SqlColumnSearch.Criteria headers){values.forEach(query::setParameter);headers.bind(query);}
    private String write(Object value){try{return json.writeValueAsString(value);}catch(Exception failure){throw new IllegalStateException(failure);}}
    private JsonNode tree(Object value){try{return json.readTree(value.toString());}catch(Exception failure){throw new IllegalStateException("Invalid quality query metadata",failure);}}
    private List<Facet> facets(Object value) {
        List<Facet> result = new ArrayList<>();
        for (JsonNode item : tree(value)) {
            result.add(new Facet(item.path("value").asText(), item.path("label").asText(), item.path("count").asLong()));
        }
        return List.copyOf(result);
    }
    private static String blank(String value){return value==null||value.isBlank()?null:value.strip();}
    private static ApiException invalid(String value){return new ApiException(ErrorCode.VALIDATION_FAILED,value);}
}
