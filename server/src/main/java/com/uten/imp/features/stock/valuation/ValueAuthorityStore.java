package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryValueAuthorityPort.ValueReference;
import com.uten.imp.common.util.FinancialExactAmount;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.stock.valuation.InventoryValueLedger.args;
import static com.uten.imp.features.stock.valuation.ValueMath.conflict;

/** Existing value expressions with bounded, non-authoritative numerical caches. */
final class ValueAuthorityStore {
    private final NamedParameterJdbcTemplate db;
    final boolean installed;
    ValueAuthorityStore(NamedParameterJdbcTemplate db){
        this.db=db;
        installed=Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=to_regclass('public.stock_value_nodes')
                    AND attname='source_amount_exact' AND NOT attisdropped)
                """,Map.of(),Boolean.class));
    }

    void initialSource(UUID id,BigDecimal actual){
        if(!installed)return;actual=FinancialExactAmount.book(actual,"取得本币原额");
        if(actual.signum()<0)throw conflict("取得原额不能为负");
        if(db.update("""
                UPDATE stock_value_nodes SET source_initial_amount_exact=:value,source_amount_exact=:value,
                    initial_bound_lower=:value,initial_bound_upper=:value,bound_lower=:value,bound_upper=:value,
                    initial_bound_scale=32,bound_scale=32
                WHERE id=:id AND kind='SOURCE' AND revision=1 AND creation_txid=txid_current()
                """,args("id",id,"value",actual))!=1)throw conflict("取得来源初始化必须属于本次新建节点");
    }

    Change sourceChange(UUID id,BigDecimal delta){
        if(!installed)return null;Map<String,Object> row=current(id);BigDecimal before=(BigDecimal)row.get("source_amount_exact");
        if(before==null)throw conflict("旧来源尚未确认未裁剪原额，不能用显示金额追加或冲减实际成本");
        BigDecimal after=FinancialExactAmount.book(before.add(delta),"取得累计本币原额");
        if(after.signum()<0)throw conflict("冲减超过该实际资金来源剩余额");
        ValueBounds previous=from(row,"bound_lower","bound_upper","bound_scale");
        ValueBounds next=previous==null?null:previous.add(ValueBounds.exact(delta));
        return new Change(previous,next,before,after,null);
    }

    Change edgeChange(UUID childId,UUID taskId){
        if(!installed)return null;
        Map<String,Object> t=db.queryForMap("""
                SELECT t.parent_revision,e.id edge_id,e.parent_node_id,e.interval_from,e.interval_to,e.denominator,
                    e.allocated_bound_lower,e.allocated_bound_upper,e.bound_scale
                FROM stock_value_tasks t JOIN stock_value_edges e ON e.id=t.edge_id WHERE t.id=:id
                """,args("id",taskId));
        ValueBounds parent=bound(new ValueReference((UUID)t.get("parent_node_id"),((Number)t.get("parent_revision")).longValue()));
        ValueBounds nextContribution=parent==null?null:parent.weighted((BigDecimal)t.get("interval_from"),(BigDecimal)t.get("interval_to"),
                (BigDecimal)t.get("denominator"),ValueBounds.DEFAULT_SCALE);
        ValueBounds previousContribution=from(t,"allocated_bound_lower","allocated_bound_upper","bound_scale");
        Map<String,Object> child=current(childId);ValueBounds previous=from(child,"bound_lower","bound_upper","bound_scale");
        ValueBounds next=previous==null||previousContribution==null||nextContribution==null?null:previous.replace(previousContribution,nextContribution);
        return new Change(previous,next,(BigDecimal)child.get("source_amount_exact"),(BigDecimal)child.get("source_amount_exact"),
                new EdgeBound((UUID)t.get("edge_id"),((Number)t.get("parent_revision")).longValue(),nextContribution));
    }

    Change productionChange(UUID outputId,UUID taskId,UUID previousTaskId){
        if(!installed)return null;
        ValueBounds previousShare=previousTaskId==null?ValueBounds.exact(BigDecimal.ZERO):productionShare(previousTaskId);
        ValueBounds nextShare=productionDesiredShare(taskId,previousTaskId);
        Map<String,Object> row=current(outputId);ValueBounds previous=from(row,"bound_lower","bound_upper","bound_scale");
        ValueBounds next=previous==null||previousShare==null||nextShare==null?null:previous.subtract(previousShare).add(nextShare);
        return new Change(previous,next,(BigDecimal)row.get("source_amount_exact"),(BigDecimal)row.get("source_amount_exact"),null);
    }
    ValueBounds productionDesiredShare(UUID taskId,UUID previousTaskId){
        if(!installed)return null;
        boolean preserve=Boolean.TRUE.equals(db.queryForObject("""
                SELECT r.target_qty_base>0 AND r.output_qty_base>r.target_qty_base FROM stock_value_production_cost_tasks t
                JOIN stock_value_production_cost_revisions r ON r.id=t.revision_id WHERE t.id=:id
                """,args("id",taskId),Boolean.class));
        return preserve?(previousTaskId==null?ValueBounds.exact(BigDecimal.ZERO):productionShare(previousTaskId)):productionShare(taskId);
    }

    ValueBounds productionShare(UUID taskId){
        return productionShare(taskId,this::bound,ValueBounds.DEFAULT_SCALE);
    }
    ValueBounds productionShare(UUID taskId,java.util.function.Function<ValueReference,ValueBounds> lookup,int requestedScale){
        Map<String,Object> t=db.queryForMap("SELECT * FROM stock_value_production_cost_tasks WHERE id=:id",args("id",taskId));
        ValueBounds saved=from(t,"exact_share_lower","exact_share_upper","exact_share_scale");
        if(saved!=null&&(saved.isExact()||saved.scale()>=requestedScale))return saved;
        BigDecimal denominator=(BigDecimal)t.get("denominator");if(denominator.signum()==0)return ValueBounds.exact(BigDecimal.ZERO);
        ValueBounds input=lookup.apply(new ValueReference((UUID)t.get("input_node_id"),((Number)t.get("input_revision")).longValue()));
        if(input==null)return null;
        // An invalid target preserves the exact previous allocation as well as
        // its decimal projection. It cannot create >100% of an input source.
        if(Boolean.TRUE.equals(db.queryForObject("SELECT output_qty_base>target_qty_base FROM stock_value_production_cost_revisions WHERE id=:id",
                args("id",t.get("revision_id")),Boolean.class))){
            if(t.get("exact_basis_task_id")==null)return ValueBounds.exact(BigDecimal.ZERO);
            t=db.queryForMap("SELECT * FROM stock_value_production_cost_tasks WHERE id=:id",args("id",t.get("exact_basis_task_id")));
            denominator=(BigDecimal)t.get("denominator");if(denominator.signum()==0)return ValueBounds.exact(BigDecimal.ZERO);
            input=lookup.apply(new ValueReference((UUID)t.get("input_node_id"),((Number)t.get("input_revision")).longValue()));
            if(input==null)return null;
        }
        if(t.get("input_quantity_basis") instanceof BigDecimal basis){
            BigDecimal returned=(BigDecimal)t.get("input_returned_qty");
            input=input.weighted(BigDecimal.ZERO,basis.subtract(returned),basis,requestedScale);
        }
        return input.weighted((BigDecimal)t.get("output_from"),(BigDecimal)t.get("output_to"),denominator,requestedScale);
    }

    static Map<String,Object> revisionArgs(Change change){
        return args("sourceBefore",change.sourceBefore(),"sourceAfter",change.sourceAfter(),
                "beforeLower",lower(change.before()),"beforeUpper",upper(change.before()),"beforeScale",scale(change.before()),
                "afterLower",lower(change.after()),"afterUpper",upper(change.after()),"afterScale",scale(change.after()));
    }

    void reviseEdge(Change change){
        if(!installed||change==null)return;
        if(change.edge()!=null){EdgeBound e=change.edge();db.update("""
                UPDATE stock_value_edges SET allocated_bound_lower=:lower,allocated_bound_upper=:upper,
                    bound_scale=:scale,bound_parent_revision=:revision WHERE id=:id
                """,args("id",e.id(),"revision",e.revision(),"lower",lower(e.bound()),"upper",upper(e.bound()),"scale",scale(e.bound())));}
    }

    ValueBounds bound(ValueReference ref){
        if(!installed)return null;Map<String,Object> n=current(ref.nodeId());
        if(((Number)n.get("revision")).longValue()==ref.revision()&&Objects.equals(n.get("bound_revision"),ref.revision()))
            return from(n,"bound_lower","bound_upper","bound_scale");
        if(ref.revision()==1)return from(n,"initial_bound_lower","initial_bound_upper","initial_bound_scale");
        List<Map<String,Object>> rows=db.queryForList("SELECT * FROM stock_value_node_revisions WHERE node_id=:id AND revision=:revision",
                args("id",ref.nodeId(),"revision",ref.revision()));
        return rows.isEmpty()?null:from(rows.getFirst(),"after_bound_lower","after_bound_upper","after_bound_scale");
    }
    Map<String,Object> current(UUID id){List<Map<String,Object>> rows=db.queryForList("SELECT * FROM stock_value_nodes WHERE id=:id",args("id",id));
        if(rows.size()!=1)throw conflict("金额权威引用的节点不存在");return rows.getFirst();}
    static ValueBounds from(Map<String,Object> row,String lo,String hi,String scale){return row.get(lo)==null||row.get(hi)==null||row.get(scale)==null?null:
            new ValueBounds((BigDecimal)row.get(lo),(BigDecimal)row.get(hi),((Number)row.get(scale)).intValue());}
    static BigDecimal lower(ValueBounds b){return b==null?null:b.lower();}
    static BigDecimal upper(ValueBounds b){return b==null?null:b.upper();}
    static Integer scale(ValueBounds b){return b==null?null:b.scale();}
    record EdgeBound(UUID id,long revision,ValueBounds bound){}
    record Change(ValueBounds before,ValueBounds after,BigDecimal sourceBefore,BigDecimal sourceAfter,EdgeBound edge){}
}
