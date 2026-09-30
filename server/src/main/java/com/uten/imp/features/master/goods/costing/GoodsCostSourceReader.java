package com.uten.imp.features.master.goods.costing;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.stereotype.Component;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;
import static com.uten.imp.common.finance.CostCalculationMath.*;

/** Bounded, read-only source projections. A remembered draft price is deliberately not an approved candidate. */
@Component
@RequiredArgsConstructor
public class GoodsCostSourceReader {
    private final NamedParameterJdbcTemplate db;
    private final MasterReferenceValidationPort references;
    private final MasterObjectAccess access;
    public record GoodsInfo(UUID id,String code,String name,UUID unitId,String unitName,
            UUID colorId,String colorName,String sourceType,String revision) {}
    public record Edge(UUID id,UUID parentId,GoodsInfo goods,BigDecimal designQty,BigDecimal actualQty,
            BigDecimal effectiveQty,String actualStatus,long samples,BigDecimal output,BigDecimal net,
            String basis,BigDecimal basisOutput,boolean partial,boolean learned,String revision) {}
    public GoodsInfo goods(UUID id) {
        references.requireVisibleGoods(id);
        List<GoodsInfo> rows=db.query("""
                SELECT g.id,g.code,g.name,g.unit_id,u.name unit_name,g.color_id,c.name color_name,
                       g.source_type,g.version FROM goods g LEFT JOIN units u ON u.id=g.unit_id
                LEFT JOIN colors c ON c.id=g.color_id WHERE g.id=:id AND NOT g.is_deleted AND NOT g.auto_created
                """,Map.of("id",id),(r,n)->new GoodsInfo(r.getObject("id",UUID.class),r.getString("code"),
                r.getString("name"),r.getObject("unit_id",UUID.class),r.getString("unit_name"),
                r.getObject("color_id",UUID.class),r.getString("color_name"),r.getString("source_type"),r.getString("version")));
        if(rows.size()!=1) throw invalid("货品不存在或为历史占位货品");
        if(rows.getFirst().unitId()==null) throw invalid("货品未维护基本单位");
        return rows.getFirst();
    }
    public List<Edge> edges(UUID parent) {
        return db.query("""
                SELECT b.id,b.goods_id,b.component_goods_id,g.code,g.name,g.unit_id,u.name unit_name,
                       COALESCE(b.color_id,g.color_id) color_id,c.name color_name,g.source_type,g.version,
                       b.qty,b.consumption_basis,b.basis_output_qty,b.allow_partial_package,b.updated_at,
                       x.actual_qty,x.effective_qty,x.actual_status,x.sample_count,x.exposure_output_qty,x.net_qty,
                       x.system_learned
                FROM goods_bom_items b JOIN goods g ON g.id=b.component_goods_id
                LEFT JOIN units u ON u.id=g.unit_id LEFT JOIN colors c ON c.id=COALESCE(b.color_id,g.color_id)
                LEFT JOIN v_goods_bom_item_usage x ON x.bom_item_id=b.id
                WHERE b.goods_id=:id AND NOT b.is_deleted AND NOT g.is_deleted AND NOT g.auto_created
                ORDER BY b.sort_order,b.id
                """,Map.of("id",parent),(r,n)->new Edge(r.getObject("id",UUID.class),parent,
                new GoodsInfo(r.getObject("component_goods_id",UUID.class),r.getString("code"),r.getString("name"),
                r.getObject("unit_id",UUID.class),r.getString("unit_name"),r.getObject("color_id",UUID.class),
                r.getString("color_name"),r.getString("source_type"),r.getString("version")),r.getBigDecimal("qty"),
                r.getBigDecimal("actual_qty"),r.getBigDecimal("effective_qty"),r.getString("actual_status"),
                r.getLong("sample_count"),r.getBigDecimal("exposure_output_qty"),r.getBigDecimal("net_qty"),
                r.getString("consumption_basis"),r.getBigDecimal("basis_output_qty"),r.getBoolean("allow_partial_package"),
                r.getBoolean("system_learned"),Objects.toString(r.getObject("updated_at"),"")));
    }
    public String currency(UUID id) {
        if(id==null) return "本币";
        List<String> rows=db.queryForList("SELECT name FROM currencies WHERE id=:id AND NOT is_deleted",Map.of("id",id),String.class);
        if(rows.size()!=1) throw invalid("币种不存在或已删除");
        return rows.getFirst();
    }
    public boolean baseCurrency(UUID id) {
        if(id==null)return true;
        List<Boolean> rows=db.queryForList("SELECT is_base_currency FROM currencies WHERE id=:id AND NOT is_deleted",Map.of("id",id),Boolean.class);
        if(rows.size()!=1)throw invalid("币种不存在或已删除");
        return Boolean.TRUE.equals(rows.getFirst());
    }
    public PriceEvidence approved(GoodsInfo goods,boolean subcontract,LocalDate date,UUID explicitItem) {
        String kind=subcontract?"subcontract":"purchase";
        // Fixed identifiers only; source object scope is evaluated before selecting a candidate.
        List<Map<String,Object>> rows=db.queryForList("""
                SELECT o.id,o.bill_no,o.bill_date,o.updated_at,o.supplier_id,o.currency_id,c.name currency_name,
                       o.exchange_rate,o.tax_rate,o.purchaser_id,i.id item_id,i.unit_id,u.name unit_name,
                       i.unit_rate,i.price,i.qty,i.amount_original,i.extra_columns,i.updated_at item_updated_at,
                       EXISTS(SELECT 1 FROM jsonb_array_elements(COALESCE(i.extra_columns,'[]'::jsonb)) adjustment
                              WHERE COALESCE(adjustment->>'operation','NONE')<>'NONE') adjustment_rules
                FROM %1$s_orders o JOIN %1$s_order_items i ON i.order_id=o.id
                LEFT JOIN currencies c ON c.id=o.currency_id LEFT JOIN units u ON u.id=i.unit_id
                WHERE o.status=1 AND NOT o.is_deleted AND NOT i.is_deleted
                  AND i.goods_id=:goods AND i.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                  AND o.bill_date<=:date AND i.price IS NOT NULL AND i.price>=0
                  AND (CAST(:item AS uuid) IS NULL OR i.id=CAST(:item AS uuid))
                ORDER BY o.bill_date DESC,o.updated_at DESC,i.id LIMIT 100
                """.formatted(kind),new MapSqlParameterSource().addValue("goods",goods.id())
                .addValue("color",goods.colorId()).addValue("date",date).addValue("item",explicitItem==null?null:explicitItem.toString()));
        var visible=access.readableLabelOwner(kind);
        for(var row:rows) {
            if(!visible.test((UUID)row.get("purchaser_id"))) continue;
            UUID unit=(UUID)row.get("unit_id");
            BigDecimal unitRate=(BigDecimal)row.get("unit_rate");
            if(unitRate==null && Objects.equals(unit,goods.unitId())) unitRate=BigDecimal.ONE;
            BigDecimal fx=(BigDecimal)row.get("exchange_rate");
            if(unit==null || unitRate==null || unitRate.signum()<=0 || fx==null || fx.signum()<=0
                    || row.get("supplier_id")==null || row.get("currency_id")==null
                    || Objects.equals(unit,goods.unitId())&&unitRate.compareTo(BigDecimal.ONE)!=0) continue;
            BigDecimal sourceQty=(BigDecimal)row.get("qty"),sourceAmount=(BigDecimal)row.get("amount_original"),sourcePrice=(BigDecimal)row.get("price");
            boolean adjusted=Boolean.TRUE.equals(row.get("adjustment_rules"))||sourceQty==null||sourceQty.signum()<=0
                    ||sourceAmount==null||sourceAmount.compareTo(sourceQty.multiply(sourcePrice))!=0;
            String explanation=adjusted?"原单含独立计费项或金额依据待核对，不能把整行金额摊到不同批量；原单数量="+text(sourceQty)
                    +"，原单金额="+text(sourceAmount)+"。请拆分费用或人工复核采用成本。":"已审核单据原计价口径；税率不自动等同含税属性";
            return new PriceEvidence(subcontract?"APPROVED_SUBCONTRACT":"APPROVED_PURCHASE",(UUID)row.get("id"),
                    (UUID)row.get("item_id"),(String)row.get("bill_no"),priceRevision(row),
                    adjusted?"APPROVED_WITH_COMPONENTS":"APPROVED",(UUID)row.get("supplier_id"),(UUID)row.get("currency_id"),(String)row.get("currency_name"),
                    unit,(String)row.get("unit_name"),text(unitRate),text((BigDecimal)row.get("price")),text(fx),
                    text((BigDecimal)row.get("tax_rate")),"UNCONFIRMED",row.get("bill_date") instanceof LocalDate d?d:((java.sql.Date)row.get("bill_date")).toLocalDate(),
                    explanation);
        }
        return null;
    }
    private static String priceRevision(Map<String,Object> row) {
        StringBuilder value=new StringBuilder();
        for(String key:List.of("id","item_id","updated_at","item_updated_at","supplier_id","currency_id","exchange_rate","tax_rate","unit_id","unit_rate","price","qty","amount_original","extra_columns","bill_date")) {
            Object part=row.get(key);value.append(key).append('=')
                    .append(part instanceof BigDecimal decimal?text(decimal):Objects.toString(part,"NULL")).append('|');
        }
        try {return HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256")
                .digest(value.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)));}
        catch(java.security.NoSuchAlgorithmException impossible){throw new IllegalStateException(impossible);}
    }
    public PriceEvidence inventory(GoodsInfo goods,LocalDate date) {
        // An inventory reference is a present snapshot, not a reconstructed historical moving average.
        if(!com.uten.imp.common.time.BusinessTime.today().equals(date)) return null;
        var rows=db.queryForList("""
                SELECT sum(b.qty) qty,sum(b.amount_local) amount,
                       bool_and(COALESCE(p.state='ACTIVE' AND n.pending_parents=0 AND n.source_final AND n.active
                            AND n.kind='POOL' AND n.quantity_basis=b.qty AND n.basis_value_local=b.amount_local
                            AND b.amount_local IS NOT NULL,FALSE)) complete,
                       string_agg(p.id::text||':'||n.revision::text,',' ORDER BY p.id) revisions
                FROM stock_balances b JOIN warehouses w ON w.id=b.warehouse_id AND w.is_accountable
                LEFT JOIN stock_value_pools p ON p.warehouse_id=b.warehouse_id AND p.goods_id=b.goods_id
                       AND p.color_id IS NOT DISTINCT FROM b.color_id
                LEFT JOIN stock_value_nodes n ON n.id=p.head_node_id
                WHERE b.goods_id=:goods AND b.color_id IS NOT DISTINCT FROM CAST(:color AS uuid) AND b.qty>0
                """,new MapSqlParameterSource().addValue("goods",goods.id()).addValue("color",goods.colorId()));
        if(rows.isEmpty()) return null;
        var r=rows.getFirst();
        BigDecimal qty=(BigDecimal)r.get("qty"),amount=(BigDecimal)r.get("amount");
        if(qty==null || qty.signum()<=0 || amount==null || !Boolean.TRUE.equals(r.get("complete"))) return null;
        return new PriceEvidence("INVENTORY_REFERENCE",goods.id(),null,null,Objects.toString(r.get("revisions")),
                "FINAL_REFERENCE",null,null,"本币",goods.unitId(),goods.unitName(),"1",text(divide(amount,qty)),"1",null,
                "AS_RECORDED",date,"现时已核定库存参考：金额="+text(amount)+"；数量="+text(qty));
    }
}
