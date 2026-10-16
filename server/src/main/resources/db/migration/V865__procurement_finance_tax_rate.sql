-- Finance tax is a decision of the claimed reviewer, independent from immutable submitted terms.
ALTER TABLE procurement_order_approval_cases
    ADD COLUMN finance_tax_rate NUMERIC(7,4),
    ADD CONSTRAINT ck_procurement_finance_tax_rate CHECK(finance_tax_rate BETWEEN 0 AND 100);
COMMENT ON COLUMN procurement_order_approval_cases.finance_tax_rate IS
    'Finance-confirmed 0..100 percent tax, frozen with the approval event; submitted order tax and hash remain unchanged';

CREATE FUNCTION fn_procurement_approved_tax_rate(p_kind TEXT,p_order UUID,p_contract NUMERIC)
RETURNS NUMERIC LANGUAGE SQL STABLE AS $$
    SELECT COALESCE((SELECT finance_tax_rate FROM procurement_order_approval_cases
        WHERE order_type=p_kind AND order_id=p_order AND status='APPROVED'
        ORDER BY attempt DESC LIMIT 1),p_contract)
$$;

-- Read-only order-price evidence; no receipt/invoice multiplication and no second monetary ledger.
CREATE OR REPLACE VIEW v_goods_price_observations AS
SELECT 'PURCHASE'::text kind, 'PURCHASE_ORDER'::text source_type,
       o.id source_id,i.id source_item_id,o.bill_no source_no,o.bill_date business_date,
       o.updated_at order_updated_at,i.updated_at item_updated_at,
       i.goods_id,i.goods_code_snapshot,i.goods_name_snapshot,i.color_id,i.unit_id,i.unit_rate,
       u.name unit_name,o.currency_id,c.name currency_name,fn_procurement_approved_tax_rate('PURCHASE',o.id,o.tax_rate)::numeric(18,4) tax_rate,
       o.supplier_id supplier_id,NULL::uuid client_id,
       partner.name partner_name,o.maker_id owner_employee_id,
       i.qty quantity,i.price recorded_unit_price,i.amount_original,
       i.total_amount_input total_amount_input,
       COALESCE(i.gift_qty,0) gift_quantity,
       COALESCE(i.extra_columns,'[]'::jsonb) extra_columns,o.exchange_rate contract_exchange_rate,
       approved.id finance_approval_case_id,
       approved.finance_exchange_rate finance_exchange_rate,
       approved.finance_total_local finance_total_local,
       approved.status approval_status,
       approved.submission_snapshot || jsonb_build_object('_contractTaxRate',o.tax_rate,'_financeTaxRate',approved.finance_tax_rate) approval_snapshot,
       approved.decided_at approval_decided_at,
       1::numeric discount_factor,col.name color_name
FROM purchase_order_items i JOIN purchase_orders o ON o.id=i.order_id
LEFT JOIN units u ON u.id=i.unit_id LEFT JOIN currencies c ON c.id=o.currency_id
LEFT JOIN suppliers partner ON partner.id=o.supplier_id
LEFT JOIN colors col ON col.id=i.color_id
LEFT JOIN LATERAL (
    SELECT a.id,a.finance_exchange_rate,a.finance_total_local,a.finance_tax_rate,a.status,a.submission_snapshot,a.decided_at
    FROM procurement_order_approval_cases a
    WHERE a.order_type='PURCHASE' AND a.order_id=o.id
    ORDER BY a.attempt DESC LIMIT 1
) approved ON true
WHERE o.status=1 AND NOT o.is_deleted AND NOT i.is_deleted
UNION ALL
SELECT 'SUBCONTRACT'::text kind, 'SUBCONTRACT_ORDER'::text source_type,
       o.id source_id,i.id source_item_id,o.bill_no source_no,o.bill_date business_date,
       o.updated_at order_updated_at,i.updated_at item_updated_at,
       i.goods_id,i.goods_code_snapshot,i.goods_name_snapshot,i.color_id,i.unit_id,i.unit_rate,
       u.name unit_name,o.currency_id,c.name currency_name,fn_procurement_approved_tax_rate('SUBCONTRACT',o.id,o.tax_rate)::numeric(18,4) tax_rate,
       o.supplier_id supplier_id,NULL::uuid client_id,
       partner.name partner_name,o.maker_id owner_employee_id,
       i.qty quantity,i.price recorded_unit_price,i.amount_original,
       i.total_amount_input total_amount_input,
       0::numeric gift_quantity,
       COALESCE(i.extra_columns,'[]'::jsonb) extra_columns,o.exchange_rate contract_exchange_rate,
       approved.id finance_approval_case_id,
       approved.finance_exchange_rate finance_exchange_rate,
       approved.finance_total_local finance_total_local,
       approved.status approval_status,
       approved.submission_snapshot || jsonb_build_object('_contractTaxRate',o.tax_rate,'_financeTaxRate',approved.finance_tax_rate) approval_snapshot,
       approved.decided_at approval_decided_at,
       1::numeric discount_factor,col.name color_name
