package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.time.YearMonth;

/** Append-only projection of signed stock-value postings; legacy COST_CARRY is never rebuilt. */
final class ActualInventoryCostGlProjection {
    private ActualInventoryCostGlProjection() {}
    /** Includes unpriced physical shipments even when a zero known delta produced no value posting. */
    private static final String PENDING_SOURCE_ROWS = """
            SELECT cost.target_period,('POSTING:'||cost.posting_id::text) source_key,
                   cost.posting_status='READY' ready
            FROM v_inventory_cost_gl_status cost WHERE cost.posting_status NOT IN('POSTED','BEFORE_CUTOVER')
            UNION ALL
            SELECT DISTINCT to_char(coverage.business_date,'YYYY-MM'),('SHIPMENT:'||coverage.shipment_item_id::text),false
            FROM v_stock_actual_sales_cost_coverage coverage WHERE coverage.pending
              AND NOT EXISTS(SELECT 1 FROM v_inventory_cost_gl_status cost
                  WHERE cost.shipment_item_id=coverage.shipment_item_id
                    AND cost.target_period=to_char(coverage.business_date,'YYYY-MM')
                    AND cost.posting_status NOT IN('READY','POSTED','BEFORE_CUTOVER'))
            """;
    static String pendingCountSql(String periodExpression,boolean includeReady){
        if(!java.util.Set.of(":p","to_char(month,'YYYY-MM')").contains(periodExpression))throw new IllegalArgumentException("Unexpected internal period expression");
        return "(SELECT count(*) FROM ("+PENDING_SOURCE_ROWS+") unresolved WHERE unresolved.target_period="+periodExpression+(includeReady?"":" AND NOT unresolved.ready")+")";
    }
    static long pendingCount(EntityManager em,String period,boolean includeReady){
        return ((Number)em.createNativeQuery("SELECT "+pendingCountSql(":p",includeReady)).setParameter("p",period).getSingleResult()).longValue();
    }
    static void lock(EntityManager em){
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended('uten:inventory-cost:gl',0))").getSingleResult();
    }
    static boolean enabled(EntityManager em){
        return Boolean.TRUE.equals(em.createNativeQuery("SELECT enabled FROM inventory_cost_gl_policy WHERE singleton").getSingleResult());
    }
    static int postReady(EntityManager em,String period){
        YearMonth.parse(period);
        lock(em);
        if(!enabled(em))throw new ApiException(ErrorCode.CONFLICT,"实际成本过账尚未启用，请先完成对账并启用策略");
        long blocked=pendingCount(em,period,false);
        if(blocked>0)throw new ApiException(ErrorCode.CONFLICT,"本期间有 "+blocked+" 笔实际成本尚待核价、期间指定或历史对账（含未生成金额过账的出库明细），请回源处理");
        int ready=((Number)em.createNativeQuery("SELECT count(*) FROM v_inventory_cost_gl_status WHERE target_period=:p AND posting_status='READY'")
                .setParameter("p",period).getSingleResult()).intValue();
        if(ready==0)return 0;
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))").setParameter("key","uten:inventory-cost:period:"+period).getSingleResult();
        em.createNativeQuery("""
                INSERT INTO inventory_cost_gl_periods(period,created_by)
                VALUES(:p,NULLIF(current_setting('app.actor_id',true),'')::uuid) ON CONFLICT DO NOTHING
                """).setParameter("p",period).executeUpdate();
        Object status=em.createNativeQuery("SELECT status FROM inventory_cost_gl_periods WHERE period=:p FOR UPDATE").setParameter("p",period).getSingleResult();
        if(!"OPEN".equals(status))throw new ApiException(ErrorCode.CONFLICT,"实际成本会计期间已关闭，不能回写历史凭证");
        long missing=((Number)em.createNativeQuery("SELECT count(*) FROM (VALUES('SALES_COST'),('INVENTORY_ASSET')) role(key) WHERE system_posting_style_id(role.key) IS NULL").getSingleResult()).longValue();
        if(missing>0)throw new ApiException(ErrorCode.CONFLICT,"实际成本过账缺少销售成本或库存资产科目关系");
        em.createNativeQuery("""
                INSERT INTO gl_vouchers(voucher_no,period,voucher_date,source,source_type,source_doc_id,remark,created_by,updated_by)
                SELECT 'IC-'||posting_id::text,:p,
                       CASE WHEN source_period=:p THEN business_date ELSE to_date(:p||'-01','YYYY-MM-DD') END,
                       'AUTO','ACTUAL_COGS',posting_id,'库存实际成本价值变动',
                       NULLIF(current_setting('app.actor_id',true),'')::uuid,NULLIF(current_setting('app.actor_id',true),'')::uuid
                FROM v_inventory_cost_gl_status WHERE target_period=:p AND posting_status='READY'
                ON CONFLICT(voucher_no,source_type) DO NOTHING
                """).setParameter("p",period).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,
                    source_doc_type,source_doc_id,source_bill_no,summary,created_by,updated_by)
                SELECT voucher.id,leg.line_no,system_posting_style_id(leg.role_key),leg.direction,cost.amount_local,
                       voucher.voucher_date,voucher.period,'ACTUAL_COGS',cost.posting_id,voucher.voucher_no,
                       '原价值来源销售成本 / 退回 / 后补差额',NULLIF(current_setting('app.actor_id',true),'')::uuid,
                       NULLIF(current_setting('app.actor_id',true),'')::uuid
                FROM v_inventory_cost_gl_status cost JOIN gl_vouchers voucher
                  ON voucher.source_type='ACTUAL_COGS' AND voucher.source_doc_id=cost.posting_id
                CROSS JOIN (VALUES(1,1,'SALES_COST'),(2,-1,'INVENTORY_ASSET')) leg(line_no,direction,role_key)
                WHERE cost.target_period=:p AND cost.posting_status='READY'
                  AND NOT EXISTS(SELECT 1 FROM gl_entries existing WHERE existing.voucher_id=voucher.id AND existing.line_no=leg.line_no)
                """).setParameter("p",period).executeUpdate();
        int linked=em.createNativeQuery("""
                INSERT INTO inventory_cost_gl_links(posting_id,voucher_id,source_period,target_period,source_event_id,source_node_id,amount_local,created_by)
                SELECT cost.posting_id,voucher.id,cost.source_period,cost.target_period,cost.event_id,cost.node_id,cost.amount_local,
                       NULLIF(current_setting('app.actor_id',true),'')::uuid
                FROM v_inventory_cost_gl_status cost JOIN gl_vouchers voucher
                  ON voucher.source_type='ACTUAL_COGS' AND voucher.source_doc_id=cost.posting_id
                WHERE cost.target_period=:p AND cost.posting_status='READY'
                ON CONFLICT(posting_id) DO NOTHING
                """).setParameter("p",period).executeUpdate();
        if(linked!=ready)throw new ApiException(ErrorCode.CONFLICT,"实际成本来源在过账期间发生变化，请重新核对");
        return linked;
    }
}
