package com.uten.imp.features.finance.gl;

import com.uten.imp.application.port.InventoryCostPostingQueryPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.time.LocalDate;
import java.time.YearMonth;
import java.util.List;
import java.util.UUID;

/** Explicit reconciliation/cutover and target-period actions; no current-price historical restatement. */
@Service
public class InventoryCostPostingService {
    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final InventoryCostPostingQueryPort costs;
    public InventoryCostPostingService(EntityManager em,TxSessionVars tx,SecurityContextCurrentUser currentUser,InventoryCostPostingQueryPort costs){this.em=em;this.tx=tx;this.currentUser=currentUser;this.costs=costs;}
    public record Policy(boolean enabled,LocalDate effectiveFrom,String reconciliationReference,long version) {}
    public record PolicyChange(boolean enabled,LocalDate effectiveFrom,String reconciliationReference,long expectedVersion) {}
    public record PeriodChoice(String targetPeriod,String reason) {}
    public record ClosePeriod(long expectedVersion,String reason) {}
    public record Posted(String period,int newVoucherCount) {}
    public record PeriodView(String period,String status,long version,long pendingCount) {}

    @Transactional(readOnly=true)
    public List<PeriodView> periods(String from,String to){
        YearMonth first=period(from),last=period(to);
        if(first.isAfter(last)||java.time.temporal.ChronoUnit.MONTHS.between(first,last)>119)throw invalid("成本会计期间查询须为最多120个月的有效范围");
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery("""
                SELECT to_char(month,'YYYY-MM'),COALESCE(period.status,'OPEN'),COALESCE(period.version,0),
                       %s
                FROM generate_series(CAST(:from AS date),CAST(:to AS date),interval '1 month') month
                LEFT JOIN inventory_cost_gl_periods period ON period.period=to_char(month,'YYYY-MM') ORDER BY month
                """.formatted(ActualInventoryCostGlProjection.pendingCountSql("to_char(month,'YYYY-MM')",true))).setParameter("from",first.atDay(1)).setParameter("to",last.atDay(1)).getResultList();
        return rows.stream().map(row->new PeriodView(row[0].toString(),row[1].toString(),((Number)row[2]).longValue(),((Number)row[3]).longValue())).toList();
    }

