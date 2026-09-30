package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.columns.BusinessColumnService;
import com.uten.imp.common.columns.ExtraColumnCalculator;
import com.uten.imp.common.text.IntakeTextNormalizer;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.*;
import static com.uten.imp.common.platformcolumns.PlatformColumnContracts.*;

/** Business annotations with explicit domain authorization, CAS persistence and display-only math. */
@Service
public class PlatformColumnService {
    private static final int MAX_COLUMNS=32, MAX_ROWS=200, MAX_DEPENDENCIES=8192, MAX_DEPTH=16;
    private static final Set<String> TYPES=Set.of("TEXT","NUMBER","CALCULATED");
    private static final Set<String> OPERATIONS=Set.of("ADD","SUBTRACT","MULTIPLY","DIVIDE");
    private final Map<String,PlatformColumnResourceAdapter> adapters;
    private final NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper mapper;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    public PlatformColumnService(List<PlatformColumnResourceAdapter> resources, NamedParameterJdbcTemplate jdbc,
            ObjectMapper mapper, SecurityContextCurrentUser currentUser, TxSessionVars tx) {
        Map<String,PlatformColumnResourceAdapter> registrations=new LinkedHashMap<>();
        for(var resource:resources) {
            if(resource.scope()==null || !resource.scope().matches("[a-z][a-z0-9_]{0,99}")
                    || registrations.putIfAbsent(resource.scope(),resource)!=null)
                throw new IllegalStateException("Invalid or duplicate platform resource registration");
            Set<String> facts=new HashSet<>();
            for(var fact:resource.facts()) if(fact.key()==null || !fact.key().matches("[a-zA-Z][a-zA-Z0-9_]{0,79}") || !facts.add(fact.key()))
                throw new IllegalStateException("Invalid platform resource fact registration");
        }
        this.adapters=Map.copyOf(registrations);this.jdbc=jdbc;this.mapper=mapper;this.currentUser=currentUser;this.tx=tx;
    }

    @Transactional(readOnly=true)
    public List<Scope> scopes() {
        currentUser.requireId();
        List<Scope> scopes=new ArrayList<>();
        for(var adapter:adapters.values()) {
            try { adapter.requireDefinitionAccess(false); }
            catch(ApiException denied) { if(denied.getCode()==ErrorCode.FORBIDDEN) continue; throw denied; }
            boolean price=adapter.canViewPrice();
            boolean canDefine=true;
            try{adapter.requireDefinitionAccess(true);}catch(ApiException denied){if(denied.getCode()==ErrorCode.FORBIDDEN)canDefine=false;else throw denied;}
            scopes.add(new Scope(adapter.scope(),adapter.label(),adapter.canWrite(),price,adapter.supportsValues(),
                    adapter.facts().stream().filter(f->price||!f.priceProtected()).toList(),canDefine,adapter.personalDefinitions(),adapter.canCreate()));
        }
        return scopes.stream().sorted(Comparator.comparing(Scope::scope)).toList();
    }

    @Transactional(readOnly=true)
    public List<Definition> search(String scope,String query) {
        var adapter=resource(scope);adapter.requireDefinitionAccess(false);
        String needle=BusinessColumnService.normalize(query==null?"":query);
        if(needle.length()>80)throw invalid("列名搜索不能超过80字符");
        Map<String,Object> parameters=params(scope);parameters.put("q",needle);
        List<Definition> candidates=jdbc.query("""
                SELECT d.*,COALESCE(u.usage_count,0) AS personal_usage_count
                FROM platform_column_definitions d LEFT JOIN platform_column_usage u
                  ON u.definition_id=d.id AND u.user_id=:actor
                WHERE d.scope=:scope AND d.owner_user_id=:owner AND (:q='' OR position(:q IN d.normalized_name)>0
                  OR EXISTS(SELECT 1 FROM generate_series(1,length(CAST(:q AS text))-1) n
                    WHERE position(substring(CAST(:q AS text) from n for 2) IN d.normalized_name)>0))
                ORDER BY CASE WHEN d.normalized_name=:q THEN 0 WHEN position(:q IN d.normalized_name)>0 THEN 1 ELSE 2 END,
                  personal_usage_count DESC,d.usage_count DESC,d.id LIMIT 500
                """,parameters,this::definition);
        Map<UUID,Definition> catalog=loadDefinitions(scope,candidates.stream().map(Definition::id).collect(java.util.stream.Collectors.toSet()));
        Comparator<Definition> order=Comparator.comparingInt((Definition d)->tier(d.name(),needle))
                .thenComparing(Comparator.comparingDouble((Definition d)->similarity(d.name(),needle)).reversed())
                .thenComparing(Comparator.comparingLong(Definition::personalUsageCount).reversed())
                .thenComparing(Comparator.comparingLong(Definition::usageCount).reversed()).thenComparing(Definition::id);
        return candidates.stream().filter(d->adapter.canViewPrice()||!protectedDefinition(d,catalog,adapter,new HashSet<>()))
                .filter(d->needle.isEmpty()||tier(d.name(),needle)<2||similarity(d.name(),needle)>=0.4)
                .sorted(order).limit(50).map(d->visibleDefinition(d,adapter.canViewPrice())).toList();
    }