FROM subcontract_order_items i JOIN subcontract_orders o ON o.id=i.order_id
LEFT JOIN units u ON u.id=i.unit_id LEFT JOIN currencies c ON c.id=o.currency_id
LEFT JOIN suppliers partner ON partner.id=o.supplier_id
LEFT JOIN colors col ON col.id=i.color_id
LEFT JOIN LATERAL (
    SELECT a.id,a.finance_exchange_rate,a.finance_total_local,a.finance_tax_rate,a.status,a.submission_snapshot,a.decided_at
    FROM procurement_order_approval_cases a
    WHERE a.order_type='SUBCONTRACT' AND a.order_id=o.id
    ORDER BY a.attempt DESC LIMIT 1
) approved ON true
WHERE o.status=1 AND NOT o.is_deleted AND NOT i.is_deleted
UNION ALL
SELECT 'SALES'::text kind, 'SALES_ORDER'::text source_type,
       o.id source_id,i.id source_item_id,o.bill_no source_no,o.bill_date business_date,
       o.updated_at order_updated_at,i.updated_at item_updated_at,
       i.goods_id,i.goods_code_snapshot,i.goods_name_snapshot,i.color_id,i.unit_id,i.unit_rate,
       u.name unit_name,o.currency_id,c.name currency_name,o.tax_rate,
       NULL::uuid supplier_id,o.client_id client_id,
       partner.name partner_name,o.owner_employee_id owner_employee_id,
       i.qty quantity,i.price recorded_unit_price,i.amount_original,
       NULL::numeric total_amount_input,
       0::numeric gift_quantity,
       COALESCE(i.extra_columns,'[]'::jsonb) extra_columns,o.exchange_rate contract_exchange_rate,
       NULL::uuid finance_approval_case_id,
       NULL::numeric finance_exchange_rate,
       NULL::numeric finance_total_local,
       NULL::text approval_status,NULL::jsonb approval_snapshot,o.approved_at approval_decided_at,
       CASE WHEN i.discount IS NULL OR i.discount=0 THEN 1 ELSE i.discount END discount_factor,col.name color_name
FROM sales_order_items i JOIN sales_orders o ON o.id=i.order_id
LEFT JOIN units u ON u.id=i.unit_id LEFT JOIN currencies c ON c.id=o.currency_id
LEFT JOIN clients partner ON partner.id=o.client_id
LEFT JOIN colors col ON col.id=i.color_id

WHERE o.status=1 AND NOT o.is_deleted AND NOT i.is_deleted AND i.chain_status<>-1;
COMMENT ON VIEW v_goods_price_observations IS
    'Approved original-currency order terms, isolated by kind. Consumers MUST enforce source permissions and owner scope before aggregation. Financial FX is approval-case authority, never a rewrite of order terms.';

-- Historical snapshots have an explicit version identity and NEVER enter the reference-price pool.
-- No current master label is used to invent a missing historical description.
CREATE OR REPLACE VIEW v_goods_price_history AS
SELECT current.*,COALESCE(current.finance_approval_case_id,current.source_id) history_version_id,
       'ACTIVE'::text lifecycle,false historical_only,NULL::jsonb snapshot_filter,'CURRENT'::text history_kind
