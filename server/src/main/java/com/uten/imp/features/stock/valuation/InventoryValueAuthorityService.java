package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryValueAuthorityPort;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.annotation.Propagation;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.stock.valuation.InventoryValueLedger.args;
import static com.uten.imp.features.stock.valuation.ValueMath.*;

/** Read and refine one existing expression; this service does not post money or physical stock. */
@Service
public class InventoryValueAuthorityService implements InventoryValueAuthorityPort {
    private final NamedParameterJdbcTemplate db;
    private final ValueAuthorityStore store;
    // Optional bounded acceleration only. Every entry is tied to an immutable
    // node/revision; losing this cache merely requires replaying dependency work.
    private final Map<ValueReference,ValueBounds> refined=Collections.synchronizedMap(new LinkedHashMap<>(128,.75f,true){
        @Override protected boolean removeEldestEntry(Map.Entry<ValueReference,ValueBounds> eldest){return size()>10000;}
    });
    public InventoryValueAuthorityService(NamedParameterJdbcTemplate db){this.db=db;this.store=new ValueAuthorityStore(db);}

    @Override @Transactional(readOnly=true)
    public Authority authority(ValueReference ref){
        valid(ref);if(!store.installed)return new Authority(ref,null,null,0,false,Readiness.LEGACY_UNVERIFIED,List.of());
        Map<String,Object> node=store.current(ref.nodeId());ValueBounds bounds=best(ref);
        boolean legacy=!"EXACT_SOURCE_SHARES".equals(node.get("value_model"));
        boolean complete=complete(ref,node);
        return new Authority(ref,ValueAuthorityStore.lower(bounds),ValueAuthorityStore.upper(bounds),
                bounds==null?0:bounds.scale(),complete,legacy?Readiness.LEGACY_UNVERIFIED:
                    bounds==null?Readiness.PENDING_DEPENDENCIES:Readiness.READY,bounds==null?dependencies(ref):List.of());
    }

    @Override @Transactional(propagation=Propagation.NEVER)
    public Authority refine(ValueReference ref,int requestedScale){
        valid(ref);if(requestedScale<16||requestedScale>256)throw invalid("精度验证范围为16到256位");
        if(!store.installed)return authority(ref);
        Map<String,Object> node=store.current(ref.nodeId());
        if(!"EXACT_SOURCE_SHARES".equals(node.get("value_model")))return authority(ref);
        List<ValueReference> waiting=new ArrayList<>();ValueBounds result;
        if(ref.revision()==1){
            if("SOURCE".equals(node.get("kind"))){
                BigDecimal actual=(BigDecimal)node.get("source_initial_amount_exact");
                result=actual==null?null:ValueBounds.exact(actual);
            }else{
                var parents=db.queryForList("SELECT * FROM stock_value_edges WHERE child_node_id=:id ORDER BY id LIMIT 101",args("id",ref.nodeId()));
                if(parents.size()>100)throw conflict("单个金额表达式超过有界来源数，请核对结构");result=ValueBounds.exact(BigDecimal.ZERO);
                for(var edge:parents){ValueReference parent=new ValueReference((UUID)edge.get("parent_node_id"),((Number)edge.get("initial_parent_revision")).longValue());
                    ValueBounds bound=dependency(parent,requestedScale,waiting);
                    if(bound==null){result=null;continue;}
                    if(result!=null)result=result.add(bound.weighted((BigDecimal)edge.get("interval_from"),(BigDecimal)edge.get("interval_to"),
                            (BigDecimal)edge.get("denominator"),requestedScale));}
            }
        }else{
            var rows=db.queryForList("SELECT * FROM stock_value_node_revisions WHERE node_id=:id AND revision=:revision",args("id",ref.nodeId(),"revision",ref.revision()));
            if(rows.size()!=1)throw conflict("金额引用版本不存在");var revision=rows.getFirst();
            ValueBounds before=dependency(new ValueReference(ref.nodeId(),ref.revision()-1),requestedScale,waiting);
            if(revision.get("task_id")!=null){
                var task=db.queryForMap("SELECT t.parent_revision,e.* FROM stock_value_tasks t JOIN stock_value_edges e ON e.id=t.edge_id WHERE t.id=:id",args("id",revision.get("task_id")));
                long parentRevision=((Number)task.get("parent_revision")).longValue();UUID parent=(UUID)task.get("parent_node_id");
                ValueBounds next=dependency(new ValueReference(parent,parentRevision),requestedScale,waiting),old=dependency(new ValueReference(parent,parentRevision-1),requestedScale,waiting);
                result=before==null||next==null||old==null?null:before.subtract(old.weighted((BigDecimal)task.get("interval_from"),(BigDecimal)task.get("interval_to"),(BigDecimal)task.get("denominator"),requestedScale))
                        .add(next.weighted((BigDecimal)task.get("interval_from"),(BigDecimal)task.get("interval_to"),(BigDecimal)task.get("denominator"),requestedScale));
            }else{
                var event=db.queryForMap("SELECT * FROM stock_value_events WHERE id=:id",args("id",revision.get("event_id")));
                if(event.get("source_delta_exact")!=null)result=before==null?null:before.add(ValueBounds.exact((BigDecimal)event.get("source_delta_exact")));
                else if("COST_ALLOCATE".equals(event.get("operation"))){
                    var task=db.queryForMap("SELECT previous_task_id FROM stock_value_production_cost_tasks WHERE id=:id",args("id",event.get("id")));
                    ValueBounds next=store.productionShare((UUID)event.get("id"),r->dependency(r,requestedScale,waiting),requestedScale),
                            old=task.get("previous_task_id")==null?ValueBounds.exact(BigDecimal.ZERO):store.productionShare((UUID)task.get("previous_task_id"),r->dependency(r,requestedScale,waiting),requestedScale);
                    result=before==null||next==null||old==null?null:before.subtract(old).add(next);
                }else result=null;
            }
        }
        if(result!=null)refined.put(ref,result);
        return new Authority(ref,ValueAuthorityStore.lower(result),ValueAuthorityStore.upper(result),result==null?requestedScale:result.scale(),
                complete(ref,node),result==null?Readiness.PENDING_DEPENDENCIES:Readiness.READY,List.copyOf(new LinkedHashSet<>(waiting)));
    }

