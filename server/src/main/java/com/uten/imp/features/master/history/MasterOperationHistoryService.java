package com.uten.imp.features.master.history;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.features.master.lifecycle.MasterEntityKind;
import com.uten.imp.features.master.lifecycle.MasterReferenceGuard;
import com.uten.imp.features.master.warehouse.WarehouseMasterRules;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.*;

/** Personal master-data editing history. Raw snapshots never cross the API. */
@Service
@RequiredArgsConstructor
@PreAuthorize("isAuthenticated()")
public class MasterOperationHistoryService {
    private final EntityManager em;
    private final ObjectMapper mapper;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ClientAccessPolicy clientAccess;
    private final MasterReferenceGuard references;
    private final WarehouseMasterRules warehouseRules;

    public record Entry(UUID id,String operationType,String label,String summary,OffsetDateTime createdAt,
                        String state,long version,int affectedCount,boolean canUndo,boolean canRedo,String blockedReason) {}
    public record Event(String id,UUID operationId,String action,String label,OffsetDateTime createdAt,String operationType) {}
    public record History(List<Entry> entries,List<Event> events) {}
    private record Operation(UUID id,String type,String label,OffsetDateTime created,String state,long version,boolean redo,String blocked,String path) {}
    private record Row(String table,UUID id,JsonNode before,JsonNode after,JsonNode expected) {
        JsonNode target(boolean undo) { return undo?before:after; }
        boolean deleting(boolean undo) { return target(undo)==null||target(undo).path("is_deleted").asBoolean(); }
    }
    private record Domain(String permission,Set<String> tables) {}
    private static final Map<String,Domain> DOMAINS=Map.ofEntries(
        Map.entry("clients",new Domain("client",Set.of("clients","client_categories","party_contact_methods","party_addresses","client_ship_addresses"))),
        Map.entry("suppliers",new Domain("supplier",Set.of("suppliers","supplier_categories","party_contact_methods","party_addresses"))),
        Map.entry("moulds",new Domain("mould",Set.of("moulds","mould_categories"))),
        Map.entry("colors",new Domain("color",Set.of("colors"))),
        Map.entry("units",new Domain("unit",Set.of("units"))),
        Map.entry("currencies",new Domain("currency",Set.of("currencies"))),
        Map.entry("warehouses",new Domain("warehouse",Set.of("warehouses"))),
        Map.entry("accounts",new Domain("account",Set.of("accounts"))),
        Map.entry("reference-methods",new Domain("settlement_method",Set.of("settlement_methods"))),
        Map.entry("payment-styles",new Domain("payment_style",Set.of("payment_styles"))));
    /** Each authorized relation has a complete server-owned statement; request/history names are never SQL text. */
    private static final Map<String,String> SNAPSHOT_SQL=Map.ofEntries(
        Map.entry("clients","SELECT CAST(fn_goods_history_snapshot('clients'::regclass,t) AS text) FROM clients t WHERE id=:id"),
        Map.entry("client_categories","SELECT CAST(fn_goods_history_snapshot('client_categories'::regclass,t) AS text) FROM client_categories t WHERE id=:id"),
        Map.entry("party_contact_methods","SELECT CAST(fn_goods_history_snapshot('party_contact_methods'::regclass,t) AS text) FROM party_contact_methods t WHERE id=:id"),
        Map.entry("party_addresses","SELECT CAST(fn_goods_history_snapshot('party_addresses'::regclass,t) AS text) FROM party_addresses t WHERE id=:id"),
        Map.entry("client_ship_addresses","SELECT CAST(fn_goods_history_snapshot('client_ship_addresses'::regclass,t) AS text) FROM client_ship_addresses t WHERE id=:id"),
        Map.entry("suppliers","SELECT CAST(fn_goods_history_snapshot('suppliers'::regclass,t) AS text) FROM suppliers t WHERE id=:id"),
        Map.entry("supplier_categories","SELECT CAST(fn_goods_history_snapshot('supplier_categories'::regclass,t) AS text) FROM supplier_categories t WHERE id=:id"),
        Map.entry("moulds","SELECT CAST(fn_goods_history_snapshot('moulds'::regclass,t) AS text) FROM moulds t WHERE id=:id"),
        Map.entry("mould_categories","SELECT CAST(fn_goods_history_snapshot('mould_categories'::regclass,t) AS text) FROM mould_categories t WHERE id=:id"),
        Map.entry("colors","SELECT CAST(fn_goods_history_snapshot('colors'::regclass,t) AS text) FROM colors t WHERE id=:id"),
        Map.entry("units","SELECT CAST(fn_goods_history_snapshot('units'::regclass,t) AS text) FROM units t WHERE id=:id"),
        Map.entry("currencies","SELECT CAST(fn_goods_history_snapshot('currencies'::regclass,t) AS text) FROM currencies t WHERE id=:id"),
        Map.entry("warehouses","SELECT CAST(fn_goods_history_snapshot('warehouses'::regclass,t) AS text) FROM warehouses t WHERE id=:id"),
        Map.entry("accounts","SELECT CAST(fn_goods_history_snapshot('accounts'::regclass,t) AS text) FROM accounts t WHERE id=:id"),
        Map.entry("settlement_methods","SELECT CAST(fn_goods_history_snapshot('settlement_methods'::regclass,t) AS text) FROM settlement_methods t WHERE id=:id"),
        Map.entry("payment_styles","SELECT CAST(fn_goods_history_snapshot('payment_styles'::regclass,t) AS text) FROM payment_styles t WHERE id=:id"));

