# -*- coding: utf-8 -*-
"""解析抓取的旧站 HTML，提取 系列映射/产品/新闻 真实数据 → extracted.json (供 seed)"""
import sys, os, re, json, html
from urllib.parse import urlparse
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

ROOT = r'D:/Projects/uten_imp/website'
RAW = os.path.join(ROOT, 'public', 'images', 'raw')
sm = json.load(open(os.path.join(ROOT, '.scrape', 'sitemap.json'), encoding='utf-8'))
os.makedirs(os.path.join(ROOT, '.scrape', 'seed'), exist_ok=True)

def read(url):
    return open(sm[url]['html'], encoding='utf-8').read()

def img_slug(src):
    p = urlparse(src).path.strip('/').replace('/', '_')
    return re.sub(r'[^\w.\-]', '_', p)

def img_path(src):
    slug = img_slug(src)
    return f'/images/raw/{slug}' if os.path.exists(os.path.join(RAW, slug)) else None

sortpat = re.compile(r'[?&]sortid=(\d+)', re.I)
titlepat = re.compile(r'<title>(.*?)</title>', re.I | re.S)

# ---- 1. 系列 sortID -> name ----
series = {}
# 手动主系列映射 (首页图片导航确认)
series.update({'81': 'Z9', '80': 'S300', '70': 'Q7', '75': 'Q9', '76': 'Q3',
               '77': 'V4白', '78': 'A5', '79': 'A8', '61': 'A6.0',
               '60': '出口产品', '53': '液压缓冲式地面插座'})
for url in sm:
    if 'product.asp' not in url.lower():  # 排除 news 等非产品页
        continue
    m = sortpat.search(url)
    if not m:
        continue
    sid = m.group(1)
    if sid in series:
        continue
    tm = titlepat.search(read(url))
    if not tm:
        continue
    t = html.unescape(tm.group(1)).strip()
    t = re.sub(r'_.*$', '', t)
    t = re.sub(r'第\d+页$', '', t).strip()
    if t and t != '产品中心':
        series[sid] = t

# ---- 2. 产品 ----
products = []
seen = set()
for url in sorted(sm):
    if 'productshow' not in url.lower():
        continue
    h = read(url)
    tm = titlepat.search(h)
    if not tm:
        continue
    name = html.unescape(tm.group(1)).split('_')[0].strip()
    if not name or name in seen or name == '中山市优腾电器有限公司':
        continue
    seen.add(name)
    ms = sortpat.search(url)
    sid = ms.group(1) if ms else '?'
    imgs = re.findall(r'<img[^>]+src=["\']([^"\']+)["\']', h, re.I)
    main_img = None
    for src in imgs:
        if re.search(r'(logo|^images/led\.png|ewm|banner)', src, re.I):
            continue
        p = img_path(src)
        if p:
            main_img = p
            if 'upload' in src.lower():
                break
    desc = ''
    dm = re.search(r'产品说明([\s\S]{0,800}?)(?:上一产品|下一产品|版权|技术支持|相关产品)', h)
    if dm:
        desc = re.sub(r'<[^>]+>', ' ', dm.group(1))
        desc = html.unescape(desc).replace('\xa0', ' ')
        desc = re.sub(r'\s+', ' ', desc).strip()[:240]
    products.append({'name': name, 'series_id': sid,
                     'series_name': series.get(sid, ''), 'image': main_img, 'desc': desc})

# ---- 3. 新闻 ----
news = []
datepat = re.compile(r'(20\d{2}[\.\-/年]\d{1,2}[\.\-/月]\d{1,2})')
seen_n = set()
for url in sorted(sm):
    if 'newsshow' not in url.lower():
        continue
    h = read(url)
    tm = titlepat.search(h)
    if not tm:
        continue
    title = html.unescape(tm.group(1)).split('_')[0].strip()
    if not title or title in seen_n or title == '中山市优腾电器有限公司':
        continue
    seen_n.add(title)
    dm = datepat.search(h)
    date = ''
    if dm:
        date = dm.group(1).replace('年', '-').replace('月', '-').replace('/', '-').replace('.', '-')
    body = re.sub(r'<(script|style)[^>]*>.*?</\1>', ' ', h, flags=re.I | re.S)
    body = re.sub(r'<[^>]+>', ' ', body)
    body = html.unescape(body).replace('\xa0', ' ')
    body = re.sub(r'\s+', ' ', body).strip()
    if date:
        idx = body.find(date)
        body = body[idx + len(date):] if idx >= 0 else body
    body = re.split(r'(版权|技术支持|上一篇|下一篇|相关新闻)', body)[0].strip()[:800]
    img = None
    for src in re.findall(r'<img[^>]+src=["\']([^"\']+)["\']', h, re.I):
        if re.search(r'(logo|^images/led|ewm)', src, re.I):
            continue
        p = img_path(src)
        if p:
            img = p
            break
    news.append({'title': title, 'date': date, 'content': body, 'image': img})

json.dump({'series': series, 'products': products, 'news': news},
          open(os.path.join(ROOT, '.scrape', 'seed', 'extracted.json'), 'w', encoding='utf-8'),
          ensure_ascii=False, indent=2)

print('== 系列(%d) ==' % len(series))
for sid, n in sorted(series.items(), key=lambda x: int(x[0]) if x[0].isdigit() else 999):
    print(f'  {sid}: {n}')
print('\n== 产品(%d, 有图%d) ==' % (len(products), sum(1 for p in products if p['image'])))
for p in products[:12]:
    print(f"  [{p['series_name']}] {p['name']}  img={'Y' if p['image'] else '-'}")
print('\n== 新闻(%d) ==' % len(news))
for n in news[:8]:
    print(f"  {n['date']}  {n['title'][:30]}")