    private ValueBounds dependency(ValueReference ref,int scale,List<ValueReference> waiting){ValueBounds b=best(ref);
        if(b==null||(!b.isExact()&&b.scale()<scale)){waiting.add(ref);return null;}return b;}
    private ValueBounds best(ValueReference ref){ValueBounds saved=store.bound(ref),memo=refined.get(ref);
        return memo!=null&&(saved==null||memo.isExact()||memo.scale()>saved.scale())?memo:saved;}
    private List<ValueReference> dependencies(ValueReference ref){
        if(ref.revision()==1)return db.query("SELECT parent_node_id,initial_parent_revision FROM stock_value_edges WHERE child_node_id=:id ORDER BY id LIMIT 100",args("id",ref.nodeId()),
                (r,i)->new ValueReference(r.getObject(1,UUID.class),r.getLong(2)));
        return List.of(new ValueReference(ref.nodeId(),ref.revision()-1));
    }
    private boolean complete(ValueReference ref,Map<String,Object> node){
        if(ref.revision()==((Number)node.get("revision")).longValue())return ((Number)node.get("pending_parents")).intValue()==0
                &&!Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM stock_value_jobs WHERE status='PENDING') OR EXISTS(SELECT 1 FROM stock_value_production_cost_tasks WHERE status='PENDING') OR EXISTS(SELECT 1 FROM stock_value_production_cost_dirty WHERE observed_revision>cleared_revision)",Map.of(),Boolean.class));
        if(ref.revision()==1)return ((Number)node.get("initial_pending")).intValue()==0;
        Integer pending=db.queryForObject("SELECT after_pending FROM stock_value_node_revisions WHERE node_id=:id AND revision=:revision",args("id",ref.nodeId(),"revision",ref.revision()),Integer.class);
        return pending!=null&&pending==0;
    }
    private static void valid(ValueReference ref){if(ref==null||ref.nodeId()==null||ref.revision()<1)throw invalid("精确金额引用无效");}
}
