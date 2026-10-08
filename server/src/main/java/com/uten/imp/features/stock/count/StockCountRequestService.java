package com.uten.imp.features.stock.count;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.WorkshopStockCountPostingPort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.*;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.weight.WeightMath;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.namedparam.*;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import jakarta.validation.Validator;
import java.math.*;
import java.sql.Timestamp;
import java.util.*;

/** Count proposals are immutable snapshots. Only an authorized approval posts stock, atomically. */
@Service
@PreAuthorize("hasAnyAuthority('stock:count:submit','stock:count:finance_review','stock:count:warehouse_review')")
public class StockCountRequestService {
    public static final String SUBMIT="stock:count:submit", FINANCE="stock:count:finance_review", WAREHOUSE="stock:count:warehouse_review";
    /** Read-only picker identity for absent/deleted categories; never written back to goods. */
    static final UUID UNCATEGORIZED_CATEGORY=UUID.fromString("00000000-0000-0000-0000-00000000c076");
    private final NamedParameterJdbcTemplate db;
    private final SecurityContextCurrentUser user;
    private final WorkshopStockCountPostingPort workshop;
    private final StockDocService stockDocs;
    private final DocNumberService numbers;
    private final BusinessEventPublisher events;
    private final TxSessionVars tx;
    private final ObjectMapper json;
    private final Validator validator;

    public StockCountRequestService(NamedParameterJdbcTemplate db,SecurityContextCurrentUser user,
            WorkshopStockCountPostingPort workshop,StockDocService stockDocs,DocNumberService numbers,
            BusinessEventPublisher events,TxSessionVars tx,ObjectMapper json,Validator validator) {
        this.db=db;this.user=user;this.workshop=workshop;this.stockDocs=stockDocs;
        this.numbers=numbers;this.events=events;this.tx=tx;this.json=json;this.validator=validator;
    }
    private boolean has(String code) { return user.get().map(u->u.isSuperAdmin()||u.getPermissions().contains(code)).orElse(false); }
    private void require(String code) { if(!has(code)) throw new ApiException(ErrorCode.FORBIDDEN,"没有此项盘点操作权限"); }
    private static ApiException conflict(String text) { return new ApiException(ErrorCode.CONFLICT,text); }
    private static ApiException invalid(String text) { return new ApiException(ErrorCode.VALIDATION_FAILED,text); }
    private static BigDecimal decimal(Object value) { return value==null?null:new BigDecimal(value.toString()); }
    private static String exact(Object value) { BigDecimal d=decimal(value); return d==null?null:d.toPlainString(); }
    private static boolean same(Object a,Object b) { return a==null?b==null:b!=null&&decimal(a).compareTo(decimal(b))==0; }
    private static String time(Object value) { return value instanceof Timestamp t?t.toInstant().toString():value==null?null:value.toString(); }
    private String encode(Object value) { try {return json.writeValueAsString(value);} catch(JsonProcessingException e){throw new IllegalStateException(e);} }
    private String hash(Object value) { return CanonicalFingerprint.sha256(List.of(encode(value))); }
    private void commandLock(String key) {
        if(key==null||!key.matches("[A-Za-z0-9._:-]{8,128}"))throw invalid("提交编号格式不正确");
        db.queryForObject("SELECT count(*) FROM (SELECT pg_advisory_xact_lock(hashtextextended(:key,766))) l",
                Map.of("key",user.requireId()+":"+key),Long.class);
    }

    private List<Map<String,Object>> warehouses() {
        return warehouses(true);
    }
    private List<Map<String,Object>> warehouses(boolean activeOnly) {
        var rows = db.queryForList("""
                SELECT w.id,w.name,w.is_line_side,
                       CASE WHEN w.is_line_side THEN 'WORKSHOP' ELSE 'NORMAL' END AS kind,
                       CASE WHEN w.is_line_side THEN 'WAREHOUSE' ELSE 'FINANCE' END AS review_route
                FROM warehouses w
                """+(activeOnly?"""
                WHERE NOT w.is_deleted AND w.is_accountable AND w.status='使用'
                  AND (fn_warehouse_is_active_accounting_leaf(w.id) OR
                       (w.is_line_side AND EXISTS(SELECT 1 FROM workshop_material_settings s
                         WHERE s.periodic_bin_warehouse_id=w.id AND s.periodic_enabled)))
                """:"")+" ORDER BY w.code,w.id",Map.of());
        var lineSide = rows.stream().filter(w -> Boolean.TRUE.equals(w.get("is_line_side")))
                .map(w -> (UUID)w.get("id")).toList();
        var accessible = workshop.accessibleWarehouses(lineSide);
        return rows.stream().filter(w -> !Boolean.TRUE.equals(w.get("is_line_side"))
                || accessible.contains((UUID)w.get("id"))).toList();
    }
    private Map<String,Object> warehouse(UUID id) {
        return warehouses().stream().filter(w->id!=null&&id.equals(w.get("id"))).findFirst()
                .orElseThrow(()->new ApiException(ErrorCode.FORBIDDEN,"请选择可盘点的具体仓库；不能修改全部仓库或父仓合计"));
    }
    @Transactional(readOnly=true)
    public Map<String,Object> scope(UUID id) {
        var visible=warehouses().stream().map(w->Map.<String,Object>of("id",w.get("id"),"name",w.get("name"),
                "kind",w.get("kind"),"reviewRoute",w.get("review_route"))).toList();
        Map<String,Object> result=new LinkedHashMap<>(); result.put("warehouses",visible);
        result.put("allowedActions",has(SUBMIT)?List.of("SUBMIT"):List.of());
        if(id!=null)result.put("selectedWarehouseId",warehouse(id).get("id"));
        return result;
    }