    @Transactional(readOnly=true)
    public History list(String entityType) {
        AuthUser user=principal(false); Domain domain=domain(entityType); require(user,domain.permission()+":view");
        UUID nextRedo=nextRedo(user.getId(),entityType);
        List<Entry> entries=new ArrayList<>();
        for(Operation op:recent(user.getId(),entityType)) {
            List<Row> rows=rows(op.id()); boolean undo="APPLIED".equals(op.state());
            String denied=scopeReason(rows,false);
            String blocked=reason(user,domain,op,rows,undo,nextRedo);
            entries.add(new Entry(op.id(),op.type(),op.label(),denied==null?summary(rows):"",op.created(),op.state(),op.version(),rows.size(),
                undo&&blocked==null,!undo&&blocked==null,blocked));
        }
        @SuppressWarnings("unchecked") List<Object[]> log=em.createNativeQuery("""
            SELECT e.id::text,e.operation_id,e.action,h.label,e.created_at,h.operation_type
            FROM master_operation_history_events e JOIN master_operation_history h ON h.id=e.operation_id
            WHERE e.actor_id=:actor AND h.entity_type=:entity ORDER BY e.id DESC LIMIT 30
            """).setParameter("actor",user.getId()).setParameter("entity",entityType).getResultList();
        return new History(List.copyOf(entries),log.stream().map(r->new Event(r[0].toString(),uuid(r[1]),r[2].toString(),r[3].toString(),time(r[4]),r[5].toString())).toList());
    }

    @Transactional public History undo(String entityType,UUID id,long version) { return replay(entityType,id,version,true); }
    @Transactional public History redo(String entityType,UUID id,long version) { return replay(entityType,id,version,false); }