FROM v_goods_price_observations current
UNION ALL
SELECT mapped.*,c.id history_version_id,
       CASE WHEN COALESCE(po.is_deleted,so.is_deleted,false) THEN 'SOURCE_DELETED'
            WHEN COALESCE(po.status,so.status,0)=-1 THEN 'SOURCE_REVERSED'
            ELSE 'SUPERSEDED_APPROVED_VERSION' END lifecycle,
       true historical_only,c.submission_snapshot snapshot_filter,'PROCUREMENT_CASE'::text history_kind
FROM procurement_order_approval_cases c
LEFT JOIN purchase_orders po ON c.order_type='PURCHASE' AND po.id=c.order_id
LEFT JOIN subcontract_orders so ON c.order_type='SUBCONTRACT' AND so.id=c.order_id
CROSS JOIN LATERAL jsonb_array_elements(c.submission_snapshot->'items') item
LEFT JOIN LATERAL (
    SELECT value FROM jsonb_array_elements(c.display_snapshot->'items') value
    WHERE value->>'itemId'=item->>'itemId' LIMIT 1
) display_line ON true
CROSS JOIN LATERAL jsonb_populate_record(NULL::v_goods_price_observations,jsonb_build_object(
    'kind',c.order_type,'source_type',c.order_type||'_ORDER_APPROVAL','source_id',c.order_id,
    'source_item_id',item->>'itemId','source_no',c.submission_snapshot->>'billNo',
    'business_date',c.submission_snapshot->>'billDate','order_updated_at',c.decided_at,'item_updated_at',c.decided_at,
    'goods_id',item->>'goodsId','goods_code_snapshot',display_line.value->>'goodsCode',
    'goods_name_snapshot',display_line.value->>'goodsName','color_id',item->>'colorId',
    'unit_id',item->>'unitId','unit_rate',item->>'unitRate','unit_name',display_line.value->>'unitName',
    'currency_id',c.submission_snapshot->>'currencyId','currency_name',c.display_snapshot->>'currencyName',
    'tax_rate',COALESCE(c.finance_tax_rate::text,c.submission_snapshot->>'taxRate'),'supplier_id',c.submission_snapshot->>'supplierId',
    'partner_name',c.display_snapshot->>'supplierName','owner_employee_id',CASE WHEN c.order_type='PURCHASE' THEN po.maker_id ELSE so.maker_id END,
    'quantity',item->>'qty','recorded_unit_price',item->>'price','amount_original',item->>'amountOriginal',
    'total_amount_input',item->>'totalAmountInput','gift_quantity',COALESCE(item->>'giftQty','0'),
    'extra_columns',COALESCE(display_line.value->'extraColumns','[]'::jsonb),
    'contract_exchange_rate',c.submission_snapshot->>'exchangeRate','finance_approval_case_id',c.id,
    'finance_exchange_rate',c.finance_exchange_rate,'finance_total_local',c.finance_total_local,
    'approval_status','APPROVED','approval_snapshot',c.submission_snapshot || jsonb_build_object(
        '_contractTaxRate',c.submission_snapshot->'taxRate','_financeTaxRate',c.finance_tax_rate),'approval_decided_at',c.decided_at,
    'discount_factor',1,'color_name',display_line.value->>'colorName'
)) mapped
WHERE c.order_type IN ('PURCHASE','SUBCONTRACT')
  AND (c.status='APPROVED' OR EXISTS(SELECT 1 FROM procurement_order_approval_events event WHERE event.case_id=c.id AND event.event_type='APPROVED'))
  AND NOT EXISTS(SELECT 1 FROM v_goods_price_observations current
    WHERE current.finance_approval_case_id=c.id AND current.source_item_id=mapped.source_item_id
      AND current.approval_status='APPROVED'
      AND (current.quantity,current.amount_original,current.recorded_unit_price,current.total_amount_input,
           current.currency_id,current.tax_rate,current.unit_id,current.unit_rate,current.color_id,current.supplier_id)
          IS NOT DISTINCT FROM
          (mapped.quantity,mapped.amount_original,mapped.recorded_unit_price,mapped.total_amount_input,
           mapped.currency_id,mapped.tax_rate,mapped.unit_id,mapped.unit_rate,mapped.color_id,mapped.supplier_id))