    private static final String SNAPSHOT_SELECT="""
            SELECT g.id AS goods_id,g.code AS goods_code,g.name AS goods_name,c.id AS color_id,c.name AS color_name,
                   g.unit_id,u.name AS unit_name,g.version AS goods_version,g.issue_method,
                   COALESCE(category.id,'00000000-0000-0000-0000-00000000c076'::uuid) AS category_id,
                   COALESCE(b.qty,0) AS qty, b.weight AS weight_kg,COALESCE(b.weight_estimated,false) AS weight_estimated,
                   CASE WHEN p.measurement_dimension='MASS' THEN fn_weight_unit_kg_factor(p.mass_unit_code) END AS kg_factor
            FROM candidate k JOIN goods g ON g.id=k.goods_id JOIN units u ON u.id=g.unit_id
            LEFT JOIN colors c ON c.id=k.color_id
            LEFT JOIN material_categories category ON category.id=g.category_id AND NOT category.is_deleted
            LEFT JOIN unit_measurement_profiles p ON p.unit_id=g.unit_id
            LEFT JOIN stock_balances b ON b.warehouse_id=:warehouse AND b.goods_id=g.id AND b.color_id IS NOT DISTINCT FROM k.color_id
            WHERE NOT g.is_deleted AND NOT COALESCE(g.auto_created,false)
              AND g.status='使用' AND NOT u.is_deleted AND u.status='使用'
              AND (k.color_id IS NULL OR (c.id IS NOT NULL AND NOT c.is_deleted AND c.status='使用'))
            """;
    @Transactional(readOnly=true)
    public PageResponse<Map<String,Object>> candidates(UUID warehouseId,String keyword,List<UUID> ids,int page,int size) {
        return candidates(warehouseId,keyword,ids,null,page,size);
    }
    @Transactional(readOnly=true)
    public PageResponse<Map<String,Object>> candidates(UUID warehouseId,String keyword,List<UUID> ids,UUID categoryId,int page,int size) {
        require(SUBMIT);var w=warehouse(warehouseId);
        if(ids!=null&&ids.size()>500)throw invalid("一次最多查询500种物料");
        var paging=Pageables.of(page,size);
        var params=new MapSqlParameterSource("warehouse",warehouseId).addValue("keyword",keyword==null?"":keyword.strip())
                .addValue("limit",paging.getPageSize()).addValue("offset",paging.getOffset());
        String eligible=candidateSnapshots(w,ids,categoryId,params);
        long total=Objects.requireNonNull(db.queryForObject(eligible+"SELECT count(*) FROM snapshot",params,Long.class));
        var rows=db.queryForList(eligible+"SELECT * FROM snapshot ORDER BY goods_code,goods_id,color_name NULLS FIRST,color_id NULLS FIRST LIMIT :limit OFFSET :offset",params)
                .stream().map(this::snapshotView).toList();
        return new PageResponse<>(rows,paging.getPageNumber()+1,paging.getPageSize(),total,(int)((total+paging.getPageSize()-1)/paging.getPageSize()));
    }

