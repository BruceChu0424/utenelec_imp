"""Independent bootstrap-v16 stock-source acceptance; never output source values."""
import csv
from datetime import date
from decimal import Decimal, InvalidOperation, localcontext, ROUND_HALF_UP
import hashlib
from pathlib import Path
import re
import uuid


VERSION = 'stock-source-movements-v1'
TYPES = ('TRANSFER', 'OTHER_IN', 'OTHER_OUT', 'DRAW', 'WDRAW', 'FINISHED_IN', 'FINISHED_OUT', 'CHECK')
ORDINARY = {'OTHER_IN': (11, 1), 'OTHER_OUT': (12, -1), 'DRAW': (5, -1),
            'WDRAW': (6, 1), 'FINISHED_IN': (13, 1), 'FINISHED_OUT': (14, -1)}
ENTRY_FIELDS = ('run_id', 'source_file', 'source_file_sha256', 'source_row_sha256', 'doc_type',
    'document_legacy_id', 'item_legacy_id', 'document_id', 'item_id', 'qty', 'unit_rate',
    'base_qty', 'amount_original', 'amount_local', 'reason')


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def _integer(value, require, positive=False):
    if value in (None, '') and not positive:
        return 0
    try:
        result = int(value)
    except (ValueError, TypeError):
        require(False, 'Stock source integer identity is invalid')
    require(not positive or result > 0, 'Stock source identity must be positive')
    return result


def _number(value, scale, require):
    if value in (None, ''):
        return None
    try:
        with localcontext() as context:
            context.prec = 80
            number = Decimal(value)
            require(number.is_finite(), 'Stock source numeric shape must be finite')
            return number.quantize(Decimal(1).scaleb(-scale), rounding=ROUND_HALF_UP)
    except (InvalidOperation, ValueError, TypeError):
        require(False, 'Stock source numeric shape is invalid')


def _n(value):
    if value is None:
        return '~'
    if value == 0:
        return '0'
    if type(value) is int:
        return str(value)
    text = format(value, 'f')
    return text.rstrip('0').rstrip('.') if '.' in text else text


def _ref(value):
    return '~' if not value else 'L' + str(value)


def _hex(value):
    return '~' if value is None else value.encode('utf-8').hex()


def _line(values):
    return '|'.join(str(value) for value in values) + '\n'


def _hash(lines):
    result = hashlib.sha256()
    for line in lines:
        result.update(line.encode('utf-8'))
    return result.hexdigest()


