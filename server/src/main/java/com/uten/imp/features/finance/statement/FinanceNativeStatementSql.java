package com.uten.imp.features.finance.statement;

import com.uten.imp.common.finance.CurrencyDisplayLabel;

/** Native purchase/sales originals and their actual dated reversals share one statement projection. */
final class FinanceNativeStatementSql {
    private FinanceNativeStatementSql() { }
    static String sql(boolean client){
        String first=client?facts("sales_shipments","sales_shipment_items","shipment_id","SALES_SHIPMENT",3,1,true):facts("purchase_receipts","purchase_receipt_items","receipt_id","PURCHASE_RECEIPT",1,1,false);
        String second=client?facts("sales_returns","sales_return_items","return_id","SALES_RETURN",4,-1,true):facts("purchase_returns","purchase_return_items","return_id","PURCHASE_RETURN",2,-1,false);
        String names=client?"party_name AS client_name,goods_name,color_name":"goods_code,goods_name";
        return "WITH raw_facts AS ("+first+" UNION ALL "+second+"), events AS ("+"""
            SELECT raw.*,business_date AS event_date,natural_sign AS event_sign,0 AS event_order FROM raw_facts raw
            WHERE business_date BETWEEN :from AND :to
            UNION ALL SELECT raw.*,reversed_date,-natural_sign,1 FROM raw_facts raw
            WHERE status=-1 AND reversed_date BETWEEN :from AND :to
            )
            SELECT event_date AS bill_date,%s,unit_name,
              CASE WHEN NOT missing_reversal_date THEN quantity*event_sign END AS qty,price,
              CASE WHEN NOT missing_reversal_date THEN amount_original*event_sign END AS amount,
              bill_no||CASE WHEN natural_sign<0 THEN '(退货)' ELSE '' END||CASE WHEN event_order=1 THEN '(反审)' ELSE '' END AS remark,
              currency_code,currency_id,unit_id,party_name,party_code,party_id,source_type,source_id,
              (missing_reversal_date OR amount_original IS NULL OR unit_id IS NULL OR currency_id IS NULL) AS pending,
              CASE WHEN missing_reversal_date THEN '已反审来源缺少冻结的实际反向时间，不能用当前更新时间改写历史'
                WHEN amount_original IS NULL THEN '原成交金额缺失，不能用当前单价重算'
                ELSE '原单成交额与同源实际反向；名称优先原单快照，缺快照时当前名称仅作UUID参考标签' END AS basis,event_order
            FROM events
            """.formatted(names);
    }
    static String reversalDate(String doc,String source,int movementType,int naturalDirection){
        return "CASE WHEN "+doc+".status=-1 THEN COALESCE("+
            "(NULLIF(to_jsonb("+doc+")->>'reversed_at','')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date,"+
            "(SELECT min((ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::date) FROM ar_ap_ledger ledger WHERE ledger.source_doc_type='"+source+"' AND ledger.source_doc_id="+doc+".id AND ledger.status=-1 AND ledger.is_deleted AND ledger.deleted_at IS NOT NULL),"+
            "(SELECT min((movement.transaction_date AT TIME ZONE 'Asia/Shanghai')::date) FROM stock_movements movement WHERE movement.source_doc_type='"+source+"' AND movement.source_doc_id="+doc+".id AND movement.movement_type="+movementType+" AND movement.direction="+(-naturalDirection)+")) END";
    }
    private static String facts(String headers,String items,String parent,String source,int movementType,int sign,boolean client){
        String party=client?"client":"supplier",table=client?"clients":"suppliers";
        String reverse=reversalDate("document",source,movementType,sign);
        // Reversing a header preserves its approved item rows. A line removed
        // while drafting is not an original fact and cannot return on reversal.
        return """
            SELECT COALESCE(item.bill_date,document.bill_date) AS business_date,document.bill_no,document.status,
              %s AS reversed_date,(document.status=-1 AND (%s) IS NULL) AS missing_reversal_date,
              %s::int AS natural_sign,
              COALESCE(NULLIF(to_jsonb(item)->>'goods_code_snapshot',''),goods.code) AS goods_code,
              COALESCE(NULLIF(to_jsonb(item)->>'goods_name_snapshot',''),goods.name) AS goods_name,
              COALESCE(NULLIF(to_jsonb(item)->>'color_name_snapshot',''),color.name,'') AS color_name,
              COALESCE(NULLIF(to_jsonb(item)->>'unit_name_snapshot',''),unit.name,'') AS unit_name,
              item.qty AS quantity,item.price,item.amount_original,%s AS currency_code,
              document.currency_id,item.unit_id,party.name AS party_name,party.code AS party_code,
              document.%s_id AS party_id,'%s'::text AS source_type,item.id AS source_id
            FROM %s item JOIN %s document ON document.id=item.%s
            LEFT JOIN goods ON goods.id=item.goods_id LEFT JOIN colors color ON color.id=item.color_id
            LEFT JOIN units unit ON unit.id=item.unit_id LEFT JOIN %s party ON party.id=document.%s_id
            LEFT JOIN currencies currency ON currency.id=document.currency_id
            WHERE NOT item.is_deleted AND ((document.status=1 AND NOT document.is_deleted) OR document.status=-1)
              AND (CAST(:partyId AS uuid) IS NULL OR document.%s_id=:partyId)
              AND (CAST(:currencyId AS uuid) IS NULL OR document.currency_id=:currencyId)
            """.formatted(reverse,reverse,sign,CurrencyDisplayLabel.sql("currency"),party,source,items,headers,parent,table,party,party);
    }
}