    /** One eligibility/colour/search projection for candidate pages, the tree, and search relocation. */
    private static String candidateSnapshots(Map<String,Object> warehouse,List<UUID> ids,UUID categoryId,MapSqlParameterSource params) {
        String idFilter=ids==null||ids.isEmpty()?"":" AND g.id IN (:ids)";
        if(!idFilter.isEmpty())params.addValue("ids",ids);
        String categoryCte="";
        String categoryFilter="";
        if(UNCATEGORIZED_CATEGORY.equals(categoryId)) {
            categoryFilter=" AND NOT EXISTS(SELECT 1 FROM material_categories category WHERE category.id=g.category_id AND NOT category.is_deleted)";
        } else if(categoryId!=null) {
            params.addValue("category",categoryId);
            categoryCte="""
                    category_scope AS (
                        SELECT id FROM material_categories WHERE id=:category AND NOT is_deleted
                        UNION
                        SELECT child.id FROM material_categories child JOIN category_scope parent ON child.parent_id=parent.id
                        WHERE NOT child.is_deleted
                    ),
                    """;
            categoryFilter=" AND g.category_id IN (SELECT id FROM category_scope)";
        }
        return "WITH RECURSIVE "+categoryCte+"""
                eligible AS (SELECT g.id,g.color_id FROM goods g WHERE NOT g.is_deleted
                """+idFilter+categoryFilter+("WORKSHOP".equals(warehouse.get("kind"))?" AND EXISTS(SELECT 1 FROM unit_measurement_profiles p WHERE p.unit_id=g.unit_id AND p.measurement_dimension='MASS')":"")+"""
                ), candidate AS (SELECT id AS goods_id,color_id FROM eligible UNION
                    SELECT b.goods_id,b.color_id FROM stock_balances b JOIN eligible g ON g.id=b.goods_id WHERE b.warehouse_id=:warehouse),
                snapshot AS (
                """+SNAPSHOT_SELECT+" AND strpos(lower(concat_ws(' ',g.code,g.name,c.name)),lower(:keyword))>0) ";
    }

    @Transactional(readOnly=true)
    public List<Map<String,Object>> candidateCategories(UUID warehouseId) {
        require(SUBMIT);var w=warehouse(warehouseId);
        var params=new MapSqlParameterSource("warehouse",warehouseId).addValue("keyword","")
                .addValue("uncategorized",UNCATEGORIZED_CATEGORY);
        String cte=candidateSnapshots(w,null,null,params);
        var categories=db.queryForList(cte+"""
                , visible_categories AS (
                    SELECT category.id,category.parent_id FROM material_categories category
                    WHERE NOT category.is_deleted AND category.id IN (SELECT category_id FROM snapshot)
                    UNION
                    SELECT parent.id,parent.parent_id FROM material_categories parent
                    JOIN visible_categories child ON child.parent_id=parent.id WHERE NOT parent.is_deleted
                )
                SELECT * FROM (
                    SELECT category.id,category.code,category.name,category.parent_id,category.level,category.sort_order
                    FROM material_categories category JOIN visible_categories visible ON visible.id=category.id
                    UNION ALL
                    SELECT CAST(:uncategorized AS uuid),'UNCATEGORIZED','未分类',NULL::uuid,0,2147483647
                    WHERE EXISTS(SELECT 1 FROM snapshot WHERE category_id=:uncategorized)
                ) visible_tree
                ORDER BY sort_order NULLS LAST,code,id
                """,params);
        Map<UUID,Map<String,Object>> nodes=new LinkedHashMap<>();
        Map<UUID,List<Map<String,Object>>> children=new LinkedHashMap<>();
        for(var category:categories) {
            UUID id=(UUID)category.get("id");
            Map<String,Object> node=new LinkedHashMap<>();
            node.put("id",id);node.put("code",category.get("code"));node.put("name",category.get("name"));
            node.put("parentId",category.get("parent_id"));node.put("level",category.get("level"));
            node.put("sortOrder",category.get("sort_order"));
            var childNodes=new ArrayList<Map<String,Object>>();children.put(id,childNodes);node.put("children",childNodes);
            nodes.put(id,node);
        }
        List<Map<String,Object>> roots=new ArrayList<>();
        for(var node:nodes.values()) {
            UUID id=(UUID)node.get("id"),parent=(UUID)node.get("parentId");
            if(parent!=null&&nodes.containsKey(parent)&&!categoryCycle(id,parent,nodes)) children.get(parent).add(node);
            else roots.add(node);
        }
        return roots;
    }

    /** Defensive only: corrupt legacy ancestry must not create recursive JSON objects. */
    private static boolean categoryCycle(UUID id,UUID parent,Map<UUID,Map<String,Object>> nodes) {
        Set<UUID> seen=new HashSet<>();seen.add(id);
        UUID current=parent;
        while(current!=null&&nodes.containsKey(current)) {
            if(!seen.add(current))return true;
            current=(UUID)nodes.get(current).get("parentId");
        }
        return false;
    }

