package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.*;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.validation.Validator;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.Instant;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Predicate;

/** Explicitly confirmed maintenance of selected goods' direct canonical BOM relations. */
@Service
@PreAuthorize("hasAuthority('goods:bom:edit')")
public class GoodsBomBatchMaintenanceService {
    private static final int MAX_CHANGES = 2000;
    private static final UUID NO_ID = new UUID(0, 0);
    private final GoodsBomPasteService paste;
    private final GoodsBomService bom;
    private final GoodsRepository goods;
    private final GoodsBomItemRepository rows;
    private final GoodsBomGraphLock graph;
    private final GoodsBomHistoryPermissions history;
    private final MasterReferenceValidationPort references;
    private final MasterObjectAccess access;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final NamedParameterJdbcTemplate db;
    private final EntityManager em;
    private final ObjectMapper json;
    private final Validator validator;
    private final TransactionTemplate transactions;
    private final Map<UUID, Ticket> tickets = new ConcurrentHashMap<>();

    public GoodsBomBatchMaintenanceService(GoodsBomPasteService paste, GoodsBomService bom,
            GoodsRepository goods, GoodsBomItemRepository rows, GoodsBomGraphLock graph,
            GoodsBomHistoryPermissions history, MasterReferenceValidationPort references,
            MasterObjectAccess access, SecurityContextCurrentUser currentUser, TxSessionVars tx,
            NamedParameterJdbcTemplate db, EntityManager em, ObjectMapper json, Validator validator,
            PlatformTransactionManager manager) {
        this.paste=paste; this.bom=bom; this.goods=goods; this.rows=rows; this.graph=graph;
        this.history=history; this.references=references; this.access=access; this.currentUser=currentUser;
        this.tx=tx; this.db=db; this.em=em; this.json=json; this.validator=validator;
        transactions=new TransactionTemplate(manager);
        transactions.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }

    private record Scope(UUID actor, UUID session, UUID impersonator) { }
    private record State(Map<UUID, Goods> targets, Map<UUID, List<GoodsBomItem>> before, String fingerprint) { }
    private record Outcome(List<BomBatchMaintenancePreview.Target> targets,
            List<BomBatchMaintenancePreview.Product> products, int affectedCount,
            int otherUsageCount, int hiddenUsageCount, List<String> warnings) {
        int added() { return targets.stream().mapToInt(BomBatchMaintenancePreview.Target::added).sum(); }
        int updated() { return targets.stream().mapToInt(BomBatchMaintenancePreview.Target::updated).sum(); }
        int removed() { return targets.stream().mapToInt(BomBatchMaintenancePreview.Target::removed).sum(); }
        int skipped() { return targets.stream().mapToInt(BomBatchMaintenancePreview.Target::skipped).sum(); }
        int changedTargets() { return (int)targets.stream().filter(target->target.changes()>0).count(); }
    }
    private static final class Ticket {
        final BomBatchMaintenanceRequest request;
        final Scope scope;
        final String fingerprint;
        final Outcome outcome;
        final Instant expiresAt;
        BomBatchMaintenanceResult receipt;
        Ticket(BomBatchMaintenanceRequest request, Scope scope, String fingerprint, Outcome outcome) {
            this.request=request; this.scope=scope; this.fingerprint=fingerprint; this.outcome=outcome;
            expiresAt=Instant.now().plusSeconds(900);
        }
    }

    public BomBatchMaintenancePreview preview(BomBatchMaintenanceRequest requested) {
        Scope scope=scope();
        BomBatchMaintenanceRequest request=normalize(requested);
        requireAction(request.action());
        tickets.entrySet().removeIf(entry->!entry.getValue().expiresAt.isAfter(Instant.now()));
        if(tickets.size()>=1000)throw conflict("当前待确认的批量组装预览过多，请稍后重试");
        Ticket ticket=transactions.execute(status->{
            try {
                State state=lockedState(request);
                Outcome outcome=apply(request,state);
                return new Ticket(request,scope,state.fingerprint(),outcome);
            } finally { status.setRollbackOnly(); }
        });
        Objects.requireNonNull(ticket);
        UUID token=UUID.randomUUID(); tickets.put(token,ticket);
        Outcome result=ticket.outcome;
        return new BomBatchMaintenancePreview(token,request.action(),request.targetGoodsIds().size(),
                result.changedTargets(),result.added(),result.updated(),result.removed(),result.skipped(),
                result.targets(),result.products(),result.otherUsageCount(),result.hiddenUsageCount(),
                ticket.expiresAt,result.warnings());
    }