def source_inventory(directory, records, supplemental=None, require=_require):
    """Rebuild source projections, exclusions and derived events from sealed CSVs.

    Money/quantities only enter local canonical hashes. They never enter SQL or
    returned reports. NULL is '~'; scalar numerics match PostgreSQL trim_scale.
    """
    directory = Path(directory)
    supplemental = supplemental or {}
    names = {f'stock_{kind.lower()}_{suffix}.csv' for kind in TYPES for suffix in ('m', 'i')}
    decisions = {'warehouse_crosswalk.csv', 'goods_owning_warehouse.csv'}
    if not names.issubset(records) or not decisions.issubset(set(records) | set(supplemental)):
        return None
    files = {}
    for name in sorted(names | decisions):
        path = directory / name
        expected = records[name]['sha256'] if name in records else supplemental[name]
        require(isinstance(expected, str) and re.fullmatch('[0-9a-f]{64}', expected) is not None
                and _sha(path) == expected, 'Stock sealed source SHA-256 differs')
        files[name] = {'sha256': expected}

    def read(name, columns):
        with (directory / name).open(encoding='utf-8-sig', newline='') as stream:
            reader = csv.DictReader(stream, delimiter='|')
            require(reader.fieldnames and len(reader.fieldnames) == len(set(reader.fieldnames))
                    and set(columns).issubset(reader.fieldnames), 'Stock source CSV shape differs')
            count = 0
            for row in reader:
                require(None not in row, 'Stock source CSV has unexpected columns')
                count += 1
                yield row
        if name in records:
            require(count == records[name]['rows'], 'Stock source CSV row count differs')
        files[name]['rows'] = count

    crosswalk, targets, roots = {}, {}, []
    for row in read('warehouse_crosswalk.csv', ('legacy_id', 'action', 'target_code', 'target_defective')):
        action = row['action']; code = row['target_code'] or None
        require(action in ('KEEP', 'MERGE', 'SPLIT', 'DROP', 'TARGET'), 'Stock warehouse decision is unknown')
        require((action == 'DROP') == (code is None), 'Stock warehouse target code differs from its decision')
        if action != 'DROP':
            defective = row['target_defective'].lower()
            require(defective in ('true', 'false'), 'Stock warehouse use is unproven')
            require(code not in targets or targets[code] == defective, 'Stock warehouse use conflicts')
            targets[code] = defective
        if action == 'TARGET':
            require(not row['legacy_id'], 'Stock new warehouse must not claim an old identity')
            continue
        old = _integer(row['legacy_id'], require, True)
        require(old not in crosswalk, 'Stock warehouse source identity is duplicated')
        crosswalk[old] = (action, code)
        if action == 'SPLIT':
            roots.append(code)
    empty_sources = all(records[name]['rows'] == 0 for name in names)
    require(len(roots) == 1 or (not roots and not crosswalk and empty_sources), 'Stock source decisions require one main warehouse')
    owning = {}
    for row in read('goods_owning_warehouse.csv', ('goods_legacy_id', 'warehouse_code')):
        old = _integer(row['goods_legacy_id'], require); code = row['warehouse_code']
        require(old != 0, 'Stock source goods owning identity is zero')
        require(code in targets and targets[code] == 'false' and roots and code != roots[0], 'Stock source owning warehouse is not a good-stock child')
        require(old not in owning or owning[old] == code, 'Stock source goods owning warehouse conflicts')
        owning[old] = code

    def warehouse(old):
        if not old:
            return None, None
        require(old in crosswalk, 'Stock source warehouse has no sealed decision')
        return crosswalk[old]

    doc_lines, item_lines, movement_lines, nonposting_lines, nonposting_keys = [], [], [], [], []
    family_counts = {}; retained_draw_ids = set(); nonposting_nonzero = 0
    for kind in sorted(TYPES):
        header_file = f'stock_{kind.lower()}_m.csv'; item_file = f'stock_{kind.lower()}_i.csv'
        headers = {}; seen_heads = set(); dropped_heads = set()
        for row in read(header_file, ('legacy_id', 'bill_no', 'bill_date', 'stock_legacy_id', 'to_stock_legacy_id',
                'supplier_legacy_id', 'client_legacy_id', 'worker_legacy', 'maker_legacy', 'approver_legacy', 'total_original', 'status')):
            old = _integer(row['legacy_id'], require, True)
            require(old not in seen_heads, 'Stock source header identity is duplicated'); seen_heads.add(old)
            source_action, source_code = warehouse(_integer(row['stock_legacy_id'], require))
            target_action, target_code = warehouse(_integer(row['to_stock_legacy_id'], require))
            if source_action == 'DROP' or target_action == 'DROP':
                dropped_heads.add(old)
                continue
            try:
                parts = re.match(r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T]|$)', row['bill_date'])
                require(parts is not None, 'Retained stock source date shape is not established')
                day = date(*(int(part) for part in parts.groups())).isoformat()
            except (ValueError, TypeError):
                require(False, 'Retained stock source date is invalid')
            require(row['bill_no'], 'Retained stock source bill number is empty')
            total = _number(row['total_original'], 4, require) or Decimal(0)
            header = {'day': day, 'status': _integer(row['status'], require), 'from': source_code, 'to': target_code,
                'split': source_action == 'SPLIT' or target_action == 'SPLIT'}
            headers[old] = header
            doc_lines.append((kind, old, _line((kind, old, _hex(row['bill_no']), day, header['status'],
                _hex(source_code), _hex(target_code), _ref(_integer(row['supplier_legacy_id'], require)),
                _ref(_integer(row['client_legacy_id'], require)), _n(_integer(row['worker_legacy'], require) or None),
                _n(_integer(row['maker_legacy'], require) or None), _n(_integer(row['approver_legacy'], require) or None), _n(total), _n(total)))))
        items = []; seen_items = set(); dropped = unassigned = 0
        for row in read(item_file, ('legacy_id', 'bill_legacy_id', 'goods_legacy_id', 'color_legacy_id', 'unit_legacy_id',
                'qty', 'unit_rate', 'price', 'amount', 'surplus_qty', 'count_qty', 'upstream_legacy_id')):
            old = _integer(row['legacy_id'], require, True)
            require(old not in seen_items, 'Stock source item identity is duplicated'); seen_items.add(old)
            parent = _integer(row['bill_legacy_id'], require, True)
            require(parent in seen_heads, 'Stock source item has no original header')
            if parent in dropped_heads:
                dropped += 1; continue
            header = headers[parent]; goods = _integer(row['goods_legacy_id'], require, True)
            line_warehouse = owning.get(goods) if header['split'] else None
            if header['split'] and line_warehouse is None:
                unassigned += 1; continue
            qty = _number(row['qty'], 4, require); raw_rate = _number(row['unit_rate'], 6, require)
            require(qty is not None, 'Retained stock source quantity is unknown')
            rate = raw_rate if raw_rate is not None else Decimal(1)
            with localcontext() as context:
                context.prec = 80
                base = (qty * rate).quantize(Decimal('.0001'), rounding=ROUND_HALF_UP)
            amount = _number(row['amount'], 4, require); price = _number(row['price'], 4, require)
            surplus = _number(row['surplus_qty'], 4, require); count = _number(row['count_qty'], 4, require)
            surplus = surplus or None; count = count or None
            upstream = _integer(row['upstream_legacy_id'], require)
            require(kind == 'WDRAW' or upstream == 0, 'Stock source upstream namespace is not established')
            if kind == 'WDRAW' and upstream:
                require(upstream in retained_draw_ids, 'Stock return source has no exact retained DRAW upstream')
            items.append((old, parent, goods, _ref(_integer(row['color_legacy_id'], require)),
                _ref(_integer(row['unit_legacy_id'], require)), line_warehouse, qty, raw_rate, rate, base,
                price, amount, surplus, count, upstream))
        items.sort(key=lambda item: item[0]); lines_per_header = {}; movement_count = nonposting_count = 0
        for old, parent, goods, color, unit, line_warehouse, qty, raw_rate, rate, base, price, amount, surplus, count, upstream in items:
            lines_per_header[parent] = lines_per_header.get(parent, 0) + 1
            header = headers[parent]
            item_lines.append((kind, old, _line((kind, old, parent, lines_per_header[parent], goods, color, unit,
                _hex(line_warehouse), _n(qty), _n(rate), _n(base), _n(price), _n(amount), _n(amount),
                _n(surplus), _n(count), _n(upstream or None)))))
            if kind == 'DRAW': retained_draw_ids.add(old)
            events = []; nonposting = False
            if header['status'] == 1:
                if kind in ORDINARY and header['from'] is not None:
                    require(base >= 0, 'Negative historical stock movement needs an explicit source decision')
                    if base > 0:
                        movement_type, direction = ORDINARY[kind]
                        events.append((movement_type, direction, line_warehouse or header['from'], base, amount))
                    else:
                        nonposting_count += 1; nonposting = True
                elif kind == 'TRANSFER' and (header['from'] is not None or header['to'] is not None):
                    require(base >= 0, 'Negative historical transfer movement needs an explicit source decision')
                    if base > 0:
                        if header['from'] is not None:
                            events.append((8, -1, line_warehouse if header['from'] == roots[0] else header['from'], base, None))
                        if header['to'] is not None:
                            events.append((7, 1, line_warehouse if header['to'] == roots[0] else header['to'], base, None))
                    else:
                        nonposting_count += 1; nonposting = True
                elif kind == 'CHECK' and header['from'] is not None and surplus is not None:
                    events.append((9 if surplus > 0 else 10, 1 if surplus > 0 else -1,
                        line_warehouse or header['from'], abs(surplus), None))
            if nonposting:
                nonposting_keys.append((kind, old))
                nonposting_lines.append((item_file, old, _line((item_file, kind, parent, old,
                    _n(qty), _n(raw_rate), _n(base), _n(amount), _n(amount)))))
                nonposting_nonzero += amount is not None and amount != 0
            for movement_type, direction, code, quantity, event_amount in events:
                require(code is not None, 'Derived stock movement has no proven physical warehouse')
                movement_lines.append((kind, old, movement_type, direction, code, _line((kind, parent, old,
                    header['day'], movement_type, 'STOCK_DOC', goods, color, _hex(code), direction,
                    _n(quantity), unit, _n(rate), _n(event_amount)))))
                movement_count += 1
        family_counts[kind] = {'raw_documents': len(seen_heads), 'retained_documents': len(headers),
            'excluded_documents': len(dropped_heads), 'raw_items': len(seen_items), 'retained_items': len(items),
            'dropped_items': dropped, 'unassigned_split_items': unassigned,
            'expected_movements': movement_count, 'nonposting_items': nonposting_count}
    return {'version': VERSION, 'files': files, 'families': family_counts,
        '_input_directory': str(directory.resolve()), '_nonposting_keys': nonposting_keys,
        'retained_documents': len(doc_lines), 'retained_items': len(item_lines), 'expected_movements': len(movement_lines),
        'nonposting_items': len(nonposting_lines), 'nonposting_nonzero_amount_items': nonposting_nonzero,
        'document_facts_sha256': _hash(row[-1] for row in sorted(doc_lines)),
        'item_facts_sha256': _hash(row[-1] for row in sorted(item_lines)),
        'movement_facts_sha256': _hash(row[-1] for row in sorted(movement_lines)),
        'nonposting_source_facts_sha256': _hash(row[-1] for row in sorted(nonposting_lines))}