    @Transactional(readOnly=true)
    public List<UUID> candidateCategoryIds(UUID warehouseId,String keyword) {
        require(SUBMIT);var w=warehouse(warehouseId);
        if(keyword==null||keyword.isBlank())return List.of();
        var params=new MapSqlParameterSource("warehouse",warehouseId).addValue("keyword",keyword.strip());
        return db.queryForList(candidateSnapshots(w,null,null,params)+"""
                SELECT DISTINCT category_id FROM snapshot ORDER BY category_id
                """,params,UUID.class);
    }
    private Map<String,Object> snapshot(UUID warehouse,UUID goods,UUID color) {
        var rows=db.queryForList("WITH candidate AS (SELECT CAST(:goods AS uuid) AS goods_id,CAST(:color AS uuid) AS color_id) "+SNAPSHOT_SELECT,
                new MapSqlParameterSource("goods",goods).addValue("color",color).addValue("warehouse",warehouse));
        if(rows.size()!=1)throw conflict("物料、颜色或计量单位已停用或变化，请重新选择");
        return rows.getFirst();
    }
    private Map<String,Object> snapshotView(Map<String,Object> row) {
        Map<String,Object> out=new LinkedHashMap<>();
        String[][] ids={{"goodsId","goods_id"},{"goodsCode","goods_code"},{"goodsName","goods_name"},
                {"colorId","color_id"},{"colorName","color_name"},{"unitId","unit_id"},{"unitName","unit_name"},
                {"goodsVersion","goods_version"},{"issueMethod","issue_method"},{"categoryId","category_id"}};
        for(String[] field:ids)out.put(field[0],row.get(field[1]));
        out.put("qty",exact(row.get("qty")));out.put("weightKg",exact(row.get("weight_kg")));
        out.put("weightEstimated",row.get("weight_estimated"));out.put("kgPerBaseUnit",exact(row.get("kg_factor")));
        out.put("allowedActions",has(SUBMIT)?List.of("EDIT"):List.of()); return out;
    }
    private static void verifySnapshot(StockCountDtos.LineInput line,Map<String,Object> current) {
        if(!line.unitId().equals(current.get("unit_id"))||!same(line.expectedQty(),current.get("qty"))
                ||!same(line.expectedWeightKg(),current.get("weight_kg"))
                ||line.expectedWeightEstimated()!=Boolean.TRUE.equals(current.get("weight_estimated")))
            throw conflict("库存数量、重量或单位已变化，请刷新并重新核对盘点值");
    }

