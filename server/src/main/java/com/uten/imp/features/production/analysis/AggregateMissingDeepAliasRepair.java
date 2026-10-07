package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Completes missing historical descendant edges without changing any recorded alias.
 * Called only within the analysis command's complete mutation lock. The existing first
 * edge is the proof of the parent's transferred responsibility; a claim is never that proof. */
@Service
@RequiredArgsConstructor
public class AggregateMissingDeepAliasRepair {
    private final EntityManager em;
    private final ObjectMapper mapper;
    private final SecurityContextCurrentUser user;
    private final PreplanStockEntitlementService entitlements;

    @Transactional(propagation=Propagation.MANDATORY)
    public void repair(UUID analysisId, Set<UUID> originalIds) {
        if (originalIds == null || originalIds.isEmpty()) return;
        List<Object[]> batchRows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT batch.id,batch.action_id,batch.anchor_analysis_item_id,batch.row_version,
                    action.requested_qty+action.public_surplus_qty,allocation.analysis_material_id,allocation.allocated_qty
                FROM preplan_aggregate_batches batch
                JOIN preplan_supply_actions action ON action.id=batch.action_id AND action.status<>'CANCELLED'
                JOIN preplan_supply_action_allocations allocation ON allocation.action_id=action.id
                  AND allocation.external_item_id=batch.anchor_analysis_item_id AND allocation.allocated_qty>0
                JOIN production_material_analysis_items anchor ON anchor.id=batch.anchor_analysis_item_id
                  AND NOT anchor.is_deleted AND anchor.source_type='AGGREGATE_MAKE'
                WHERE batch.analysis_id=:analysis AND batch.anchor_analysis_item_id IS NOT NULL
                ORDER BY batch.created_at,batch.id,allocation.analysis_material_id
                FOR UPDATE OF batch,action,allocation
                """).setParameter("analysis",analysisId));
        if (batchRows.isEmpty()) return;
        Map<UUID,Batch> batches=new LinkedHashMap<>();
        for(Object[] row:batchRows) {
            Batch batch=batches.computeIfAbsent((UUID)row[0],id->new Batch(id,(UUID)row[1],(UUID)row[2],
                    ((Number)row[3]).longValue(),number(row[4]),new LinkedHashMap<>()));
            batch.parents.put((UUID)row[5],number(row[6]));
        }
        Map<UUID,Material> materials=loadMaterials(analysisId);
        if(!materials.keySet().containsAll(originalIds)) throw conflict("原物料来源已失效，请刷新后重试");
        Map<UUID,List<Material>> byItem=new HashMap<>();
        Map<UUID,Map<String,Material>> nodesByItem=new HashMap<>();
        for(Material material:materials.values())byItem.computeIfAbsent(material.item,ignored->new ArrayList<>()).add(material);
        for(Material material:materials.values())if(material.node!=null&&nodesByItem.computeIfAbsent(material.item,ignored->new HashMap<>())
                .putIfAbsent(material.node,material)!=null)throw conflict("历史BOM节点身份存在歧义");
        Map<Edge,Alias> aliases=new HashMap<>();
        Map<UUID,BigDecimal> outgoing=new HashMap<>(),incoming=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT alias.batch_id,alias.source_material_id,alias.aggregate_material_id,
                    fn_preplan_aggregate_alias_qty(alias.id)
                FROM preplan_aggregate_material_aliases alias
                JOIN preplan_aggregate_batches batch ON batch.id=alias.batch_id
                WHERE batch.analysis_id=:analysis AND fn_preplan_aggregate_alias_identity_valid(alias.id)
                """).setParameter("analysis",analysisId))) {
            UUID source=(UUID)row[1],target=(UUID)row[2];BigDecimal qty=number(row[3]);
            aliases.put(new Edge((UUID)row[0],source),new Alias(target,qty));
            outgoing.merge(source,qty,BigDecimal::add);incoming.merge(target,qty,BigDecimal::add);
        }
        Set<UUID> reachable=new HashSet<>(originalIds);
        // These quantities were already privately committed before the old parent
        // merge. Restoring their missing path does not claim or order new supply.
        materials.values().stream().filter(material->material.owned.signum()>0).map(Material::id).forEach(reachable::add);
        expandReachable(reachable,aliases);
        List<Insertion> inserts=new ArrayList<>();
        for(Batch batch:batches.values()) {
            Map<List<UUID>,Material> targets=paths(byItem.getOrDefault(batch.anchor,List.of()),null,false);
            Map<List<UUID>,List<Member>> members=new HashMap<>();
            for(UUID parentId:batch.parents.keySet()) {
                Material parent=materials.get(parentId);
                if(parent==null)throw conflict("历史合单的原父件不存在");
                for(var path:paths(byItem.getOrDefault(parent.item,List.of()),parent,true).entrySet())
                    members.computeIfAbsent(path.getKey(),ignored->new ArrayList<>()).add(new Member(parentId,path.getValue()));
            }
            List<List<UUID>> ordered=new ArrayList<>(targets.keySet());
            ordered.sort(Comparator.<List<UUID>>comparingInt(List::size).thenComparing(Object::toString));
            Map<List<UUID>,BigDecimal> targetOutputs=new HashMap<>();
            Map<UUID,BigDecimal> proven=new HashMap<>();
            for(List<UUID> path:ordered) {
                Material target=targets.get(path);
                List<UUID> prefix=path.subList(0,path.size()-1);
                BigDecimal targetOutput=required(path.size()==1?batch.output:targetOutputs.get(prefix),target);
                targetOutputs.put(path,targetOutput);
                List<Member> exact=members.getOrDefault(path,List.of());
                List<Candidate> candidates=new ArrayList<>();
                for(Member member:exact) {
                    Material source=member.material;
                    if(!Objects.equals(source.goods,target.goods)||!Objects.equals(source.color,target.color)||!Objects.equals(source.unit,target.unit))
                        throw conflict("历史合单的BOM来源身份已改变");
                    Alias existing=aliases.get(new Edge(batch.id,source.id));
                    if(existing!=null) {
                        if(!existing.target.equals(target.id))throw conflict("历史BOM别名与真实路径不一致");
                        proven.put(source.id,existing.qty);
                        continue;
                    }
                    // A missing direct edge has no original release proof. Repair only
                    // descendants of a positive, recorded prefix (or this exact repair).
                    if(path.size()==1)continue;
                    Material parent=nodesByItem.getOrDefault(source.item,Map.of()).get(source.parent);
                    BigDecimal parentQuota=parent==null?BigDecimal.ZERO:proven.getOrDefault(parent.id,BigDecimal.ZERO);
                    if(parentQuota.signum()<=0)continue;
                    BigDecimal parentOutgoing=outgoing.getOrDefault(parent.id,BigDecimal.ZERO).max(parentQuota);
                    BigDecimal retained=parent.required.max(parent.sourceCapacity.subtract(parentOutgoing).max(BigDecimal.ZERO));
                    BigDecimal childRetained=required(retained,source);
                    BigDecimal released=required(retained.add(parentQuota),source).subtract(childRetained).max(BigDecimal.ZERO);
                    BigDecimal allReleased=required(retained.add(parentOutgoing),source).subtract(childRetained).max(BigDecimal.ZERO);
                    BigDecimal free=allReleased.subtract(outgoing.getOrDefault(source.id,BigDecimal.ZERO)).max(BigDecimal.ZERO).min(released);
                    candidates.add(new Candidate(member,free,childRetained));
                }
                if(candidates.isEmpty())continue;
                BigDecimal capacity=target.capacity.max(target.sourceCapacity).max(target.required).min(targetOutput);
                BigDecimal remaining=capacity.subtract(incoming.getOrDefault(target.id,BigDecimal.ZERO)).max(BigDecimal.ZERO);
                BigDecimal total=candidates.stream().map(Candidate::available).reduce(BigDecimal.ZERO,BigDecimal::add).min(remaining);
                var split=AggregateQuantityAllocator.allocate(total,candidates.stream().map(candidate->
                        new AggregateQuantityAllocator.SourceCapacity(candidate.member.material.id,
                                materials.get(candidate.member.parent).priority,materials.get(candidate.member.parent).deliveryDate,
                                candidate.available)).toList(),false);
                Map<UUID,BigDecimal> quantities=new HashMap<>();
                split.allocations().forEach(part->quantities.put(part.sourceId(),part.qty()));
                for(Candidate candidate:candidates) {
                    Material source=candidate.member.material;
                    BigDecimal qty=quantities.getOrDefault(source.id,BigDecimal.ZERO);
                    proven.put(source.id,qty);
                    if(qty.signum()<=0||!reachable.contains(source.id))continue;
                    BigDecimal sourceCapacity=source.required.max(candidate.retained).add(outgoing.getOrDefault(source.id,BigDecimal.ZERO)).add(qty)
                            .max(source.owned).max(source.historicCapacity);
                    inserts.add(new Insertion(batch,candidate.member.parent,source.id,target.id,path,qty,sourceCapacity,capacity));
                    aliases.put(new Edge(batch.id,source.id),new Alias(target.id,qty));
                    outgoing.merge(source.id,qty,BigDecimal::add);incoming.merge(target.id,qty,BigDecimal::add);
                    reachable.add(target.id);
                }
                expandReachable(reachable,aliases);
            }
        }
        if(inserts.isEmpty())return;
        var payload=mapper.createArrayNode();
        for(Insertion insert:inserts) {
            var row=payload.addObject();row.put("batch_id",insert.batch.id.toString());row.put("parent_id",insert.parent.toString());
            row.put("source_id",insert.source.toString());row.put("target_id",insert.target.toString());
            row.put("edge_path",String.join("/",insert.path.stream().map(UUID::toString).toList()));
            row.put("qty",insert.qty);row.put("source_capacity",insert.sourceCapacity);row.put("canonical_capacity",insert.targetCapacity);
        }
        em.createNativeQuery("""
                INSERT INTO preplan_aggregate_material_aliases(batch_id,source_parent_material_id,source_material_id,
                    aggregate_material_id,relative_bom_path,qty,source_capacity_qty,canonical_capacity_qty,capacity_version,created_by)
                SELECT batch.id,input.parent_id,input.source_id,input.target_id,string_to_array(input.edge_path,'/')::uuid[],
                    input.qty,input.source_capacity,input.canonical_capacity,batch.row_version,:actor
                FROM jsonb_to_recordset(CAST(:rows AS jsonb)) input(batch_id uuid,parent_id uuid,source_id uuid,target_id uuid,
                    edge_path text,qty numeric,source_capacity numeric,canonical_capacity numeric)
                JOIN preplan_aggregate_batches batch ON batch.id=input.batch_id AND batch.analysis_id=:analysis
                ORDER BY batch.created_at,batch.id,input.source_id
                """).setParameter("rows",payload.toString()).setParameter("actor",user.requireId()).setParameter("analysis",analysisId).executeUpdate();
        // Origins received before the bridge was completed must move now as well.
        // Existing delegate guards retain formalized/consumed and old private responsibility.
        for(int depth=0;depth<256;depth++) {
            BigDecimal moved=BigDecimal.ZERO;
            for(Batch batch:batches.values())moved=moved.add(entitlements.delegateAggregateMakeEntitlements(analysisId,batch.action));
            if(moved.signum()==0)return;
        }
        throw conflict("历史合单权益链超过允许层级");
    }

    private Map<UUID,Material> loadMaterials(UUID analysisId) {
        Map<UUID,Material> result=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT material.id,material.analysis_item_id,material.node_key,material.parent_node_key,material.node_role,
                    material.bom_item_id,material.confirmed_route,material.required_qty,material.bom_qty,material.consumption_basis,
                    material.basis_output_qty,material.allow_partial_package,material.goods_id,material.color_id,material.unit_id,
                    fn_preplan_aggregate_source_capacity(material.id),fn_preplan_aggregate_material_capacity(material.id),
                    COALESCE((SELECT MAX(fn_preplan_aggregate_alias_source_capacity(alias.id)) FROM preplan_aggregate_material_aliases alias
                        WHERE alias.source_material_id=material.id AND fn_preplan_aggregate_alias_identity_valid(alias.id)),0),
                    fn_preplan_aggregate_material_pending_qty(material.id)+fn_preplan_aggregate_target_committed_qty(material.id),
                    EXISTS(SELECT 1 FROM production_material_analysis_items child
                        JOIN production_material_analysis_plan_links link ON link.analysis_item_id=child.id
                          AND link.allocation_status IN('SUBMITTED','APPROVED')
                        JOIN production_plans plan ON plan.id=link.plan_id AND plan.status IN(0,1)
                          AND NOT plan.is_deleted AND NOT plan.is_canceled
                        WHERE child.parent_analysis_material_id=material.id AND NOT child.is_deleted
                          AND child.source_type<>'AGGREGATE_MAKE'),material.depth,item.line_priority,item.delivery_date,
                    material.source_suggestion
                FROM production_material_analysis_materials material
                JOIN production_material_analysis_items item ON item.id=material.analysis_item_id
                WHERE material.analysis_id=:analysis AND material.active
                """).setParameter("analysis",analysisId))) {
            Material value=new Material((UUID)row[0],(UUID)row[1],(String)row[2],(String)row[3],(String)row[4],(UUID)row[5],
                    (String)row[6],number(row[7]),number(row[8]),(String)row[9],number(row[10]),Boolean.TRUE.equals(row[11]),
                    (UUID)row[12],(UUID)row[13],(UUID)row[14],number(row[15]),number(row[16]),number(row[17]),number(row[18]),
                    Boolean.TRUE.equals(row[19]),((Number)row[20]).intValue(),((Number)row[21]).intValue(),date(row[22]),(String)row[23]);
            result.put(value.id,value);
        }
        return result;
    }

    private static Map<List<UUID>,Material> paths(List<Material> items,Material root,boolean freeze) {
        Map<List<UUID>,Material> result=new LinkedHashMap<>();
        Map<String,List<Material>> children=new HashMap<>();
        for(Material row:items)if("BOM_COMPONENT".equals(row.role))
            children.computeIfAbsent(row.parent,ignored->new ArrayList<>()).add(row);
        record Walk(Material material,List<UUID> path,Set<UUID> visited){}
        ArrayDeque<Walk> queue=new ArrayDeque<>();
        for(Material row:items)if("BOM_COMPONENT".equals(row.role)&&
                (root==null||"ROOT_SUPPLY".equals(root.role)?row.depth==1:Objects.equals(row.parent,root.node)))
            queue.add(new Walk(row,List.of(row.edge),Set.of(row.id)));
        while(!queue.isEmpty()) {
            Walk walk=queue.removeFirst();
            if(result.putIfAbsent(walk.path,walk.material)!=null)throw conflict("历史BOM路径存在歧义");
            // 子树转发判定统一走 AggregateRouteForwarding(与需求侧/供给侧同口径)。
            if(freeze&&(!AggregateRouteForwarding.forwardsSubtree(walk.material.route,walk.material.suggestion)||walk.material.frozen))continue;
            for(Material child:children.getOrDefault(walk.material.node,List.of())) {
                if(walk.visited.contains(child.id)||walk.path.size()>=256)throw conflict("历史BOM路径循环或层级超过256");
                List<UUID> next=new ArrayList<>(walk.path);next.add(child.edge);Set<UUID> visited=new HashSet<>(walk.visited);visited.add(child.id);
                queue.add(new Walk(child,List.copyOf(next),visited));
            }
        }
        return result;
    }
    private static void expandReachable(Set<UUID> reachable,Map<Edge,Alias> aliases) {
        boolean changed;
        do {changed=false;for(var edge:aliases.entrySet())if(edge.getValue().qty.signum()>0&&reachable.contains(edge.getKey().source))
            changed|=reachable.add(edge.getValue().target);
        } while(changed);
    }
    private static BigDecimal required(BigDecimal output,Material material) {
        if(output==null)throw conflict("历史BOM路径缺少父层责任");
        try{return MaterialConsumptionMath.required(output,material.bomQty,material.basis,material.basisOutput,material.partial);}
        catch(IllegalArgumentException invalid){throw conflict("历史BOM用量规则失效，请核对后重试");}
    }
    private static BigDecimal number(Object value){return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static LocalDate date(Object value){return value==null?null:value instanceof LocalDate date?date:
            value instanceof java.sql.Date sqlDate?sqlDate.toLocalDate():LocalDate.parse(value.toString());}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private record Batch(UUID id,UUID action,UUID anchor,long version,BigDecimal output,Map<UUID,BigDecimal> parents){}
    private record Material(UUID id,UUID item,String node,String parent,String role,UUID edge,String route,BigDecimal required,
                            BigDecimal bomQty,String basis,BigDecimal basisOutput,boolean partial,UUID goods,UUID color,UUID unit,
                            BigDecimal sourceCapacity,BigDecimal capacity,BigDecimal historicCapacity,BigDecimal owned,boolean frozen,int depth,
                            int priority,LocalDate deliveryDate,String suggestion){}
    private record Edge(UUID batch,UUID source){}
    private record Alias(UUID target,BigDecimal qty){}
    private record Member(UUID parent,Material material){}
    private record Candidate(Member member,BigDecimal available,BigDecimal retained){}
    private record Insertion(Batch batch,UUID parent,UUID source,UUID target,List<UUID> path,BigDecimal qty,
                             BigDecimal sourceCapacity,BigDecimal targetCapacity){}
}
