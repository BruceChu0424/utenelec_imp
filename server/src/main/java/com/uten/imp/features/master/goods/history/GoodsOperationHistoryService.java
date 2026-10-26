package com.uten.imp.features.master.goods.history;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.lifecycle.MasterEntityKind;
import com.uten.imp.features.master.lifecycle.MasterReferenceGuard;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.*;
import java.util.stream.Collectors;

/** A bounded editing window over durable evidence, never a business-document reversal. */
@Service
@RequiredArgsConstructor
public class GoodsOperationHistoryService {
    private final EntityManager em;
    private final ObjectMapper mapper;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final MasterReferenceGuard referenceGuard;
    private final OwnerVisibility ownerVisibility;
    private final BusinessEventPublisher events;
    @org.springframework.beans.factory.annotation.Autowired
    private MasterReferenceValidationPort masterReferences;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.features.master.warehouse.WarehouseMasterRules warehouseRules;
    @Value("${uten.features.goods-owner-scope-enabled:false}")
    private boolean goodsOwnerScopeEnabled;

    public record Entry(UUID id, String operationType, String label, String summary,
                        OffsetDateTime createdAt, String state, long version, int affectedCount,
                        boolean canUndo, boolean canRedo, String blockedReason) {}
    public record Event(String id, UUID operationId, String action, String label, OffsetDateTime createdAt,String operationType) {}
    public record History(List<Entry> entries, List<Event> events) {}
    private record Operation(UUID id, String type, String label, OffsetDateTime createdAt, String state,
                             long version, boolean redoAllowed, String unsupportedReason,
                             Set<String> requiredPermissions) {}
    private record Row(String table, UUID id, JsonNode before, JsonNode after, JsonNode expected) {
        JsonNode target(boolean undo) { return undo ? before : after; }
        boolean deleting(boolean undo) { JsonNode target=target(undo); return target==null || target.path("is_deleted").asBoolean(); }
    }
    private record Facts(Map<String,JsonNode> current,Set<UUID> periodic,OwnerVisibility.OwnerScope scope) {}
    private static final Set<String> TABLES=Set.of("goods","goods_bom_items","material_categories","colors","units");
    private static final Set<String> GOODS_COSTS=Set.of("source_e","machining_e","incidental_e","lacquer_e","plating_e",
            "casing_e","polish_e","total","work_rate","work_e","lost_rate","lost_e","rent_rate","rent_e","make_rate","make_e","c_total","g_total");

    @PreAuthorize("hasAuthority('goods:view')")
    @Transactional(readOnly=true)
    public History list() {
        UUID actor=requireHistoryPrincipal(false).getId();
        UUID nextRedo=nextRedo(actor);
        List<Entry> entries=new ArrayList<>();
        List<Operation> operations=recent(actor);
        Map<UUID,List<Row>> allRows=allRows(operations.stream().map(Operation::id).toList());
        Facts facts=facts(allRows.values().stream().flatMap(Collection::stream).toList());
        for (Operation op:operations) {
            List<Row> rows=allRows.getOrDefault(op.id(),List.of());
            boolean undo="APPLIED".equals(op.state());
            String blocked=reason(op,rows,undo,nextRedo,facts);
            String summary=readScopeReason(rows,facts)==null?summary(rows,facts):"";
            entries.add(new Entry(op.id(),op.type(),op.label(),summary,op.createdAt(),op.state(),op.version(),rows.size(),
                    undo&&blocked==null,!undo&&blocked==null,blocked));
        }
        @SuppressWarnings("unchecked") List<Object[]> result=em.createNativeQuery("""
                SELECT e.id::text,e.operation_id,e.action,h.label,e.created_at,h.operation_type
                FROM goods_operation_history_events e JOIN goods_operation_history h ON h.id=e.operation_id
                WHERE e.actor_id=:actor ORDER BY e.id DESC LIMIT 30
                """).setParameter("actor",actor).getResultList();
        List<Event> log=result.stream().map(r->new Event(r[0].toString(),uuid(r[1]),r[2].toString(),r[3].toString(),time(r[4]),r[5].toString())).toList();
        return new History(List.copyOf(entries),log);
    }

    @PreAuthorize("hasAuthority('goods:view')")
    @Transactional
    public History undo(UUID id,long expectedVersion) { return replay(id,expectedVersion,true); }

    @PreAuthorize("hasAuthority('goods:view')")
    @Transactional
    public History redo(UUID id,long expectedVersion) { return replay(id,expectedVersion,false); }