UNION ALL
SELECT mapped.*,o.id history_version_id,
       CASE WHEN o.is_deleted OR i.is_deleted THEN 'SOURCE_DELETED' WHEN o.status=-1 THEN 'SOURCE_REVERSED' ELSE 'SOURCE_CANCELLED' END lifecycle,
       true historical_only,NULL::jsonb snapshot_filter,'SALES_ORDER_ARCHIVED'::text history_kind
FROM sales_orders o JOIN sales_order_items i ON i.order_id=o.id
CROSS JOIN LATERAL jsonb_populate_record(NULL::v_goods_price_observations,jsonb_build_object(
    'kind','SALES','source_type','SALES_ORDER_ARCHIVED','source_id',o.id,'source_item_id',i.id,
    'source_no',o.bill_no,'business_date',o.bill_date,'order_updated_at',o.updated_at,'item_updated_at',i.updated_at,
    'goods_id',i.goods_id,'goods_code_snapshot',i.goods_code_snapshot,'goods_name_snapshot',i.goods_name_snapshot,
    'color_id',i.color_id,'unit_id',i.unit_id,'unit_rate',i.unit_rate,'currency_id',o.currency_id,'tax_rate',o.tax_rate,
    'client_id',o.client_id,'owner_employee_id',o.owner_employee_id,
    'quantity',i.qty,'recorded_unit_price',i.price,'amount_original',i.amount_original,'gift_quantity',0,
    'extra_columns',COALESCE(i.extra_columns,'[]'::jsonb),'contract_exchange_rate',o.exchange_rate,'approval_decided_at',o.approved_at,
    'discount_factor',CASE WHEN COALESCE(i.discount,0)=0 THEN 1 ELSE i.discount END
)) mapped
WHERE o.status=-1 OR (o.status=1 AND (o.is_deleted OR i.is_deleted OR i.chain_status=-1))
UNION ALL
SELECT mapped.*,log.id history_version_id,'CONFIRMED_QUOTATION'::text lifecycle,
       true historical_only,log.snapshot snapshot_filter,'QUOTE_CONFIRMATION'::text history_kind
FROM sales_quote_revision_logs log JOIN sales_quotes quote ON quote.id=log.quote_id
CROSS JOIN LATERAL jsonb_array_elements(log.snapshot->'lines') line
CROSS JOIN LATERAL jsonb_populate_record(NULL::v_goods_price_observations,jsonb_build_object(
    'kind','SALES','source_type','SALES_QUOTE_CONFIRMED','source_id',quote.id,
    'source_item_id',line->>'id','source_no',quote.bill_no,'business_date',log.snapshot->>'billDate',
    'order_updated_at',log.created_at,'item_updated_at',log.created_at,
    'goods_id',line->>'goodsId','goods_code_snapshot',line->>'goodsCode','goods_name_snapshot',line->>'goodsName',
    'color_id',line->>'colorId','unit_id',line->>'unitId','unit_rate',line->>'unitRate','unit_name',line->>'unitName',
    'currency_id',log.snapshot->>'currencyId','currency_name',log.snapshot->>'currencyName',
    'client_id',log.snapshot->>'clientId','partner_name',log.snapshot->>'clientName','owner_employee_id',quote.maker_id,
    'quantity',line->>'qty','recorded_unit_price',line->>'price','amount_original',line->>'amount','gift_quantity',0,
    'extra_columns',COALESCE(line->'extraColumns','[]'::jsonb),'approval_decided_at',log.created_at,
    'discount_factor',CASE WHEN COALESCE((line->>'discount')::numeric,0)=0 THEN 1 ELSE (line->>'discount')::numeric END,
    'color_name',line->>'colorName'
)) mapped
WHERE log.action='CONFIRM';
COMMENT ON VIEW v_goods_price_history IS
    'Current authorized records plus immutable approved procurement-case and confirmed quotation versions. Historical-only rows are never statistical samples; missing labels stay unknown. Quotes are distinct from sales orders.';