def acceptance_sql(run_id, source):
    """Independent source hashes vs one RR/READ ONLY target fact snapshot.

    No source quantity, amount, remark or complete source row is embedded in SQL.
    UUIDs are checked relationally and separately hashed for rename continuity.
    """
    run_id = str(uuid.UUID(run_id))
    kinds = ','.join("'" + kind + "'" for kind in sorted(TYPES))
    entry_fields = 'ARRAY[' + ','.join("'" + key + "'" for key in sorted(ENTRY_FIELDS)) + ']::text[]'
    file_json = {}
    for name, record in source['files'].items():
        _require(re.fullmatch('[a-z0-9_]+[.]csv', name) is not None
                 and re.fullmatch('[0-9a-f]{64}', record['sha256']) is not None, 'Invalid stock source file identity')
        file_json[name] = record['sha256']
    import json
    files_sql = "'" + json.dumps(file_json, separators=(',', ':')) + "'::jsonb"

    def integer(value): return f"coalesce(({value})::text,'~')"
    def numeric(value): return f"coalesce(trim_scale(({value})::numeric)::text,'~')"
    def reference(identity, legacy): return f"CASE WHEN {identity} IS NULL THEN '~' ELSE 'L'||coalesce(({legacy})::text,'!') END"
    def code(identity, value): return f"CASE WHEN {identity} IS NULL THEN '~' ELSE coalesce(encode(convert_to({value},'UTF8'),'hex'),'!') END"
    def line(values): return "concat_ws('|'," + ','.join(values) + ")||chr(10)"
    def digest_lines(table, field, order):
        return f"(SELECT encode(digest(coalesce(string_agg({field},'' ORDER BY {order}),''),'sha256'),'hex') FROM {table})"
    def entry_numeric(field):
        return f"CASE WHEN jsonb_typeof(e->'{field}')='number' THEN trim_scale((e->>'{field}')::numeric)::text WHEN e->'{field}'='null'::jsonb THEN '~' ELSE '!' END"
    def entry_uuid(field):
        return f"CASE WHEN e->>'{field}' ~ '^[0-9a-f]{{8}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{12}}$' THEN (e->>'{field}')::uuid END"

    doc_line = line(["d.doc_type", integer('d.legacy_id'), "coalesce(encode(convert_to(d.bill_no,'UTF8'),'hex'),'~')",
        "coalesce(to_char(d.bill_date,'YYYY-MM-DD'),'~')", integer('d.status'), code('d.warehouse_id', 'wf.code'),
        code('d.to_warehouse_id', 'wt.code'), reference('d.supplier_id', 'supplier.legacy_id'),
        reference('d.client_id', 'client.legacy_id'), integer('d.worker_legacy_id'), integer('d.maker_legacy_id'),
        integer('d.approver_legacy_id'), numeric('d.total_original'), numeric('d.total_local')])
    item_line = line(["i.bill_type", integer('i.legacy_id'), integer('d.legacy_id'), integer('i.line_no'),
        integer('g.legacy_id'), reference('i.color_id', 'color.legacy_id'), reference('i.unit_id', 'unit.legacy_id'),
        code('i.warehouse_id', 'w.code'), numeric('i.qty'), numeric('i.unit_rate'), numeric('i.base_qty'),
        numeric('i.price'), numeric('i.amount_original'), numeric('i.amount_local'), numeric('i.surplus_qty'),
        numeric('i.count_qty'), integer('upstream.legacy_id')])
    movement_line = line(["i.bill_type", integer('d.legacy_id'), integer('i.legacy_id'),
        "coalesce(to_char(m.transaction_date,'YYYY-MM-DD'),'~')", integer('m.movement_type'), "m.source_doc_type",
        integer('g.legacy_id'), reference('m.color_id', 'color.legacy_id'), code('m.warehouse_id', 'w.code'),
        integer('m.direction'), numeric('m.qty'), reference('m.unit_id', 'unit.legacy_id'), numeric('m.unit_rate'), numeric('m.amount_local')])
    entry_line = line(["coalesce(e->>'source_file','!')", "coalesce(e->>'doc_type','!')",
        "coalesce(e->>'document_legacy_id','!')", "coalesce(e->>'item_legacy_id','!')",
        *[entry_numeric(field) for field in ('qty', 'unit_rate', 'base_qty', 'amount_original', 'amount_local')]])
    entry_shape = f"""jsonb_typeof(e) IS DISTINCT FROM 'object'
       OR (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(CASE WHEN jsonb_typeof(e)='object' THEN e ELSE '{{}}'::jsonb END) key) IS DISTINCT FROM {entry_fields}
       OR e->>'run_id' IS DISTINCT FROM '{run_id}' OR e->>'reason' IS DISTINCT FROM 'NONPOSTING_ZERO_QUANTITY'
       OR (e->>'document_legacy_id' ~ '^[1-9][0-9]*$') IS NOT TRUE OR (e->>'item_legacy_id' ~ '^[1-9][0-9]*$') IS NOT TRUE
       OR (e->>'source_row_sha256' ~ '^[0-9a-f]{{64}}$') IS NOT TRUE
       OR (jsonb_typeof(e->'qty')='number') IS NOT TRUE OR (jsonb_typeof(e->'base_qty')='number') IS NOT TRUE
       OR jsonb_typeof(e->'unit_rate') NOT IN('number','null')
       OR jsonb_typeof(e->'amount_original') NOT IN('number','null') OR jsonb_typeof(e->'amount_local') NOT IN('number','null')"""
    return f"""SELECT (
WITH summary AS MATERIALIZED (
 SELECT reconciliation_summary->'stockMovementChecks' AS value FROM public.legacy_migration_runs WHERE run_id='{run_id}'::uuid
), docs AS MATERIALIZED (
 SELECT d.id,d.doc_type,d.legacy_id,{doc_line} AS facts_line,
   (d.legacy_id IS NULL OR d.legacy_id<=0 OR d.doc_type NOT IN({kinds})) AS invalid_identity,
   (d.maker_id IS NOT NULL OR d.approver_id IS NOT NULL OR d.source_daily_report_id IS NOT NULL OR d.is_closed OR d.is_deleted
     OR (d.worker_legacy_id IS NULL AND d.worker_id IS NOT NULL)
     OR (d.worker_legacy_id IS NOT NULL AND (worker.id IS NULL OR worker.legacy_id IS DISTINCT FROM d.worker_legacy_id))) AS invalid_source_controls
 FROM public.stock_documents d LEFT JOIN public.warehouses wf ON wf.id=d.warehouse_id
 LEFT JOIN public.warehouses wt ON wt.id=d.to_warehouse_id LEFT JOIN public.suppliers supplier ON supplier.id=d.supplier_id
 LEFT JOIN public.clients client ON client.id=d.client_id
 LEFT JOIN public.employees worker ON worker.id=d.worker_id
), items AS MATERIALIZED (
 SELECT i.id,i.bill_type,i.legacy_id,{item_line} AS facts_line,
   (i.legacy_id IS NULL OR i.legacy_id<=0 OR i.bill_type NOT IN({kinds})) AS invalid_identity,
   (d.id IS NULL OR i.bill_type IS DISTINCT FROM d.doc_type OR i.bill_no IS DISTINCT FROM d.bill_no OR i.bill_date IS DISTINCT FROM d.bill_date) AS invalid_parent,
   (i.is_deleted OR i.source_daily_report_item_id IS NOT NULL OR i.execution_segment_id IS NOT NULL OR i.execution_segment_sales_allocation_id IS NOT NULL
     OR i.weight IS NOT NULL OR i.gift_qty IS DISTINCT FROM 0::numeric OR i.goods_snapshot_source IS DISTINCT FROM 'LEGACY_IMPORT') AS invalid_source_controls,
   (i.upstream_item_id IS NOT NULL AND (i.bill_type<>'WDRAW' OR upstream.id IS NULL OR upstream.bill_type<>'DRAW')) AS invalid_upstream
 FROM public.stock_document_items i LEFT JOIN public.stock_documents d ON d.id=i.doc_id
 LEFT JOIN public.goods g ON g.id=i.goods_id LEFT JOIN public.colors color ON color.id=i.color_id
 LEFT JOIN public.units unit ON unit.id=i.unit_id LEFT JOIN public.warehouses w ON w.id=i.warehouse_id
 LEFT JOIN public.stock_document_items upstream ON upstream.id=i.upstream_item_id
), movements AS MATERIALIZED (
 SELECT m.id,m.source_item_id,i.bill_type,i.legacy_id,m.movement_type,m.direction,w.code,{movement_line} AS facts_line,
   (m.qty IS NULL OR m.qty<=0) AS nonpositive,
   (i.id IS NULL OR d.id IS NULL OR m.source_doc_id IS DISTINCT FROM i.doc_id OR i.bill_type IS DISTINCT FROM d.doc_type
      OR m.goods_id IS DISTINCT FROM i.goods_id OR m.color_id IS DISTINCT FROM i.color_id OR m.unit_id IS DISTINCT FROM i.unit_id
      OR m.unit_rate IS DISTINCT FROM i.unit_rate OR m.transaction_date IS DISTINCT FROM d.bill_date::timestamptz) AS invalid_relation
 FROM public.stock_movements m LEFT JOIN public.stock_document_items i ON i.id=m.source_item_id
 LEFT JOIN public.stock_documents d ON d.id=m.source_doc_id LEFT JOIN public.goods g ON g.id=m.goods_id
 LEFT JOIN public.colors color ON color.id=m.color_id LEFT JOIN public.units unit ON unit.id=m.unit_id
 LEFT JOIN public.warehouses w ON w.id=m.warehouse_id WHERE m.source_doc_type='STOCK_DOC'
), posted_items AS MATERIALIZED (
 SELECT DISTINCT source_item_id FROM movements
), entries AS MATERIALIZED (
 SELECT x.value AS e FROM summary s CROSS JOIN LATERAL jsonb_array_elements(coalesce(s.value->'entries','[]'::jsonb)) x
), entry_facts AS MATERIALIZED (
 SELECT e,{entry_line} AS facts_line,
   ({entry_shape}) AS invalid_shape,
   (e->>'source_file_sha256' IS DISTINCT FROM ({files_sql}->>(e->>'source_file'))
      OR e->>'source_file' IS DISTINCT FROM 'stock_'||lower(e->>'doc_type')||'_i.csv'
      OR (e->>'doc_type' IN('OTHER_IN','OTHER_OUT','DRAW','WDRAW','FINISHED_IN','FINISHED_OUT','TRANSFER')) IS NOT TRUE) AS invalid_file,
   (i.id IS NULL OR d.id IS NULL OR i.doc_id IS DISTINCT FROM d.id OR i.bill_type IS DISTINCT FROM e->>'doc_type'
      OR i.legacy_id::text IS DISTINCT FROM e->>'item_legacy_id' OR d.legacy_id::text IS DISTINCT FROM e->>'document_legacy_id'
      OR d.doc_type IS DISTINCT FROM e->>'doc_type' OR d.status IS DISTINCT FROM 1 OR i.base_qty IS DISTINCT FROM 0::numeric) AS invalid_binding,
   (posted.source_item_id IS NOT NULL) AS has_movement
 FROM entries LEFT JOIN public.stock_document_items i ON i.id={entry_uuid('item_id')}
 LEFT JOIN public.stock_documents d ON d.id={entry_uuid('document_id')}
 LEFT JOIN posted_items posted ON posted.source_item_id=i.id
)
SELECT jsonb_build_object(
 'summary_present',(SELECT value IS NOT NULL FROM summary),
 'summary_passed',(SELECT value->'passed'='true'::jsonb FROM summary),
 'summary_version',(SELECT value->>'validationVersion' FROM summary),
 'summary_exact',(SELECT value->'exactPerItemIdentityQuantityDirectionWarehouseAmount'='true'::jsonb FROM summary),
 'summary_entries_persisted',(SELECT value->'entriesPersisted'='true'::jsonb FROM summary),
 'summary_retained_source_items',(SELECT value->'retainedSourceItems' FROM summary),
 'summary_expected_movements',(SELECT value->'expectedMovements' FROM summary),
 'summary_matched_movements',(SELECT value->'matchedMovements' FROM summary),
 'summary_zero_quantity_movements',(SELECT value->'zeroQuantityMovementCount' FROM summary),
 'summary_nonposting_items',(SELECT value->'nonpostingItems' FROM summary),
 'summary_nonposting_nonzero_amount_items',(SELECT value->'nonpostingNonzeroAmountItems' FROM summary),
 'summary_declared_entries_sha256',(SELECT value->>'nonpostingFactsSha256' FROM summary),
 'summary_actual_entries_sha256',(SELECT encode(digest(coalesce(value->'entries','[]'::jsonb)::text,'sha256'),'hex') FROM summary),
 'document_rows',(SELECT count(*) FROM docs), 'item_rows',(SELECT count(*) FROM items), 'movement_rows',(SELECT count(*) FROM movements),
 'nonposting_rows',(SELECT count(*) FROM entries),
 'document_facts_sha256',{digest_lines('docs','facts_line','doc_type,legacy_id')},
 'item_facts_sha256',{digest_lines('items','facts_line','bill_type,legacy_id')},
 'movement_facts_sha256',{digest_lines('movements','facts_line','bill_type,legacy_id,movement_type,direction,code')},
 'nonposting_source_facts_sha256',{digest_lines('entry_facts','facts_line',"e->>'source_file',CASE WHEN e->>'item_legacy_id' ~ '^[1-9][0-9]*$' THEN (e->>'item_legacy_id')::numeric END")},
 'nonposting_source_rows_sha256',{digest_lines('entries',"(e->>'source_file')||'|'||(e->>'item_legacy_id')||'|'||(e->>'source_row_sha256')||chr(10)","e->>'source_file',CASE WHEN e->>'item_legacy_id' ~ '^[1-9][0-9]*$' THEN (e->>'item_legacy_id')::numeric END")},
 'document_uuid_identity_sha256',{digest_lines('docs',"doc_type||':'||legacy_id::text||':'||id::text||chr(10)",'doc_type,legacy_id')},
 'item_uuid_identity_sha256',{digest_lines('items',"bill_type||':'||legacy_id::text||':'||id::text||chr(10)",'bill_type,legacy_id')},
 'movement_uuid_identity_sha256',{digest_lines('movements',"id::text||chr(10)",'id')},
 'invalid_document_identities',(SELECT count(*) FROM docs WHERE invalid_identity),
 'invalid_item_identities',(SELECT count(*) FROM items WHERE invalid_identity),
 'duplicate_document_identities',(SELECT count(*) FROM(SELECT doc_type,legacy_id FROM docs GROUP BY 1,2 HAVING count(*)<>1) duplicate),
 'duplicate_item_identities',(SELECT count(*) FROM(SELECT bill_type,legacy_id FROM items GROUP BY 1,2 HAVING count(*)<>1) duplicate),
 'invalid_item_parents',(SELECT count(*) FROM items WHERE invalid_parent),
 'invalid_header_source_controls',(SELECT count(*) FROM docs WHERE invalid_source_controls),
 'invalid_item_source_controls',(SELECT count(*) FROM items WHERE invalid_source_controls),
 'invalid_upstream_namespaces',(SELECT count(*) FROM items WHERE invalid_upstream),
 'nonpositive_movements',(SELECT count(*) FROM movements WHERE nonpositive),
 'invalid_movement_relations',(SELECT count(*) FROM movements WHERE invalid_relation),
 'foreign_source_types_on_stock_items',(SELECT count(*) FROM public.stock_movements m WHERE m.source_doc_type IS DISTINCT FROM 'STOCK_DOC' AND
    (m.source_doc_id IN(SELECT id FROM docs) OR m.source_item_id IN(SELECT id FROM items))),
 'invalid_nonposting_shapes',(SELECT count(*) FROM entry_facts WHERE invalid_shape IS DISTINCT FROM false),
 'invalid_nonposting_files',(SELECT count(*) FROM entry_facts WHERE invalid_file IS DISTINCT FROM false),
 'invalid_nonposting_bindings',(SELECT count(*) FROM entry_facts WHERE invalid_binding IS DISTINCT FROM false),
 'nonposting_entries_with_movements',(SELECT count(*) FROM entry_facts WHERE has_movement),
 'nonposting_nonzero_amount_rows',(SELECT count(*) FROM entries WHERE CASE WHEN jsonb_typeof(e->'amount_original')='number' THEN (e->>'amount_original')::numeric<>0 ELSE false END)
))"""


