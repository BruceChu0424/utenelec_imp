package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.util.List;
import java.util.UUID;

/** A proven inverse can remove its already posted amount while the source
 * correctly returns to unknown. It never authorizes a new positive cost. */
final class ActualInventoryCostStornoProjection {
    private ActualInventoryCostStornoProjection() { }
    private static final String PROOF="""
        WITH eligible AS MATERIALIZED (
          SELECT cost.* FROM fn_inventory_cost_exact_storno_candidates(:p,CAST(NULL AS uuid)) cost WHERE cost.target_period=:p
            AND NOT EXISTS(SELECT 1 FROM inventory_cost_gl_links existing WHERE existing.posting_id=cost.posting_id)
        ), legs AS MATERIALIZED (
          SELECT cost.posting_id,leg.* FROM eligible cost CROSS JOIN LATERAL fn_inventory_cost_exact_storno_legs(cost.original_voucher_ids) leg
        )
        """;

    static int postAvailable(EntityManager em,String period){
        if(!Boolean.TRUE.equals(em.createNativeQuery("SELECT to_regprocedure('public.fn_inventory_cost_exact_storno_valid(uuid,uuid,text)') IS NOT NULL").getSingleResult()))return 0;
        if(((Number)em.createNativeQuery("SELECT fn_inventory_value_revaluation_contract_version()").getSingleResult()).intValue()!=1)return 0;
        @SuppressWarnings("unchecked") List<UUID> ids=em.createNativeQuery(PROOF+"SELECT posting_id FROM eligible ORDER BY posting_id").setParameter("p",period).getResultList();
        if(ids.isEmpty())return 0;
        ActualInventoryCostGlProjection.requireOpenPeriod(em,period);
        em.createNativeQuery(PROOF+"""
            INSERT INTO gl_vouchers(voucher_no,period,voucher_date,source,source_type,source_doc_id,remark,created_by,updated_by)
            SELECT 'IC-'||posting_id::text,:p,CASE WHEN source_period=:p THEN business_date ELSE to_date(:p||'-01','YYYY-MM-DD') END,
              'AUTO','ACTUAL_COGS',posting_id,'原已记实际成本的精确反向',NULLIF(current_setting('app.actor_id',true),'')::uuid,NULLIF(current_setting('app.actor_id',true),'')::uuid
            FROM eligible WHERE posting_id IN(:ids) ON CONFLICT(voucher_no,source_type) DO NOTHING
            """).setParameter("p",period).setParameter("ids",ids).executeUpdate();
        em.createNativeQuery(PROOF+"""
            INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,source_doc_type,source_doc_id,source_bill_no,summary,created_by,updated_by)
            SELECT voucher.id,leg.line_no,leg.style_id,leg.direction,leg.amount,voucher.voucher_date,voucher.period,
              'ACTUAL_COGS',cost.posting_id,voucher.voucher_no,'按原已记科目及实际金额反向',NULLIF(current_setting('app.actor_id',true),'')::uuid,NULLIF(current_setting('app.actor_id',true),'')::uuid
            FROM eligible cost JOIN gl_vouchers voucher ON voucher.source_type='ACTUAL_COGS' AND voucher.source_doc_id=cost.posting_id
            JOIN legs leg ON leg.posting_id=cost.posting_id
            WHERE cost.posting_id IN(:ids) AND NOT EXISTS(SELECT 1 FROM gl_entries prior WHERE prior.voucher_id=voucher.id AND prior.line_no=leg.line_no)
            """).setParameter("p",period).setParameter("ids",ids).executeUpdate();
        long invalid=((Number)em.createNativeQuery(PROOF+"""
            SELECT count(*) FROM eligible cost JOIN gl_vouchers voucher ON voucher.source_type='ACTUAL_COGS' AND voucher.source_doc_id=cost.posting_id
            WHERE cost.posting_id IN(:ids) AND NOT fn_inventory_cost_exact_storno_valid(cost.posting_id,voucher.id,:p)
            """).setParameter("p",period).setParameter("ids",ids).getSingleResult()).longValue();
        if(invalid!=0)throw conflict();
        int linked=em.createNativeQuery(PROOF+"""
            INSERT INTO inventory_cost_gl_links(posting_id,voucher_id,source_period,target_period,source_event_id,source_node_id,amount_local,created_by)
            SELECT cost.posting_id,voucher.id,cost.source_period,cost.target_period,cost.event_id,cost.node_id,cost.amount_local,NULLIF(current_setting('app.actor_id',true),'')::uuid
            FROM eligible cost JOIN gl_vouchers voucher ON voucher.source_type='ACTUAL_COGS' AND voucher.source_doc_id=cost.posting_id
            WHERE cost.posting_id IN(:ids) ON CONFLICT(posting_id) DO NOTHING
            """).setParameter("p",period).setParameter("ids",ids).executeUpdate();
        if(linked!=ids.size())throw conflict();
        return linked;
    }
    private static ApiException conflict(){return new ApiException(ErrorCode.CONFLICT,"原实际成本反向证明或凭证在入账时发生变化，请保留来源重新核对");}
}