    private History replay(String entityType,UUID id,long version,boolean undo) {
        AuthUser user=principal(true);Domain domain=domain(entityType);require(user,domain.permission()+":view");
        tx.bind();
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended('master-history:'||CAST(:actor AS text),0))").setParameter("actor",user.getId()).getSingleResult();
        Operation op=recent(user.getId(),entityType).stream().filter(o->o.id().equals(id)).findFirst()
            .orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"操作历史不存在或已超出最近 10 次范围"));
        if(op.version()!=version||undo!="APPLIED".equals(op.state()))throw conflict("记录已变化，请刷新后重试");
        List<Row> rows=rows(id);
        // Identifiers originate only from the immutable server whitelist. NOWAIT
        // prevents lock-order inversions with normal service/reference writers.
        try {
            Set<String> lockedTables=new TreeSet<>(rows.stream().map(Row::table).toList());
            if(rows.stream().anyMatch(r->directory(r.table())||r.table().equals("client_ship_addresses")))lockedTables.add(entityType.equals("clients")?"clients":"suppliers");
            for(String table:lockedTables) {
                if(!domain.tables().contains(table))throw conflict("此操作包含其他业务资料，不能通过资料历史恢复");
                em.createNativeQuery("LOCK TABLE "+table+" IN SHARE ROW EXCLUSIVE MODE NOWAIT").executeUpdate();
            }
            for(Row row:rows.stream().sorted(Comparator.comparing(Row::table).thenComparing(Row::id)).toList())
                em.createNativeQuery("SELECT id FROM "+row.table()+" WHERE id=:id FOR UPDATE NOWAIT").setParameter("id",row.id()).getResultList();
            String blocked=reason(user,domain,op,rows,undo,nextRedo(user.getId(),entityType));
            if(blocked!=null)throw conflict(blocked);
            validateTargets(rows,undo);
            em.createNativeQuery("SELECT fn_replay_master_operation(:id,:actor,:version,:undo,:employee)")
                .setParameter("id",id).setParameter("actor",user.getId()).setParameter("version",version).setParameter("undo",undo).setParameter("employee",user.getEmployeeId()).getSingleResult();
        } catch(ApiException failure) {throw failure;}
        catch(RuntimeException failure) {
            for(Throwable cause=failure;cause!=null;cause=cause.getCause())if(cause instanceof java.sql.SQLException sql&&"55P03".equals(sql.getSQLState()))
                throw conflict("资料正在由其他操作更新，本次没有修改资料；请稍后刷新重试");
            var error=conflict("资料引用或业务状态已变化，不能恢复；本次没有修改资料，请刷新后检查");error.initCause(failure);throw error;
        }
        em.clear();return list(entityType);
    }

    private String reason(AuthUser user,Domain domain,Operation op,List<Row> rows,boolean undo,UUID nextRedo) {
        String scope=scopeReason(rows,true);if(scope!=null)return scope;
        if(user.getImpersonatedBy()!=null)return "模拟身份仅供查看，不能撤回或取消撤回资料操作";
        if(op.blocked()!=null)return op.blocked();
        if(!undo&&(!op.redo()||!op.id().equals(nextRedo)))return "只能取消最近一次撤回；新增操作后不能再取消之前的撤回";
        if(rows.isEmpty())return "没有可恢复的资料修改";
        Set<String> needed=new LinkedHashSet<>();
        for(Row row:rows) {
            if(!domain.tables().contains(row.table()))return "此操作包含不支持恢复的业务资料";
            String permission=permission(row.table(),domain);
            if(op.type().equals("DELETE")&&op.path().startsWith("/api/master/mould-categories/"))permission="mould_category";
            String action=switch(op.type()) {case "CREATE"->"create";case "DELETE"->"delete";case "STATUS"->"status";default->"edit";};
            if(op.path().contains("/ship-addresses"))needed.add("client_address:"+(op.type().equals("DELETE")?"delete":"create"));
            else if(op.path().endsWith("/warning")) {needed.add("account:warning:manage");needed.add("account:balance:view");}
            else if(row.table().equals("payment_styles")&&op.type().equals("EDIT")) {if(changed(row,"name"))needed.add("payment_style:edit");}
            else needed.add(permission+":"+action);
            if(changed(row,"status"))needed.add(permission+":status");
            if(row.before()==null&&row.after()!=null&&row.after().hasNonNull("status")&&!"使用".equals(row.after().path("status").asText()))needed.add(permission+":status");
            if(changed(row,"balance_floor"))needed.add("account:warning:manage");
            if(changed(row,"sort_order"))needed.add(permission+":reorder");
            if(!Objects.equals(snapshot(row.table(),row.id()),row.expected()))return "相关资料已有后续修改，请先撤回后续操作或刷新后处理；没有覆盖任何修改";
        }
        if(!user.isSuperAdmin()) {needed.removeAll(user.getPermissions());if(!needed.isEmpty())return "当前缺少原操作所需权限："+String.join("、",needed);}
        return null;
    }

    private String scopeReason(List<Row> rows,boolean writing) {
        ClientAccessPolicy.ClientScope scope=null;
        for(Row row:rows) {
            JsonNode node=row.after()!=null?row.after():row.before();
            boolean clientAddress=row.table().equals("client_ship_addresses");
            boolean clientDirectory=directory(row.table())&&node!=null&&"CLIENT".equals(node.path("party_type").asText())||clientAddress;
            if("clients".equals(row.table())||clientDirectory) {
            if(scope==null)scope=clientAccess.evaluate();
            UUID clientId=clientDirectory?optionalUuid(node,clientAddress?"client_id":"party_id"):row.id();
            JsonNode actual=snapshot("clients",clientId);
            UUID owner=optionalUuid(actual,"owner_employee_id");
            if(actual==null||!clientAccess.canRead(clientId,owner,scope))return "你已没有相关客户的查看权限";
            if(writing&&!clientAccess.canWriteOwner(owner,scope))return "你已没有相关客户的修改权限";
            }
        }
        return null;
    }

    private void validateTargets(List<Row> rows,boolean undo) {
        for(Row row:rows) {
            JsonNode target=row.target(undo);
            String targetStatus=target==null?null:target.path("status").asText();
            if(directory(row.table())) {
                JsonNode identity=target!=null?target:row.before()!=null?row.before():row.after();
                String parent="CLIENT".equals(identity.path("party_type").asText())?"clients":"suppliers";
                UUID parentId=optionalUuid(identity,"party_id");
                if(em.createNativeQuery("SELECT id FROM "+parent+" WHERE id=:id AND NOT is_deleted FOR SHARE NOWAIT").setParameter("id",parentId).getResultList().isEmpty())
                    throw conflict("联系方式或地址所属的客户、供应商已删除，不能恢复");
                if(row.table().equals("party_contact_methods")&&target!=null
                    &&!em.createNativeQuery("""
                        SELECT id FROM party_contact_methods WHERE party_type=:type AND party_id=:party
                         AND kind=:kind AND lower(value)=lower(:value) AND id<>:id FOR SHARE NOWAIT
                        """).setParameter("type",target.path("party_type").asText()).setParameter("party",parentId)
                        .setParameter("kind",target.path("kind").asText()).setParameter("value",target.path("value").asText()).setParameter("id",row.id()).getResultList().isEmpty())
                    throw conflict("该联系方式后来已由其他记录重新添加，不能恢复为重复联系方式");
                if(target!=null)validateDirectorySelection(row,target,rows,undo,parentId);
            }
            if(row.table().equals("client_ship_addresses")) {
                JsonNode identity=target!=null?target:row.before()!=null?row.before():row.after();
                UUID clientId=optionalUuid(identity,"client_id");
                if(em.createNativeQuery("SELECT id FROM clients WHERE id=:id AND NOT is_deleted FOR SHARE NOWAIT").setParameter("id",clientId).getResultList().isEmpty())
                    throw conflict("收货地址所属的客户已删除，不能恢复");
            }
            if("currencies".equals(row.table())&&row.expected().path("is_base_currency").asBoolean()
                &&(row.deleting(undo)||!"使用".equals(targetStatus)))throw conflict("本位币必须保持启用，不能通过历史停用或删除");
            if("settlement_methods".equals(row.table())&&!row.expected().path("system_role").asText("").isBlank())
                throw conflict("系统结算方式不能修改，请使用结算方式维护流程处理");
            if("payment_styles".equals(row.table()))validatePaymentStyle(row,target);
            if("warehouses".equals(row.table())&&(row.deleting(undo)||!"使用".equals(targetStatus))
                &&!warehouseRules.retirementBlockers(List.of(row.id())).isEmpty())throw conflict("该仓库仍有库存、业务任务或下级仓库，不能停用或删除");
            if(row.deleting(undo)) {
                MasterEntityKind kind=kind(row.table());
                if(kind!=null&&!references.blockers(kind,List.of(row.id()),List.of()).isEmpty())throw conflict("相关资料已被其他资料或业务引用，不能撤回；没有修改任何资料");
                if(!directory(row.table()))assertNoOtherReferences(row,rows,undo);
            } else {
                assertLiveReferences(row,target,rows,undo);
            }
        }
    }

    private void validateDirectorySelection(Row row,JsonNode target,List<Row> rows,boolean undo,UUID party) {
        boolean contact=row.table().equals("party_contact_methods");String flag=contact?"is_primary":"is_default";
        if(!target.path(flag).asBoolean())return;
        String sql="SELECT id FROM "+row.table()+" WHERE party_type=:type AND party_id=:party AND "+flag+" AND id<>:id"
            +(contact?" AND kind=:kind":"")+" FOR SHARE NOWAIT";
        var query=em.createNativeQuery(sql).setParameter("type",target.path("party_type").asText()).setParameter("party",party).setParameter("id",row.id());
        if(contact)query.setParameter("kind",target.path("kind").asText());
        List<?> selected=query.getResultList();
        for(Object selectedId:selected) {
            UUID id=uuid(selectedId);
            Row other=rows.stream().filter(r->r.table().equals(row.table())&&r.id().equals(id)).findFirst().orElse(null);
            JsonNode desired=other==null?null:other.target(undo);
            boolean clearedByThisCommand=other!=null&&(desired==null||!desired.path(flag).asBoolean()
                ||contact&&!Objects.equals(desired.get("kind"),target.get("kind")));
            if(!clearedByThisCommand)throw conflict(contact?"后来已有其他主选联系方式，不能恢复旧主选；没有修改后来的选择":"后来已有其他默认地址，不能恢复旧默认；没有修改后来的选择");
        }
    }

    private void validatePaymentStyle(Row row,JsonNode target) {
        // Ordinary label/order edits are reversible. System identity is still
        // evaluated against today's row and the desired label, not old grants.
        Set<String> protectedPaths=Set.of("/031/","/032/","/033/","/041/","/042/","/043/","/101/","/102/","/113/","/123/","/139/","/151/","/152/","/172/","/173/","/203/","/204/","/205/","/221/","/301/","/321/");
        JsonNode actual=row.expected();boolean nameChanged=changed(row,"name");
        if(nameChanged&&(protectedPaths.contains(actual.path("path").asText())||row.id().equals(UUID.fromString("40000000-0000-4000-8100-000000000001"))
            ||"EXPENSE".equals(actual.path("category").asText())&&(Set.of("手续费","汇兑损益").contains(actual.path("name").asText())||Set.of("手续费","汇兑损益").contains(target.path("name").asText()))))
            throw conflict("财务系统科目不能改名，也不能占用系统保留科目名称");
    }

    /** Resolve physical FK metadata from the database, never from request identifiers. */
    private List<Object[]> foreignKeys(String table,boolean incoming) {
        @SuppressWarnings("unchecked") List<Object[]> result=em.createNativeQuery("""
            SELECT child.relname,ca.attname,parent.relname,pa.attname,
             EXISTS(SELECT 1 FROM pg_attribute da WHERE da.attrelid=parent.oid AND da.attname='is_deleted' AND NOT da.attisdropped),
             EXISTS(SELECT 1 FROM pg_attribute sa WHERE sa.attrelid=parent.oid AND sa.attname='status' AND NOT sa.attisdropped),
             EXISTS(SELECT 1 FROM pg_attribute da WHERE da.attrelid=child.oid AND da.attname='is_deleted' AND NOT da.attisdropped),
             EXISTS(SELECT 1 FROM pg_attribute ia WHERE ia.attrelid=child.oid AND ia.attname='id' AND NOT ia.attisdropped)
            FROM pg_constraint c JOIN pg_class child ON child.oid=c.conrelid JOIN pg_class parent ON parent.oid=c.confrelid
            JOIN pg_namespace ns ON ns.oid=child.relnamespace
            JOIN pg_attribute ca ON ca.attrelid=c.conrelid AND ca.attnum=c.conkey[1]
            JOIN pg_attribute pa ON pa.attrelid=c.confrelid AND pa.attnum=c.confkey[1]
            WHERE c.contype='f' AND ns.nspname='public' AND cardinality(c.conkey)=1
             AND ca.atttypid='uuid'::regtype AND pa.attname='id'
             AND CASE WHEN :incoming THEN parent.relname ELSE child.relname END=:table
            """).setParameter("incoming",incoming).setParameter("table",table).getResultList();
        return result;
    }
    private void assertLiveReferences(Row row,JsonNode target,List<Row> rows,boolean undo) {
        for(Object[] fk:foreignKeys(row.table(),false)) {
            UUID id=optionalUuid(target,fk[1].toString());if(id==null)continue;
            boolean reintroducing=row.expected()==null||row.expected().path("is_deleted").asBoolean()||!Objects.equals(row.expected().get(fk[1].toString()),target.get(fk[1].toString()));
            Row grouped=rows.stream().filter(r->r.table().equals(fk[2].toString())&&r.id().equals(id)).findFirst().orElse(null);
            if(grouped!=null) {
                if(grouped.deleting(undo))throw conflict("本次恢复的资料不能引用本次将删除的主档");
                if(reintroducing&&Set.of("禁用","报废").contains(grouped.target(undo).path("status").asText()))throw conflict("本次恢复的原关联资料已停用或报废，不能重新引入");
                continue;
            }
            String sql="SELECT "+identifier(fk[3])+" FROM "+identifier(fk[2])+" WHERE "+identifier(fk[3])+"=:id"
                +((Boolean)fk[4]?" AND NOT is_deleted":"")+((Boolean)fk[5]&&reintroducing?" AND COALESCE(status,'') NOT IN ('禁用','报废')":"")+" FOR SHARE NOWAIT";
            if(em.createNativeQuery(sql).setParameter("id",id).getResultList().isEmpty())throw conflict("原资料引用的分类、负责人或其他主档已删除或停用，不能恢复");
        }
    }
    private void assertNoOtherReferences(Row row,List<Row> rows,boolean undo) {
        // Also protect category/currency and later-created auxiliary rows. This
        // conservative physical check never rewrites later business records.
        for(Object[] fk:foreignKeys(row.table(),true)) {
            String child=fk[0].toString();
            if(Set.of("master_operation_history","master_operation_history_rows","master_operation_history_events").contains(child))continue;
            List<UUID> grouped=(Boolean)fk[7]?rows.stream().filter(r->r.table().equals(child)&&r.deleting(undo)).map(Row::id).toList():List.of();
            String sql="SELECT 1 FROM "+identifier(child)+" WHERE "+identifier(fk[1])+"=:id"
                +((Boolean)fk[6]?" AND NOT is_deleted":"")
                +(grouped.isEmpty()?"":" AND NOT(id=ANY(CAST(string_to_array(:grouped,',') AS uuid[])))")+" LIMIT 1";
            var query=em.createNativeQuery(sql).setParameter("id",row.id());
            if(!grouped.isEmpty())query.setParameter("grouped",grouped.stream().map(UUID::toString).collect(java.util.stream.Collectors.joining(",")));
            if(!query.getResultList().isEmpty())throw conflict("该资料已有其他资料或历史业务引用，不能撤回新增或重做删除；请保留资料身份");
        }
    }

    private List<Operation> recent(UUID actor,String entity) {
        @SuppressWarnings("unchecked") List<Object[]> result=em.createNativeQuery("""
            SELECT id,operation_type,label,created_at,state,version,redo_allowed,unsupported_reason,request_path
            FROM master_operation_history WHERE actor_id=:actor AND entity_type=:entity ORDER BY created_at DESC,id DESC LIMIT 10
            """).setParameter("actor",actor).setParameter("entity",entity).getResultList();
        return result.stream().map(r->new Operation(uuid(r[0]),r[1].toString(),r[2].toString(),time(r[3]),r[4].toString(),((Number)r[5]).longValue(),(Boolean)r[6],(String)r[7],r[8].toString())).toList();
    }
    private List<Row> rows(UUID id) {
        @SuppressWarnings("unchecked") List<Object[]> result=em.createNativeQuery("SELECT table_name,row_id,before_row::text,after_row::text,expected_row::text FROM master_operation_history_rows WHERE operation_id=:id ORDER BY capture_order").setParameter("id",id).getResultList();
        return result.stream().map(r->new Row(r[0].toString(),uuid(r[1]),json(r[2]),json(r[3]),json(r[4]))).toList();
    }
    private UUID nextRedo(UUID actor,String entity) {
        List<?> result=em.createNativeQuery("""
            SELECT h.id FROM master_operation_history_events e JOIN master_operation_history h ON h.id=e.operation_id
            WHERE e.actor_id=:actor AND h.entity_type=:entity AND e.action='UNDO' AND h.state='UNDONE' AND h.redo_allowed ORDER BY e.id DESC LIMIT 1
            """).setParameter("actor",actor).setParameter("entity",entity).getResultList();
        return result.isEmpty()?null:uuid(result.getFirst());
    }
    private JsonNode snapshot(String table,UUID id) {
        if(DOMAINS.values().stream().noneMatch(d->d.tables().contains(table)))throw conflict("不支持的资料表");
        String sql=SNAPSHOT_SQL.get(table);
        if(sql==null)throw conflict("不支持的资料表");
        List<?> result=em.createNativeQuery(sql).setParameter("id",id).getResultList();
        return result.isEmpty()?null:json(result.getFirst());
    }
    private AuthUser principal(boolean writing) {
        AuthUser user=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED,"当前登录状态无效"));
        if(user.getId()==null||user.getEmployeeId()==null||user.isVisitor()||!user.isAccountNonLocked()||user.isMustChangePassword())throw new ApiException(ErrorCode.FORBIDDEN,"当前账号不能访问资料操作历史，请核对登录状态");
        if(writing&&user.getImpersonatedBy()!=null)throw new ApiException(ErrorCode.FORBIDDEN,"模拟身份仅供查看，不能撤回或取消撤回资料操作");return user;
    }
    private static Domain domain(String entity) {Domain value=DOMAINS.get(entity);if(value==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"不支持的基础资料类型");return value;}
    private static void require(AuthUser user,String permission) {if(!user.isSuperAdmin()&&!user.getPermissions().contains(permission))throw new ApiException(ErrorCode.FORBIDDEN,"缺少权限："+permission);}
    private static String permission(String table,Domain domain) {return table.endsWith("_categories")?table.substring(0,table.length()-"_categories".length())+"_category":domain.permission();}
    private static MasterEntityKind kind(String table) {return Arrays.stream(MasterEntityKind.values()).filter(k->k.table().equals(table)).findFirst().orElse(null);}
    private static boolean directory(String table) {return table.equals("party_contact_methods")||table.equals("party_addresses");}
    private static boolean changed(Row row,String field) {return row.before()!=null&&row.after()!=null&&!Objects.equals(row.before().get(field),row.after().get(field));}
    private static String summary(List<Row> rows) {return rows.stream().map(r->{JsonNode n=r.after()!=null?r.after():r.before();return n==null?"":(n.path("code").asText("")+" "+n.path("name").asText("")).trim();}).filter(s->!s.isBlank()).limit(3).reduce((a,b)->a+"、"+b).orElse("");}
    private JsonNode json(Object value) {try{return value==null?null:mapper.reader().with(com.fasterxml.jackson.databind.DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS).readTree(value.toString());}catch(Exception error){throw new IllegalStateException("资料历史快照格式错误",error);}}
    private static UUID optionalUuid(JsonNode node,String field) {return node==null||!node.hasNonNull(field)?null:UUID.fromString(node.path(field).asText());}
    private static UUID uuid(Object value) {return value instanceof UUID id?id:UUID.fromString(value.toString());}
    private static OffsetDateTime time(Object value) {return value instanceof OffsetDateTime t?t:value instanceof java.sql.Timestamp t?t.toInstant().atOffset(java.time.ZoneOffset.UTC):OffsetDateTime.parse(value.toString());}
    private static String identifier(Object value) {return "\""+value.toString().replace("\"","\"\"")+"\"";}
    private static ApiException conflict(String message) {return new ApiException(ErrorCode.CONFLICT,message);}
}