ZERO_INVARIANTS = ('invalid_document_identities', 'invalid_item_identities', 'duplicate_document_identities',
    'duplicate_item_identities', 'invalid_item_parents', 'invalid_header_source_controls', 'invalid_item_source_controls',
    'invalid_upstream_namespaces', 'nonpositive_movements', 'invalid_movement_relations',
    'foreign_source_types_on_stock_items', 'invalid_nonposting_shapes', 'invalid_nonposting_files',
    'invalid_nonposting_bindings', 'nonposting_entries_with_movements')


def validate(actual, source, require=_require):
    require(isinstance(actual, dict) and isinstance(source, dict), 'Stock movement proof or sealed source inventory is absent')
    require(isinstance(source.get('nonposting_source_rows_sha256'), str)
            and re.fullmatch('[0-9a-f]{64}', source['nonposting_source_rows_sha256']) is not None,
            'Complete stock typed source row hashes have not been independently verified')
    for key in ('summary_present', 'summary_passed', 'summary_exact', 'summary_entries_persisted'):
        require(actual.get(key) is True, 'Stock movement summary assertion is absent or failed: ' + key)
    require(actual.get('summary_version') == VERSION, 'Stock movement validation contract version differs')
    for fact, expected in (
        ('summary_retained_source_items', 'retained_items'), ('summary_expected_movements', 'expected_movements'),
        ('summary_matched_movements', 'expected_movements'), ('summary_nonposting_items', 'nonposting_items'),
        ('summary_nonposting_nonzero_amount_items', 'nonposting_nonzero_amount_items'),
        ('document_rows', 'retained_documents'), ('item_rows', 'retained_items'), ('movement_rows', 'expected_movements'),
        ('nonposting_rows', 'nonposting_items'), ('nonposting_nonzero_amount_rows', 'nonposting_nonzero_amount_items'),
        ('document_facts_sha256', 'document_facts_sha256'), ('item_facts_sha256', 'item_facts_sha256'),
        ('movement_facts_sha256', 'movement_facts_sha256'), ('nonposting_source_facts_sha256', 'nonposting_source_facts_sha256'),
        ('nonposting_source_rows_sha256', 'nonposting_source_rows_sha256'),
    ):
        require(fact in actual and type(actual[fact]) is type(source[expected]) and actual[fact] == source[expected],
                'Independent stock source invariant differs: ' + fact)
    require(type(actual.get('summary_zero_quantity_movements')) is int and actual['summary_zero_quantity_movements'] == 0,
            'Stock movement summary contains zero-quantity events')
    for key in ZERO_INVARIANTS:
        require(type(actual.get(key)) is int and actual[key] == 0, 'Stock source acceptance invariant failed: ' + key)
    for key in ('summary_declared_entries_sha256', 'summary_actual_entries_sha256', 'document_uuid_identity_sha256',
                'item_uuid_identity_sha256', 'movement_uuid_identity_sha256'):
        require(isinstance(actual.get(key), str) and re.fullmatch('[0-9a-f]{64}', actual[key]) is not None, 'Invalid stock acceptance hash: ' + key)
    require(actual['summary_declared_entries_sha256'] == actual['summary_actual_entries_sha256'], 'Stock nonposting persisted-entry hash differs')
    return {'verified': True, 'validation_version': VERSION, 'source_files_verified': len(source['files']),
        'retained_source_documents': source['retained_documents'], 'retained_source_items': source['retained_items'],
        'expected_movements': source['expected_movements'], 'matched_movements': actual['movement_rows'],
        'nonposting_items': source['nonposting_items'], 'nonposting_nonzero_amount_items': source['nonposting_nonzero_amount_items'],
        'zero_quantity_movement_count': 0, 'independent_source_projections_verified': True,
        'complete_nonposting_typed_source_row_hashes_verified': True,
        'nonposting_is_not_a_quantity_or_finance_exclusion': True, 'stock_balances_verified_by_this_gate': False,
        **{key: source[key] for key in ('document_facts_sha256', 'item_facts_sha256', 'movement_facts_sha256', 'nonposting_source_facts_sha256', 'nonposting_source_rows_sha256')},
        **{key: actual[key] for key in ('document_uuid_identity_sha256', 'item_uuid_identity_sha256', 'movement_uuid_identity_sha256')},
        'source_files': {name: value['sha256'] for name, value in sorted(source['files'].items())}}