    /** Safe compatibility for the old import endpoint; old snapshots are never guessed. */
    @PreAuthorize("hasAuthority('goods:import:undo')")
    @Transactional
    public int undoImport(UUID batchId) {
        UUID actor=requireHistoryPrincipal(true).getId();
        tx.bind();
        lockHistoryActor(actor);
        @SuppressWarnings("unchecked") List<Object[]> batch=em.createNativeQuery("""
                SELECT id,status,operation_id FROM goods_import_batches WHERE id=:id AND created_by=:actor
                """).setParameter("id",batchId).setParameter("actor",actor).getResultList();
        if(batch.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND,"导入批次不存在");
        if(!"IMPORTED".equals(batch.getFirst()[1])) throw conflict("该导入批次已撤回，请到操作记录查看");
        List<Object[]> found;
        UUID boundOperation=batch.getFirst()[2]==null?null:uuid(batch.getFirst()[2]);
        if(boundOperation!=null) {
            @SuppressWarnings("unchecked") List<Object[]> exact=em.createNativeQuery("""
                    SELECT h.id,h.version FROM goods_operation_history h
                    WHERE h.id=:operation AND h.actor_id=:actor AND h.operation_type='GOODS_IMPORT'
                    """).setParameter("operation",boundOperation).setParameter("actor",actor).getResultList();
            found=exact;
        } else {
            // Old creation-only receipts have no immutable request key. Recover
            // only a unique operation that is not already owned by another batch.
            @SuppressWarnings("unchecked") List<Object[]> legacy=em.createNativeQuery("""
                    SELECT DISTINCT h.id,h.version FROM goods_operation_history h
                    JOIN goods_operation_history_rows r ON r.operation_id=h.id AND r.table_name='goods'
                    JOIN goods_import_creations c ON c.entity_id=r.row_id AND c.entity_type='GOODS'
                    WHERE c.batch_id=:batch AND h.actor_id=:actor AND h.operation_type='GOODS_IMPORT'
                      AND NOT EXISTS(SELECT 1 FROM goods_import_batches linked WHERE linked.operation_id=h.id)
                    """).setParameter("batch",batchId).setParameter("actor",actor).getResultList();
            found=legacy;
        }
        if(found.size()!=1) throw conflict("该旧批次没有完整安全快照，不能直接撤回；请核对后在货品资料中处理");
        UUID operation=uuid(found.getFirst()[0]);
        if(boundOperation==null)em.createNativeQuery("UPDATE goods_import_batches SET operation_id=:operation WHERE id=:batch")
                .setParameter("operation",operation).setParameter("batch",batchId).executeUpdate();
        int affected=rows(operation).size();
        replay(operation,((Number)found.getFirst()[1]).longValue(),true);
        return affected;
    }

