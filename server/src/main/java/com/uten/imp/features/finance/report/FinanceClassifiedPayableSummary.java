package com.uten.imp.features.finance.report;

import com.uten.imp.common.report.ReportTotalsCalculator;
import com.uten.imp.common.util.*;
import com.uten.imp.features.finance.LegacyOpeningBalanceSql;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import jakarta.persistence.EntityManager;
import java.time.LocalDate;
import java.util.*;

/** Original goods/tooling columns from explicit existing open-item, cash-line and offset allocations. */
final class FinanceClassifiedPayableSummary {
    private FinanceClassifiedPayableSummary() { }
    static ReportTableResponse read(EntityManager em,String keyword,LocalDate from,LocalDate to,int page,int size,FinanceReportColumnOptions options) {
        String[] keys={"partyCode","partyName","partyFull","settlement","prevBalance","goodsAmount","goodsPaidAmount","returnAmount","goodsOffsetAmount","goodsBalance","mouldAmount","mouldPaidAmount","mouldOffsetAmount","mouldBalance","totalBalance"};
        var columns=new ArrayList<ReportColumn>();var totals=new ArrayList<ReportTotalsCalculator.Spec>();
        for(int i=0;i<keys.length;i++) {
            var column=new ReportColumn(keys[i],FinanceTemplateContract.header("payableSummary",i),i<4?"text":"money",i==2?230:120)
                    .withHeaderGroups(FinanceTemplateContract.headerGroups("payableSummary",i));
            if(i>=4){column=column.withUnitLabel("元");totals.add(new ReportTotalsCalculator.Spec(keys[i],column.label()+"合计","money",null,null,true));}
            columns.add(column);
        }
        columns.addAll(List.of(ReportColumn.text("__supplierId",""),ReportColumn.bool("__pending",""),ReportColumn.text("__basis",""),
                ReportColumn.number("__unknownClassificationCount",""),ReportColumn.money("__goodsOpening",""),ReportColumn.money("__mouldOpening",""),
                ReportColumn.money("__goodsCashBookDelta",""),ReportColumn.money("__mouldCashBookDelta",""),ReportColumn.money("__classificationDifference",""),
                ReportColumn.money("__unappliedAdvanceLocal",""),ReportColumn.money("__formalPayableBalance","")));
        boolean searching=!KeywordSearch.terms(keyword).isEmpty();String source=sql();
        if(searching)source="SELECT matched.* FROM ("+source+") matched WHERE "+TaskKeywordSearch.conditionParameter("kw","matched.\"partyCode\"","matched.\"partyName\"","matched.\"partyFull\"");
        return FinanceProjectedReportTable.query(em,columns,source,q->{q.setParameter("from",from);q.setParameter("to",to);if(searching)q.setParameter("kw",KeywordSearch.phrase(keyword));},
                "report.\"partyCode\",report.\"__supplierId\"",options.filters(),Set.of(),page,size,options.sort(),options.order(),false,totals);
    }
    static String sql() {
        return """
                WITH origin AS (
                    SELECT ledger.*, %s AS source_local,
                           CASE WHEN ledger.legacy_import_run_id IS NULL THEN ledger.bill_date
                                ELSE ((ledger.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date END AS effective_date
                    FROM ar_ap_ledger ledger %s
                    WHERE ledger.direction='AP' AND ledger.supplier_id IS NOT NULL
                      AND NOT @representedCashLedger@
                      AND ((ledger.status=1 AND NOT ledger.is_deleted) OR (ledger.status=-1 AND ledger.is_deleted AND ledger.deleted_at IS NOT NULL))
                ), posting_facts AS (
                    SELECT origin.supplier_id,origin.source_doc_type,origin.effective_date AS event_date,
                           origin.deleted_at,origin.status,origin.is_deleted,part.category,
                           COALESCE(part.amount_local,origin.source_local) AS amount_local,
                           (classified.id IS NULL OR origin.source_local IS NULL OR
                            (origin.source_doc_type NOT IN('PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT','PURCHASE_RETURN','SUBCONTRACT_RETURN',
                              'PURCHASE_IQC_CREDIT','SUBCONTRACT_IQC_CREDIT','SUBCONTRACT_WASTE','SUBCONTRACT_LOSS_OFFSET','LEGACY_OPENING','DIRECT_PAYMENT')
                             AND NOT(origin.source_doc_type='PAYABLE_STATEMENT_CREDIT' AND EXISTS(
                               SELECT 1 FROM finance_payable_statement_adjustment_lines decision
                               JOIN finance_payable_statement_adjustments owner ON owner.id=decision.adjustment_id
                               WHERE decision.credit_ledger_id=origin.id AND decision.id=origin.source_doc_id
                                 AND decision.decision='RELEASED' AND owner.status IN('APPROVED','REVERSED'))))) AS pending
                    FROM origin LEFT JOIN v_finance_open_item_classification_current classified ON classified.ledger_id=origin.id
                    LEFT JOIN finance_open_item_classification_parts part ON part.batch_id=classified.id
                ), posting_events AS (
                    SELECT supplier_id,category,source_doc_type,event_date,amount_local,pending FROM posting_facts
                    UNION ALL SELECT supplier_id,category,source_doc_type,(deleted_at AT TIME ZONE 'Asia/Shanghai')::date,-amount_local,pending
                    FROM posting_facts WHERE status=-1 AND is_deleted AND deleted_at IS NOT NULL
                ), payment_facts AS (
                    SELECT payment.supplier_id,payment.bill_date AS event_date,payment.status,
                           (@reversalDate@ AT TIME ZONE 'Asia/Shanghai')::date AS reversed_date,
                           part.category,COALESCE(part.cash_local,line.amount_local) AS cash_local,
                           COALESCE(part.book_local,%s) AS book_local,classified.id IS NULL AS pending,payment.amount_authority_version>0 AS amount_verified
                    FROM finance_payments payment JOIN finance_payment_lines line ON line.payment_id=payment.id AND NOT line.is_deleted
                    LEFT JOIN v_finance_payment_classification_current classified ON classified.payment_line_id=line.id
                    LEFT JOIN finance_payment_classification_parts part ON part.batch_id=classified.id
                    WHERE payment.status IN(1,-1) AND NOT payment.is_deleted AND payment.legacy_id IS NULL AND payment.legacy_import_run_id IS NULL
                    UNION ALL SELECT payment.supplier_id,payment.bill_date,payment.status,
                           (@reversalDate@ AT TIME ZONE 'Asia/Shanghai')::date,
                           NULL,payment.amount_local,payment.amount_local,true,payment.amount_authority_version>0
                    FROM finance_payments payment WHERE payment.status IN(1,-1) AND NOT payment.is_deleted AND payment.legacy_id IS NULL
                      AND payment.legacy_import_run_id IS NULL AND NOT EXISTS(SELECT 1 FROM finance_payment_lines line WHERE line.payment_id=payment.id AND NOT line.is_deleted)
                      AND NOT EXISTS(SELECT 1 FROM finance_supplier_advances advance WHERE advance.payment_id=payment.id)
                    UNION ALL SELECT payment.supplier_id,payment.bill_date,payment.status,
                           (@reversalDate@ AT TIME ZONE 'Asia/Shanghai')::date,
                           part.category,-COALESCE(part.amount_local,legacy.amount_original_local),0::numeric,classified.id IS NULL,payment.amount_authority_version>0
                    FROM finance_payments payment JOIN ar_ap_ledger legacy ON legacy.source_doc_type='DIRECT_PAYMENT' AND legacy.source_doc_id=payment.id
                    LEFT JOIN v_finance_open_item_classification_current classified ON classified.ledger_id=legacy.id
                    LEFT JOIN finance_open_item_classification_parts part ON part.batch_id=classified.id
                    WHERE payment.status IN(1,-1) AND NOT payment.is_deleted AND payment.legacy_id IS NULL AND payment.legacy_import_run_id IS NULL
                      AND EXISTS(SELECT 1 FROM finance_payment_lines line WHERE line.payment_id=payment.id AND NOT line.is_deleted)
                      AND @legacyPostingProof@
                    UNION ALL SELECT advance.supplier_id,payment.bill_date,payment.status,
                           (payment.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,part.category,
                           COALESCE(part.amount_local,advance.amount_local),COALESCE(part.amount_local,advance.amount_local),part.payment_id IS NULL,true
                    FROM finance_supplier_advances advance JOIN finance_payments payment ON payment.id=advance.payment_id
                    LEFT JOIN finance_supplier_advance_parts part ON part.payment_id=advance.payment_id
                    UNION ALL SELECT advance.supplier_id,refund.effective_date,CASE refund.status WHEN 'APPROVED' THEN 1 ELSE -1 END,
                           (refund.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,refund.source_category,
                           -(refund.bank_local+refund.fee_local),-refund.source_local,false,true
                    FROM finance_supplier_advance_refunds refund JOIN finance_supplier_advances advance ON advance.payment_id=refund.payment_id
                    WHERE refund.status IN('APPROVED','REVERSED')
                ), payment_events AS (
                    SELECT supplier_id,category,event_date,cash_local,book_local,pending,amount_verified FROM payment_facts
                    UNION ALL SELECT supplier_id,category,reversed_date,-cash_local,-book_local,pending,amount_verified FROM payment_facts
                    WHERE status=-1 AND reversed_date IS NOT NULL
                ), offset_facts AS (
                    SELECT offset_row.supplier_id,offset_row.effective_date AS event_date,offset_row.status,
                           (offset_row.reversed_at AT TIME ZONE 'Asia/Shanghai')::date AS reversed_date,
                           part.source_category AS category,COALESCE(part.source_local,offset_row.source_amount_local) AS amount_local,
                           classified.id IS NULL AS pending
                    FROM supplier_open_item_offsets offset_row
                    LEFT JOIN v_finance_supplier_offset_classification_current classified ON classified.offset_id=offset_row.id
                    LEFT JOIN finance_supplier_offset_classification_parts part ON part.batch_id=classified.id
                    UNION ALL SELECT advance.supplier_id,application.effective_date,application.status,
                           (application.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,application.source_category,application.source_local,false
                    FROM finance_supplier_advance_applications application JOIN finance_supplier_advances advance ON advance.payment_id=application.payment_id
                    UNION ALL SELECT advance.supplier_id,application.effective_date,application.status,
                           (application.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,target_part.category,-target_part.target_local,false
                    FROM v_finance_supplier_advance_target_parts_effective target_part
                    JOIN finance_supplier_advance_applications application ON application.id=target_part.application_id
                    JOIN finance_supplier_advances advance ON advance.payment_id=application.payment_id
                    UNION ALL
                    SELECT offset_row.supplier_id,offset_row.effective_date,offset_row.status,
                           (offset_row.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,part.target_category,
                           -COALESCE(part.target_local,offset_row.target_amount_local),classified.id IS NULL
                    FROM supplier_open_item_offsets offset_row
                    LEFT JOIN v_finance_supplier_offset_classification_current classified ON classified.offset_id=offset_row.id
                    LEFT JOIN finance_supplier_offset_classification_parts part ON part.batch_id=classified.id
                ), offset_events AS (
                    SELECT supplier_id,category,event_date,amount_local,pending FROM offset_facts
                    UNION ALL SELECT supplier_id,category,reversed_date,-amount_local,pending FROM offset_facts WHERE status='REVERSED' AND reversed_date IS NOT NULL
                ), events AS (
                    SELECT supplier_id,category,event_date,amount_local AS signed_local,0::numeric AS cash_local,0::numeric AS book_local,
                           CASE WHEN source_doc_type IN('PURCHASE_RECEIPT','SUBCONTRACT_RECEIPT') THEN amount_local ELSE 0 END AS charges,
                           CASE WHEN source_doc_type IN('PURCHASE_RETURN','SUBCONTRACT_RETURN','PURCHASE_IQC_CREDIT','SUBCONTRACT_IQC_CREDIT') AND category='GOODS' THEN amount_local ELSE 0 END AS returned,
                           CASE WHEN source_doc_type IN('SUBCONTRACT_WASTE','SUBCONTRACT_LOSS_OFFSET','PAYABLE_STATEMENT_CREDIT')
                                     OR(source_doc_type IN('PURCHASE_RETURN','SUBCONTRACT_RETURN','PURCHASE_IQC_CREDIT','SUBCONTRACT_IQC_CREDIT') AND category='MOULD')
                                THEN -amount_local ELSE 0 END AS offset_local,pending,true AS amount_verified FROM posting_events
                    UNION ALL SELECT supplier_id,category,event_date,-book_local,cash_local,book_local,0,0,0,pending,amount_verified FROM payment_events
                    UNION ALL SELECT supplier_id,category,event_date,amount_local,0,0,0,0,-amount_local,pending,true FROM offset_events
                ), advance_events AS (
                    SELECT advance.supplier_id,advance.effective_date AS event_date,advance.amount_local AS amount_local
                    FROM finance_supplier_advances advance
                    UNION ALL SELECT advance.supplier_id,(advance.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,-advance.amount_local
                    FROM finance_supplier_advances advance WHERE advance.status='REVERSED'
                    UNION ALL SELECT advance.supplier_id,application.effective_date,-application.source_local
                    FROM finance_supplier_advance_applications application JOIN finance_supplier_advances advance ON advance.payment_id=application.payment_id
                    UNION ALL SELECT advance.supplier_id,(application.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,application.source_local
                    FROM finance_supplier_advance_applications application JOIN finance_supplier_advances advance ON advance.payment_id=application.payment_id WHERE application.status='REVERSED'
                    UNION ALL SELECT advance.supplier_id,refund.effective_date,-refund.source_local
                    FROM finance_supplier_advance_refunds refund JOIN finance_supplier_advances advance ON advance.payment_id=refund.payment_id WHERE refund.status IN('APPROVED','REVERSED')
                    UNION ALL SELECT advance.supplier_id,(refund.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,refund.source_local
                    FROM finance_supplier_advance_refunds refund JOIN finance_supplier_advances advance ON advance.payment_id=refund.payment_id WHERE refund.status='REVERSED'
                ), advance_balances AS (
                    SELECT supplier_id,sum(amount_local) AS remaining FROM advance_events WHERE event_date<=:to GROUP BY supplier_id
                ), balances AS (
                    SELECT supplier_id,bool_or(pending) AS pending,count(*) FILTER(WHERE pending) AS unknown_count,
                        bool_or(NOT amount_verified) AS raw_unknown,bool_or(NOT amount_verified AND event_date<:from) AS prior_raw_unknown,
                        sum(signed_local) FILTER(WHERE event_date<:from) AS prior_balance,sum(signed_local) AS balance,
                        sum(signed_local) FILTER(WHERE event_date<:from AND category='GOODS') AS goods_opening,
                        sum(signed_local) FILTER(WHERE event_date<:from AND category='MOULD') AS mould_opening,
                        sum(signed_local) FILTER(WHERE category='GOODS') AS goods_balance,sum(signed_local) FILTER(WHERE category='MOULD') AS mould_balance,
                        sum(charges) FILTER(WHERE event_date>=:from AND category='GOODS') AS goods_amount,
                        sum(charges) FILTER(WHERE event_date>=:from AND category='MOULD') AS mould_amount,
                        sum(cash_local) FILTER(WHERE event_date>=:from AND category='GOODS') AS goods_paid,
                        sum(cash_local) FILTER(WHERE event_date>=:from AND category='MOULD') AS mould_paid,
                        sum(book_local) FILTER(WHERE event_date>=:from AND category='GOODS') AS goods_settled,
                        sum(book_local) FILTER(WHERE event_date>=:from AND category='MOULD') AS mould_settled,
                        sum(returned) FILTER(WHERE event_date>=:from AND category='GOODS') AS goods_returned,
                        sum(offset_local) FILTER(WHERE event_date>=:from AND category='GOODS') AS goods_offset,
                        sum(offset_local) FILTER(WHERE event_date>=:from AND category='MOULD') AS mould_offset
                    FROM events WHERE event_date<=:to GROUP BY supplier_id
                )
                SELECT supplier.code AS "partyCode",supplier.name AS "partyName",COALESCE(supplier.description,supplier.name) AS "partyFull",
                    CASE supplier.price_style WHEN 6 THEN '月结'||COALESCE(NULLIF(supplier.tday,0),30)||'天'
                         WHEN 1 THEN '现金' WHEN 2 THEN '提货' WHEN 3 THEN '代付' WHEN 4 THEN '支票' WHEN 7 THEN '垫付' WHEN 8 THEN '汇款' WHEN 10 THEN '代收'
                         ELSE CASE WHEN supplier.tday IS NOT NULL AND supplier.tday>0 THEN '账期'||supplier.tday||'天' ELSE '' END END AS settlement,
                    CASE WHEN NOT balance.prior_raw_unknown THEN COALESCE(balance.prior_balance,0) END AS "prevBalance",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.goods_amount,0) END AS "goodsAmount",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.goods_paid,0) END AS "goodsPaidAmount",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.goods_returned,0) END AS "returnAmount",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.goods_offset,0) END AS "goodsOffsetAmount",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.goods_balance,0) END AS "goodsBalance",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.mould_amount,0) END AS "mouldAmount",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.mould_paid,0) END AS "mouldPaidAmount",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.mould_offset,0) END AS "mouldOffsetAmount",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.mould_balance,0) END AS "mouldBalance",CASE WHEN NOT balance.raw_unknown THEN balance.balance END AS "totalBalance",
                    supplier.id AS "__supplierId",balance.pending AS "__pending",
                    CASE WHEN balance.raw_unknown THEN '存在尚未经服务端核验的历史付款；不能通过分类把原未知金额认作已确认事实'
                         WHEN balance.pending THEN '部分来源应付、付款行或抵销尚未完成明确货款/模具款分配；分类金额待核验，已核验的完整应付合计保留'
                         ELSE '本币口径；原表余额为经营往来净额=正式未付应付-未应用预付资产（可负），法定负债与资产仍分别记账；付款为实际供应商资金，退款按银行净到账+实际手续费还原供应商退款总额；预付应用不重复现金。退货保持原负数，反审按原事实反向。货款现金减账面差额='
                              ||(COALESCE(balance.goods_paid,0)-COALESCE(balance.goods_settled,0))::text||'元；模具款现金减账面差额='
                              ||(COALESCE(balance.mould_paid,0)-COALESCE(balance.mould_settled,0))::text||'元；正式未付AP='
                              ||(balance.balance+COALESCE(advance.remaining,0))::text||'元；未应用预付资产='||COALESCE(advance.remaining,0)::text||'元；明确分配分别守恒' END AS "__basis",
                    balance.unknown_count AS "__unknownClassificationCount",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.goods_opening,0) END AS "__goodsOpening",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.mould_opening,0) END AS "__mouldOpening",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.goods_paid,0)-COALESCE(balance.goods_settled,0) END AS "__goodsCashBookDelta",
                    CASE WHEN NOT balance.pending THEN COALESCE(balance.mould_paid,0)-COALESCE(balance.mould_settled,0) END AS "__mouldCashBookDelta",
                    CASE WHEN NOT balance.pending THEN balance.balance-COALESCE(balance.goods_balance,0)-COALESCE(balance.mould_balance,0) END AS "__classificationDifference",
                    COALESCE(advance.remaining,0) AS "__unappliedAdvanceLocal",
                    CASE WHEN NOT balance.raw_unknown THEN balance.balance+COALESCE(advance.remaining,0) END AS "__formalPayableBalance"
                FROM balances balance JOIN suppliers supplier ON supplier.id=balance.supplier_id LEFT JOIN advance_balances advance ON advance.supplier_id=balance.supplier_id
                """.formatted(LegacyOpeningBalanceSql.localAmount("ledger.amount_original_local"),LegacyOpeningBalanceSql.PROOF_JOIN,LegacyOpeningBalanceSql.paymentBookLocal("line"))
                .replace("@representedCashLedger@",com.uten.imp.features.finance.SupplierAdvanceReplaySql.cashRepresentedLedger("ledger"))
                .replace("@legacyPostingProof@",com.uten.imp.features.finance.SupplierAdvanceReplaySql.legacyPostingProof("payment"))
                .replace("@reversalDate@",com.uten.imp.features.finance.SupplierAdvanceReplaySql.reversalDate("payment"));
    }
}