    @Transactional
    public Definition create(String scope,CreateDefinition input) {
        var adapter=resource(scope);adapter.requireDefinitionAccess(true);
        if(input==null)throw invalid("请填写扩展列定义");
        String name=input.name()==null?"":input.name().strip();
        String normalized=BusinessColumnService.normalize(name);
        if(normalized.isBlank()||name.length()>80||name.chars().anyMatch(Character::isISOControl))throw invalid("列名需为1至80个可见字符");
        if(input.type()==null||!TYPES.contains(input.type()))throw invalid("无效的扩展列类型");
        if((adapter.personalDefinitions()||!adapter.supportsValues())&&!"CALCULATED".equals(input.type()))throw invalid("个人显示配置只支持计算展示列");
        if("CALCULATED".equals(input.type())!=(input.formula()!=null))throw invalid("计算展示列必须填写公式，普通信息列不能带公式");
        Formula formula=normalizeFormula(input.formula());
        Set<UUID> refs=references(formula);
        Map<UUID,Definition> dependencies=loadDefinitions(scope,refs);
        boolean protectedPrice=input.priceProtected()||isPriceProtected(formula,dependencies,adapter);
        if(protectedPrice&&!adapter.canViewPrice())throw forbidden("没有价格权限，不能定义费用或敏感计算列");
        requireDependencyDepth(formula,dependencies,new HashSet<>(),0);
        tx.bind();
        Map<String,Object> parameters=params(scope);
        parameters.put("id",UUID.randomUUID());parameters.put("name",name);parameters.put("normalized",normalized);
        parameters.put("type",input.type());parameters.put("protected",protectedPrice);parameters.put("formula",formula==null?null:json(formula));
        parameters.put("fingerprint",hash(normalized+"|"+input.type()+"|"+protectedPrice+"|"+json(formula)));
        jdbc.update("""
                INSERT INTO platform_column_definitions(id,scope,name,normalized_name,value_type,price_protected,formula,definition_fingerprint,created_by,owner_user_id)
                VALUES(:id,:scope,:name,:normalized,:type,:protected,CAST(:formula AS jsonb),:fingerprint,:actor,:owner)
                ON CONFLICT(scope,owner_user_id,definition_fingerprint) DO NOTHING
                """,parameters);
        return jdbc.queryForObject("""
                SELECT d.*,COALESCE(u.usage_count,0) AS personal_usage_count
                FROM platform_column_definitions d LEFT JOIN platform_column_usage u ON u.definition_id=d.id AND u.user_id=:actor
                WHERE d.scope=:scope AND d.owner_user_id=:owner AND d.definition_fingerprint=:fingerprint
                """,parameters,this::definition);
    }

    /** Stable layout restoration includes the entire authorized immutable dependency closure. */
    @Transactional(readOnly=true)
    public List<Definition> definitions(String scope,List<UUID> requested) {
        var adapter=resource(scope);adapter.requireDefinitionAccess(false);
        var definitions=loadDefinitions(scope,ids(requested,MAX_COLUMNS,"列"));
        if(!adapter.canViewPrice()&&definitions.values().stream().anyMatch(d->protectedDefinition(d,definitions,adapter,new HashSet<>())))
            throw forbidden("没有所选计算列及其依赖的价格查看权限");
        return definitions.values().stream().sorted(Comparator.comparing(Definition::id)).toList();
    }

    /** Export-friendly alias; includes authorized dependencies without fuzzy-search limits. */
    @Transactional(readOnly=true)
    public List<Definition> definitionsByIds(String scope,List<UUID> requested) { return definitions(scope,requested); }

    /** Internal review capture. The domain supplies locked, authoritative native facts; no HTTP route exposes this method. */
    @Transactional(readOnly=true)
    public Map<UUID,Row> freezeForReview(String scope,UUID documentId,Map<UUID,Map<String,BigDecimal>> nativeFacts) {
        var adapter=resource(scope);adapter.requireDefinitionAccess(false);requireValues(adapter);
        if(adapter.personalDefinitions())throw invalid("个人显示配置不能进入共享业务审核快照");
        if(nativeFacts==null||nativeFacts.size()>2000)throw invalid("审核快照的明细数量无效");
        Set<UUID> ids=nativeFacts.keySet();if(ids.isEmpty())return Map.of();
        authorize(adapter,ids,false);var parents=adapter.parentDocuments(ids);
        if(!parents.keySet().equals(ids)||parents.values().stream().anyMatch(id->!documentId.equals(id)))throw forbidden("审核快照明细不属于本单据");
        var parameters=params(scope);parameters.put("ids",ids);Map<UUID,Stored> stored=new HashMap<>();
        jdbc.query("SELECT record_id,version,cells::text FROM platform_record_fields WHERE scope=:scope AND record_id IN(:ids)",parameters,
                rs->{stored.put(rs.getObject("record_id",UUID.class),new Stored(rs.getLong("version"),parseCells(rs.getString("cells"))));});
        Set<UUID> columns=new LinkedHashSet<>();stored.values().forEach(r->r.cells().forEach(c->columns.add(c.columnId())));
        var definitions=loadDefinitions(scope,columns);Map<UUID,Row> frozen=new LinkedHashMap<>();
        Set<String> allowedFacts=adapter.facts().stream().map(PlatformColumnResourceAdapter.FactDefinition::key).collect(java.util.stream.Collectors.toSet());
        for(UUID id:ids) {
            Map<String,BigDecimal> facts=nativeFacts.get(id);
            if(facts==null||!allowedFacts.containsAll(facts.keySet()))throw invalid("审核快照包含未注册的业务事实");
            Row captured=row(id,stored.getOrDefault(id,new Stored(0,List.of())),Set.of(),definitions,
                    new PlatformColumnResourceAdapter.RecordAccess(false,true,facts),adapter);
            frozen.put(id,new Row(id,captured.version(),false,captured.cells().stream().map(cell->{
                Definition d=cell.definition();
                return new Cell(cell.columnId(),cell.value(),new Definition(d.id(),d.scope(),d.name(),d.type(),d.priceProtected(),d.formula(),0,0),
                        false,cell.persisted(),cell.error());
            }).toList()));
        }
        return Collections.unmodifiableMap(frozen);
    }

