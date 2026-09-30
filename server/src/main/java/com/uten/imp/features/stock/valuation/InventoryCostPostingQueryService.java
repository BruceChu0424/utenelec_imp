package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryCostPostingQueryPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

@Service
public class InventoryCostPostingQueryService implements InventoryCostPostingQueryPort {
    private final NamedParameterJdbcTemplate db;
    public InventoryCostPostingQueryService(NamedParameterJdbcTemplate db){this.db=db;}
    @Override @Transactional(readOnly=true)
    public List<Posting> postings(LocalDate from,LocalDate to,UUID goodsId){
        if(from==null||to==null||from.isAfter(to))throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择有效的实际成本过账期间");
        var args=new MapSqlParameterSource("from",from).addValue("to",to).addValue("goods",goodsId);
        var result=db.query("""
                SELECT * FROM v_inventory_cost_gl_status WHERE business_date BETWEEN :from AND :to
                  AND (CAST(:goods AS uuid) IS NULL OR goods_id=CAST(:goods AS uuid))
                ORDER BY business_date,created_at,posting_id LIMIT 10001
                """,args,(rs,index)->new Posting(rs.getObject("posting_id",UUID.class),rs.getObject("event_id",UUID.class),rs.getObject("node_id",UUID.class),rs.getLong("value_revision"),rs.getObject("shipment_id",UUID.class),rs.getObject("shipment_item_id",UUID.class),rs.getObject("client_id",UUID.class),rs.getObject("goods_id",UUID.class),rs.getObject("warehouse_id",UUID.class),rs.getObject("color_id",UUID.class),rs.getObject("business_date",LocalDate.class),rs.getString("source_period"),rs.getString("target_period"),rs.getString("source_doc_type"),rs.getObject("source_doc_id",UUID.class),rs.getObject("source_item_id",UUID.class),rs.getString("operation"),rs.getBigDecimal("amount_local"),rs.getBoolean("pending"),rs.getString("posting_status"),rs.getObject("voucher_id",UUID.class)));
        if(result.size()>10000)throw new ApiException(ErrorCode.VALIDATION_FAILED,"实际成本过账明细超过10000条，请缩小日期或指定货品");
        return List.copyOf(result);
    }
}
