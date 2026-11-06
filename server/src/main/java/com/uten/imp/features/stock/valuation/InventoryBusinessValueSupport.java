package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryValuationPort.EventContext;
import com.uten.imp.application.port.InventoryValuationPort.PoolKey;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;

/** Business adapters share identity resolution, never caller supplied monetary values. */
@Component
public class InventoryBusinessValueSupport {
    private final NamedParameterJdbcTemplate db;
    private com.uten.imp.application.port.InventoryOpeningPort openings;
    public InventoryBusinessValueSupport(NamedParameterJdbcTemplate db) { this.db=db; }
    @org.springframework.beans.factory.annotation.Autowired
    public void setOpenings(com.uten.imp.application.port.InventoryOpeningPort openings){this.openings=openings;}

    /** Preserve the old balance snapshot and admit only unknown cost, never its old recorded price. */
    public void ensureActive(PoolKey key,EventContext source){
        Map<String,Object> args=new HashMap<>();args.put("warehouse",key.warehouseId());args.put("goods",key.goodsId());args.put("color",key.colorId());
        var pools=db.queryForList("SELECT state,head_node_id FROM stock_value_pools WHERE warehouse_id=:warehouse AND goods_id=:goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)",args);
        if(!pools.isEmpty()&&"ACTIVE".equals(pools.getFirst().get("state")))return;
        var balances=db.queryForList("SELECT qty,amount_local FROM stock_balances WHERE warehouse_id=:warehouse AND goods_id=:goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)",args);
        if(balances.isEmpty())return;
        if(balances.size()!=1)throw conflict("历史库存维度重复，不能建立待核成本");
        var balance=balances.getFirst();java.math.BigDecimal qty=(java.math.BigDecimal)balance.get("qty"),recorded=(java.math.BigDecimal)balance.get("amount_local");
        if(qty.signum()==0&&recorded!=null&&recorded.signum()==0&&pools.isEmpty())return;
        UUID event=UUID.randomUUID();String kind=qty.signum()==0?"INVENTORY_EMPTY_CYCLE":"INVENTORY_OPENING";
        EventContext context=new EventContext(event,kind,event,event,1,source.actorUserId(),source.actorEmployeeId(),kind+":"+event,source.occurredAt());
        String reason="本次业务保留原库存快照并建立待核成本，历史记载金额未经核定，不作为成本来源";
        if(qty.signum()>0)openings.open(new com.uten.imp.application.port.InventoryOpeningPort.Opening(context,key,qty,recorded,null,false,reason));
        else openings.startEmptyCycle(new com.uten.imp.application.port.InventoryOpeningPort.EmptyCycle(context,key,recorded,reason));
    }
    public EventContext context(String kind,UUID event,UUID doc,UUID item,UUID actor,OffsetDateTime at) {
        return contexts(List.of(new ContextInput(kind,event,doc,item,actor,at))).getFirst();
    }

    record ContextInput(String kind,UUID event,UUID document,UUID item,UUID actor,OffsetDateTime at) { }
    private record ActorIdentity(UUID actor,UUID knownUser,UUID employee) { }

    /** Resolve this invocation's real transaction actor and employee in bounded reads; never cache an identity. */
    List<EventContext> contexts(List<ContextInput> inputs) {
        List<EventContext> result=new ArrayList<>(inputs.size());
        for(int start=0;start<inputs.size();start+=100){
            var batch=inputs.subList(start,Math.min(start+100,inputs.size()));
            var actors=db.query("""
                    SELECT COALESCE(requested.actor_id,nullif(current_setting('app.actor_id',true),'')::uuid) AS actor_id,
                        person.id AS known_user,person.employee_id
                    FROM unnest(CAST(:actors AS uuid[])) WITH ORDINALITY requested(actor_id,position)
                    LEFT JOIN users person ON person.id=COALESCE(requested.actor_id,
                        nullif(current_setting('app.actor_id',true),'')::uuid)
                    ORDER BY requested.position
                    """,Map.of("actors",new org.springframework.jdbc.support.SqlArrayValue("uuid",
                        batch.stream().map(ContextInput::actor).toArray())),
                    (row,index)->new ActorIdentity(row.getObject("actor_id",UUID.class),row.getObject("known_user",UUID.class),row.getObject("employee_id",UUID.class)));
            if(actors.size()!=batch.size())throw new IllegalStateException("Cost identity read lost an original source");
            for(int index=0;index<batch.size();index++){
                var input=batch.get(index);var identity=actors.get(index);
                if(identity.actor()==null)throw conflict("库存成本记账缺少实际责任账号");
                // Retain the original queryForObject failure for a missing user:
                // corrupt source identity is not a recoverable employee choice.
                if(identity.knownUser()==null)throw new org.springframework.dao.EmptyResultDataAccessException(1);
                if(identity.employee()==null)throw conflict("库存成本责任账号尚未关联员工");
                result.add(new EventContext(input.event(),input.kind(),input.document(),input.item(),1,
                        identity.actor(),identity.employee(),input.kind()+":"+input.event(),input.at()));
            }
        }
        return List.copyOf(result);
    }
    public EventContext context(String kind,UUID fact,UUID actor) {
        return context(kind,fact,fact,fact,actor,db.queryForObject("SELECT transaction_timestamp()",Map.of(),OffsetDateTime.class));
    }
    public static PoolKey pool(Map<String,Object> row) {
        return new PoolKey((UUID)row.get("warehouse_id"),(UUID)row.get("goods_id"),(UUID)row.get("color_id"));
    }
    public static OffsetDateTime time(Object value) {
        if(value instanceof OffsetDateTime at)return at;
        return ((java.sql.Timestamp)value).toInstant().atOffset(ZoneOffset.UTC);
    }
}