    /** Caller already authorized the parent document. Redaction never re-reads live rows or rewrites stored history. */
    public String maskReviewSnapshot(String scope,String snapshot) {
        if(snapshot==null)return null;var adapter=resource(scope);adapter.requireDefinitionAccess(false);
        if(adapter.canViewPrice())return snapshot;
        try {
            var root=mapper.readTree(snapshot);
            List<com.fasterxml.jackson.databind.JsonNode> contexts=new ArrayList<>();contexts.add(root);root.path("items").forEach(contexts::add);
            for(var item:contexts)for(var cell:item.path("platformFields").path("cells")) {
                if(cell.path("definition").path("priceProtected").asBoolean(true)&&cell instanceof com.fasterxml.jackson.databind.node.ObjectNode value) {
                    value.putNull("value");value.putNull("error");value.put("masked",true);
                    if(value.path("definition") instanceof com.fasterxml.jackson.databind.node.ObjectNode definition) {
                        definition.put("name","受保护字段");definition.putNull("formula");
                    }
                }
            }
            return mapper.writeValueAsString(root);
        }catch(JsonProcessingException invalid){throw new IllegalStateException("Invalid stored review snapshot",invalid);}
    }

    @Transactional(readOnly=true)
    public List<Row> read(String scope,BatchRead request) {
        var adapter=resource(scope);adapter.requireDefinitionAccess(false);requireValues(adapter);
        if(request==null)throw invalid("请提供记录编号");
        Set<UUID> ids=ids(request.recordIds(),MAX_ROWS,"记录");
        Set<UUID> selected=request.columnIds()==null?Set.of():ids(request.columnIds(),MAX_COLUMNS,"列");
        if(ids.isEmpty())return List.of();
        Map<UUID,PlatformColumnResourceAdapter.RecordAccess> access=authorize(adapter,ids,false);
        Map<String,Object> parameters=params(scope);parameters.put("ids",ids);
        Map<UUID,Stored> records=new HashMap<>();
        jdbc.query("SELECT record_id,version,cells::text FROM platform_record_fields WHERE scope=:scope AND record_id IN(:ids)",parameters,
                rs->{records.put(rs.getObject("record_id",UUID.class),new Stored(rs.getLong("version"),parseCells(rs.getString("cells"))));});
        Set<UUID> needed=new LinkedHashSet<>(selected);
        records.values().forEach(r->r.cells().forEach(c->needed.add(c.columnId())));
        Map<UUID,Definition> definitions=loadDefinitions(scope,needed);
        return ids.stream().map(id->row(id,records.getOrDefault(id,new Stored(0,List.of())),selected,definitions,access.get(id),adapter)).toList();
    }

    @Transactional
    public Row write(String scope,UUID recordId,Write request) {
        if(recordId==null||request==null)throw invalid("请提供记录编号及当前字段版本");
        PreparedFields prepared=prepareFields(scope,recordId,request.expectedVersion(),request.cells(),false,false);
        return applyFields(recordId,prepared);
    }

    /** Package-private proof used only by the annotated atomic business-save bridge. */
    record PreparedFields(String scope,UUID actor,UUID sourceId,long sourceVersion,List<CellInput> cells,boolean documentCreate,boolean unchanged,UUID documentId,Integer lineIndex) { }

    PreparedFields bindFields(PreparedFields fields,UUID documentId,int index) {
        return new PreparedFields(fields.scope(),fields.actor(),fields.sourceId(),fields.sourceVersion(),fields.cells(),fields.documentCreate(),fields.unchanged(),documentId,index);
    }

    List<UUID> replayTargets(PreparedFields fields,Set<UUID> resultIds) {
        if(!fields.documentCreate()||resultIds.isEmpty()||fields.documentId()==null)return List.of();
        var parameters=params(fields.scope());parameters.put("ids",resultIds);parameters.put("document",fields.documentId());
        parameters.put("index",fields.lineIndex());parameters.put("version",fields.sourceVersion());
        return jdbc.queryForList("""
                SELECT record_id FROM platform_record_fields WHERE scope=:scope AND record_id IN(:ids)
                  AND source_document_id=:document AND source_line_index=:index AND source_fields_version=:version
                ORDER BY record_id
                """,parameters,UUID.class);
    }

    Set<UUID> documentRecords(String scope,UUID documentId,Object request) {
        var adapter=resource(scope);adapter.requireDocumentSaveAccess(false);requireValues(adapter);
        adapter.lockDocumentSave(documentId,request);
        Set<UUID> ids=adapter.recordIdsForDocument(documentId);
        if(ids==null)throw conflict("该单据不能安全解析扩展字段来源");
        if(!ids.isEmpty())authorize(adapter,ids,false);
        return ids;
    }

