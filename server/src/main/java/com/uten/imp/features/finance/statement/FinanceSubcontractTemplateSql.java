package com.uten.imp.features.finance.statement;

/** Original document rows are zipped, never cross-joined or repriced at a later receipt's price. */
final class FinanceSubcontractTemplateSql {
    private FinanceSubcontractTemplateSql() { }
    static String sql() {
        return """
                WITH quantity_evidence AS (
                    SELECT * FROM jsonb_to_recordset(CAST(:quantityEvidence AS jsonb)) AS evidence(
                      id uuid,purpose text,evidence_type text,source_kind text,source_item_id uuid,material_issue_item_id uuid,
                      goods_id uuid,color_id uuid,unit_id uuid,quantity numeric,order_item_id uuid,goods_code text,goods_name text)
                ), quantity_groups AS (
                    SELECT DISTINCT goods_id,color_id,unit_id FROM quantity_evidence
                ), opening_counts AS (SELECT * FROM quantity_evidence WHERE purpose='PERIOD_OPENING'),
                ending_counts AS (SELECT * FROM quantity_evidence WHERE purpose='PERIOD_ENDING'),
                loss_rules AS (
                    SELECT * FROM jsonb_to_recordset(CAST(:lossRules AS jsonb)) AS rule(
                        id uuid,"goodsId" uuid,"colorId" uuid,"unitId" uuid,rate numeric,"effectiveFrom" date,"effectiveTo" date)
                ), issue_raw AS (%s UNION ALL %s), receipt_raw AS (%s UNION ALL %s), waste_raw AS (%s),
                issue_events AS (
                    SELECT raw.*,business_date AS bill_date,natural_sign AS sign,0 AS event_order FROM issue_raw raw WHERE business_date<=:to
                    UNION ALL SELECT raw.*,reversed_date,-natural_sign,1 FROM issue_raw raw WHERE status=-1 AND reversed_date<=:to
                ), issue_facts AS (
                    SELECT event.supplier_id,event.goods_id,event.color_id,COALESCE(proven.unit_id,event.unit_id) AS unit_id,event.unit_id AS original_unit_id,
                           event.id,event.bill_no||CASE WHEN event.natural_sign<0 THEN '(材料退回)' ELSE '' END||CASE WHEN event.event_order=1 THEN '(反审)' ELSE '' END AS bill_no,
                           event.bill_date,event.event_order,event.source_kind,event.order_item_id,
                           CASE WHEN NOT event.missing_reversal_date THEN COALESCE(proven.quantity,event.quantity)*event.sign END AS qty,
                           CASE WHEN NOT event.missing_reversal_date THEN COALESCE(proven.quantity,event.quantity)*event.sign*COALESCE(rule.rate,:lossRate) END AS allowed_loss,
                           COALESCE(rule.rate,:lossRate) AS loss_rate,rule.id AS loss_policy_id,event.goods_code_snapshot,event.goods_name_snapshot,
                           event.missing_reversal_date AS pending,proven.id AS quantity_evidence_id
                    FROM issue_events event LEFT JOIN quantity_evidence proven ON proven.purpose='ROW_CORRESPONDENCE'
                      AND proven.source_kind=event.source_kind AND proven.source_item_id=event.id
                    LEFT JOIN loss_rules rule ON rule."goodsId"=event.goods_id AND rule."unitId"=event.unit_id
                      AND(rule."colorId" IS NULL OR rule."colorId"=event.color_id)
                      AND event.loss_basis_date>=rule."effectiveFrom" AND(rule."effectiveTo" IS NULL OR event.loss_basis_date<=rule."effectiveTo")
                ), receipt_events AS (
                    SELECT raw.*,business_date AS bill_date,natural_sign AS sign,0 AS event_order FROM receipt_raw raw WHERE business_date<=:to
                    UNION ALL SELECT raw.*,reversed_date,-natural_sign,1 FROM receipt_raw raw WHERE status=-1 AND reversed_date<=:to
                ), native_receipts AS (
                    SELECT event.*,
                      (EXISTS(SELECT 1 FROM quantity_evidence q WHERE q.purpose='ROW_CORRESPONDENCE' AND q.source_kind=event.source_kind AND q.source_item_id=event.id)
                        AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions consumed
                          WHERE consumed.receipt_item_id=CASE WHEN event.source_kind='PRODUCT_RETURN' THEN(SELECT receipt_item_id FROM subcontract_return_items WHERE id=event.id) ELSE event.id END
                            AND consumed.reversal_of IS NULL AND consumed.qty_doc<>0
                            AND NOT EXISTS(SELECT 1 FROM quantity_evidence q WHERE q.purpose='ROW_CORRESPONDENCE' AND q.source_kind=event.source_kind AND q.source_item_id=event.id AND q.material_issue_item_id=consumed.issue_item_id))) AS proven,
                      (EXISTS(SELECT 1 FROM issue_raw issued WHERE issued.goods_id=event.goods_id AND issued.color_id IS NOT DISTINCT FROM event.color_id AND issued.unit_id=event.unit_id)
                        AND EXISTS(SELECT 1 FROM units WHERE id=event.unit_id AND upper(btrim(code))='PCS')
                        AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions consumption
                          JOIN subcontract_material_issue_items issued ON issued.id=consumption.issue_item_id
                          WHERE consumption.receipt_item_id=CASE WHEN event.source_kind='PRODUCT_RETURN' THEN(SELECT receipt_item_id FROM subcontract_return_items WHERE id=event.id) ELSE event.id END AND consumption.reversal_of IS NULL
                            AND(consumption.consumption_basis<>'DIRECT_TARGET' OR(issued.goods_id,issued.color_id,issued.unit_id) IS DISTINCT FROM(event.goods_id,event.color_id,event.unit_id)))) AS comparable
                    FROM receipt_events event
                ), receipt_facts AS (
                    SELECT supplier_id,currency_id,goods_id,color_id,unit_id,id,event_order,source_kind,order_item_id,
                      bill_no||CASE WHEN natural_sign<0 THEN '(成品退货)' ELSE '' END||CASE WHEN event_order=1 THEN '(反审)' ELSE '' END AS bill_no,bill_date,
                      CASE WHEN NOT missing_reversal_date AND comparable AND NOT proven AND NOT COALESCE(no_company_material,false) THEN quantity*sign END AS qty,
                      CASE WHEN currency_id IS NOT NULL THEN price END AS price,CASE WHEN NOT missing_reversal_date AND currency_id IS NOT NULL THEN amount_original*sign END AS amount_original,
                      goods_code_snapshot,goods_name_snapshot,(missing_reversal_date OR currency_id IS NULL) AS pending,
                      CASE WHEN comparable AND NOT proven AND NOT COALESCE(no_company_material,false) THEN 'STOCK' ELSE 'FEE' END::text AS row_role,
                      true AS has_fee,(NOT comparable AND NOT proven AND NOT COALESCE(no_company_material,false)) AS mapping_pending,
                      quantity*sign AS billing_qty,unit_id AS billing_unit_id,NULL::uuid AS quantity_evidence_id
                    FROM native_receipts
                    UNION ALL
                    SELECT event.supplier_id,event.currency_id,q.goods_id,q.color_id,q.unit_id,event.id,event.event_order,event.source_kind,event.order_item_id,
                      event.bill_no||CASE WHEN event.natural_sign<0 THEN '(成品退货)' ELSE '' END||CASE WHEN event.event_order=1 THEN '(反审)' ELSE '' END,event.bill_date,
                      CASE WHEN NOT event.missing_reversal_date THEN q.quantity*event.sign END,NULL::numeric,NULL::numeric,q.goods_code,q.goods_name,event.missing_reversal_date,
                      'STOCK',false,false,NULL::numeric,NULL::uuid,q.id
                    FROM native_receipts event JOIN quantity_evidence q ON q.purpose='ROW_CORRESPONDENCE' AND q.source_kind=event.source_kind AND q.source_item_id=event.id
                ), incomplete_quantity AS (
                    SELECT EXISTS(SELECT 1 FROM native_receipts event WHERE event.bill_date BETWEEN :from AND :to
                      AND NOT event.comparable AND NOT event.proven AND NOT COALESCE(event.no_company_material,false)) AS pending
                ), waste_events AS (
                    SELECT supplier_id,goods_id,color_id,unit_id,business_date AS bill_date,
                      CASE WHEN NOT missing_reversal_date THEN quantity END AS qty,missing_reversal_date AS pending FROM waste_raw WHERE business_date<=:to
                    UNION ALL SELECT supplier_id,goods_id,color_id,unit_id,reversed_date,-quantity,false FROM waste_raw WHERE status=-1 AND reversed_date<=:to
                ), compensation_events AS (
                    SELECT document.supplier_id,item.goods_id,item.color_id,item.unit_id,allocation.id,'供应商补料'::text AS bill_no,
                      (allocation.created_at AT TIME ZONE 'Asia/Shanghai')::date AS bill_date,allocation.quantity AS qty,0 AS event_order,false AS pending
                    FROM subcontract_loss_fulfillment_allocations allocation JOIN subcontract_loss_case_lines line ON line.id=allocation.case_line_id
                    JOIN subcontract_material_issue_items item ON item.id=line.material_issue_item_id JOIN subcontract_material_issues document ON document.id=item.issue_id
                    WHERE allocation.document_type='SUPPLIER_MATERIAL_REPLACEMENT' AND document.supplier_id=:partyId
                    UNION ALL SELECT document.supplier_id,item.goods_id,item.color_id,item.unit_id,allocation.id,'供应商补料(反转)',
                      (allocation.reversed_at AT TIME ZONE 'Asia/Shanghai')::date,-allocation.quantity,1,false
                    FROM subcontract_loss_fulfillment_allocations allocation JOIN subcontract_loss_case_lines line ON line.id=allocation.case_line_id
                    JOIN subcontract_material_issue_items item ON item.id=line.material_issue_item_id JOIN subcontract_material_issues document ON document.id=item.issue_id
                    WHERE allocation.document_type='SUPPLIER_MATERIAL_REPLACEMENT' AND document.supplier_id=:partyId AND allocation.status='REVERSED'
                ), issue_display AS (
                    SELECT * FROM issue_facts
                    UNION ALL SELECT supplier_id,goods_id,color_id,unit_id,unit_id,id,bill_no,bill_date,event_order,'MATERIAL_REPLACEMENT',NULL::uuid,
                      qty,0::numeric,NULL::numeric,NULL::uuid,NULL::text,NULL::text,pending,NULL::uuid FROM compensation_events WHERE bill_date<=:to
                ), deduction_events AS (
                    SELECT ledger.id AS ledger_id,line.material_issue_item_id,ledger.bill_date AS event_date,-ledger.amount_original AS amount,resolution.quantity
                    FROM subcontract_loss_resolutions resolution JOIN subcontract_loss_case_lines line ON line.id=resolution.case_line_id
                    JOIN ar_ap_ledger ledger ON ledger.id=resolution.offset_ledger_id
                    WHERE resolution.resolution_type='AP_OFFSET' AND ledger.supplier_id=:partyId AND ledger.currency_id=:currencyId
                      AND((ledger.status=1 AND NOT ledger.is_deleted) OR(ledger.status=-1 AND ledger.is_deleted AND ledger.deleted_at IS NOT NULL))
                    UNION ALL SELECT ledger.id,line.material_issue_item_id,(ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::date,ledger.amount_original,-resolution.quantity
                    FROM subcontract_loss_resolutions resolution JOIN subcontract_loss_case_lines line ON line.id=resolution.case_line_id
                    JOIN ar_ap_ledger ledger ON ledger.id=resolution.offset_ledger_id
                    WHERE resolution.resolution_type='AP_OFFSET' AND ledger.supplier_id=:partyId AND ledger.currency_id=:currencyId AND ledger.status=-1 AND ledger.is_deleted AND ledger.deleted_at IS NOT NULL
                ), deduction_facts AS (
                    SELECT source.goods_id,source.color_id,source.unit_id,source.original_unit_id,event.*,
                      FIRST_VALUE(event.amount) OVER price_basis AS reference_amount,FIRST_VALUE(event.quantity) OVER price_basis AS reference_quantity
                    FROM deduction_events event JOIN(SELECT DISTINCT goods_id,color_id,unit_id,original_unit_id,id FROM issue_facts) source ON source.id=event.material_issue_item_id
                    WHERE event.event_date BETWEEN :from AND :to
                    WINDOW price_basis AS(PARTITION BY source.goods_id,source.color_id,source.unit_id ORDER BY event.event_date,event.ledger_id,event.amount,event.quantity)
                ), deductions AS (
                    SELECT event.goods_id,event.color_id,event.unit_id,
                      CASE WHEN bool_or(event.amount IS NULL) THEN NULL ELSE SUM(event.amount) END AS amount,bool_or(event.amount IS NULL) AS pending,
                      bool_or(event.original_unit_id IS DISTINCT FROM event.unit_id) AS price_pending,
                      CASE WHEN bool_or(event.original_unit_id IS DISTINCT FROM event.unit_id OR event.quantity IS NULL OR event.quantity=0 OR event.amount IS NULL)
                        OR bool_or(event.amount*event.reference_quantity<>event.reference_amount*event.quantity) THEN NULL
                        ELSE fn_business_exact_divide(MIN(event.reference_amount),MIN(event.reference_quantity),'finance.subcontract.material-price','委外对账单材料扣款单价',30) END AS price
                    FROM deduction_facts event GROUP BY event.goods_id,event.color_id,event.unit_id
                ), unmatched_deductions AS (
                    SELECT count(*)>0 AS pending FROM ar_ap_ledger ledger WHERE ledger.direction='AP' AND ledger.supplier_id=:partyId AND ledger.currency_id=:currencyId
                      AND ledger.source_doc_type IN('SUBCONTRACT_WASTE','SUBCONTRACT_LOSS_OFFSET')
                      AND(ledger.bill_date BETWEEN :from AND :to OR(ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::date BETWEEN :from AND :to)
                      AND((ledger.status=1 AND NOT ledger.is_deleted) OR(ledger.status=-1 AND ledger.is_deleted AND ledger.deleted_at IS NOT NULL))
                      AND NOT EXISTS(SELECT 1 FROM deduction_events event JOIN issue_facts source ON source.id=event.material_issue_item_id WHERE event.ledger_id=ledger.id)
                ), movements AS (
                    SELECT supplier_id,goods_id,color_id,unit_id,CASE WHEN bill_date<:from THEN qty ELSE 0 END AS prior,
                      CASE WHEN bill_date>=:from THEN qty ELSE 0 END AS issued,0::numeric AS received,
                      CASE WHEN bill_date>=:from THEN allowed_loss ELSE 0 END AS issue_loss,false AS other_currency,pending
                    FROM issue_display
                    UNION ALL SELECT supplier_id,goods_id,color_id,unit_id,CASE WHEN bill_date<:from THEN -qty ELSE 0 END,0::numeric,
                      CASE WHEN bill_date>=:from THEN qty ELSE 0 END,0::numeric,
                      bill_date>=:from AND has_fee AND currency_id IS DISTINCT FROM :currencyId,pending
                    FROM receipt_facts WHERE row_role='STOCK'
                    UNION ALL SELECT supplier_id,goods_id,color_id,unit_id,CASE WHEN bill_date<:from THEN -qty ELSE 0 END,0::numeric,0::numeric,0::numeric,false,pending FROM waste_events
                ), physical AS (
                    SELECT supplier_id,goods_id,color_id,unit_id,
                      CASE WHEN unit_id IS NOT NULL AND NOT bool_or(pending) THEN SUM(prior) END AS opening_qty,
                      CASE WHEN unit_id IS NOT NULL AND NOT bool_or(pending) THEN SUM(issued) END AS issue_qty,
                      CASE WHEN unit_id IS NOT NULL AND NOT bool_or(pending) THEN SUM(received) END AS receipt_qty,
                      CASE WHEN unit_id IS NOT NULL AND NOT bool_or(pending) THEN SUM(issue_loss) END AS issue_loss,
                      bool_or(other_currency) AS other_currency,bool_or(pending) AS pending
                    FROM movements GROUP BY supplier_id,goods_id,color_id,unit_id
                ), stock_dimensions AS (
                    SELECT supplier_id,goods_id,color_id,unit_id FROM physical
                    UNION SELECT :partyId,goods_id,color_id,unit_id FROM quantity_groups
                ), dimensions AS (
                    SELECT dimension.*,COALESCE(opening.quantity,CASE WHEN controlled.goods_id IS NULL THEN physical.opening_qty END) AS opening_qty,
                      CASE WHEN physical.supplier_id IS NULL THEN 0 ELSE physical.issue_qty END AS issue_qty,
                      CASE WHEN physical.supplier_id IS NULL THEN 0 ELSE physical.receipt_qty END AS receipt_qty,
                      CASE WHEN physical.supplier_id IS NULL THEN 0 ELSE physical.issue_loss END AS issue_loss,
                      COALESCE(physical.other_currency,false) AS other_currency,COALESCE(physical.pending,false) AS pending,
                      (controlled.goods_id IS NOT NULL AND opening.id IS NULL OR incomplete.pending) AS quantity_pending,
                      'STOCK'::text AS row_role,ending.quantity AS confirmed_ending
                    FROM stock_dimensions dimension LEFT JOIN physical ON physical.supplier_id=dimension.supplier_id AND physical.goods_id=dimension.goods_id
                      AND physical.color_id IS NOT DISTINCT FROM dimension.color_id AND physical.unit_id IS NOT DISTINCT FROM dimension.unit_id
                    LEFT JOIN quantity_groups controlled ON controlled.goods_id=dimension.goods_id AND controlled.color_id IS NOT DISTINCT FROM dimension.color_id AND controlled.unit_id IS NOT DISTINCT FROM dimension.unit_id
                    LEFT JOIN opening_counts opening ON opening.goods_id=dimension.goods_id AND opening.color_id IS NOT DISTINCT FROM dimension.color_id AND opening.unit_id IS NOT DISTINCT FROM dimension.unit_id
                    LEFT JOIN ending_counts ending ON ending.goods_id=dimension.goods_id AND ending.color_id IS NOT DISTINCT FROM dimension.color_id AND ending.unit_id IS NOT DISTINCT FROM dimension.unit_id
                    CROSS JOIN incomplete_quantity incomplete
                    UNION ALL SELECT supplier_id,goods_id,color_id,unit_id,NULL::numeric,0::numeric,0::numeric,0::numeric,false,false,false,'FEE',NULL::numeric
                    FROM receipt_facts WHERE row_role='FEE' AND(currency_id=:currencyId OR currency_id IS NULL) AND bill_date BETWEEN :from AND :to GROUP BY supplier_id,goods_id,color_id,unit_id
                ), issues AS (
                    SELECT *,ROW_NUMBER() OVER(PARTITION BY supplier_id,goods_id,color_id,unit_id ORDER BY bill_date,bill_no,id,event_order) AS rn
                    FROM issue_display WHERE bill_date>=:from
                ), receipts AS (
                    SELECT *,ROW_NUMBER() OVER(PARTITION BY supplier_id,goods_id,color_id,unit_id,row_role ORDER BY bill_date,bill_no,id,event_order,quantity_evidence_id) AS rn
                    FROM receipt_facts WHERE bill_date>=:from AND(row_role='STOCK' OR currency_id=:currencyId OR currency_id IS NULL)
                ), sizes AS (
                    SELECT p.*,GREATEST(1,COALESCE((SELECT max(i.rn) FROM issues i WHERE p.row_role='STOCK' AND i.supplier_id=p.supplier_id AND i.goods_id=p.goods_id AND i.color_id IS NOT DISTINCT FROM p.color_id AND i.unit_id IS NOT DISTINCT FROM p.unit_id),0),
                      COALESCE((SELECT max(r.rn) FROM receipts r WHERE r.supplier_id=p.supplier_id AND r.goods_id=p.goods_id AND r.color_id IS NOT DISTINCT FROM p.color_id AND r.unit_id IS NOT DISTINCT FROM p.unit_id AND r.row_role=p.row_role),0)) AS row_count,
                      deduction.amount AS deduction_amount,deduction.price AS deduction_price,COALESCE(deduction.pending,false) AS deduction_pending,COALESCE(deduction.price_pending,false) AS deduction_price_pending
                    FROM dimensions p LEFT JOIN deductions deduction ON p.row_role='STOCK' AND deduction.goods_id=p.goods_id AND deduction.color_id IS NOT DISTINCT FROM p.color_id AND deduction.unit_id IS NOT DISTINCT FROM p.unit_id
                ), detailed AS (
                    SELECT p.*,slot.rn,i.bill_no AS issue_no,i.bill_date AS issue_date,i.qty AS issue_line_qty,i.allowed_loss,i.loss_rate,i.loss_policy_id,i.id AS issue_item_id,
                      r.bill_no AS receipt_no,r.bill_date AS receipt_date,r.qty AS receipt_line_qty,r.price,r.amount_original,r.has_fee,r.mapping_pending AS receipt_mapping_pending,r.pending AS receipt_pending,r.id AS receipt_item_id,
                      r.billing_qty,r.billing_unit_id,COALESCE(i.goods_code_snapshot,r.goods_code_snapshot) AS goods_code_snapshot,COALESCE(i.goods_name_snapshot,r.goods_name_snapshot) AS goods_name_snapshot
                    FROM sizes p CROSS JOIN LATERAL generate_series(1,p.row_count) slot(rn)
                    LEFT JOIN issues i ON p.row_role='STOCK' AND i.supplier_id=p.supplier_id AND i.goods_id=p.goods_id AND i.color_id IS NOT DISTINCT FROM p.color_id AND i.unit_id IS NOT DISTINCT FROM p.unit_id AND i.rn=slot.rn
                    LEFT JOIN receipts r ON r.supplier_id=p.supplier_id AND r.goods_id=p.goods_id AND r.color_id IS NOT DISTINCT FROM p.color_id AND r.unit_id IS NOT DISTINCT FROM p.unit_id AND r.row_role=p.row_role AND r.rn=slot.rn
                    WHERE p.row_role='FEE' OR p.quantity_pending OR p.pending OR p.opening_qty IS NULL OR p.opening_qty<>0 OR p.issue_qty<>0 OR p.receipt_qty<>0 OR i.id IS NOT NULL OR r.id IS NOT NULL OR p.deduction_amount IS NOT NULL
                )
                SELECT CASE WHEN d.rn=1 THEN DENSE_RANK() OVER(ORDER BY g.code,d.goods_id,d.color_id,d.unit_id,d.row_role) END AS "rowNo",
                  COALESCE(d.goods_code_snapshot,g.code) AS "goodsCode",COALESCE(d.goods_name_snapshot,g.name) AS "goodsName",COALESCE(color.name,'') AS color,
                  CASE WHEN d.row_role='STOCK' AND NOT d.quantity_pending AND d.rn=1 AND upper(btrim(unit.code))='PCS' THEN d.opening_qty END AS "prevStock",
                  d.issue_no AS "issueBillNo",d.issue_date AS "issueDate",CASE WHEN upper(btrim(unit.code))='PCS' THEN d.issue_line_qty END AS "issueQty",
                  CASE WHEN d.row_role='STOCK' AND NOT d.quantity_pending AND d.rn=1 AND upper(btrim(unit.code))='PCS' THEN d.issue_qty END AS "issueTotalQty",
                  CASE WHEN upper(btrim(unit.code))='PCS' THEN d.allowed_loss END AS "lossAllowed",d.receipt_no AS "receiptBillNo",d.receipt_date AS "receiptDate",
                  CASE WHEN d.row_role='STOCK' AND upper(btrim(unit.code))='PCS' THEN d.receipt_line_qty END AS "receiptQty",
                  CASE WHEN d.row_role='STOCK' AND NOT d.quantity_pending AND d.rn=1 AND upper(btrim(unit.code))='PCS' THEN d.receipt_qty END AS "receiptTotalQty",
                  CASE WHEN d.row_role='STOCK' AND NOT d.quantity_pending AND NOT d.pending AND d.rn=1 AND upper(btrim(unit.code))='PCS' THEN d.opening_qty+d.issue_qty-d.issue_loss-d.receipt_qty END AS balance,
                  CASE WHEN d.has_fee THEN d.price END AS "processPrice",CASE WHEN d.has_fee THEN d.amount_original END AS "processAmount",
                  CASE WHEN d.row_role='STOCK' AND d.rn=1 AND upper(btrim(unit.code))='PCS' THEN d.deduction_price END AS "materialPrice",
                  CASE WHEN d.row_role='STOCK' AND d.rn=1 AND NOT unmatched.pending AND NOT d.deduction_pending THEN COALESCE(d.deduction_amount,0) END AS "materialAmount",
                  d.unit_id AS "__unitId",:currencyId AS "__currencyId",currency.code AS "__currencyCode",d.receipt_item_id AS "__receiptItemId",d.issue_item_id AS "__issueItemId",
                  supplier.name AS "__partyName",supplier.code AS "__partyCode",
                  (d.pending OR d.quantity_pending OR COALESCE(d.receipt_pending,false) OR COALESCE(d.receipt_mapping_pending,false) OR(d.row_role='STOCK' AND COALESCE(upper(btrim(unit.code)),'')<>'PCS') OR d.other_currency OR unmatched.pending OR d.deduction_pending OR d.deduction_price_pending OR(d.has_fee AND d.amount_original IS NULL)) AS "__pending",
                  d.loss_rate*100 AS "__lossRatePercent",d.loss_policy_id AS "__lossPolicyId",
                  CASE WHEN d.pending OR COALESCE(d.receipt_pending,false) THEN '已反审来源缺少冻结的实际反向时间，不能用当前累计或更新时间倒灌历史'
                    WHEN d.quantity_pending OR COALESCE(d.receipt_mapping_pending,false) THEN '原数量对应尚待完整受审；冻结BOM估计不冒充实际材料结存，未知不填0'
                    WHEN d.row_role='FEE' THEN '唯一原成品收费行；库存列不适用，原计价数量/单位、原单价及原额保留，不按材料当量回乘'
                    WHEN COALESCE(upper(btrim(unit.code)),'')<>'PCS' THEN '来源单位尚未对应原表PCS，不能按名称或前缀猜配'
                    WHEN d.other_currency THEN '原同量纲实物流含其他币别，须核对完整数量来源，不混币计算加工金额'
                    WHEN unmatched.pending OR d.deduction_pending OR d.deduction_price_pending THEN '材料扣款保原来源原额；未有实际PCS或单价依据时保留待核'
                    ELSE '本期财务原表数量按已审核真实来源或双方确认当量；账载冻结估计与实盘分别核对，未改仓库/成本/原计价量和原额' END
                    ||CASE WHEN d.has_fee THEN '；原计价数量='||COALESCE(d.billing_qty::text,'待核')||COALESCE(unit.code,'（单位待核）') ELSE '' END
                    ||CASE WHEN d.row_role='STOCK' AND d.rn=1 AND d.confirmed_ending IS NOT NULL THEN '；本期已审尾料实盘='||d.confirmed_ending::text||'PCS，原表公式减实盘差异='||COALESCE((d.opening_qty+d.issue_qty-d.issue_loss-d.receipt_qty-d.confirmed_ending)::text,'待核')||'PCS' ELSE '' END AS "__basis",
                  d.goods_id AS "__goodsId",d.color_id AS "__colorId",d.rn AS "__lineOrdinal",
                  CASE WHEN d.has_fee THEN d.amount_original ELSE 0 END AS "__processAmountForTotal",
                  CASE WHEN d.row_role<>'STOCK' OR d.rn<>1 THEN 0 WHEN NOT unmatched.pending AND NOT d.deduction_pending THEN COALESCE(d.deduction_amount,0) END AS "__materialAmountForTotal",
                  CASE WHEN d.row_role='FEE' THEN 'prevStock,issueQty,issueTotalQty,lossAllowed,receiptQty,receiptTotalQty,balance,materialPrice,materialAmount' WHEN d.has_fee IS NOT TRUE THEN 'processPrice,processAmount' ELSE '' END AS "__notApplicable",
                  d.billing_qty AS "__billingQty",d.billing_unit_id AS "__billingUnitId",d.row_role AS "__quantityRole",
                  CASE WHEN d.rn=1 THEN d.confirmed_ending END AS "__confirmedEndingQty",
                  CASE WHEN d.row_role='STOCK' AND NOT d.quantity_pending AND NOT d.pending AND d.rn=1 AND upper(btrim(unit.code))='PCS' THEN d.opening_qty+d.issue_qty-d.issue_loss-d.receipt_qty-d.confirmed_ending END AS "__tailDifferenceQty"
                FROM detailed d CROSS JOIN unmatched_deductions unmatched JOIN goods g ON g.id=d.goods_id JOIN suppliers supplier ON supplier.id=d.supplier_id
                LEFT JOIN colors color ON color.id=d.color_id LEFT JOIN currencies currency ON currency.id=:currencyId LEFT JOIN units unit ON unit.id=d.unit_id
                """.formatted(
                  facts("subcontract_material_issues","subcontract_material_issue_items","issue_id","SUBCONTRACT_MATERIAL_ISSUE",15,-1,1,false,false),
                  facts("subcontract_material_returns","subcontract_material_return_items","material_return_id","SUBCONTRACT_MATERIAL_RETURN",16,1,-1,false,true),
                  facts("subcontract_receipts","subcontract_receipt_items","receipt_id","SUBCONTRACT_RECEIPT",17,1,1,true,false),
                  facts("subcontract_returns","subcontract_return_items","return_id","SUBCONTRACT_RETURN",18,-1,-1,true,false),
                  facts("subcontract_wastes","subcontract_waste_items","waste_id","SUBCONTRACT_WASTE",19,-1,1,false,false));
    }
    static String facts(String headers,String items,String parent,String source,int movementType,int direction,int sign,boolean monetary,boolean materialReturn){
        // Financial reconciliation may reverse before the physical source. Prefer the source's immutable reversal.
        String family=switch(source){case "SUBCONTRACT_MATERIAL_ISSUE"->"subcontractMaterialIssue";case "SUBCONTRACT_MATERIAL_RETURN"->"subcontractMaterialReturn";case "SUBCONTRACT_RECEIPT"->"subcontractReceipt";case "SUBCONTRACT_RETURN"->"subcontractReturn";case "SUBCONTRACT_WASTE"->"subcontractWaste";default->throw new IllegalArgumentException(source);};
        String lineage="(SELECT min((lineage.created_at AT TIME ZONE 'Asia/Shanghai')::date) FROM document_unapprovals lineage WHERE lineage.family='"+family+"' AND lineage.original_id=document.id)";
        String movement="(SELECT min((movement.transaction_date AT TIME ZONE 'Asia/Shanghai')::date) FROM stock_movements movement WHERE movement.source_doc_type='"+source+"' AND movement.source_doc_id=document.id AND movement.movement_type="+movementType+" AND movement.direction="+(-direction)+")";
        String reverse="COALESCE("+lineage+","+movement+","+FinanceNativeStatementSql.reversalDate("document",source,movementType,direction)+")";
        if(source.equals("SUBCONTRACT_RECEIPT"))reverse="COALESCE((SELECT min((reversal.created_at AT TIME ZONE 'Asia/Shanghai')::date) FROM procurement_iqc_consideration_reversals reversal JOIN procurement_receipt_consideration_parts part ON part.id=reversal.target_id WHERE reversal.target_kind='CONSIDERATION' AND part.receipt_type='SUBCONTRACT' AND part.receipt_id=document.id),"+reverse+")";
        if(source.equals("SUBCONTRACT_WASTE"))reverse="COALESCE("+reverse+",(SELECT min((event.occurred_at AT TIME ZONE 'Asia/Shanghai')::date) FROM stock_value_events event WHERE event.source_doc_id=document.id AND event.source_doc_type IN('SUBCONTRACT_NORMAL_LOSS_REVERSE','SUBCONTRACT_EXCESS_LOSS_REVERSE')),(SELECT min((lineage.created_at AT TIME ZONE 'Asia/Shanghai')::date) FROM document_unapprovals lineage WHERE lineage.family='subcontractWaste' AND lineage.original_id=document.id))";
        reverse="CASE WHEN document.status=-1 THEN "+reverse+" END";
        String basis=materialReturn?"COALESCE((SELECT COALESCE(origin.bill_date,header.bill_date) FROM subcontract_material_issue_items origin JOIN subcontract_material_issues header ON header.id=origin.issue_id WHERE origin.id=item.material_issue_item_id),item.bill_date,document.bill_date)":"COALESCE(item.bill_date,document.bill_date)";
        return "SELECT document.supplier_id,item.goods_id,item.color_id,item.unit_id,item.id,COALESCE(item.bill_no,document.bill_no) AS bill_no,COALESCE(item.bill_date,document.bill_date) AS business_date,"+basis+" AS loss_basis_date,document.status,"+reverse+" AS reversed_date,(document.status=-1 AND ("+reverse+") IS NULL) AS missing_reversal_date,"+sign+" AS natural_sign,item.qty AS quantity,"+(monetary?"document.currency_id,item.price,item.amount_original":"NULL::uuid AS currency_id,NULL::numeric AS price,NULL::numeric AS amount_original")+",NULLIF(to_jsonb(item)->>'goods_code_snapshot','') AS goods_code_snapshot,NULLIF(to_jsonb(item)->>'goods_name_snapshot','') AS goods_name_snapshot,'"+quantityKind(source)+"'::text AS source_kind,NULLIF(to_jsonb(item)->>'order_item_id','')::uuid AS order_item_id,"+noCompanyMaterial(source)+" AS no_company_material FROM "+items+" item JOIN "+headers+" document ON document.id=item."+parent+" WHERE ((document.status=1 AND NOT document.is_deleted AND NOT item.is_deleted) OR document.status=-1) AND document.supplier_id=:partyId";
    }
    private static String quantityKind(String source){return switch(source){case "SUBCONTRACT_MATERIAL_ISSUE"->"MATERIAL_ISSUE";case "SUBCONTRACT_MATERIAL_RETURN"->"MATERIAL_RETURN";case "SUBCONTRACT_RECEIPT"->"RECEIPT";case "SUBCONTRACT_RETURN"->"PRODUCT_RETURN";case "SUBCONTRACT_WASTE"->"WASTE";default->throw new IllegalArgumentException(source);};}
    private static String noCompanyMaterial(String source){return source.equals("SUBCONTRACT_RECEIPT")?"(NULLIF(to_jsonb(item)->>'material_basis_qty','')::numeric=0)":source.equals("SUBCONTRACT_RETURN")?"EXISTS(SELECT 1 FROM subcontract_receipt_items origin WHERE origin.id=item.receipt_item_id AND NULLIF(to_jsonb(origin)->>'material_basis_qty','')::numeric=0)":"false";}
    static String relevantSourcesSql(){
        String original=facts("subcontract_material_issues","subcontract_material_issue_items","issue_id","SUBCONTRACT_MATERIAL_ISSUE",15,-1,1,false,false)+" UNION ALL "+facts("subcontract_material_returns","subcontract_material_return_items","material_return_id","SUBCONTRACT_MATERIAL_RETURN",16,1,-1,false,true)+" UNION ALL "+facts("subcontract_receipts","subcontract_receipt_items","receipt_id","SUBCONTRACT_RECEIPT",17,1,1,true,false)+" UNION ALL "+facts("subcontract_returns","subcontract_return_items","return_id","SUBCONTRACT_RETURN",18,-1,-1,true,false);
        return "WITH raw AS("+original+") SELECT id,source_kind FROM raw WHERE business_date BETWEEN :from AND :to OR(status=-1 AND reversed_date BETWEEN :from AND :to)";
    }
}
