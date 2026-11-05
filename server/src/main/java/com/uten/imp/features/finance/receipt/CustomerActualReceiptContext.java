package com.uten.imp.features.finance.receipt;

import com.uten.imp.application.port.CustomerActualReceiptContextPort;
import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;

/** Approved receipt + its one authoritative account posting prove cash; a draft never does. */
@Component
@RequiredArgsConstructor
public class CustomerActualReceiptContext implements CustomerActualReceiptContextPort {
    private final EntityManager em;
    static final String FACTS="""
            WITH flow AS (
                SELECT source_doc_id,count(*) AS count,min(account_id::text)::uuid AS account_id,
                    min(account_currency_id::text)::uuid AS currency_id,SUM(in_amount) AS incoming,SUM(out_amount) AS outgoing,SUM(amount_local) AS cash_local
                FROM finance_reconciliations WHERE source_doc_type='RECEIPT' AND entry_kind='POSTING' AND NOT is_deleted
                  AND source_doc_id IN(SELECT id FROM finance_receipts WHERE client_id=:client AND currency_id=:currency AND status=1 AND NOT is_deleted)
                GROUP BY source_doc_id
            ), facts AS (
                SELECT r.id,r.bill_no,r.bank_booked_at,c.name AS account_currency,r.account_amount,r.account_amount_local,
                    (%s) IS TRUE AS verified
                FROM finance_receipts r LEFT JOIN flow f ON f.source_doc_id=r.id LEFT JOIN currencies c ON c.id=r.account_currency_id
                WHERE r.client_id=:client AND r.currency_id=:currency AND r.status=1 AND NOT r.is_deleted
                  AND COALESCE(r.bank_booked_at,r.bill_date::timestamp AT TIME ZONE 'Asia/Shanghai')<=:asOf
            )
            """.formatted(ReceiptCashPostingProof.verified("r","f"));
    @Override public Context read(UUID clientId,UUID currencyId,OffsetDateTime asOf){
        var facts=NativeQueryResults.objectArrayRows(em.createNativeQuery(FACTS+"""
                , totals AS (SELECT count(*) FILTER(WHERE verified) AS verified_count,
                    COALESCE(sum(account_amount_local) FILTER(WHERE verified),0) AS cash_local,
                    count(*) FILTER(WHERE NOT verified) AS pending_count FROM facts), recent AS (
                    SELECT id,bill_no,bank_booked_at,account_currency,account_amount,account_amount_local FROM facts
                    WHERE verified ORDER BY bank_booked_at DESC,id LIMIT 20)
                SELECT totals.verified_count,totals.cash_local,totals.pending_count,recent.id,recent.bill_no,to_char(recent.bank_booked_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM-DD HH24:MI:SS'),
                    recent.account_currency,recent.account_amount,recent.account_amount_local
                FROM totals LEFT JOIN recent ON true ORDER BY recent.bank_booked_at DESC,recent.id
                """).setParameter("client",clientId).setParameter("currency",currencyId).setParameter("asOf",asOf));
        Object[] totals=facts.getFirst();List<Receipt> rows=new ArrayList<>();
        for(Object[] row:facts)if(row[3]!=null)rows.add(new Receipt((UUID)row[3],Objects.toString(row[4],""),Objects.toString(row[5],""),Objects.toString(row[6],""),((BigDecimal)row[7]).toPlainString(),((BigDecimal)row[8]).toPlainString()));
        long count=((Number)totals[0]).longValue();return new Context(true,asOf.toString(),count,((BigDecimal)totals[1]).toPlainString(),((Number)totals[2]).longValue(),List.copyOf(rows),count>rows.size(),"本单币种已审核收款及唯一账户入账事实；已核销收款也包含在累计中，累计到账不等于可用预收。草稿、红冲、未来到账和未核实历史不计入已核对金额。");
    }
}