    boolean hasStoredFields(String scope,Set<UUID> ids) {
        if(ids.isEmpty())return false;
        var parameters=params(scope);parameters.put("ids",ids);
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM platform_record_fields WHERE scope=:scope AND record_id IN(:ids) AND jsonb_array_length(cells)>0)",parameters,Boolean.class));
    }

    void requireDocumentFieldWrite(String scope,UUID documentId) {
        resource(scope).requireDocumentFieldWrite(documentId);
    }

    PreparedFields prepareFields(String scope,UUID sourceId,long expectedVersion,List<CellInput> cells,boolean preserve,boolean documentCreate) {
        return prepareFields(scope,sourceId,expectedVersion,cells,preserve,documentCreate,false);
    }

    /** Only the atomic document bridge may carry unchanged values through a lawful domain edit. */
    PreparedFields prepareDocumentFields(String scope,UUID sourceId,long expectedVersion,List<CellInput> cells,boolean preserve,boolean documentCreate) {
        return prepareFields(scope,sourceId,expectedVersion,cells,preserve,documentCreate,!documentCreate);
    }

    private PreparedFields prepareFields(String scope,UUID sourceId,long expectedVersion,List<CellInput> cells,boolean preserve,boolean documentCreate,boolean allowUnchanged) {
        var adapter=resource(scope);requireValues(adapter);
        adapter.requireDocumentSaveAccess(documentCreate);
        if(adapter.personalDefinitions())throw forbidden("个人计算展示不允许写入业务记录");
        if(documentCreate&&sourceId!=null)throw invalid("新建单据不能借用既有记录的扩展字段");
        if(expectedVersion<0||(!preserve&&cells==null)||(cells!=null&&cells.size()>MAX_COLUMNS))throw invalid("请提供当前版本及最多32个扩展字段");
        var access=sourceId==null?new PlatformColumnResourceAdapter.RecordAccess(true,adapter.canViewPrice()):authorize(adapter,Set.of(sourceId),!allowUnchanged).get(sourceId);
        tx.bind();
        Map<String,Object> parameters=params(scope);parameters.put("record",sourceId);
        List<Stored> rows=sourceId==null?List.of():jdbc.query("SELECT version,cells::text FROM platform_record_fields WHERE scope=:scope AND record_id=:record FOR UPDATE",
                    parameters,(rs,n)->new Stored(rs.getLong("version"),parseCells(rs.getString("cells"))));
        Stored stored=rows.isEmpty()?new Stored(0,List.of()):rows.getFirst();
        if(preserve)return new PreparedFields(scope,currentUser.requireId(),sourceId,stored.version(),stored.cells(),documentCreate,allowUnchanged,null,null);
        if(stored.version()!=expectedVersion)throw conflict("扩展字段已被其他人修改，请刷新后重新保存");
        Set<UUID> requested=new LinkedHashSet<>();
        for(var cell:cells)if(cell==null||cell.columnId()==null||!requested.add(cell.columnId()))throw invalid("列编号不能为空或重复");
        Set<UUID> needed=new LinkedHashSet<>(requested);stored.cells().forEach(c->needed.add(c.columnId()));
        Map<UUID,Definition> definitions=loadDefinitions(scope,needed);
        Map<UUID,CellInput> previous=new HashMap<>();stored.cells().forEach(c->previous.put(c.columnId(),c));
        List<CellInput> normalized=new ArrayList<>();
        for(var cell:cells) {
            Definition definition=definitions.get(cell.columnId());
            String value=cell.value()==null||cell.value().isBlank()?null:cell.value().strip();
            if(protectedDefinition(definition,definitions,adapter,new HashSet<>())&&!access.priceVisible()) {
                if(!previous.containsKey(cell.columnId())||value!=null)throw forbidden("没有价格权限，不能添加或修改敏感字段");
                normalized.add(previous.get(cell.columnId()));continue;
            }
            if(value!=null&&value.length()>2000)throw invalid(definition.name()+"不能超过2000字符");
            if("CALCULATED".equals(definition.type())&&value!=null)throw invalid("计算展示列的值只能由公式生成");
            if("NUMBER".equals(definition.type())&&value!=null)value=ExtraColumnCalculator.decimal(value,definition.name()).toPlainString();
            normalized.add(new CellInput(cell.columnId(),value));
        }
        if(!access.priceVisible())for(var prior:stored.cells())if(protectedDefinition(definitions.get(prior.columnId()),definitions,adapter,new HashSet<>())&&!requested.contains(prior.columnId()))
            throw forbidden("没有价格权限，不能删除敏感字段");
        boolean unchanged=allowUnchanged&&stored.cells().equals(normalized);
        if(allowUnchanged&&!unchanged) {
            // Check before the domain can revoke approval or reopen a document.
            adapter.requireDocumentSaveAccess(false);
            if(sourceId!=null)authorize(adapter,Set.of(sourceId),true);
        }
        return new PreparedFields(scope,currentUser.requireId(),sourceId,stored.version(),List.copyOf(normalized),documentCreate,unchanged,null,null);
    }

    Row applyFields(UUID recordId,PreparedFields prepared) {
        if(!currentUser.requireId().equals(prepared.actor()))throw forbidden("扩展字段保存身份已变化");
        String scope=prepared.scope();var adapter=resource(scope);
        if(adapter.personalDefinitions())throw forbidden("个人计算展示不允许写入业务记录");
        if(prepared.documentId()!=null&&!prepared.documentId().equals(adapter.parentDocuments(Set.of(recordId)).get(recordId)))
            throw conflict("扩展字段保存结果不属于本次真实单据");
        if(prepared.unchanged()&&prepared.documentId()!=null&&recordId.equals(prepared.sourceId())) {
            var access=authorize(adapter,Set.of(recordId),false).get(recordId);
            var parameters=params(scope);parameters.put("record",recordId);
            var records=jdbc.query("SELECT version,cells::text FROM platform_record_fields WHERE scope=:scope AND record_id=:record FOR UPDATE",parameters,
                    (rs,n)->new Stored(rs.getLong("version"),parseCells(rs.getString("cells"))));
            Stored stored=records.isEmpty()?new Stored(0,List.of()):records.getFirst();
            if(stored.version()!=prepared.sourceVersion()||!stored.cells().equals(prepared.cells()))throw conflict("扩展字段已被其他人修改，请刷新后重新保存");
            // No UPDATE, usage event, or version bump for an unchanged stable business row.
            return row(recordId,stored,Set.of(),loadDefinitions(scope,stored.cells().stream().map(CellInput::columnId).collect(java.util.stream.Collectors.toSet())),access,adapter);
        }
        adapter.requireDocumentSaveAccess(prepared.documentCreate());
        if(!prepared.documentCreate()&&prepared.documentId()!=null&&!recordId.equals(prepared.sourceId())&&!PlatformColumnSaveLineage.wasPersisted(recordId))
            throw conflict("扩展字段只能映射到原始明细或本次新建的真实明细");
        if(prepared.documentCreate()&&!PlatformColumnSaveLineage.wasPersisted(recordId))return verifyCreateReplay(recordId,prepared,adapter);
        var grants=prepared.documentCreate()?adapter.authorizeCreated(Set.of(recordId)):authorize(adapter,Set.of(recordId),true);
        if(grants==null||!grants.keySet().equals(Set.of(recordId))||grants.get(recordId)==null)throw forbidden("新建记录的扩展字段授权不完整");
        var access=grants.get(recordId);
        long expectedVersion=recordId.equals(prepared.sourceId())?prepared.sourceVersion():0;
        Map<String,Object> parameters=params(scope);parameters.put("record",recordId);parameters.put("retain",adapter.preserveValuesOnReset());
        parameters.put("cells",json(prepared.cells()));parameters.put("version",expectedVersion);
        parameters.put("sourceDocument",prepared.documentId());parameters.put("sourceIndex",prepared.lineIndex());
        parameters.put("sourceVersion",prepared.documentId()==null?null:prepared.sourceVersion());
        tx.bind();
        int changed=expectedVersion==0?jdbc.update("""
                INSERT INTO platform_record_fields(scope,record_id,version,cells,created_by,updated_by,retain_on_reset,source_document_id,source_line_index,source_fields_version)
                VALUES(:scope,:record,1,CAST(:cells AS jsonb),:actor,:actor,:retain,:sourceDocument,:sourceIndex,:sourceVersion) ON CONFLICT(scope,record_id) DO NOTHING
                """,parameters):jdbc.update("""
                UPDATE platform_record_fields SET version=version+1,cells=CAST(:cells AS jsonb),updated_by=:actor,updated_at=now(),retain_on_reset=:retain,
                    source_document_id=COALESCE(source_document_id,:sourceDocument),source_line_index=COALESCE(source_line_index,:sourceIndex),
                    source_fields_version=COALESCE(source_fields_version,:sourceVersion)
                WHERE scope=:scope AND record_id=:record AND version=:version
                """,parameters);
        if(changed!=1)throw conflict("扩展字段已被其他人修改，请刷新后重新保存");
        Set<UUID> requested=prepared.cells().stream().map(CellInput::columnId).collect(java.util.stream.Collectors.toSet());
        trackUsage(scope,requested);
        return row(recordId,new Stored(expectedVersion+1,prepared.cells()),Set.of(),loadDefinitions(scope,requested),access,adapter);
    }

    private Row verifyCreateReplay(UUID recordId,PreparedFields prepared,PlatformColumnResourceAdapter adapter) {
        var access=authorize(adapter,Set.of(recordId),false).get(recordId);
        var parameters=params(prepared.scope());parameters.put("record",recordId);
        parameters.put("document",prepared.documentId());parameters.put("index",prepared.lineIndex());parameters.put("sourceVersion",prepared.sourceVersion());
        if(prepared.documentId()!=null&&!Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM platform_record_fields WHERE scope=:scope AND record_id=:record
                  AND source_document_id=:document AND source_line_index=:index AND source_fields_version=:sourceVersion)
                """,parameters,Boolean.class)))throw conflict("创建重放缺少同一单据、明细及字段版本的持久来源证明");
        var records=jdbc.query("SELECT version,cells::text FROM platform_record_fields WHERE scope=:scope AND record_id=:record FOR UPDATE",parameters,
                (rs,n)->new Stored(rs.getLong("version"),parseCells(rs.getString("cells"))));
        Stored stored=records.isEmpty()?new Stored(0,List.of()):records.getFirst();
        Map<UUID,String> old=new HashMap<>(),requested=new HashMap<>();
        stored.cells().forEach(c->old.put(c.columnId(),c.value()));prepared.cells().forEach(c->requested.put(c.columnId(),c.value()));
        if(!old.equals(requested))throw conflict("创建请求返回了既有记录，不能借创建权限修改其扩展字段，请刷新后使用编辑流程");
        return row(recordId,stored,Set.of(),loadDefinitions(prepared.scope(),old.keySet()),access,adapter);
    }

    /** Explicit selection feedback never accepts raw values or changes business records. */
    @Transactional
    public void used(String scope,UUID definitionId) {
        var adapter=resource(scope);adapter.requireDefinitionAccess(false);
        if(definitionId==null)throw invalid("请选择扩展列");
        var definitions=loadDefinitions(scope,Set.of(definitionId));
        if(!adapter.canViewPrice()&&protectedDefinition(definitions.get(definitionId),definitions,adapter,new HashSet<>()))throw forbidden("没有该敏感列的查看权限");
        tx.bind();trackUsage(scope,Set.of(definitionId));
    }

    /** Internal export projection: callers supply already-authorized business facts, never formulas. */
    @Transactional(readOnly=true)
    public Map<UUID,String> evaluateDisplay(String scope,List<UUID> definitionIds,Map<String,BigDecimal> authorizedFacts) {
        return evaluateDisplayRows(scope,definitionIds,List.of(authorizedFacts==null?Map.of():authorizedFacts)).getFirst();
    }

    @Transactional(readOnly=true)
    public List<Map<UUID,String>> evaluateDisplayRows(String scope,List<UUID> definitionIds,List<Map<String,BigDecimal>> rows) {
        var adapter=resource(scope);adapter.requireDefinitionAccess(false);
        if(rows==null||rows.size()>2000||rows.stream().anyMatch(Objects::isNull))throw invalid("显示投影最多2000行且行不能为空");
        Set<UUID> selected=ids(definitionIds,MAX_COLUMNS,"计算列");
        Map<UUID,Definition> definitions=loadDefinitions(scope,selected);
        Map<String,PlatformColumnResourceAdapter.FactDefinition> allowed=new HashMap<>();adapter.facts().forEach(f->allowed.put(f.key(),f));
        for(UUID id:selected) {
            Definition definition=definitions.get(id);
            if(!"CALCULATED".equals(definition.type()))throw invalid("显示投影只能使用计算列");
            if(protectedDefinition(definition,definitions,adapter,new HashSet<>())&&!adapter.canViewPrice())throw forbidden("没有该计算列的价格查看权限");
        }
        return rows.stream().map(facts->evaluateDisplayRow(adapter,selected,definitions,allowed,facts)).toList();
    }
    private Map<UUID,String> evaluateDisplayRow(PlatformColumnResourceAdapter adapter,Set<UUID> selected,Map<UUID,Definition> definitions,
            Map<String,PlatformColumnResourceAdapter.FactDefinition> allowed,Map<String,BigDecimal> authorizedFacts) {
        Map<String,BigDecimal> facts=new HashMap<>();
        if(authorizedFacts!=null)for(var entry:authorizedFacts.entrySet()) {
            var fact=allowed.get(entry.getKey());if(fact==null)throw invalid("该显示模块不允许引用此业务字段");
            if(entry.getValue()!=null&&(!fact.priceProtected()||adapter.canViewPrice()))facts.put(entry.getKey(),entry.getValue());
        }
        Map<UUID,String> results=new LinkedHashMap<>();
        for(UUID id:selected) {
            results.put(id,decimalText(evaluate(id,definitions,Map.of(),facts,new HashSet<>(),0)));
        }
        return Collections.unmodifiableMap(results);
    }

    private Row row(UUID id,Stored stored,Set<UUID> selected,Map<UUID,Definition> definitions,PlatformColumnResourceAdapter.RecordAccess access,PlatformColumnResourceAdapter adapter) {
        Map<UUID,String> values=new LinkedHashMap<>();stored.cells().forEach(c->values.put(c.columnId(),c.value()));
        Set<UUID> columns=new LinkedHashSet<>(values.keySet());columns.addAll(selected);
        List<Cell> cells=new ArrayList<>();
        for(UUID column:columns) {
            Definition definition=definitions.get(column);
            boolean protectedPrice=protectedDefinition(definition,definitions,adapter,new HashSet<>());
            if(protectedPrice&&!definition.priceProtected())definition=new Definition(definition.id(),definition.scope(),definition.name(),definition.type(),true,definition.formula(),definition.usageCount(),definition.personalUsageCount());
            boolean masked=protectedPrice&&!access.priceVisible();
            String value=null,error=null;
            if(!masked) {
                try { value="CALCULATED".equals(definition.type())?decimalText(evaluate(column,definitions,values,access.facts(),new HashSet<>(),0)):values.get(column); }
                catch(ApiException badCalculation){error=badCalculation.getMessage();}
            }
            cells.add(new Cell(column,value,visibleDefinition(definition,access.priceVisible()),masked,values.containsKey(column),error));
        }
        return new Row(id,stored.version(),access.canWrite(),List.copyOf(cells));
    }

    static BigDecimal evaluate(UUID id,Map<UUID,Definition> definitions,Map<UUID,String> values,Map<String,BigDecimal> facts,Set<UUID> visiting,int depth) {
        return evaluateCached(id,definitions,values,facts,visiting,depth,new HashMap<>());
    }
    private static BigDecimal evaluateCached(UUID id,Map<UUID,Definition> definitions,Map<UUID,String> values,Map<String,BigDecimal> facts,Set<UUID> visiting,int depth,Map<UUID,BigDecimal> cache) {
        if(cache.containsKey(id))return cache.get(id);
        if(depth>MAX_DEPTH||!visiting.add(id))throw invalid("计算列依赖过深或存在循环");
        try {
            Definition definition=definitions.get(id);
            if(definition==null)throw conflict("扩展列定义不完整");
            if(!"CALCULATED".equals(definition.type()))return values.get(id)==null?null:ExtraColumnCalculator.decimal(values.get(id),definition.name());
            Formula formula=definition.formula();
            BigDecimal value=operandValue(formula.base(),definitions,values,facts,visiting,depth,cache);
            for(Step step:formula.steps()) {
                BigDecimal right=operandValue(step.operand(),definitions,values,facts,visiting,depth,cache);
                if(value==null||right==null){cache.put(id,null);return null;}
                try {
                    value=switch(step.operation()) {
                        case "ADD"->value.add(right);case "SUBTRACT"->value.subtract(right);case "MULTIPLY"->value.multiply(right);
                        case "DIVIDE"->{if(right.signum()==0)throw invalid("计算列除数不能为0");yield value.divide(right);}
                        default->throw invalid("不支持的计算操作");
                    };
                }catch(ArithmeticException nonFinite){throw invalid("计算结果不是精确有限小数");}
                value=FinancialExactAmount.book(value,"计算展示值");
            }
            BigDecimal result=value==null?null:FinancialExactAmount.book(value,"计算展示值");cache.put(id,result);return result;
        }finally{visiting.remove(id);}
    }

    private static BigDecimal operandValue(Operand operand,Map<UUID,Definition> definitions,Map<UUID,String> values,
            Map<String,BigDecimal> facts,Set<UUID> visiting,int depth,Map<UUID,BigDecimal> cache) {
        if(operand.columnId()!=null)return evaluateCached(operand.columnId(),definitions,values,facts,visiting,depth+1,cache);
        if(operand.fact()!=null)return facts.get(operand.fact());
        return ExtraColumnCalculator.decimal(operand.constant(),"计算常量");
    }

    private boolean isPriceProtected(Formula formula,Map<UUID,Definition> definitions,PlatformColumnResourceAdapter adapter) {
        if(formula==null)return false;
        Map<String,PlatformColumnResourceAdapter.FactDefinition> facts=new HashMap<>();adapter.facts().forEach(f->facts.put(f.key(),f));
        boolean protectedPrice=false;
        for(Operand operand:operands(formula)) {
            if(operand.columnId()!=null) {
                Definition definition=definitions.get(operand.columnId());
                if(definition==null||"TEXT".equals(definition.type()))throw invalid("计算只能引用同模块的数字列或计算列");
                protectedPrice|=protectedDefinition(definition,definitions,adapter,new HashSet<>());
            }
            if(operand.fact()!=null) {
                var fact=facts.get(operand.fact());if(fact==null)throw invalid("该模块不允许引用此业务字段");
                protectedPrice|=fact.priceProtected();
            }
        }
        return protectedPrice;
    }
    private boolean protectedDefinition(Definition definition,Map<UUID,Definition> definitions,PlatformColumnResourceAdapter adapter,Set<UUID> visiting) {
        if(definition==null)throw invalid("计算列定义缺失");
        if(!visiting.add(definition.id()))return false;
            if(definition.priceProtected())return true;
            for(Operand operand:operands(definition.formula())) {
                if(operand.columnId()!=null&&protectedDefinition(definitions.get(operand.columnId()),definitions,adapter,visiting))return true;
                if(operand.fact()!=null) {
                    var fact=adapter.facts().stream().filter(f->f.key().equals(operand.fact())).findFirst()
                            .orElseThrow(()->invalid("该模块不允许引用此业务字段"));
                    if(fact.priceProtected())return true;
                }
            }
            return false;
    }

    private static Formula normalizeFormula(Formula formula) {
        if(formula==null)return null;
        if(formula.steps()==null||formula.steps().size()>16)throw invalid("计算展示最多16个步骤");
        List<Step> steps=new ArrayList<>();
        for(Step step:formula.steps()) {
            if(step==null||step.operation()==null||!OPERATIONS.contains(step.operation()))throw invalid("请选择加、减、乘、除操作");
            Operand operand=normalizeOperand(step.operand());
            if("DIVIDE".equals(step.operation())&&operand.constant()!=null&&new BigDecimal(operand.constant()).signum()==0)throw invalid("除数不能为0");
            steps.add(new Step(step.operation(),operand));
        }
        return new Formula(normalizeOperand(formula.base()),List.copyOf(steps));
    }
    private static void requireDependencyDepth(Formula formula,Map<UUID,Definition> definitions,Set<UUID> path,int depth) {
        if(formulaDepth(formula,definitions,path,new HashMap<>())>MAX_DEPTH)throw invalid("计算列依赖过深");
    }
    private static int formulaDepth(Formula formula,Map<UUID,Definition> definitions,Set<UUID> path,Map<UUID,Integer> cache) {
        int maximum=0;
        for(UUID id:references(formula)) {
            if(!path.add(id))throw invalid("计算列不能形成循环引用");
            Integer computed=cache.get(id);
            if(computed==null){computed=formulaDepth(definitions.get(id).formula(),definitions,path,cache);cache.put(id,computed);}
            maximum=Math.max(maximum,1+computed);
            path.remove(id);
        }
        return maximum;
    }
    private static Operand normalizeOperand(Operand operand) {
        if(operand==null)throw invalid("请选择计算基数");
        int kinds=(operand.columnId()==null?0:1)+(operand.fact()==null?0:1)+(operand.constant()==null?0:1);
        if(kinds!=1)throw invalid("计算基数只能选择一个数字列、业务字段或常量");
        if(operand.fact()!=null&&!operand.fact().matches("[a-zA-Z][a-zA-Z0-9_]{0,79}"))throw invalid("无效的业务字段名");
        return operand.constant()==null?operand:new Operand(null,null,ExtraColumnCalculator.decimal(operand.constant(),"计算常量").toPlainString());
    }
    private Map<UUID,Definition> loadDefinitions(String scope,Set<UUID> ids) {
        Map<UUID,Definition> definitions=new LinkedHashMap<>();Set<UUID> pending=new LinkedHashSet<>(ids);
        for(int depth=0;!pending.isEmpty();depth++) {
            if(depth>MAX_DEPTH||definitions.size()+pending.size()>MAX_DEPENDENCIES)throw invalid("计算列依赖过多或过深");
            Map<String,Object> parameters=params(scope);parameters.put("ids",pending);
            List<Definition> loaded=jdbc.query("""
                    SELECT d.*,COALESCE(u.usage_count,0) AS personal_usage_count FROM platform_column_definitions d
                    LEFT JOIN platform_column_usage u ON u.definition_id=d.id AND u.user_id=:actor
                    WHERE d.scope=:scope AND d.owner_user_id=:owner AND d.id IN(:ids)
                    """,parameters,this::definition);
            if(loaded.size()!=pending.size())throw invalid("扩展列不存在或不属于当前模块");
            pending=new LinkedHashSet<>();
            for(Definition definition:loaded){definitions.put(definition.id(),definition);pending.addAll(references(definition.formula()));}
            pending.removeAll(definitions.keySet());
        }
        return definitions;
    }
    private void trackUsage(String scope,Set<UUID> ids) {
        if(ids.isEmpty())return;
        Map<String,Object> parameters=params(scope);parameters.put("ids",ids);
        jdbc.update("UPDATE platform_column_definitions SET usage_count=usage_count+1,last_used_at=now() WHERE scope=:scope AND owner_user_id=:owner AND id IN(:ids)",parameters);
        jdbc.update("""
                INSERT INTO platform_column_usage(user_id,definition_id,usage_count,last_used_at)
                SELECT :actor,d.id,1,now() FROM platform_column_definitions d WHERE d.scope=:scope AND d.owner_user_id=:owner AND d.id IN(:ids)
                ON CONFLICT(user_id,definition_id) DO UPDATE SET usage_count=platform_column_usage.usage_count+1,last_used_at=now()
                """,parameters);
    }
    private Map<UUID,PlatformColumnResourceAdapter.RecordAccess> authorize(PlatformColumnResourceAdapter adapter,Set<UUID> ids,boolean write) {
        var access=adapter.authorize(ids,write);
        if(access==null||!access.keySet().equals(ids))throw forbidden("记录不存在或不在当前可访问范围");
        if(write&&access.values().stream().anyMatch(a->a==null||!a.canWrite()))throw forbidden("当前记录不可编辑扩展字段");
        if(access.values().stream().anyMatch(Objects::isNull))throw forbidden("记录访问状态不完整");
        return access;
    }
    private PlatformColumnResourceAdapter resource(String scope) {
        currentUser.requireId();var adapter=scope==null?null:adapters.get(scope);
        if(adapter==null)throw invalid("当前模块未注册可授权的扩展字段资源");return adapter;
    }
    private static void requireValues(PlatformColumnResourceAdapter adapter) { if(!adapter.supportsValues())throw invalid("汇总报表没有可保存的实体记录，请使用计算展示列"); }
    private Definition definition(ResultSet rs,int row) throws SQLException {
        String formula=rs.getString("formula");
        return new Definition(rs.getObject("id",UUID.class),rs.getString("scope"),rs.getString("name"),rs.getString("value_type"),
                rs.getBoolean("price_protected"),formula==null?null:readJson(formula,Formula.class),rs.getLong("usage_count"),rs.getLong("personal_usage_count"));
    }
    private static Definition visibleDefinition(Definition definition,boolean priceVisible) {
        return definition.priceProtected()&&!priceVisible?new Definition(definition.id(),definition.scope(),"受保护字段",definition.type(),true,null,
                definition.usageCount(),definition.personalUsageCount()):definition;
    }
    private static Set<UUID> ids(List<UUID> ids,int max,String label) {
        if(ids==null||ids.size()>max||ids.stream().anyMatch(Objects::isNull))throw invalid(label+"编号数量必须介于0至"+max);
        return new LinkedHashSet<>(ids);
    }
    private static List<Operand> operands(Formula formula) {
        if(formula==null)return List.of();List<Operand> out=new ArrayList<>();out.add(formula.base());formula.steps().forEach(s->out.add(s.operand()));return out;
    }
    private static Set<UUID> references(Formula formula) {Set<UUID> ids=new LinkedHashSet<>();operands(formula).forEach(o->{if(o.columnId()!=null)ids.add(o.columnId());});return ids;}
    private Map<String,Object> params(String scope) {Map<String,Object> parameters=new HashMap<>();parameters.put("scope",scope);UUID actor=currentUser.requireId();parameters.put("actor",actor);parameters.put("owner",adapters.get(scope).personalDefinitions()?actor:new UUID(0,0));return parameters;}
    private List<CellInput> parseCells(String json) {try{return mapper.readValue(json,new TypeReference<List<CellInput>>(){});}catch(JsonProcessingException invalid){throw new IllegalStateException("Invalid stored platform fields",invalid);}}
    private <T>T readJson(String json,Class<T> type) {try{return mapper.readValue(json,type);}catch(JsonProcessingException invalid){throw new IllegalStateException("Invalid stored platform definition",invalid);}}
    private String json(Object value) {try{return mapper.writeValueAsString(value);}catch(JsonProcessingException invalid){throw new IllegalStateException(invalid);}}
    private record Stored(long version,List<CellInput> cells) { }
    private static String decimalText(BigDecimal value) {return value==null?null:value.stripTrailingZeros().toPlainString();}
    private static int tier(String name,String needle) {String key=BusinessColumnService.normalize(name);return key.equals(needle)?0:key.contains(needle)?1:2;}
    private static double similarity(String name,String needle) {return IntakeTextNormalizer.bigramDice(BusinessColumnService.normalize(name),needle);}
    private static String hash(String source) {try{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(source.getBytes(StandardCharsets.UTF_8)));}catch(NoSuchAlgorithmException impossible){throw new IllegalStateException(impossible);}}
    private static ApiException invalid(String message) {return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException forbidden(String message) {return new ApiException(ErrorCode.FORBIDDEN,message);}
    private static ApiException conflict(String message) {return new ApiException(ErrorCode.CONFLICT,message);}
}