    public BomBatchMaintenanceResult commit(BomBatchMaintenanceCommit request) {
        Scope scope=scope();
        if(request==null||!validator.validate(request).isEmpty())throw invalid("缺少有效的预览确认记录");
        Ticket ticket=tickets.get(request.previewToken());
        if(ticket==null||!ticket.scope.equals(scope)||!ticket.expiresAt.isAfter(Instant.now()))
            throw conflict("批量组装预览已过期或登录会话已变化，请重新预览");
        requireAction(ticket.request.action());
        if(!Boolean.TRUE.equals(request.confirmSharedChanges()))throw conflict("请先确认本次组装修改及共享引用影响");
        synchronized(ticket) {
            if(ticket.receipt!=null) {
                // A successful receipt remains recoverable without replay, but never crosses a revoked data scope.
                return transactions.execute(status->{
                    ticket.request.targetGoodsIds().forEach(references::requireVisibleGoods);
                    return ticket.receipt;
                });
            }
            BomBatchMaintenanceResult result=transactions.execute(status->{
                State state=lockedState(ticket.request);
                if(!state.fingerprint().equals(ticket.fingerprint))
                    throw conflict("组装信息、相关资料或共享引用范围已变化，请重新预览；本次未保存");
                // The immutable request was fully simulated already. An identical no-op must not
                // publish the legacy REPLACE command's otherwise unconditional BOM-updated event.
                Outcome outcome=ticket.outcome.changedTargets()==0?ticket.outcome:apply(ticket.request,state);
                if(!ticket.outcome.equals(outcome))throw conflict("本次实际变化或提醒与预览不一致，请重新预览；本次未保存");
                if(outcome.changedTargets()>0)history.record(requiredPermissions(ticket.request.action()));
                return new BomBatchMaintenanceResult(ticket.request.action(),ticket.request.targetGoodsIds().size(),
                        outcome.changedTargets(),outcome.added(),outcome.updated(),outcome.removed(),outcome.skipped(),
                        outcome.targets(),outcome.affectedCount(),outcome.warnings());
            });
            ticket.receipt=Objects.requireNonNull(result);
            return result;
        }
    }