    @Transactional(readOnly=true)
    public List<InventoryCostPostingQueryPort.Posting> postings(LocalDate from,LocalDate to,UUID goods){return costs.postings(from,to,goods);}
    @Transactional(readOnly=true)
    public Policy policy(){
        Object[] row=(Object[])em.createNativeQuery("SELECT enabled,effective_from,reconciliation_reference,version FROM inventory_cost_gl_policy WHERE singleton").getSingleResult();
        return new Policy(Boolean.TRUE.equals(row[0]),row[1]==null?null:row[1] instanceof LocalDate date?date:((java.sql.Date)row[1]).toLocalDate(),row[2]==null?null:row[2].toString(),((Number)row[3]).longValue());
    }
    @Transactional
    public Policy configure(PolicyChange change){
        if(change==null||change.expectedVersion()<0)throw invalid("成本过账策略版本缺失");
        if(change.enabled()&&(change.effectiveFrom()==null||change.reconciliationReference()==null||change.reconciliationReference().trim().length()<8))throw invalid("启用实际成本过账须指定生效日并填写新旧成本对账依据");
        tx.bind();UUID actor=currentUser.requireId();ActualInventoryCostGlProjection.lock(em);
        Policy existing=policy();
        if(existing.version()!=change.expectedVersion())throw conflict("成本过账策略已被更新，请重新读取");
        long posted=((Number)em.createNativeQuery("SELECT count(*) FROM inventory_cost_gl_links").getSingleResult()).longValue();
        if(posted>0&&!java.util.Objects.equals(existing.effectiveFrom(),change.effectiveFrom()))throw conflict("已有实际成本凭证，不能回改启用边界");
        int updated=em.createNativeQuery("""
                UPDATE inventory_cost_gl_policy SET enabled=:enabled,effective_from=:from,reconciliation_reference=:reference,
                    version=version+1,updated_at=now(),updated_by=:actor WHERE singleton AND version=:version
                """).setParameter("enabled",change.enabled()).setParameter("from",change.effectiveFrom())
                .setParameter("reference",change.reconciliationReference()).setParameter("actor",actor).setParameter("version",change.expectedVersion()).executeUpdate();
        if(updated!=1)throw conflict("成本过账策略并发冲突");
        return policy();
    }
    @Transactional
    public InventoryCostPostingQueryPort.Posting choosePeriod(UUID posting,PeriodChoice choice){
        if(posting==null||choice==null)throw invalid("实际成本来源和目标期间不能为空");
        YearMonth target=period(choice.targetPeriod());
        if(choice.reason()==null||choice.reason().trim().length()<4)throw invalid("请填写差额入账期间的核定原因");
        tx.bind();UUID actor=currentUser.requireId();ActualInventoryCostGlProjection.lock(em);requireOpen(target.toString(),actor);
        @SuppressWarnings("unchecked") List<Object[]> source=em.createNativeQuery("SELECT business_date,posting_status,target_period FROM v_inventory_cost_gl_status WHERE posting_id=:id").setParameter("id",posting).getResultList();
        if(source.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"实际库存成本过账来源不存在");
        Object[] row=source.getFirst();LocalDate business=row[0] instanceof LocalDate date?date:((java.sql.Date)row[0]).toLocalDate();
        if(target.isBefore(YearMonth.from(business)))throw invalid("成本差额不能倒填到来源发生之前的期间");
        if("POSTED".equals(row[1]))throw conflict("该原价值过账已形成凭证，不能改变其会计期间");
        @SuppressWarnings("unchecked") List<String> prior=em.createNativeQuery("SELECT target_period FROM inventory_cost_gl_period_choices WHERE posting_id=:id").setParameter("id",posting).getResultList();
        if(!prior.isEmpty()&&!prior.getFirst().trim().equals(target.toString()))throw conflict("该来源已有核定期间；不能覆盖已保存的期间决定");
        em.createNativeQuery("""
                INSERT INTO inventory_cost_gl_period_choices(posting_id,target_period,reason,created_by)
                VALUES(:id,:period,:reason,:actor) ON CONFLICT(posting_id) DO NOTHING
                """).setParameter("id",posting).setParameter("period",target.toString()).setParameter("reason",choice.reason().trim()).setParameter("actor",actor).executeUpdate();
        return costs.postings(business,business,null).stream().filter(item->posting.equals(item.postingId())).findFirst().orElseThrow();
    }
    @Transactional
    public Posted post(String value){
        String period=period(value).toString();tx.bind();currentUser.requireId();
        return new Posted(period,ActualInventoryCostGlProjection.postReady(em,period));
    }
    @Transactional
    public void close(String value,ClosePeriod request){
        String period=period(value).toString();
        if(request==null||request.reason()==null||request.reason().isBlank())throw invalid("关闭成本期间须填写核对原因");
        tx.bind();UUID actor=currentUser.requireId();ActualInventoryCostGlProjection.lock(em);
        if(!ActualInventoryCostGlProjection.enabled(em))throw conflict("实际成本过账尚未启用，请先完成对账并启用策略");
        requireOpen(period,actor);
        long pending=ActualInventoryCostGlProjection.pendingCount(em,period,true);
        if(pending>0)throw conflict("成本期间仍有 "+pending+" 笔未入账或未定价来源，不能关闭");
        int changed=em.createNativeQuery("""
                UPDATE inventory_cost_gl_periods SET status='CLOSED',version=version+1,closed_at=now(),closed_by=:actor,close_reason=:reason
                WHERE period=:period AND status='OPEN' AND version=:version
                """).setParameter("actor",actor).setParameter("reason",request.reason().trim()).setParameter("period",period).setParameter("version",request.expectedVersion()).executeUpdate();
        if(changed!=1)throw conflict("成本期间状态已变化，请重新核对");
    }
    private void requireOpen(String period,UUID actor){
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))").setParameter("key","uten:inventory-cost:period:"+period).getSingleResult();
        em.createNativeQuery("INSERT INTO inventory_cost_gl_periods(period,created_by) VALUES(:period,:actor) ON CONFLICT DO NOTHING").setParameter("period",period).setParameter("actor",actor).executeUpdate();
        if(!"OPEN".equals(em.createNativeQuery("SELECT status FROM inventory_cost_gl_periods WHERE period=:period FOR UPDATE").setParameter("period",period).getSingleResult()))throw conflict("目标成本会计期间已关闭，请指定有效的开放期间");
    }
    private static YearMonth period(String value){try{return YearMonth.parse(value);}catch(RuntimeException ex){throw invalid("会计期间格式须为 YYYY-MM");}}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
