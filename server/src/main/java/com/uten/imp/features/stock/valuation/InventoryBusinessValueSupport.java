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
        if(actor==null) actor=db.queryForObject("SELECT nullif(current_setting('app.actor_id',true),'')::uuid",Map.of(),UUID.class);
        if(actor==null)throw conflict("库存成本记账缺少实际责任账号");
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=:id",Map.of("id",actor),UUID.class);
        if(employee==null)throw conflict("库存成本责任账号尚未关联员工");
        return new EventContext(event,kind,doc,item,1,actor,employee,kind+":"+event,at);
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
