"""Real HTTP acceptance against the disposable loopback database only.

Credentials and response bodies stay under ignored build/mobile/local-backend.
Never accepts a remote URL, never modifies the company's system.
"""
from __future__ import annotations
import argparse
import json
import secrets
from decimal import Decimal
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / 'build/mobile/local-backend'
BASE = 'http://127.0.0.1:8281/api'
TOKEN = ''


def call(method: str, path: str, body=None):
    assert path.startswith('/') and '://' not in path
    headers = {'Content-Type': 'application/json', 'X-Client-Device': 'local-ui-acceptance'}
    if TOKEN:
        headers['Authorization'] = 'Bearer ' + TOKEN
    request = urllib.request.Request(BASE + path,
        data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            data = response.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        # Backend credential DTOs redact their values; keep request bodies private.
        raise RuntimeError(f'{method} {path}: HTTP {error.code}: {error.read().decode()}') from None


def login(credentials):
    global TOKEN
    result = call('POST', '/auth/login', {
        **credentials, 'deviceName': 'Local business-chain acceptance'})
    TOKEN = result['accessToken']
    return result


def flatten(rows):
    for row in rows:
        yield row
        yield from flatten(row.get('children', []))


def setup():
    global TOKEN
    if (PRIVATE / 'api-login.json').exists():
        login(json.loads((PRIVATE / 'api-login.json').read_text(encoding='utf-8')))
        print('PASS: reuse the existing disposable API acceptance account')
        return
    login(json.loads((PRIVATE / 'ui-login.json').read_text(encoding='utf-8')))
    departments = call('GET', '/org/departments/tree')
    hr = next(row for row in flatten(departments) if row.get('code') == 'DEPT_HR')
    created = call('POST', '/org/employees', {
        'profile': {'fullName': '本地链路验收员', 'gender': 'male', 'idType': '其他',
            'idNumber': 'LOCALMOBILE202611020001', 'phone': '13800009991'},
        'employment': {'departmentId': hr['id'], 'positionName': '本地验收员',
            'hireDate': '2026-11-01', 'employmentType': 'regular', 'status': 'active',
            'confirmedAt': '2026-11-01'},
        'account': {'openAccount': True, 'loginAccount': 'mobile_api_review'},
    })
    credentials = {'loginAccount': created['loginAccount'], 'password': created['temporaryPassword']}
    login(credentials)
    password = secrets.token_urlsafe(24) + 'aA1!'
    result = call('POST', '/auth/change-password', {'oldPassword': credentials['password'], 'newPassword': password})
    (PRIVATE / 'api-login.json').write_text(json.dumps({'loginAccount': created['loginAccount'], 'password': password}), encoding='utf-8')
    (PRIVATE / 'api-account.json').write_text(json.dumps({'employeeId': created['employee']['id'], 'userId': result['user']['id']}), encoding='utf-8')
    print('PASS: local HR onboarding -> account issuance -> login -> mandatory password change')


def seed():
    login(json.loads((PRIVATE / 'api-login.json').read_text(encoding='utf-8')))
    checkpoint = PRIVATE / 'master-fixtures.json'
    fixtures = json.loads(checkpoint.read_text(encoding='utf-8')) if checkpoint.exists() else {}

    def create(key, path, payload):
        if key in fixtures:
            return fixtures[key]
        result = call('POST', path, payload)
        fixtures[key] = result
        checkpoint.write_text(json.dumps(fixtures, ensure_ascii=False, indent=2), encoding='utf-8')
        print('PASS: create/readback', key)
        if 'id' in result:
            verified = call('GET', path + '/' + result['id'])
            assert verified['id'] == result['id']
        return result

    def items(value):
        return value if isinstance(value, list) else value.get('items', value.get('content', []))

    units = items(call('GET', '/master/units?page=1&size=100'))
    unit = next((row for row in units if row.get('name') == '本地验收-件'), None)
    if unit is None:
        unit = create('unit', '/master/units', {'name': '本地验收-件', 'measurementDimension': 'COUNT'})
    fixtures['unit'] = unit
    warehouse_rows = items(call('GET', '/master/warehouses?page=1&size=100'))
    warehouse = next((row for row in warehouse_rows if not row.get('parentId')), None)
    if warehouse is None:
        warehouse = create('warehouse', '/master/warehouses', {'name': '本地验收仓库'})
    fixtures['warehouse'] = warehouse
    color = create('color', '/master/colors', {'name': '本地验收-蓝色'})
    goods_category = create('goodsCategory', '/master/material-categories', {'name': '本地手机验收货品', 'codePrefix': 'LG'})
    client_category = create('clientCategory', '/master/client-categories', {'name': '本地验收客户分类', 'codePrefix': 'LC'})
    supplier_category = create('supplierCategory', '/master/supplier-categories', {'name': '本地验收供应商分类', 'codePrefix': 'LS'})
    client = create('client', '/master/clients', {'name': '本地验收客户', 'categoryId': client_category['id']})
    supplier = create('supplier', '/master/suppliers', {'name': '本地验收供应商', 'categoryId': supplier_category['id']})
    for index, source in enumerate(['采购', '自制', '委外']):
        create('goods' + str(index), '/master/goods', {
            'categoryId': goods_category['id'], 'name': '本地验收' + source + '货品',
            'unitId': unit['id'], 'colorId': color['id'], 'price': '12.3456',
            'sourceType': source, 'clientId': client['id'], 'defaultSupplierId': supplier['id'],
            'owningWarehouseId': warehouse['id'],
        })
    checkpoint.write_text(json.dumps(fixtures, ensure_ascii=False, indent=2), encoding='utf-8')
    print('PASS: local real master fixtures ready')


def documents():
    login(json.loads((PRIVATE / 'api-login.json').read_text(encoding='utf-8')))
    fixtures = json.loads((PRIVATE / 'master-fixtures.json').read_text(encoding='utf-8'))
    checkpoint = PRIVATE / 'document-fixtures.json'
    saved = json.loads(checkpoint.read_text(encoding='utf-8')) if checkpoint.exists() else {}
    currencies = call('GET', '/master/currencies?page=1&size=100')
    rows = currencies if isinstance(currencies, list) else currencies.get('items', [])
    currency = next(row for row in rows if row.get('name') == '人民币' or row.get('code') == 'CNY')

    def persist(key, value):
        saved[key] = value
        checkpoint.write_text(json.dumps(saved, ensure_ascii=False, indent=2), encoding='utf-8')
        return value

    body = {'billDate': '2026-11-02', 'clientId': fixtures['client']['id'],
        'currencyId': currency['id'], 'validUntil': '2026-12-02',
        'remark': '本地手机验收报价，合成测试数据', 'items': [{
            'goodsId': fixtures['goods0']['id'], 'colorId': fixtures['color']['id'],
            'unitId': fixtures['unit']['id'], 'qty': '2.5000', 'price': '12.3456',
            'discount': '0.9000', 'remark': '四位数量和单价精度验证',
        }]}
    if 'quote' not in saved:
        persist('quote', call('POST', '/sales/quotes', body))
    quote = call('GET', '/sales/quotes/' + saved['quote']['id'])
    assert Decimal(str(quote['items'][0]['qty'])) == Decimal('2.5')
    assert Decimal(str(quote['items'][0]['price'])) == Decimal('12.3456')
    print('PASS: quote create -> detail/readback -> quantity/price precision')
    if 'quoteUpdated' not in saved:
        body['expectedRevision'] = quote['reviewRevision']
        body['remark'] += '；已测试编辑保存'
        body['items'][0]['id'] = quote['items'][0]['id']
        updated = call('PUT', '/sales/quotes/' + quote['id'], body)
        assert updated['items'][0]['id'] == quote['items'][0]['id']
        persist('quoteUpdated', updated)
    quote = call('GET', '/sales/quotes/' + saved['quote']['id'])
    if quote.get('statusBucket') in ('DRAFT', 'FINANCE_REJECTED'):
        persist('quoteSubmitted', call('POST', '/sales/quotes/' + quote['id'] + '/submit', {'expectedRevision': quote['reviewRevision']}))
    print('PASS: quote edit retains line identity -> submit into the manager/finance review workflow')
    if 'order' not in saved:
        order_body = {'billDate': '2026-11-02', 'clientId': fixtures['client']['id'],
            'currencyId': currency['id'], 'deliverDate': '2026-11-20',
            'shipmentPolicy': 'ALLOW_PARTIAL', 'remark': '本地手机验收订货，合成数据',
            'items': [{'goodsId': fixtures['goods0']['id'], 'colorId': fixtures['color']['id'],
                'unitId': fixtures['unit']['id'], 'qty': '10.0000'}]}
        persist('order', call('POST', '/sales/orders', order_body))
    order = call('GET', '/sales/orders/' + saved['order']['id'])
    assert Decimal(str(order['items'][0]['qty'])) == Decimal('10')
    print('PASS: sales order create -> detail/readback -> quantity retained')


def attachments():
    import hashlib
    login(json.loads((PRIVATE / 'api-login.json').read_text(encoding='utf-8')))
    documents = json.loads((PRIVATE / 'document-fixtures.json').read_text(encoding='utf-8'))
    owner = documents['uiQuote']['id']
    payload = (ROOT / 'output/mobile-adaptation/mobile-acceptance.txt').read_bytes()
    checkpoint = PRIVATE / 'attachment-fixture.json'
    metadata = {'ownerType': 'SALES_QUOTE', 'ownerId': owner,
        'originalName': 'mobile-acceptance.txt', 'contentType': 'text/plain', 'sizeBytes': len(payload)}
    rows = call('GET', '/attachments?' + urllib.parse.urlencode({'ownerType': metadata['ownerType'], 'ownerId': owner}))
    existing = next((row for row in rows if row.get('originalName') == metadata['originalName']), None)
    if existing is None:
        if checkpoint.exists():
            raise RuntimeError('An upload attempt already exists; reconcile its stored grant before retrying')
        grant = call('POST', '/attachments/presign', {**metadata, 'fileName': metadata['originalName']})
        checkpoint.write_text(json.dumps({'grant': grant}, ensure_ascii=False), encoding='utf-8')
        upload_path = grant.get('url', grant.get('uploadUrl', ''))
        assert upload_path.startswith('/attachments/raw/') and '://' not in upload_path
        headers = {'Authorization': 'Bearer ' + TOKEN, 'Content-Type': metadata['contentType'],
            'X-Uten-Attachment-Upload-Token': grant['confirmToken']}
        request = urllib.request.Request(BASE + upload_path, data=payload, headers=headers, method='PUT')
        with urllib.request.urlopen(request, timeout=45) as response:
            response.read()
        existing = call('POST', '/attachments/confirm', {**metadata,
            'storageKey': grant['storageKey'], 'confirmToken': grant['confirmToken']})
        checkpoint.write_text(json.dumps({'attachment': existing}, ensure_ascii=False), encoding='utf-8')
    download = call('GET', '/attachments/' + existing['id'] + '/download-grant')
    assert download['url'].startswith('/attachments/raw/')
    request = urllib.request.Request(BASE + download['url'], headers={'Authorization': 'Bearer ' + TOKEN})
    with urllib.request.urlopen(request, timeout=45) as response:
        result = response.read()
    assert result == payload
    assert hashlib.sha256(result).hexdigest() == existing['sha256']
    print('PASS: local attachment presign -> raw bytes -> confirm -> list -> download SHA256')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--setup', action='store_true')
    parser.add_argument('--seed', action='store_true')
    parser.add_argument('--documents', action='store_true')
    parser.add_argument('--attachments', action='store_true')
    args = parser.parse_args()
    if args.setup:
        setup()
    if args.seed:
        seed()
    if args.documents:
        documents()
    if args.attachments:
        attachments()


if __name__ == '__main__':
    main()