    @Transactional @PreAuthorize("hasAuthority('stock:count:submit')")
    public Map<String,Object> submit(StockCountDtos.Submit request) {
        require(SUBMIT);
        if(request==null||!validator.validate(request).isEmpty())throw invalid("盘点输入不完整，数量和重量最多14位整数、4位小数");
        // 盘点说明选填(2026-10-02 用户口径, V795 只留 500 字上限): 不填/null/空白统一存成 ""。
        // 指纹也按归一化后的内容算, 同一次提交 null 与 "" 重放不被当成不同盘点。
        String reason=request.reason()==null?"":request.reason().strip();
        if(reason.length()>500)throw invalid("盘点说明最多500字");
        request=new StockCountDtos.Submit(request.warehouseId(),reason,request.idempotencyKey(),request.lines());
        tx.bind();commandLock(request.idempotencyKey());String fingerprint=hash(request);
        var prior=db.queryForList("SELECT id,request_hash FROM stock_count_requests WHERE submitted_by=:actor AND command_key=:key",
                Map.of("actor",user.requireId(),"key",request.idempotencyKey()));
        if(!prior.isEmpty()) {
            if(!fingerprint.equals(prior.getFirst().get("request_hash")))throw conflict("此提交编号已用于不同的盘点内容");
            return detail((UUID)prior.getFirst().get("id"));
        }
        var w=warehouse(request.warehouseId());
        if(request.lines()==null||request.lines().isEmpty()||request.lines().size()>500)throw invalid("请选择1至500项盘点数值");
        var snapshots=new ArrayList<Map<String,Object>>();var targets=new ArrayList<BigDecimal>();var identities=new HashSet<String>();
        for(var line:request.lines()) {
            if(line==null||line.goodsId()==null||line.unitId()==null||line.expectedQty()==null||line.targetQty()==null||line.targetQty().signum()<0)
                throw invalid("请完整填写物料与非负目标数量");
            if(!identities.add(line.goodsId()+"|"+line.colorId()))throw invalid("同仓同料同色只能填写一次");
            var current=snapshot(request.warehouseId(),line.goodsId(),line.colorId());verifySnapshot(line,current);
            BigDecimal factor=decimal(current.get("kg_factor"));
            if(line.targetQty().signum()==0&&line.weightChanged()&&line.targetWeightKg()!=null&&line.targetWeightKg().signum()>0)
                throw invalid("实盘数量为0时，实盘重量不能大于0");
            BigDecimal target=factor!=null?WeightMath.times(line.targetQty(),factor)
                    :line.targetQty().signum()==0?BigDecimal.ZERO:line.weightChanged()?line.targetWeightKg():line.expectedWeightKg();
            if(line.weightChanged()&&factor!=null&&line.targetWeightKg()!=null&&!same(target,line.targetWeightKg()))
                throw invalid("重量单位货品的数量与重量不一致，请按该物料单位填写数量");
            if((line.weightChanged()||factor!=null)&&line.targetQty().signum()>0&&(target==null||target.signum()<=0))
                throw invalid("有库存时实盘重量须大于0；未知重量请留空不修改");
            if(target!=null&&target.signum()<0)throw invalid("实盘重量不能为负数");
            if(same(line.targetQty(),line.expectedQty())&&(!line.weightChanged()||same(target,line.expectedWeightKg())))
                throw invalid("只提交真正修改的数值，未变化的行请保留原样");
            if("WORKSHOP".equals(w.get("kind"))&&"ORDER".equals(current.get("issue_method"))) {
                if(!Set.of("OWN","SHARED","EXPENSE").contains(Objects.toString(line.materialSetupBasis(),"")))
                    throw invalid("首次登记内料仓原料，请注明主料、辅料或车间费用用途，交仓库核准");
                if(!Objects.equals(line.goodsVersion(),((Number)current.get("goods_version")).longValue()))throw conflict("物料资料已变化，请刷新");
            } else if(line.materialSetupBasis()!=null)throw invalid("已配置材料不应再次提交首次用途设置");
            snapshots.add(current);targets.add(target);
        }
        UUID id=UUID.randomUUID();UUID actor=user.requireId();String number=numbers.nextNumber(DocNumberPrefix.STOCK_COUNT_REQUEST);
        db.update("""
                INSERT INTO stock_count_requests(id,request_no,warehouse_id,review_route,submitted_by,reason,command_key,request_hash)
                VALUES(:id,:number,:warehouse,:route,:actor,:reason,:key,:hash)
                """,new MapSqlParameterSource("id",id).addValue("number",number).addValue("warehouse",request.warehouseId())
                .addValue("route",w.get("review_route")).addValue("actor",actor).addValue("reason",reason)
                .addValue("key",request.idempotencyKey()).addValue("hash",fingerprint));
        for(int index=0;index<request.lines().size();index++) {
            var line=request.lines().get(index);var current=snapshots.get(index);
            db.update("""
                    INSERT INTO stock_count_request_lines(id,request_id,line_no,goods_id,color_id,unit_id,expected_qty,
                      expected_weight_kg,expected_weight_estimated,target_qty,target_weight_kg,weight_changed,material_setup_basis,
                      goods_version,goods_code,goods_name,color_name,unit_name,kg_per_base_unit)
                    VALUES(:id,:request,:no,:goods,CAST(:color AS uuid),:unit,:before,:beforeWeight,:estimated,:after,:afterWeight,
                      :weightChanged,:basis,:version,:code,:name,:colorName,:unitName,:factor)
                    """,new MapSqlParameterSource("id",UUID.randomUUID()).addValue("request",id).addValue("no",index+1)
                    .addValue("goods",line.goodsId()).addValue("color",line.colorId()).addValue("unit",line.unitId())
                    .addValue("before",line.expectedQty()).addValue("beforeWeight",line.expectedWeightKg())
                    .addValue("estimated",line.expectedWeightEstimated()).addValue("after",line.targetQty()).addValue("afterWeight",targets.get(index))
                    .addValue("weightChanged",line.weightChanged()).addValue("basis",line.materialSetupBasis())
                    .addValue("version",current.get("goods_version")).addValue("code",current.get("goods_code"))
                    .addValue("name",current.get("goods_name")).addValue("colorName",current.get("color_name"))
                    .addValue("unitName",current.get("unit_name")).addValue("factor",current.get("kg_factor")));
        }
        insertEvent(id,"SUBMIT",0,request.idempotencyKey(),reason);
        publish(header(id,false));return detail(id);
    }