    private History replay(UUID id,long expectedVersion,boolean undo) {
        UUID actor=requireHistoryPrincipal(true).getId();
        tx.bind();
        // The transaction preparation hook takes the actor lock before normal
        // writes. Explicitly take it here too, including legacy/internal callers.
        // Never wait for table locks while another writer may hold business rows.
        lockHistoryActor(actor);
        try {
            em.createNativeQuery("LOCK TABLE colors,units,material_categories,goods,goods_bom_items IN SHARE ROW EXCLUSIVE MODE NOWAIT").executeUpdate();
        } catch(RuntimeException error) {
            if(lockBusy(error))throw busy();
            throw error;
        }
        Operation op=recent(actor).stream().filter(o->o.id().equals(id)).findFirst()
                .orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"操作历史不存在或已超出最近 10 次范围"));
        if(op.version()!=expectedVersion) throw conflict("记录已变化，请刷新后重试");
        if(undo!="APPLIED".equals(op.state())) throw conflict("操作状态已变化，请刷新后重试");
        List<Row> rows=rows(id);
        try {
            for(Row row:rows.stream().filter(r->TABLES.contains(r.table()))
                    .sorted(Comparator.comparing(Row::table).thenComparing(Row::id)).toList())
                em.createNativeQuery("SELECT id FROM "+row.table()+" WHERE id=:id FOR UPDATE NOWAIT").setParameter("id",row.id()).getResultList();
        } catch(RuntimeException error) {
            if(lockBusy(error))throw busy();
            throw error;
        }
        String blocked=reason(op,rows,undo,nextRedo(actor),facts(rows));
        if(blocked!=null) throw conflict(blocked);
        requireDeletionReferences(rows,undo);
        requireLiveReferences(rows,undo);
        if(!op.type().equals("BOM_AUDIT"))requireAcyclicBom(id,undo,rows);
        requireCategoryContext(op);
        try {
            em.createNativeQuery("SELECT fn_replay_goods_operation(:id,:actor,:version,:undo)")
                    .setParameter("id",id).setParameter("actor",actor).setParameter("version",expectedVersion).setParameter("undo",undo).getSingleResult();
        } catch(RuntimeException error) {
            if(lockBusy(error))throw busy();
            throw conflict("相关资料的引用或业务状态已变化，不能恢复；没有修改任何资料，请刷新后检查");
        }
        // Legacy import visibility and the new history agree after either action.
        if("GOODS_IMPORT".equals(op.type())) {
            em.createNativeQuery("""
                    UPDATE goods_import_batches b SET status=:status
                    WHERE b.created_by=:actor AND b.operation_id=:operation
                    """).setParameter("status",undo?"UNDONE":"IMPORTED").setParameter("actor",actor).setParameter("operation",id).executeUpdate();
        }
        Set<UUID> parents=new LinkedHashSet<>();
        for(Row row:rows) if("goods_bom_items".equals(row.table())) {
            for(JsonNode node:Arrays.asList(row.before(),row.after())) if(node!=null) parents.add(uuid(node.path("goods_id").asText()));
        }
        boolean disablesGoods=rows.stream().anyMatch(row->row.table().equals("goods")
                && row.target(undo)!=null && "禁用".equals(row.target(undo).path("status").asText())
                && changed(row.before(),row.after(),"status"));
        Map<String,Object> bomEvent=disablesGoods
                ? Map.of("historyOperationId",id.toString(),"reason","COMPONENT_DISABLED")
                : Map.of("historyOperationId",id.toString());
        if(!op.type().equals("BOM_AUDIT")) for(UUID parent:parents) events.publish("GOODS_BOM_UPDATED","GOODS_BOM",parent,bomEvent);
        em.clear();
        return list();
    }

    private String reason(Operation op,List<Row> rows,boolean undo,UUID nextRedo,Facts facts) {
        return reason(op,rows,undo,nextRedo,facts,false);
    }
    private String reason(Operation op,List<Row> rows,boolean undo,UUID nextRedo,Facts facts,boolean versionRestore) {
        for(Row row:rows) if("goods".equals(row.table()) && row.target(undo)!=null
                && facts.current().get("goods:"+row.id())!=null
                && facts.current().get("goods:"+row.id()).path("is_deleted").asBoolean()
                && !row.target(undo).path("is_deleted").asBoolean()
                && Boolean.TRUE.equals(em.createNativeQuery("SELECT EXISTS(SELECT 1 FROM goods_code_reuse_releases WHERE old_goods_id=:id)")
                    .setParameter("id",row.id()).getSingleResult()))
            return "原编号已回用于新 UUID 的货品，不能撤回删除或恢复旧货品；请核对当前货品";
        String scopeDenied=writeScopeReason(op,rows,facts,undo);
        if(scopeDenied!=null)return scopeDenied;
        if(currentUser.get().map(u->u.getImpersonatedBy()!=null).orElse(false))return "模拟身份仅供查看，不能撤回或取消撤回资料操作";
        if(op.unsupportedReason()!=null) return op.unsupportedReason();
        if(!undo&&(!op.redoAllowed()||!op.id().equals(nextRedo))) return "只能取消最近一次撤回；新增操作后不能再取消之前的撤回";
        String permission=permissionReason(op,rows);
        if(permission!=null) return permission;
        if(rows.isEmpty()) return "没有可恢复的资料修改";
        for(Row row:rows) {
            if(!versionRestore&&row.table().equals("goods")&&changed(row.before(),row.after(),"code","code_managed","code_sequence","code_prefix_category_id"))
                return "此操作包含编号变化，请从修改历史选择版本，通过当前编号规则恢复";
            if(!TABLES.contains(row.table())) return "该操作包含不支持恢复的资料";
            if(!Objects.equals(facts.current().get(row.table()+":"+row.id()),row.expected())) return "相关资料已有后续修改，请先撤回后续操作或刷新后处理；没有覆盖任何修改";
            if("goods_bom_items".equals(row.table())&&!op.type().equals("BOM_AUDIT")) {
                for(JsonNode node:Arrays.asList(row.before(),row.after())) if(node!=null) {
                    if(!node.path("learning_profile_goods_id").isNull()&&node.hasNonNull("learning_profile_goods_id")) return "此组件包含自动学习来源，请使用组装维护流程处理";
                    UUID component=uuid(node.path("component_goods_id").asText());
                    if(facts.periodic().contains(component)) return "此组装变更涉及期间领料和认料状态，请使用组装维护流程处理";
                }
            }
            if("goods".equals(row.table())&&row.before()!=null&&row.after()!=null
                    &&changed(row.before(),row.after(),"issue_method","periodic_cost_basis","bulk_package_qty","is_recycled_material")) return "此操作涉及发料方式或期间成本，不能通过资料历史恢复";
        }
        return null;
    }

    private String readScopeReason(List<Row> rows,Facts facts) {
        if(!goodsOwnerScopeEnabled)return null;
        var scope=facts.scope();
        if(scope.seeAll())return null;
        for(Row row:rows) {
            if(row.table().equals("goods")) {
                JsonNode actual=facts.current().get("goods:"+row.id());
                UUID owner=optionalUuid(actual,"owner_employee_id");
                if(actual==null||owner!=null&&!scope.visibleOwners().contains(owner))return "你已没有相关货品的查看权限";
            }
            if(row.table().equals("goods_bom_items"))for(JsonNode node:Arrays.asList(row.before(),row.after()))if(node!=null) {
                JsonNode actual=facts.current().get("goods:"+optionalUuid(node,"goods_id"));
                UUID owner=optionalUuid(actual,"owner_employee_id");
                if(actual==null||owner!=null&&!scope.visibleOwners().contains(owner))return "你已没有相关货品的查看权限";
            }
        }
        return null;
    }

    private String writeScopeReason(Operation op,List<Row> rows,Facts facts,boolean undo) {
        String denied=readScopeReason(rows,facts);
        if(denied!=null)return denied;
        if(!goodsOwnerScopeEnabled)return null;
        var scope=facts.scope();
        if(scope.seeAll())return null;
        for(Row row:rows) {
            if(row.table().equals("goods")&&!op.type().startsWith("BOM_")) {
                for(JsonNode node:Arrays.asList(facts.current().get("goods:"+row.id()),row.target(undo))) {
                    UUID owner=optionalUuid(node,"owner_employee_id");
                    if(owner!=null&&!scope.writableOwners().contains(owner))return "你已没有相关货品的修改权限";
                }
            }
            // Auditing and removing an edge only require visibility of its
            // parent in the normal BOM service. Reintroducing or editing an
            // active edge additionally requires the component to be visible.
            if(row.table().equals("goods_bom_items")&&!op.type().equals("BOM_AUDIT")&&!row.deleting(undo)) {
                JsonNode target=row.target(undo);
                JsonNode component=facts.current().get("goods:"+optionalUuid(target,"component_goods_id"));
                UUID owner=optionalUuid(component,"owner_employee_id");
                if(component==null||owner!=null&&!scope.visibleOwners().contains(owner))return "你已没有相关组件货品的查看权限";
            }
        }
        return null;
    }

    private AuthUser requireHistoryPrincipal(boolean writing) {
        AuthUser user=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED,"当前登录状态无效"));
        if(user.getId()==null||user.isVisitor()||user.getEmployeeId()==null||!user.isAccountNonLocked()||user.isMustChangePassword())
            throw new ApiException(ErrorCode.FORBIDDEN,"当前账号不能访问货品操作历史，请重新核对登录状态");
        if(writing&&user.getImpersonatedBy()!=null)throw new ApiException(ErrorCode.FORBIDDEN,"模拟身份仅供查看，不能撤回或取消撤回资料操作");
        return user;
    }

    private void lockHistoryActor(UUID actor) {
        try {
            em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended('goods-history:'||CAST(:actor AS text),0))")
                    .setParameter("actor",actor).getSingleResult();
            em.createNativeQuery("SELECT set_config('app.goods_history_prelocked_actor',CAST(:actor AS text),true)")
                    .setParameter("actor",actor).getSingleResult();
        } catch(RuntimeException error) {
            if(lockBusy(error))throw busy();
            throw error;
        }
    }
    private static boolean lockBusy(Throwable error) {
        for(Throwable cause=error;cause!=null;cause=cause.getCause())if(cause instanceof java.sql.SQLException sql&&"55P03".equals(sql.getSQLState()))return true;
        return false;
    }
    private static ApiException busy(){return conflict("货品资料正在由其他操作更新，本次未作任何修改；请稍后刷新后重试");}

    /** Pure native authority check shared by history availability and its locked writer. */
    public String versionRestorePermissionReason(List<com.uten.imp.features.master.history.MasterVersionRow> versions) {
        return permissionReason(versionRestoreOperation(),versionRestoreRows(versions));
    }

    private static List<Row> versionRestoreRows(List<com.uten.imp.features.master.history.MasterVersionRow> versions) {
        return versions.stream().map(v->new Row(v.table(),v.id(),v.target(),v.current(),v.current())).toList();
    }

    private static Operation versionRestoreOperation() {
        return new Operation(UUID.randomUUID(),"GOODS_EDIT","恢复资料版本",OffsetDateTime.now(),"APPLIED",0,false,null,Set.of());
    }

    /** Called by the immutable object-version history after locking its scope. */
    public void validateVersionRestore(List<com.uten.imp.features.master.history.MasterVersionRow> versions) {
        AuthUser user=requireHistoryPrincipal(true);
        List<Row> rows=versionRestoreRows(versions);
        Set<String> needed=new LinkedHashSet<>();
        for(Row row:rows) {
            needed.add(switch(row.table()) {
                case "goods" -> "goods:view";
                case "goods_bom_items" -> "goods:bom:edit";
                case "material_categories" -> "material_category:edit";
                default -> throw conflict("不支持的货品版本资料");
            });
            if(row.deleting(true))needed.add(switch(row.table()) {
                case "goods" -> "goods:delete";
                case "goods_bom_items" -> "goods:bom:delete";
                case "material_categories" -> "material_category:delete";
                default -> throw conflict("不支持的货品版本资料");
            });
            if(row.table().equals("goods_bom_items")&&changed(row.before(),row.after(),"price","total"))needed.add("goods:cost:view");
            if(row.table().equals("goods_bom_items")&&changed(row.before(),row.after(),"audited_at","audited_by"))needed.add("goods:bom:audit");
            if(row.table().equals("goods")&&changed(row.before(),row.after(),"category_id","owner_employee_id","owning_warehouse_id","owning_workshop_department_id","owning_responsible_employee_id"))
                throw conflict("此版本涉及编号、分类或责任归属，请通过对应维护流程修改，不能覆盖后续责任设置");
            if(row.table().equals("material_categories")&&changed(row.before(),row.after(),"parent_id","code_prefix","path","level","sort_order"))
                throw conflict("此版本涉及分类层级或编号前缀，请通过分类维护流程处理");
        }
        if(!user.isSuperAdmin()&&!user.getPermissions().containsAll(needed))throw conflict("当前没有恢复此版本所需的编辑或删除权限");
        String permission=versionRestorePermissionReason(versions);
        if(permission!=null)throw conflict(permission);
        Operation operation=versionRestoreOperation();
        String blocked=reason(operation,rows,true,null,facts(rows),true);
        if(blocked!=null)throw conflict(blocked);
        requireDeletionReferences(rows,true);
        requireLiveReferences(rows,true);
        // Each restored edge is checked against the complete desired graph by
        // the object history service, before any writes occur.
    }

    private String permissionReason(Operation op,List<Row> rows) {
        AuthUser user=currentUser.get().orElse(null);
        if(user==null) return "当前登录状态无效";
        if(user.isSuperAdmin()) return null;
        Set<String> needed=new LinkedHashSet<>();
        switch(op.type()) {
            case "GOODS_CREATE"->needed.add("goods:create");
            case "GOODS_EDIT"->{}
            case "GOODS_PURCHASE_POLICY"->needed.add("goods:purchase:edit");
            case "GOODS_SUBCONTRACT_POLICY"->{needed.add("goods:purchase:edit");needed.add("goods:cost:view");}
            case "GOODS_NAME_EN"->{if(!user.getPermissions().contains("goods:sales:edit"))needed.add("goods:name_en:edit");}
            case "GOODS_STATUS"->needed.add("goods:status");
            case "GOODS_DELETE"->needed.add("goods:delete");
            case "GOODS_IMPORT"->{needed.add("goods:import");needed.add("goods:import:undo");}
            case "BOM_CREATE","BOM_PASTE"->needed.add("goods:bom:create");
            case "BOM_EDIT"->{needed.add("goods:bom:edit");needed.addAll(op.requiredPermissions());}
            case "BOM_MOVE"->needed.add("goods:bom:edit");
            case "BOM_DELETE"->needed.add("goods:bom:delete");
            case "BOM_AUDIT"->needed.add("goods:bom:audit");
            case "CATEGORY_CREATE"->needed.add("material_category:create");
            case "CATEGORY_DELETE"->needed.add("material_category:delete");
            case "CATEGORY_EDIT"->{
                for(Row row:rows) if("material_categories".equals(row.table())) {
                    if(changed(row.before(),row.after(),"name","remark","code_prefix"))needed.add("material_category:edit");
                    if(changed(row.before(),row.after(),"parent_id"))needed.add("material_category:move");
                    if(changed(row.before(),row.after(),"sort_order"))needed.add("material_category:reorder");
                }
            }
            default->{return "此操作需要专用业务流程处理";}
        }
        for(Row row:rows) {
            if("goods".equals(row.table()) && row.before()!=null && row.after()!=null) {
                if(changed(row.before(),row.after(),"status"))needed.add("goods:status");
                if(changed(row.before(),row.after(),"price","zk"))needed.add("goods:price:edit");
                if(changed(row.before(),row.after(),"zk"))needed.add("goods:discount:view");
                // Direct master edits and version restoration require the same field rights.
                // BOM-derived source costs retain the original BOM command's authority.
                if(("GOODS_EDIT".equals(op.type()) || "GOODS_IMPORT".equals(op.type()))
                        && changed(row.before(),row.after(),GOODS_COSTS.toArray(String[]::new))) {
                    needed.add("goods:edit"); needed.add("goods:cost:view");
                }
                if(changed(row.before(),row.after(),"code","category_id","name","short_name","model","spec","series","stock_place","material","thickness","m_weight","pack","pieces","paper","rear_insert_code","color_id","unit_id","mould_id","thickness_unit_id","m_weight_unit_id","owning_warehouse_id","color_legacy_id","unit_legacy_id","mould_legacy_id"))needed.add("goods:edit");
                if(changed(row.before(),row.after(),"source_type","min_order_qty","order_multiple_qty","default_supplier_id","secondary_supplier_id","vend_legacy_id","vend2_legacy_id","subcontract_allowed_loss_pct","purchase_allowed_over_receipt_pct"))needed.add("goods:purchase:edit");
                if(changed(row.before(),row.after(),"c_number","client_goods_name","client_id","client_legacy_id"))needed.add("goods:sales:edit");
                if(changed(row.before(),row.after(),"name_en") && !user.getPermissions().contains("goods:name_en:edit"))needed.add("goods:sales:edit");
            }
            if("BOM_PASTE".equals(op.type())&&row.before()!=null&&row.after()!=null&&row.after().path("is_deleted").asBoolean())needed.add("goods:bom:delete");
            if("GOODS_CREATE".equals(op.type())&&"goods".equals(row.table())&&row.after()!=null) {
                if(row.after().hasNonNull("status")&&!"使用".equals(row.after().path("status").asText()))needed.add("goods:status");
                if(row.after().hasNonNull("price")||row.after().hasNonNull("zk"))needed.add("goods:price:edit");
                if(GOODS_COSTS.stream().anyMatch(row.after()::hasNonNull))needed.add("goods:cost:view");
            }
        }
        needed.removeAll(user.getPermissions());
        return needed.isEmpty()?null:"当前缺少原操作所需权限："+String.join("、",needed);
    }

    private void requireDeletionReferences(List<Row> rows,boolean undo) {
        List<UUID> deletingGoods=rows.stream().filter(r->r.table().equals("goods")&&r.deleting(undo)).map(Row::id).toList();
        if(!referenceGuard.goodsBlockers(deletingGoods).isEmpty()) throw conflict("相关货品已被组装、单据、库存或业务任务引用，不能撤回；没有修改任何资料");
        if(!deletingGoods.isEmpty()) {
            List<UUID> deletingBom=rows.stream().filter(r->r.table().equals("goods_bom_items")&&r.deleting(undo)).map(Row::id).toList();
            Number laterBom=(Number)em.createNativeQuery("""
                    SELECT count(*) FROM goods_bom_items WHERE NOT is_deleted
                    AND goods_id=ANY(CAST(string_to_array(:goods,',') AS uuid[]))
                    AND NOT(id=ANY(CAST(string_to_array(:bom,',') AS uuid[])))
                    """).setParameter("goods",joined(deletingGoods)).setParameter("bom",joined(deletingBom)).getSingleResult();
            if(laterBom.longValue()>0)throw conflict("该货品后来新增了组装组件，请先处理这些后续组装操作；没有删除任何资料");
        }
        for(MasterEntityKind kind:List.of(MasterEntityKind.COLOR,MasterEntityKind.UNIT)) {
            List<UUID> ids=rows.stream().filter(r->r.table().equals(kind.table())&&r.deleting(undo)).map(Row::id).toList();
            if(!referenceGuard.blockers(kind,ids,deletingGoods).isEmpty())throw conflict("本次新建的颜色或单位后来已被其他资料引用，不能撤回");
        }
        Set<UUID> deletingCategories=rows.stream().filter(r->r.table().equals("material_categories")&&r.deleting(undo)).map(Row::id).collect(Collectors.toSet());
        if(!deletingCategories.isEmpty()) {
            String ids=joined(deletingCategories),goods=joined(deletingGoods);
            Number count=(Number)em.createNativeQuery("""
                    SELECT (SELECT count(*) FROM goods WHERE category_id=ANY(CAST(string_to_array(:ids,',') AS uuid[])) AND NOT is_deleted
                       AND NOT(id=ANY(CAST(string_to_array(:goods,',') AS uuid[]))))
                     +(SELECT count(*) FROM material_categories WHERE parent_id=ANY(CAST(string_to_array(:ids,',') AS uuid[])) AND NOT is_deleted
                       AND NOT(id=ANY(CAST(string_to_array(:ids,',') AS uuid[]))))
                    """).setParameter("ids",ids).setParameter("goods",goods).getSingleResult();
            if(count.longValue()>0)throw conflict("该分类后来新增了货品或子分类，不能撤回");
        }
    }

    /** Later independent edges must not turn a restored relationship into a cycle. */
    private void requireAcyclicBom(UUID operation,boolean undo,List<Row> rows) {
        if(rows.stream().noneMatch(r->r.table().equals("goods_bom_items")&&!r.deleting(undo)))return;
        Boolean cyclic=(Boolean)em.createNativeQuery("""
            WITH RECURSIVE desired AS (
             SELECT CASE WHEN :undo THEN before_row ELSE after_row END AS node
             FROM goods_operation_history_rows WHERE operation_id=:operation AND table_name='goods_bom_items'
            ), restored AS (
             SELECT (node->>'goods_id')::uuid parent,(node->>'component_goods_id')::uuid component
             FROM desired WHERE node IS NOT NULL AND NOT COALESCE((node->>'is_deleted')::boolean,false)
            ), effective AS (
             SELECT b.goods_id parent,b.component_goods_id component FROM goods_bom_items b
             WHERE NOT b.is_deleted AND NOT EXISTS(SELECT 1 FROM goods_operation_history_rows r
              WHERE r.operation_id=:operation AND r.table_name='goods_bom_items' AND r.row_id=b.id)
             UNION SELECT parent,component FROM restored
            ), descendants(root,node) AS (
             SELECT parent,component FROM restored
             UNION SELECT d.root,e.component FROM descendants d JOIN effective e ON e.parent=d.node
            ) SELECT EXISTS(SELECT 1 FROM descendants WHERE root=node)
            """).setParameter("operation",operation).setParameter("undo",undo).getSingleResult();
        if(cyclic)throw conflict("后来新增的组装关系会使恢复后的组件互相套用形成循环，请先处理后续组装操作");
    }

    private void requireCategoryContext(Operation op) {
        if(!op.type().equals("CATEGORY_EDIT"))return;
        Boolean changed=(Boolean)em.createNativeQuery("SELECT category_context IS NOT NULL AND category_context IS DISTINCT FROM fn_goods_history_category_context(id) FROM goods_operation_history WHERE id=:id")
                .setParameter("id",op.id()).getSingleResult();
        if(changed)throw conflict("此分类子树后来新增、移动或修改了资料，不能直接恢复旧层级或编号前缀；请先处理后续操作");
    }

    private void requireLiveReferences(List<Row> rows,boolean undo) {
        Map<String,Map<UUID,JsonNode>> targets=new HashMap<>();
        Map<String,Set<UUID>> references=new LinkedHashMap<>();
        Map<String,Set<UUID>> newReferences=new LinkedHashMap<>();
        for(Row row:rows) if(!row.deleting(undo)) targets.computeIfAbsent(row.table(),k->new HashMap<>()).put(row.id(),row.target(undo));
        for(Row row:rows) {
            JsonNode target=row.target(undo); if(target==null||row.deleting(undo))continue;
            switch(row.table()) {
                case "goods"->{
                    addReference(references,"material_categories",optionalUuid(target,"category_id"));
                    addReference(references,"material_categories",optionalUuid(target,"code_prefix_category_id"));
                    addReference(references,"colors",optionalUuid(target,"color_id"));
                    for(String field:List.of("unit_id","thickness_unit_id","m_weight_unit_id"))addReference(references,"units",optionalUuid(target,field));
                    addReference(references,"moulds",optionalUuid(target,"mould_id"));
                    addReference(references,"clients",optionalUuid(target,"client_id"));
                    for(String field:List.of("default_supplier_id","secondary_supplier_id"))addReference(references,"suppliers",optionalUuid(target,field));
                    addReference(references,"warehouses",optionalUuid(target,"owning_warehouse_id"));
                    addReference(references,"departments",optionalUuid(target,"owning_workshop_department_id"));
                    addReference(references,"employees",optionalUuid(target,"owning_responsible_employee_id"));
                    for(String field:List.of("default_purchase_price_color_id","default_subcontract_price_color_id"))addReference(references,"colors",optionalUuid(target,field));
                    for(String field:List.of("default_purchase_price_unit_id","default_subcontract_price_unit_id"))addReference(references,"units",optionalUuid(target,field));
                    for(var fields:Map.of("colors",List.of("color_id"),"units",List.of("unit_id","thickness_unit_id","m_weight_unit_id"),
                            "moulds",List.of("mould_id"),"clients",List.of("client_id"),"suppliers",List.of("default_supplier_id","secondary_supplier_id"),
                            "warehouses",List.of("owning_warehouse_id")).entrySet())for(String field:fields.getValue())
                        if(newReference(row,target,field))addReference(newReferences,fields.getKey(),optionalUuid(target,field));
                }
                case "material_categories"->addReference(references,"material_categories",optionalUuid(target,"parent_id"));
                case "goods_bom_items"->{
                    addReference(references,"goods",optionalUuid(target,"goods_id"));
                    addReference(references,"goods",optionalUuid(target,"component_goods_id"));
                    addReference(references,"colors",optionalUuid(target,"color_id"));
                    addReference(references,"suppliers",optionalUuid(target,"default_supplier_id"));
                    for(var fields:Map.of("goods",List.of("goods_id","component_goods_id"),"colors",List.of("color_id"),"suppliers",List.of("default_supplier_id")).entrySet())
                        for(String field:fields.getValue())if(newReference(row,target,field))addReference(newReferences,fields.getKey(),optionalUuid(target,field));
                }
                default->{}
            }
        }
        for(var reference:references.entrySet()) {
            String table=reference.getKey();Set<UUID> ids=reference.getValue();ids.removeAll(targets.getOrDefault(table,Map.of()).keySet());
            if(ids.isEmpty())continue;
            // Names originate in the fixed mapping above. Batch locks coordinate
            // with normal saves without one database round trip per field/row.
            @SuppressWarnings("unchecked") List<Object> found=em.createNativeQuery("SELECT id FROM "+table+" WHERE id=ANY(CAST(string_to_array(:ids,',') AS uuid[])) AND NOT is_deleted FOR SHARE NOWAIT")
                    .setParameter("ids",joined(ids)).getResultList();
            if(found.size()!=ids.size())throw conflict("原资料引用的分类、货品、颜色、单位或其他主档已删除，不能恢复；请先处理引用资料");
        }
        for(var reference:newReferences.entrySet()) {
            String table=reference.getKey();Set<UUID> ids=reference.getValue();
            for(UUID id:new ArrayList<>(ids))if(targets.getOrDefault(table,Map.of()).containsKey(id)) {
                JsonNode target=targets.get(table).get(id);
                if(Set.of("禁用","报废").contains(target.path("status").asText("")))throw conflict("原关联资料已经停用或报废，不能重新引入");
                ids.remove(id);
            }
            if(ids.isEmpty())continue;
            @SuppressWarnings("unchecked") List<Object> active=em.createNativeQuery("SELECT id FROM "+table+" WHERE id=ANY(CAST(string_to_array(:ids,',') AS uuid[])) AND NOT is_deleted AND COALESCE(status,'') NOT IN ('禁用','报废') FOR SHARE NOWAIT")
                    .setParameter("ids",joined(ids)).getResultList();
            if(active.size()!=ids.size())throw conflict("原关联资料已经停用或报废，不能重新引入；请先处理对应主档");
            if(table.equals("clients"))for(UUID id:ids)masterReferences.requireVisibleActiveClient(id);
            if(table.equals("warehouses"))for(UUID id:ids)if(warehouseRules.selectionRefusal(id)!=null)throw conflict("原所属仓库已不可选，不能恢复该仓库归属");
        }
    }
    private static boolean newReference(Row row,JsonNode target,String field) {return row.expected()==null||row.expected().path("is_deleted").asBoolean()||!Objects.equals(target.get(field),row.expected().get(field));}
    private static void addReference(Map<String,Set<UUID>> references,String table,UUID id) {if(id!=null)references.computeIfAbsent(table,k->new LinkedHashSet<>()).add(id);}

    private List<Operation> recent(UUID actor) {
        @SuppressWarnings("unchecked") List<Object[]> result=em.createNativeQuery("""
                SELECT id,operation_type,label,created_at,state,version,redo_allowed,unsupported_reason,
                       array_to_string(required_permissions,',')
                FROM goods_operation_history WHERE actor_id=:actor ORDER BY created_at DESC,id DESC LIMIT 10
                """).setParameter("actor",actor).getResultList();
        return result.stream().map(r->new Operation(uuid(r[0]),r[1].toString(),r[2].toString(),time(r[3]),r[4].toString(),((Number)r[5]).longValue(),(Boolean)r[6],(String)r[7],
                r[8]==null||r[8].toString().isBlank()?Set.<String>of():Set.copyOf(Arrays.asList(r[8].toString().split(","))))).toList();
    }
    private UUID nextRedo(UUID actor) {
        List<?> result=em.createNativeQuery("""
                SELECT h.id FROM goods_operation_history_events e JOIN goods_operation_history h ON h.id=e.operation_id
                WHERE e.actor_id=:actor AND e.action='UNDO' AND h.state='UNDONE' AND h.redo_allowed ORDER BY e.id DESC LIMIT 1
                """).setParameter("actor",actor).getResultList();
        return result.isEmpty()?null:uuid(result.getFirst());
    }
    private List<Row> rows(UUID id) {
        return allRows(List.of(id)).getOrDefault(id,List.of());
    }
    private Map<UUID,List<Row>> allRows(List<UUID> ids) {
        if(ids.isEmpty())return Map.of();
        @SuppressWarnings("unchecked") List<Object[]> result=em.createNativeQuery("""
                SELECT operation_id,table_name,row_id,before_row::text,after_row::text,
                       fn_goods_bom_history_schema(expected_row,table_name)::text
                FROM goods_operation_history_rows WHERE operation_id=ANY(CAST(string_to_array(:ids,',') AS uuid[])) ORDER BY capture_order
                """).setParameter("ids",joined(ids)).getResultList();
        Map<UUID,List<Row>> grouped=new LinkedHashMap<>();
        for(Object[] r:result)grouped.computeIfAbsent(uuid(r[0]),k->new ArrayList<>()).add(new Row(r[1].toString(),uuid(r[2]),json(r[3]),json(r[4]),json(r[5])));
        return grouped;
    }
    private Facts facts(List<Row> rows) {
        Map<String,Set<UUID>> ids=new LinkedHashMap<>();Set<UUID> components=new LinkedHashSet<>();
        for(Row row:rows) {
            if(TABLES.contains(row.table()))ids.computeIfAbsent(row.table(),k->new LinkedHashSet<>()).add(row.id());
            if(row.table().equals("goods_bom_items"))for(JsonNode node:Arrays.asList(row.before(),row.after()))if(node!=null) {
                components.add(optionalUuid(node,"component_goods_id"));
                addReference(ids,"goods",optionalUuid(node,"goods_id"));addReference(ids,"goods",optionalUuid(node,"component_goods_id"));
            }
        }
        Map<String,JsonNode> current=new HashMap<>();
        for(var table:ids.entrySet()) {
            @SuppressWarnings("unchecked") List<Object[]> result=em.createNativeQuery(snapshotQuery(table.getKey()))
                    .setParameter("ids",joined(table.getValue())).getResultList();
            for(Object[] r:result)current.put(table.getKey()+":"+uuid(r[0]),json(r[1]));
        }
        Set<UUID> periodic=new HashSet<>();components.remove(null);
        if(!components.isEmpty()) {
            @SuppressWarnings("unchecked") List<Object> result=em.createNativeQuery("SELECT id FROM goods WHERE id=ANY(CAST(string_to_array(:ids,',') AS uuid[])) AND issue_method='PERIODIC'")
                    .setParameter("ids",joined(components)).getResultList();
            result.forEach(id->periodic.add(uuid(id)));
        }
        return new Facts(current,periodic,goodsOwnerScopeEnabled?ownerVisibility.evaluate("goods","goods:view:all"):null);
    }
    /** Every SQL identifier is a complete server-owned statement; only UUID values are bound. */
    private static String snapshotQuery(String table) {
        return switch(table) {
            case "goods" -> """
                    SELECT id,CAST(fn_goods_history_snapshot('goods'::regclass,t) AS text)
                    FROM goods t WHERE id=ANY(CAST(string_to_array(:ids,',') AS uuid[]))
                    """;
            case "goods_bom_items" -> """
                    SELECT id,CAST(fn_goods_history_snapshot('goods_bom_items'::regclass,t) AS text)
                    FROM goods_bom_items t WHERE id=ANY(CAST(string_to_array(:ids,',') AS uuid[]))
                    """;
            case "material_categories" -> """
                    SELECT id,CAST(fn_goods_history_snapshot('material_categories'::regclass,t) AS text)
                    FROM material_categories t WHERE id=ANY(CAST(string_to_array(:ids,',') AS uuid[]))
                    """;
            case "colors" -> """
                    SELECT id,CAST(fn_goods_history_snapshot('colors'::regclass,t) AS text)
                    FROM colors t WHERE id=ANY(CAST(string_to_array(:ids,',') AS uuid[]))
                    """;
            case "units" -> """
                    SELECT id,CAST(fn_goods_history_snapshot('units'::regclass,t) AS text)
                    FROM units t WHERE id=ANY(CAST(string_to_array(:ids,',') AS uuid[]))
                    """;
            default -> throw new IllegalArgumentException("Unsupported goods history snapshot table");
        };
    }
    private String summary(List<Row> rows,Facts facts) {
        for(String table:List.of("material_categories","goods","goods_bom_items")) for(Row row:rows) if(row.table().equals(table)) {
            if(table.equals("material_categories")&&!canReadCategory())continue;
            JsonNode node=row.after()!=null?row.after():row.before();
            String name=node.path("name").asText(""); String code=node.path("code").asText("");
            if(!name.isBlank()||!code.isBlank())return (code+" "+name).strip();
            if(table.equals("goods_bom_items")) {
                JsonNode parent=facts.current().get("goods:"+optionalUuid(node,"goods_id"));
                JsonNode component=facts.current().get("goods:"+optionalUuid(node,"component_goods_id"));
                return label(parent)+" / "+(canReadGoods(component,facts)?label(component):"受限组件");
            }
        }
        return "";
    }
    private boolean canReadCategory(){return currentUser.get().map(u->u.isSuperAdmin()||u.getPermissions().contains("material_category:view")).orElse(false);}
    private boolean canReadGoods(JsonNode node,Facts facts){
        if(node==null)return false;
        if(!goodsOwnerScopeEnabled)return true;
        var scope=facts.scope();UUID owner=optionalUuid(node,"owner_employee_id");
        return scope.seeAll()||owner==null||scope.visibleOwners().contains(owner);
    }
    private static String label(JsonNode node){return node==null?"":(node.path("code").asText("")+" "+node.path("name").asText("")).strip();}
    private JsonNode json(Object value) {if(value==null)return null;try{return mapper.reader().with(com.fasterxml.jackson.databind.DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS).readTree(value.toString());}catch(Exception error){throw new IllegalStateException("Invalid goods history snapshot",error);}}
    private static boolean changed(JsonNode before,JsonNode after,String...fields) {if(before==null||after==null)return false;return Arrays.stream(fields).anyMatch(k->!Objects.equals(before.get(k),after.get(k)));}
    private static UUID optionalUuid(JsonNode node,String field) {return node==null||!node.hasNonNull(field)?null:uuid(node.path(field).asText());}
    private static UUID uuid(Object value) {return value instanceof UUID id?id:UUID.fromString(value.toString());}
    private static OffsetDateTime time(Object value) {
        if(value instanceof OffsetDateTime t)return t;
        if(value instanceof java.time.Instant t)return t.atOffset(java.time.ZoneOffset.UTC);
        if(value instanceof java.sql.Timestamp t)return t.toInstant().atOffset(java.time.ZoneOffset.UTC);
        throw new IllegalStateException("Unsupported history timestamp type: "+value.getClass().getName());
    }
    private static String joined(Collection<UUID> ids) {return ids.stream().map(UUID::toString).collect(Collectors.joining(","));}
    private static ApiException conflict(String message) {return new ApiException(ErrorCode.CONFLICT,message);}
}