    private Scope scope() {
        CurrentAuthorityGuard.requireAll("goods:bom:edit");
        AuthUser user=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED,"当前登录状态无效"));
        if(user.isVisitor()||user.getImpersonatedBy()!=null)
            throw new ApiException(ErrorCode.FORBIDDEN,"当前身份不能维护货品组装信息");
        return new Scope(user.getId(),user.getSessionId(),user.getImpersonatedBy());
    }
    private void requireAction(BomBatchMaintenanceRequest.Action action) {
        CurrentAuthorityGuard.requireAll(requiredPermissions(action).toArray(String[]::new));
    }
    private Set<String> requiredPermissions(BomBatchMaintenanceRequest.Action action) {
        return switch(action) {
            case ADD -> Set.of("goods:bom:edit","goods:bom:create");
            case REMOVE -> Set.of("goods:bom:edit","goods:bom:delete");
            case OVERWRITE -> Set.of("goods:bom:edit","goods:bom:create","goods:bom:delete");
        };
    }
    private BomBatchMaintenanceRequest normalize(BomBatchMaintenanceRequest request) {
        if(request==null||!validator.validate(request).isEmpty())throw invalid("请选择 1 至 50 个货品及有效组件，添加或覆盖最多 200 项，移除最多 500 项");
        if(new HashSet<>(request.targetGoodsIds()).size()!=request.targetGoodsIds().size())throw invalid("目标货品重复，请重新选择");
        List<BomItemSaveRequest> items=request.items()==null?List.of():request.items();
        List<UUID> componentIds=request.componentGoodsIds()==null?List.of():request.componentGoodsIds();
        if(request.action()==BomBatchMaintenanceRequest.Action.REMOVE) {
            if(componentIds.isEmpty()||!items.isEmpty())throw invalid("批量移除只需选择要移除的组件身份");
            if(new HashSet<>(componentIds).size()!=componentIds.size())throw invalid("待移除组件重复，请重新选择");
        } else {
            if(items.isEmpty()||!componentIds.isEmpty())throw invalid("批量添加或整份覆盖需要填写组件清单");
            if(request.action()==BomBatchMaintenanceRequest.Action.OVERWRITE&&request.targetGoodsIds().size()!=1)
                throw invalid("整份覆盖一次只能操作一个货品，请改用批量添加或批量移除");
            Set<UUID> unique=new HashSet<>();
            for(BomItemSaveRequest item:items)if(!unique.add(item.getComponentGoodsId()))
                throw invalid("同一个组件不能重复填写，请合并后确认用量");
        }
        List<BomItemSaveRequest> frozen=new ArrayList<>();
        for(BomItemSaveRequest item:items) {
            ObjectNode node=json.valueToTree(item);
            if(!item.hasColorReference()){node.remove("colorId");node.remove("colorLegacyId");}
            if(!item.hasDefaultSupplierReference()){node.remove("defaultSupplierId");node.remove("vendLegacyId");}
            try { frozen.add(json.treeToValue(node,BomItemSaveRequest.class)); }
            catch(JsonProcessingException error){throw new IllegalArgumentException("无法读取组装组件清单",error);}
        }
        return new BomBatchMaintenanceRequest(request.action(),List.copyOf(request.targetGoodsIds()),
                List.copyOf(frozen),List.copyOf(componentIds));
    }

    private Set<UUID> componentIds(BomBatchMaintenanceRequest request) {
        if(request.action()==BomBatchMaintenanceRequest.Action.REMOVE)return new LinkedHashSet<>(request.componentGoodsIds());
        Set<UUID> ids=new LinkedHashSet<>();request.items().forEach(item->ids.add(item.getComponentGoodsId()));return ids;
    }
    private State lockedState(BomBatchMaintenanceRequest request) {
        Set<UUID> involved=new LinkedHashSet<>(request.targetGoodsIds()); involved.addAll(componentIds(request));
        for(Object[] edge:rows.findOperationalEdges(request.targetGoodsIds()))involved.add((UUID)edge[2]);
        Set<UUID> copiedItems=request.items()==null?Set.of():request.items().stream()
                .map(BomItemSaveRequest::getCopiedFromBomItemId).filter(Objects::nonNull)
                .collect(java.util.stream.Collectors.toSet());
        if(!copiedItems.isEmpty())for(Object[] edge:rows.findLiveItemParents(copiedItems))involved.add((UUID)edge[1]);
        // Same order as the canonical learning publisher and V739 trigger: all goods rows, then graph lock.
        goods.lockBomParents(involved);graph.acquire();references.lockGoodsQuantityBasis(involved);em.clear();
        Map<UUID,Goods> targets=new LinkedHashMap<>();
        Map<UUID,List<GoodsBomItem>> before=new LinkedHashMap<>();
        for(UUID id:request.targetGoodsIds()) {
            references.requireVisibleActiveGoods(id);
            Goods parent=goods.findById(id).orElseThrow(()->invalid("目标货品不存在"));targets.put(id,parent);
            List<GoodsBomItem> snapshot=new ArrayList<>();
            for(GoodsBomItem row:bom.operationalRows(id)) {
                GoodsBomItem clone=new GoodsBomItem();clone.setId(row.getId());clone.setGoods(parent);
                clone.setComponent(row.getComponent());clone.takeContentFrom(row);clone.setSortOrder(row.getSortOrder());snapshot.add(clone);
            }
            before.put(id,List.copyOf(snapshot));
        }
        for(UUID id:componentIds(request)) {
            if(request.action()==BomBatchMaintenanceRequest.Action.ADD)references.requireVisibleActiveGoods(id);
            else references.requireVisibleGoods(id);
            Goods component=goods.findById(id).orElseThrow(()->invalid("组件货品不存在"));
            if(component.isAutoCreated())throw invalid("迁移占位货品不能用于当前组装维护");
        }
        return new State(targets,before,fingerprint(request));
    }

    private Outcome apply(BomBatchMaintenanceRequest request,State state) {
        LinkedHashSet<String> warnings=new LinkedHashSet<>();
        Set<UUID> requested=componentIds(request);
        if(request.action()==BomBatchMaintenanceRequest.Action.ADD) {
            Map<List<UUID>,List<UUID>> groups=new LinkedHashMap<>();
            int additions=0;
            for(UUID parent:request.targetGoodsIds()) {
                Set<UUID> present=new HashSet<>();state.before().get(parent).forEach(row->present.add(row.getComponent().getId()));
                List<UUID> missing=requested.stream().filter(id->!present.contains(id)).toList();
                additions+=missing.size();
                if(!missing.isEmpty())groups.computeIfAbsent(missing,ignored->new ArrayList<>()).add(parent);
            }
            requireLimit(additions);
            for(var group:groups.entrySet()) {
                List<BomItemSaveRequest> items=request.items().stream().filter(item->group.getKey().contains(item.getComponentGoodsId())).toList();
                BomPasteResult result=paste.paste(new BomPasteRequest(BomPasteRequest.Mode.APPEND,
                        group.getValue().stream().map(id->new BomPasteRequest.Target(id,null)).toList(),items));
                warnings.addAll(result.warnings());
            }
        } else if(request.action()==BomBatchMaintenanceRequest.Action.REMOVE) {
            int removals=state.before().values().stream().mapToInt(list->(int)list.stream().filter(row->requested.contains(row.getComponent().getId())).count()).sum();
            requireLimit(removals);
            for(UUID parent:request.targetGoodsIds()) {
                List<UUID> ids=state.before().get(parent).stream().filter(row->requested.contains(row.getComponent().getId())).map(GoodsBomItem::getId).toList();
                if(!ids.isEmpty()){bom.deleteAll(parent,ids);em.flush();em.clear();}
            }
        } else {
            UUID parent=request.targetGoodsIds().getFirst();
            long removing=state.before().get(parent).stream().filter(row->!requested.contains(row.getComponent().getId())).count();
            requireLimit((int)removing);
            BomPasteResult result=paste.paste(new BomPasteRequest(BomPasteRequest.Mode.REPLACE,
                    List.of(new BomPasteRequest.Target(parent,null)),request.items()));
            warnings.addAll(result.warnings());
            // REPLACE also updates existing periodic edges; the original paste result only reports newly created edges.
            for(GoodsBomItem row:bom.operationalRows(parent))warnings.addAll(GoodsBomService.periodicWarnings(row.getGoods(),row.getComponent(),row));
        }
        em.flush();
        List<BomBatchMaintenancePreview.Target> targets=new ArrayList<>();
        Set<UUID> changed=new LinkedHashSet<>();
        int actual=0;
        for(UUID parent:request.targetGoodsIds()) {
            Map<UUID,GoodsBomItem> prior=index(state.before().get(parent)),after=index(bom.operationalRows(parent));
            int added=0,updated=0,removed=0,skipped=0;
            if(request.action()==BomBatchMaintenanceRequest.Action.REMOVE) {
                for(UUID id:requested)if(prior.containsKey(id))removed++;else skipped++;
            } else {
                for(UUID id:requested) {
                    GoodsBomItem old=prior.get(id),now=after.get(id);
                    if(old==null)added++;
                    else if(request.action()==BomBatchMaintenanceRequest.Action.OVERWRITE
                            &&(!old.sameContentAs(now)||!Objects.equals(old.getSortOrder(),now.getSortOrder())))updated++;
                    else skipped++;
                }
                if(request.action()==BomBatchMaintenanceRequest.Action.OVERWRITE)
                    removed=(int)prior.keySet().stream().filter(id->!requested.contains(id)).count();
            }
            Goods target=state.targets().get(parent);
            var row=new BomBatchMaintenancePreview.Target(parent,target.getCode(),target.getName(),added,updated,removed,skipped);
            targets.add(row);actual+=row.changes();if(row.changes()>0)changed.add(parent);
        }
        requireLimit(actual);
        return outcome(request,List.copyOf(targets),changed,List.copyOf(warnings));
    }
    private Map<UUID,GoodsBomItem> index(List<GoodsBomItem> list) {
        Map<UUID,GoodsBomItem> indexed=new LinkedHashMap<>();list.forEach(row->indexed.put(row.getComponent().getId(),row));return indexed;
    }

    private Outcome outcome(BomBatchMaintenanceRequest request,List<BomBatchMaintenancePreview.Target> targets,
                            Set<UUID> changed,List<String> warnings) {
        if(changed.isEmpty())return new Outcome(targets,List.of(),0,0,0,warnings);
        List<Map<String,Object>> ancestors=db.queryForList("""
                WITH RECURSIVE affected(id) AS (
                    SELECT id FROM goods WHERE id IN(:parents)
                    UNION SELECT b.goods_id FROM affected a JOIN goods_bom_items b ON b.component_goods_id=a.id
                        JOIN goods p ON p.id=b.goods_id
                    WHERE NOT b.is_deleted AND NOT p.is_deleted AND NOT p.auto_created
                ) SELECT g.id,g.code,g.name,g.owner_employee_id FROM affected a JOIN goods g ON g.id=a.id ORDER BY g.code,g.id
                """,Map.of("parents",changed));
        Predicate<UUID> visible=access.visibleGoodsOwner();Set<UUID> selected=new HashSet<>(request.targetGoodsIds());
        List<BomBatchMaintenancePreview.Product> products=new ArrayList<>();int others=0,hidden=0;
        for(Map<String,Object> row:ancestors) {
            UUID id=(UUID)row.get("id");boolean isSelected=selected.contains(id);
            if(!isSelected)others++;
            if(visible.test((UUID)row.get("owner_employee_id")))products.add(new BomBatchMaintenancePreview.Product(
                    id,(String)row.get("code"),(String)row.get("name"),isSelected));
            else hidden++;
        }
        return new Outcome(targets,List.copyOf(products),ancestors.size(),others,hidden,warnings);
    }

    private String fingerprint(BomBatchMaintenanceRequest request) {
        Set<UUID> requested=componentIds(request);
        Set<UUID> colorIds=new HashSet<>(),supplierIds=new HashSet<>();
        for(BomItemSaveRequest item:request.items()) {
            if(item.getColorId()!=null)colorIds.add(item.getColorId());
            if(item.getDefaultSupplierId()!=null)supplierIds.add(item.getDefaultSupplierId());
        }
        String state=db.queryForObject("""
                WITH edges AS (SELECT * FROM goods_bom_items WHERE goods_id IN(:parents) AND NOT is_deleted),
                involved AS (SELECT id,version,updated_at,code,name,status,is_deleted,auto_created,owner_employee_id,
                    unit_id,unit_legacy_id,color_id,color_legacy_id,issue_method,periodic_cost_basis,price,source_type,
                    m_weight,m_weight_unit_id,m_weight_unit_legacy_id FROM goods
                    WHERE id IN(:parents) OR id IN(:components) OR id IN(SELECT component_goods_id FROM edges)),
                relevant_units AS (SELECT * FROM units WHERE id IN(SELECT unit_id FROM involved UNION SELECT m_weight_unit_id FROM involved)
                    OR legacy_id IN(SELECT unit_legacy_id FROM involved UNION SELECT m_weight_unit_legacy_id FROM involved))
                SELECT jsonb_build_object(
                    'goods',(SELECT jsonb_agg(to_jsonb(g) ORDER BY g.id) FROM involved g),
                    'edges',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM edges e),
                    'usage',(SELECT jsonb_agg(to_jsonb(u) ORDER BY u.bom_item_id) FROM v_goods_bom_item_usage u WHERE u.bom_item_id IN(SELECT id FROM edges)),
                    'colors',(SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id) FROM colors c WHERE c.id IN(:colors)
                        OR c.id IN(SELECT color_id FROM involved UNION SELECT color_id FROM edges)
                        OR c.legacy_id IN(SELECT color_legacy_id FROM involved UNION SELECT color_legacy_id FROM edges)),
                    'units',(SELECT jsonb_agg(to_jsonb(u) ORDER BY u.id) FROM relevant_units u),
                    'unitProfiles',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.unit_id) FROM unit_measurement_profiles p WHERE p.unit_id IN(SELECT id FROM relevant_units)),
                    'suppliers',(SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) FROM suppliers s WHERE s.id IN(:suppliers)
                        OR s.id IN(SELECT default_supplier_id FROM edges) OR s.legacy_id IN(SELECT vend_legacy_id FROM edges)),
                    'topology',(SELECT md5(COALESCE(string_agg(b.id::text||':'||b.goods_id::text||':'||b.component_goods_id::text,',' ORDER BY b.id),''))
                        FROM goods_bom_items b JOIN goods p ON p.id=b.goods_id JOIN goods c ON c.id=b.component_goods_id
                        WHERE NOT b.is_deleted AND NOT p.is_deleted AND NOT c.is_deleted AND NOT p.auto_created AND NOT c.auto_created)
                )::text
                """,Map.of("parents",request.targetGoodsIds(),"components",requested,
                "colors",colorIds.isEmpty()?Set.of(NO_ID):colorIds,"suppliers",supplierIds.isEmpty()?Set.of(NO_ID):supplierIds),String.class);
        return tx.hmac("goods-bom-batch-maintenance:v1\n"+state);
    }
    private void requireLimit(int changes) {
        if(changes>MAX_CHANGES)throw invalid("本次实际变化超过 2000 条组装关系，请减少所选货品或组件后分批操作");
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