    private Map<String,Object> header(UUID id,boolean lock) {
        var rows=db.queryForList("""
                SELECT r.*,w.name AS warehouse_name,COALESCE(e.full_name,u.login_account) AS submitted_by_name
                FROM stock_count_requests r JOIN warehouses w ON w.id=r.warehouse_id
                JOIN users u ON u.id=r.submitted_by LEFT JOIN employees e ON e.id=u.employee_id
                WHERE r.id=:id
                """+(lock?" FOR UPDATE OF r":""),Map.of("id",id));
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"盘点申请不存在");return rows.getFirst();
    }
    private boolean reviewAllowed(Map<String,Object> h) {
        return has("WAREHOUSE".equals(h.get("review_route"))?WAREHOUSE:FINANCE);
    }
    private void readAllowed(Map<String,Object> h) {
        if(warehouses(false).stream().noneMatch(w->w.get("id").equals(h.get("warehouse_id"))))
            throw new ApiException(ErrorCode.FORBIDDEN,"无权查看此仓库的盘点申请");
        if(!reviewAllowed(h)&&!(has(SUBMIT)&&user.requireId().equals(h.get("submitted_by"))))
            throw new ApiException(ErrorCode.FORBIDDEN,"无权查看此盘点申请");
    }
    @Transactional(readOnly=true)
    public Map<String,Object> detail(UUID id) {
        var h=header(id,false);readAllowed(h);Map<String,Object> out=headerView(h);
        var rows=db.queryForList("SELECT * FROM stock_count_request_lines WHERE request_id=:id ORDER BY line_no",Map.of("id",id));
        var lines=new ArrayList<Map<String,Object>>();boolean stale=warehouses().stream().noneMatch(w->w.get("id").equals(h.get("warehouse_id")));
        for(var row:rows) {
            Map<String,Object> line=new LinkedHashMap<>();
            String[][] names={{"id","id"},{"goodsId","goods_id"},{"goodsCode","goods_code"},{"goodsName","goods_name"},
                    {"colorId","color_id"},{"colorName","color_name"},{"unitId","unit_id"},{"unitName","unit_name"},
                    {"materialSetupBasis","material_setup_basis"},{"goodsVersion","goods_version"}};
            for(var name:names)line.put(name[0],row.get(name[1]));
            line.put("beforeQty",exact(row.get("expected_qty")));line.put("beforeWeightKg",exact(row.get("expected_weight_kg")));
            line.put("targetQty",exact(row.get("target_qty")));line.put("targetWeightKg",exact(row.get("target_weight_kg")));
            // Review shows the effective posting difference, including quantity-zero's derived weight-zero.
            // Persisted weight_changed remains the user's input fact; an absent target is never a request to clear weight.
            line.put("weightChanged",row.get("target_weight_kg")!=null
                    &&!same(row.get("expected_weight_kg"),row.get("target_weight_kg")));
            line.put("deltaQty",decimal(row.get("target_qty")).subtract(decimal(row.get("expected_qty"))).toPlainString());
            line.put("weightEstimated",row.get("expected_weight_estimated"));line.put("kgPerBaseUnit",exact(row.get("kg_per_base_unit")));
            line.put("deltaWeightKg",row.get("target_weight_kg")==null||row.get("expected_weight_kg")==null?null:
                    decimal(row.get("target_weight_kg")).subtract(decimal(row.get("expected_weight_kg"))).toPlainString());
            boolean changed=true;
            try {
                var current=snapshot((UUID)h.get("warehouse_id"),(UUID)row.get("goods_id"),(UUID)row.get("color_id"));
                line.put("currentQty",exact(current.get("qty")));line.put("currentWeightKg",exact(current.get("weight_kg")));
                changed=!same(row.get("expected_qty"),current.get("qty"))||!same(row.get("expected_weight_kg"),current.get("weight_kg"))
                        ||!Objects.equals(row.get("expected_weight_estimated"),current.get("weight_estimated"))
                        ||!Objects.equals(row.get("unit_id"),current.get("unit_id"))||!same(row.get("kg_per_base_unit"),current.get("kg_factor"))
                        ||(row.get("material_setup_basis")!=null&&!Objects.equals(row.get("goods_version"),current.get("goods_version")));
            } catch(ApiException ignored) { line.put("currentQty",null);line.put("currentWeightKg",null); }
            line.put("stale",changed&&"PENDING".equals(h.get("status")));stale|=changed;lines.add(line);
        }
        var actions=new ArrayList<String>();
        if("PENDING".equals(h.get("status"))) {
            if(reviewAllowed(h)){if(!stale)actions.add("APPROVE");actions.add("REJECT");}
            if(has(SUBMIT)&&user.requireId().equals(h.get("submitted_by")))actions.add("CANCEL");
        }
        out.put("lines",lines);out.put("allowedActions",actions);return out;
    }
    private Map<String,Object> headerView(Map<String,Object> h) {
        var out=new LinkedHashMap<String,Object>();
        String[][] names={{"id","id"},{"requestNo","request_no"},{"warehouseId","warehouse_id"},{"warehouseName","warehouse_name"},
                {"reviewRoute","review_route"},{"status","status"},{"version","row_version"},{"submittedByName","submitted_by_name"},
                {"reason","reason"},{"reviewReason","review_reason"},{"stockDocumentId","stock_document_id"}};
        for(var name:names)out.put(name[0],h.get(name[1]));
        out.put("submittedAt",time(h.get("submitted_at")));out.put("reviewedAt",time(h.get("reviewed_at")));return out;
    }

    @Transactional
    public Map<String,Object> decide(UUID id,String action,StockCountDtos.Decision request) {
        if(request==null||!validator.validate(request).isEmpty())throw invalid("请提供当前审核版本和有效的操作编号");
        tx.bind();commandLock(request.idempotencyKey());var h=header(id,true);readAllowed(h);
        if("CANCEL".equals(action)){require(SUBMIT);if(!user.requireId().equals(h.get("submitted_by")))throw new ApiException(ErrorCode.FORBIDDEN,"只能撤回本人申请");}
        else require("WAREHOUSE".equals(h.get("review_route"))?WAREHOUSE:FINANCE);
        String reason=request.reason()==null?null:request.reason().strip();
        if("REJECT".equals(action)&&(reason==null||reason.isEmpty()))throw invalid("请填写驳回原因");
        var replay=db.queryForList("SELECT * FROM stock_count_request_events WHERE actor_id=:actor AND command_key=:key",
                Map.of("actor",user.requireId(),"key",request.idempotencyKey()));
        if(!replay.isEmpty()) {
            var e=replay.getFirst();
            if(!id.equals(e.get("request_id"))||!action.equals(e.get("action"))||!Objects.equals(reason,e.get("reason"))
                    ||((Number)e.get("request_version")).longValue()!=request.expectedVersion()+1)throw conflict("同一操作编号不能用于不同审核内容");
            return detail(id);
        }
        if(!"PENDING".equals(h.get("status"))||((Number)h.get("row_version")).longValue()!=request.expectedVersion())throw conflict("申请已被办理或版本变化，请刷新");
        if("APPROVE".equals(action)) {
            var w=warehouse((UUID)h.get("warehouse_id"));if(!w.get("review_route").equals(h.get("review_route")))throw conflict("仓库类型已变化，请重新盘点");
        }
        long version=request.expectedVersion()+1;UUID event=insertEvent(id,action,version,request.idempotencyKey(),reason);
        String status=switch(action){case "APPROVE"->"APPROVED";case "REJECT"->"REJECTED";case "CANCEL"->"CANCELLED";default->throw invalid("审核动作不正确");};
        db.update("""
                UPDATE stock_count_requests SET status=:status,row_version=:version,reviewed_by=:actor,reviewed_at=now(),
                    review_reason=:reason,approval_event_id=CAST(:event AS uuid),updated_at=now() WHERE id=:id
                """,new MapSqlParameterSource("status",status).addValue("version",version).addValue("actor",user.requireId())
                .addValue("reason",reason).addValue("event","APPROVE".equals(action)?event:null).addValue("id",id));
        if("APPROVE".equals(action)) {
            Object posted="WAREHOUSE".equals(h.get("review_route"))?workshop.postApproved(id,event):stockDocs.applyApprovedStockCount(id,event);
            db.update("UPDATE stock_count_requests SET posting_result=CAST(:result AS jsonb) WHERE id=:id",Map.of("result",encode(posted),"id",id));
        }
        publish(header(id,false));return detail(id);
    }
    private UUID insertEvent(UUID id,String action,long version,String key,String reason) {
        UUID event=UUID.randomUUID();db.update("""
                INSERT INTO stock_count_request_events(id,request_id,action,actor_id,reason,request_version,command_key)
                VALUES(:event,:request,:action,:actor,:reason,:version,:key)
                """,new MapSqlParameterSource("event",event).addValue("request",id).addValue("action",action)
                .addValue("actor",user.requireId()).addValue("reason",reason).addValue("version",version).addValue("key",key));return event;
    }
    private void publish(Map<String,Object> h) {
        var payload=new LinkedHashMap<String,Object>();
        payload.put("requestId",h.get("id"));payload.put("requestNo",h.get("request_no"));payload.put("warehouseId",h.get("warehouse_id"));
        payload.put("warehouseName",h.get("warehouse_name"));payload.put("reviewRoute",h.get("review_route"));payload.put("submittedBy",h.get("submitted_by"));
        payload.put("status",h.get("status"));payload.put("reason",h.get("review_reason")==null?h.get("reason"):h.get("review_reason"));
        String event=switch(h.get("status").toString()){case "PENDING"->"SUBMITTED";case "APPROVED"->"APPROVED";case "REJECTED"->"REJECTED";default->"CANCELLED";};
        events.publishOnce("STOCK_COUNT_"+event,"STOCK_COUNT_REQUEST",(UUID)h.get("id"),payload,h.get("id")+":"+h.get("status")+":"+h.get("row_version"));
    }
    @Transactional(readOnly=true)
    public PageResponse<Map<String,Object>> list(String route,String status,UUID warehouseId,int page,int size,
                                               WarehouseTaskScope taskWarehouseScope) {
        return list(route,status,warehouseId,page,size,taskWarehouseScope,null);
    }
    @Transactional(readOnly=true)
    public PageResponse<Map<String,Object>> list(String route,String status,UUID warehouseId,int page,int size,
                                               WarehouseTaskScope taskWarehouseScope,String keyword) {
        if(route!=null&&!Set.of("FINANCE","WAREHOUSE").contains(route))throw invalid("审核归属不正确");
        if(status!=null&&!Set.of("PENDING","APPROVED","REJECTED","CANCELLED").contains(status))throw invalid("盘点状态不正确");
        if(route!=null)require("WAREHOUSE".equals(route)?WAREHOUSE:FINANCE);
        var allowed=warehouses(false).stream().map(w->(UUID)w.get("id")).filter(w->warehouseId==null||warehouseId.equals(w)).toList();
        var paging=Pageables.of(page,size);if(allowed.isEmpty())return new PageResponse<>(List.of(),paging.getPageNumber()+1,paging.getPageSize(),0,0);
        var params=new MapSqlParameterSource("warehouses",allowed).addValue("actor",user.requireId())
                .addValue("limit",paging.getPageSize()).addValue("offset",paging.getOffset());
        String where=" WHERE r.warehouse_id IN (:warehouses)";
        // ADR-149: 仓库审核是仓库任务, 与原对象范围、精确仓库筛选取交集; 财务审核与「我提交的」不按仓库范围裁剪。
        // 范围已展开下级(含车间内料仓)。
        if("WAREHOUSE".equals(route)&&taskWarehouseScope!=null&&taskWarehouseScope.active()) {
            where+=" AND "+taskWarehouseScope.predicate("r.warehouse_id",":taskWarehouseScope");
            params.addValue("taskWarehouseScope",taskWarehouseScope.idsCsv());
        }
        if(route==null)where+=" AND r.submitted_by=:actor";else{where+=" AND r.review_route=:route";params.addValue("route",route);}
        if(status!=null){where+=" AND r.status=:status";params.addValue("status",status);}
        if(keyword!=null&&!keyword.isBlank()) {
            params.addValue("keyword",keyword.strip());
            where+="\n"+"""
                    AND (strpos(lower(concat_ws(' ',r.request_no,r.reason,
                          (SELECT count_warehouse.name FROM warehouses count_warehouse WHERE count_warehouse.id=r.warehouse_id))),lower(:keyword))>0
                      OR EXISTS(SELECT 1 FROM stock_count_request_lines count_line WHERE count_line.request_id=r.id
                          AND strpos(lower(concat_ws(' ',count_line.goods_code,count_line.goods_name,count_line.color_name)),lower(:keyword))>0))
                    """;
        }
        long total=Objects.requireNonNull(db.queryForObject("SELECT count(*) FROM stock_count_requests r"+where,params,Long.class));
        var rows=db.queryForList("""
                SELECT r.*,w.name AS warehouse_name,COALESCE(e.full_name,u.login_account) AS submitted_by_name
                FROM stock_count_requests r JOIN warehouses w ON w.id=r.warehouse_id
                JOIN users u ON u.id=r.submitted_by LEFT JOIN employees e ON e.id=u.employee_id
                """+where+" ORDER BY r.submitted_at DESC,r.id DESC LIMIT :limit OFFSET :offset",params).stream().map(this::headerView).toList();
        return new PageResponse<>(rows,paging.getPageNumber()+1,paging.getPageSize(),total,(int)((total+paging.getPageSize()-1)/paging.getPageSize()));
    }
    @Transactional(readOnly=true)
    public Map<String,Object> counts() {
        return counts(WarehouseTaskScope.ALL);
    }

    /** warehouse_pending 与仓库审核列表同一仓库数据范围(ADR-149); 财务与本人计数不按仓库范围裁剪。 */
    @Transactional(readOnly=true)
    public Map<String,Object> counts(WarehouseTaskScope taskWarehouseScope) {
        var allowed = warehouses(false).stream().map(w -> (UUID)w.get("id")).toList();
        if (allowed.isEmpty()) return Map.of("financePending",0L,"warehousePending",0L,"myPending",0L,"myRejected",0L);
        var params = new MapSqlParameterSource("warehouses",allowed).addValue("actor",user.requireId());
        boolean scoped = taskWarehouseScope != null && taskWarehouseScope.active();
        if (scoped) params.addValue("taskWarehouseScope", taskWarehouseScope.idsCsv());
        var counts = db.queryForMap("""
                SELECT count(*) FILTER (WHERE r.review_route='FINANCE' AND r.status='PENDING') AS finance_pending,
                       count(*) FILTER (WHERE r.review_route='WAREHOUSE' AND r.status='PENDING'%s) AS warehouse_pending,
                       count(*) FILTER (WHERE r.submitted_by=:actor AND r.status='PENDING') AS my_pending,
                       count(*) FILTER (WHERE r.submitted_by=:actor AND r.status='REJECTED') AS my_rejected
                FROM stock_count_requests r WHERE r.warehouse_id IN (:warehouses) AND r.status IN ('PENDING','REJECTED')
                """.formatted(scoped ? " AND " + taskWarehouseScope.predicate("r.warehouse_id", ":taskWarehouseScope") : ""),
                params);
        return Map.of("financePending",has(FINANCE)?counts.get("finance_pending"):0L,
                "warehousePending",has(WAREHOUSE)?counts.get("warehouse_pending"):0L,
                "myPending",has(SUBMIT)?counts.get("my_pending"):0L,
                "myRejected",has(SUBMIT)?counts.get("my_rejected"):0L);
    }
}
