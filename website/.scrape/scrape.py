# -*- coding: utf-8 -*-
"""优腾旧站素材抓取器 v2：BFS 抓取同域 .asp 页面 + 下载图片 + 提取纯文本。
加固: UTF-8 输出 / URL quote 非 ASCII / 跳过搜索·资源·中文链接。"""
import os, re, sys, time, json
import urllib.request, urllib.parse

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

BASE_HOST = "www.ch-uten.com"
BASE = "http://www.ch-uten.com"
ROOT = r"D:/Projects/uten_imp/website"
SCRAPE_DIR = os.path.join(ROOT, ".scrape", "pages")
IMG_DIR = os.path.join(ROOT, "public", "images", "raw")
os.makedirs(SCRAPE_DIR, exist_ok=True)
os.makedirs(IMG_DIR, exist_ok=True)

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) uten-website-migration/1.0"
MAX_PAGES = 250
SKIP_HINTS = ('seanews', 'mailto:', 'javascript:', 'tel:', 'keyword=', 'logout',
              '.css', '.js', '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.ico',
              '.doc', '.docx', '.pdf', '.xls', '.zip', '.rar', 'en/')  # en/ 英文站同内容跳过

def is_ascii(s):
    try:
        s.encode('ascii'); return True
    except UnicodeEncodeError:
        return False

def fetch(url, timeout=20):
    url = urllib.parse.quote(url, safe=':/?&=,%#_~+@')
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    for enc in ("utf-8", "gbk", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "ignore")

def norm(url):
    url = url.strip()
    if url.startswith(("http://", "https://")):
        pass
    elif url.startswith("/"):
        url = BASE + url
    elif url.startswith(("#", "mailto:", "javascript:", "tel:")):
        return url
    else:
        url = BASE + "/" + url
    return url.split("#")[0]

def is_internal(url):
    u = urllib.parse.urlparse(url)
    return u.netloc.lower() in ("", BASE_HOST) and u.scheme in ("http", "https")

def should_skip(url):
    low = url.lower()
    return any(h in low for h in SKIP_HINTS)

IMG_RE = re.compile(r'<img[^>]+src=["\']([^"\']+)["\']', re.I)
A_RE = re.compile(r'<a[^>]+href=["\']([^"\']+)["\']', re.I)
TITLE_RE = re.compile(r'<title>(.*?)</title>', re.I | re.S)
TAG_RE = re.compile(r'<[^>]+>')
SCRIPT_RE = re.compile(r'<(script|style)[^>]*>.*?</\1>', re.I | re.S)

def page_file(url):
    u = urllib.parse.urlparse(url)
    base = os.path.basename(u.path) or "index"
    base = re.sub(r'[^\w.\-]', '_', base)
    if u.query:
        base = base + "__" + re.sub(r'[^\w.\-]', '_', u.query)
    return os.path.join(SCRAPE_DIR, base + ".html")

def text_file(url):
    return page_file(url).replace(".html", ".txt")

def download_image(src):
    try:
        url = norm(src)
    except Exception:
        return None
    if not is_ascii(url) or not is_internal(url) or url in img_seen:
        return None
    img_seen.add(url)
    u = urllib.parse.urlparse(url)
    slug = u.path.strip("/").replace("/", "_")
    slug = re.sub(r'[^\w.\-]', '_', slug)
    if not slug:
        return None
    target = os.path.join(IMG_DIR, slug)
    try:
        qurl = urllib.parse.quote(url, safe=':/?&=,%#_~+@')
        req = urllib.request.Request(qurl, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=20) as r:
            data = r.read()
        if len(data) < 200:
            return None
        with open(target, "wb") as f:
            f.write(data)
        return os.path.relpath(target, ROOT).replace("\\", "/")
    except Exception:
        return None

seeds = ["index.asp", "about.asp?id=1", "case.asp?id=6", "join.asp?id=7",
         "ln.asp?id=10", "contact.asp?id=11", "product.asp", "news.asp", "Product.asp"]
queue = seeds[:]
visited = set()
img_seen = set()
sitemap = {}
img_count = 0

while queue and len(visited) < MAX_PAGES:
    rel = queue.pop(0)
    try:
        url = norm(rel)
    except Exception:
        continue
    if url in visited or not is_internal(url) or not is_ascii(url) or should_skip(url):
        continue
    path = urllib.parse.urlparse(url).path.lower()
    if not (path.endswith((".asp", ".html", ".htm")) or path in ("/", "")):
        continue
    visited.add(url)
    try:
        html = fetch(url)
    except Exception as e:
        print("ERR " + str(url) + " " + str(e)[:80])
        continue
    pf = page_file(url)
    with open(pf, "w", encoding="utf-8") as f:
        f.write(html)
    m = TITLE_RE.search(html)
    title = (m.group(1).strip() if m else "").replace("\n", " ").replace("\r", "")
    txt = SCRIPT_RE.sub("", html)
    txt = TAG_RE.sub("\n", txt)
    txt = re.sub(r'\n\s*\n+', '\n', txt)
    txt = re.sub(r'[ \t]+', ' ', txt).strip()
    with open(text_file(url), "w", encoding="utf-8") as f:
        f.write(txt)
    imgs = []
    for src in IMG_RE.findall(html):
        p = download_image(src)
        if p:
            imgs.append(p); img_count += 1
    links = []
    for href in A_RE.findall(html):
        try:
            hu = norm(href)
        except Exception:
            continue
        if not is_internal(hu) or not is_ascii(hu) or should_skip(hu):
            continue
        links.append(hu)
        if hu not in visited and hu not in queue:
            queue.append(hu)
    sitemap[url] = {
        "title": title,
        "html": os.path.relpath(pf, ROOT).replace("\\", "/"),
        "text": os.path.relpath(text_file(url), ROOT).replace("\\", "/"),
        "imgs": imgs, "n_links": len(links),
    }
    print("[%d] %s  imgs=%d links=%d" % (len(visited), url, len(imgs), len(links)))
    time.sleep(0.2)

with open(os.path.join(ROOT, ".scrape", "sitemap.json"), "w", encoding="utf-8") as f:
    json.dump(sitemap, f, ensure_ascii=False, indent=2)
print("\nDONE pages=%d images=%d" % (len(visited), img_count))
