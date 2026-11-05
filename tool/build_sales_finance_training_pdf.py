"""Build the reviewed employee training PDF from final, anonymous Uten screenshots.

The manifest is produced only after implementation acceptance. This generator
does not query company services or alter screenshot files.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas
from reportlab.platypus import Paragraph

ROOT = Path(__file__).resolve().parents[1]
PAGE_W, PAGE_H = landscape(A4)
MARGIN = 34
WIDTH = PAGE_W - MARGIN * 2
TEAL = colors.HexColor("#0F766E")
RED = colors.HexColor("#B91C1C")
TEXT = colors.HexColor("#0F172A")
MUTED = colors.HexColor("#475569")
BORDER = colors.HexColor("#E2E8F0")
BG = colors.HexColor("#F5F7FA")
PALE = colors.HexColor("#F0FDFA")
RED_BG = colors.HexColor("#FEF2F2")
FONT = "UtenTrainingSC"
FONT_BOLD = "UtenTrainingSCBold"


def register_training_fonts(manifest):
    # ReportLab takes the default (Thin/100) face of this variable font. Pin
    # real static 400/700 instances so the printed Chinese remains readable.
    local_dependencies = ROOT/"tmp/pdfs/python-deps"
    if local_dependencies.is_dir():
        sys.path.insert(0, str(local_dependencies))
    from fontTools.ttLib import TTFont as FontToolsFont
    from fontTools.subset import Subsetter
    from fontTools.varLib.instancer import instantiateVariableFont
    source = ROOT/"assets/fonts/NotoSansSCFull.ttf"
    cache = ROOT/"tmp/pdfs/fonts"
    cache.mkdir(parents=True, exist_ok=True)
    glyph_text = Path(__file__).read_text(encoding="utf-8") + json.dumps(manifest, ensure_ascii=False)
    glyph_key = hashlib.sha256(glyph_text.encode("utf-8")).hexdigest()[:12]
    for name, weight in ((FONT, 400), (FONT_BOLD, 700)):
        target = cache/f"NotoSansSC-{weight}-{glyph_key}.ttf"
        if not target.exists() or target.stat().st_mtime < source.stat().st_mtime:
            with FontToolsFont(str(source)) as variable:
                subset = Subsetter()
                subset.populate(text=glyph_text, unicodes=[160])
                subset.subset(variable)
                static = instantiateVariableFont(variable, {"wght": weight}, inplace=False)
                # Distinct PostScript names prevent ReportLab's face cache
                # from merging the regular and bold static instances.
                for record in static["name"].names:
                    if record.nameID == 6:
                        record.string = f"UtenTrainingSC-{weight}".encode(record.getEncoding())
                static.save(str(target))
        pdfmetrics.registerFont(TTFont(name, str(target)))
    pdfmetrics.registerFontFamily(FONT, normal=FONT, bold=FONT_BOLD,
                                  italic=FONT, boldItalic=FONT_BOLD)


class Training:
    def __init__(self, manifest: dict, output: Path):
        self.manifest = manifest
        self.output = output
        self.pages = 0
        self.images = manifest.get("images", {})
        self.c = canvas.Canvas(str(output), pagesize=(PAGE_W, PAGE_H), pageCompression=1,
                               initialFontName=FONT, initialFontSize=11, lang="zh-CN")
        self.c.setTitle("销售与财务联动操作手册")
        self.c.setAuthor("UTEN")
        self.c.setSubject("按出货批次收款、按订货单收定金，分次收款与还欠跟进")

    def box(self, x, y, w, h, fill=colors.white, stroke=BORDER, radius=8):
        self.c.setFillColor(fill)
        self.c.setStrokeColor(stroke)
        self.c.setLineWidth(.7)
        self.c.roundRect(x, PAGE_H-y-h, w, h, radius, fill=1, stroke=1)

    def line(self, x1, y1, x2, y2, color=BORDER, width=1):
        self.c.setStrokeColor(color)
        self.c.setLineWidth(width)
        self.c.line(x1, PAGE_H-y1, x2, PAGE_H-y2)

    def text(self, text, x, y, size=11, color=TEXT, numeric=False):
        self.c.setFont(FONT_BOLD if numeric or size >= 13 else FONT, size)
        self.c.setFillColor(color)
        self.c.drawString(x, PAGE_H-y-size, text)

    def para(self, text, x, y, w, size=11, leading=None, color=TEXT, markup=False):
        style = ParagraphStyle("training", fontName=FONT, fontSize=size,
                               leading=leading or size*1.6, textColor=color, wordWrap="CJK")
        p = Paragraph(text if markup else escape(text).replace("\n", "<br/>"), style)
        _, height = p.wrap(w, PAGE_H)
        if y+height > PAGE_H-30:
            raise ValueError(f"Text exceeds page {self.pages}: {text[:35]}")
        p.drawOn(self.c, x, PAGE_H-y-height)
        return y+height

    def arrow(self, x1, y1, x2, y2, color=TEAL):
        import math
        self.line(x1, y1, x2, y2, color, 1.6)
        angle = math.atan2(y2-y1, x2-x1)
        p = self.c.beginPath()
        p.moveTo(x2, PAGE_H-y2)
        for delta in (2.6, -2.6):
            p.lineTo(x2+7*math.cos(angle+delta), PAGE_H-(y2+7*math.sin(angle+delta)))
        p.close()
        self.c.setFillColor(color)
        self.c.drawPath(p, fill=1, stroke=0)

    def page(self, title, role):
        if self.pages:
            self.c.showPage()
        self.pages += 1
        self.c.setFillColor(BG)
        self.c.rect(0, 0, PAGE_W, PAGE_H, fill=1, stroke=0)
        self.text("UTEN", MARGIN, 18, 12, TEAL, numeric=True)
        self.text(role, PAGE_W-190, 19, 10, MUTED)
        self.text(title, MARGIN, 47, 23)
        self.line(MARGIN, 87, PAGE_W-MARGIN, 87)
        self.text("销售与财务联动 | 匿名学习示例", MARGIN, PAGE_H-24, 8.5, MUTED)
        self.text(f"{self.pages:02d}", PAGE_W-MARGIN-17, PAGE_H-25, 9, TEAL, numeric=True)

    def steps(self, entries, x, y, w, gap=14):
        for number, (title, body) in enumerate(entries, 1):
            self.box(x, y+1, 24, 24, PALE, PALE, 12)
            self.text(str(number), x+8, y+4, 11, TEAL, numeric=True)
            self.text(title, x+35, y, 13)
            end = self.para(body, x+35, y+24, w-35, 10.5, 16, MUTED)
            y = end+gap
        return y

    def note(self, text, x, y, w=WIDTH, h=49, important=False):
        self.box(x, y, w, h, RED_BG if important else PALE,
                 RED_BG if important else PALE, 6)
        self.para(text, x+13, y+10, w-26, 10.5, 16, RED if important else TEAL)

    def money(self, x, y, w, amount, paid, balance, label="本批货款"):
        self.box(x, y, w, 104)
        self.text(label, x+14, y+10, 11, MUTED)
        cell = (w-28)/3
        for i, (name, value) in enumerate((("货款", amount), ("已收", paid), ("还欠", balance))):
            px=x+14+cell*i
            self.text(name, px, y+35, 10, MUTED)
            self.text(value, px, y+55, 25, RED if i==2 and value!="0" else TEXT, numeric=True)

    def screen(self, key, x, y, w, h, region=None):
        raw = self.images.get(key)
        if not raw:
            raise ValueError(f"Final reviewed screenshot is missing: {key}")
        path = Path(raw)
        if not path.is_absolute():
            path = ROOT/path
        if not path.is_file():
            raise FileNotFoundError(path)
        image = ImageReader(str(path))
        iw, ih = image.getSize()
        sx, sy, sw, sh = region or self.manifest.get("regions", {}).get(key) or (0, 0, iw, ih)
        if sx < 0 or sy < 0 or sx+sw > iw+1 or sy+sh > ih+1:
            raise ValueError(f"Screenshot region exceeds {key}")
        scale = min(w/sw, h/sh)
        vw, vh = sw*scale, sh*scale
        self.box(x-1, y-1, vw+2, vh+2, colors.white, BORDER, 4)
        self.c.saveState()
        clip = self.c.beginPath()
        clip.rect(x, PAGE_H-y-vh, vw, vh)
        self.c.clipPath(clip, stroke=0)
        # Place the original image under a PDF viewport; no screenshot file is edited.
        self.c.drawImage(image, x-sx*scale, PAGE_H-y-(ih-sy)*scale,
                         width=iw*scale, height=ih*scale, mask="auto")
        self.c.restoreState()
        return vh

    def cover(self):
        self.page("销售和财务怎么配合", "全员先读")
        self.text("按出货单收款，按订货单收定金", MARGIN, 112, 24, TEAL)
        self.para("一批货一笔应收。每次只登记这次实际收到的款，还没收齐的余额继续保留。",
                  MARGIN, 153, WIDTH, 13, 21)
        self.para("主线示例直接分次收400和600；定金、手续费另页说明，分别核对。",
                  MARGIN, 183, WIDTH, 10, 16, MUTED)
        self.money(MARGIN, 208, WIDTH, "1000", "400", "600", "贯穿示例：同一批货")
        roles=[("销售", "确认本批出货；看还欠并按约定跟进"),
               ("仓库", "按已放行任务实际出库；不代记收款"),
               ("财务", "核对真实到账；登记、审核及抵扣定金")]
        col=(WIDTH-24)/3
        for i,(name,body) in enumerate(roles):
            px=MARGIN+i*(col+12)
            self.box(px, 344, col, 99)
            self.text(name, px+14, 358, 16, TEAL)
            self.para(body, px+14, 389, col-28, 10.5, 17)
        self.note("只保存草稿不算已收；发货放行不算尾款到账；客户承诺付款也不算已收。",
                  MARGIN, 466, important=True)
        self.para(self.manifest["release_note"], MARGIN, 532, WIDTH, 8.5, 12, MUTED)

    def overview(self):
        self.page("先看完整流程", "销售 / 仓库 / 财务")
        self.text("先完成这批货的出货链",MARGIN,111,13,TEAL)
        gap=18
        width=(WIDTH-gap*4)/5
        for i,(role,title,body) in enumerate([
            ("销售","订货单","记录客户的订单"),
            ("销售","本批出货单","这次发哪些货、多少"),
            ("财务","核对并放行","按约定允许仓库发货"),
            ("仓库","实际出库","确认真实发出的数量"),
            ("系统","形成本批应收","这批货才有正式还欠"),
        ]):
            x=MARGIN+i*(width+gap)
            self.box(x,143,width,112)
            self.text(role,x+12,154,10,TEAL)
            self.text(title,x+12,179,14)
            self.para(body,x+12,210,width-24,10,15,MUTED)
            if i<4:self.arrow(x+width+3,198,x+width+gap-3,198)
        self.text("再按真实到账，分次收清同一批",MARGIN,282,13,TEAL)
        width=(WIDTH-36)/3
        for i,(title,body) in enumerate([
            ("财务登记并审核","引用出货单，只填本次收到的钱"),
            ("销售刷新查看还欠","还欠有余额，继续按约定跟进"),
            ("尾款到账后再登记","仍引用原批次，审核后重新核对"),
        ]):
            x=MARGIN+i*(width+18)
            self.box(x,312,width,85,PALE,PALE)
            self.text(title,x+13,325,13,TEAL)
            self.para(body,x+13,354,width-26,10.5,16)
            if i<2:self.arrow(x+width+3,355,x+width+15,355)
        self.para("如果先收定金：先引用订货单登记并审核。等本批应收建立，再把定金实际抵到本批。",
                  MARGIN,427,WIDTH,12,20)
        self.note("发货审核是允许仓库发货；收款审核才确认这笔钱。两个动作不要混。",
                  MARGIN,510,important=True)

    def deposit(self):
        self.page("定金或多付款，怎么登记", "财务经办 / 财务审核")
        self.steps([
            ("选订单预收", "由有订单预收权限的财务新建收款单，在收款类型列选订单预收（定金/多付），再引用真实订货单。看不到该列先核对岗位权限。"),
            ("填这次真实收到的金额", "实际收到多少就填多少。核对客户、币种、收款账户、收款方式、到账时间和费用，不能按承诺提前登记。"),
            ("保存后交有权人员审核", "保存仍是草稿。按系统职责分离，由另一位有权限的人员核对银行事实后审核。"),
            ("抵到实际出货批次", "未出货定金等应收建立再抵；已出货的多付款也先记录真实预收，再抵正式应收。未用余额继续保留，不计收入，不重复用到两批。"),
        ],MARGIN,111,330,12)
        self.screen("prepayment",400,110,405,337)
        self.box(400,210,405,155,PALE,PALE)
        self.text("图示：按订货单预收1000",415,225,15,TEAL)
        self.para("图中仍在填写，须保存并审核。\n例如已正常履约的订单货款735、真实收到1000：先记预收1000，再实际抵735，剩余265仍保留为预收。",415,261,375,11,19)
        self.para("此页为独立预收示例，不与400/600主线叠加。",415,341,375,10,15,TEAL)
        self.note("订货单用于定金来源；真正收到钱以后再审核。尚未发生的付款约定不能填成已到账。",
                  MARGIN,498,important=True)

    def release(self):
        self.page("发货前，先核对再放行", "销售 / 财务 / 仓库")
        self.steps([
            ("销售确认这批货", "核对出货单号、客户、货品、数量、货款和结款约定。到货后付尾款等要求应有原单据依据。"),
            ("财务决定是否放行", "订单定金可作参考。是否允许留尾款发货，由有权限的财务按约定判断，不由红字自动决定。"),
            ("仓库按实际出库", "只有实际出库后才形成这批正式应收。不要为了先收定金而提前确认出库。"),
        ],MARGIN,112,445,22)
        self.screen("not_posted",530,108,260,360)
        self.note("看到“待出库”表示还没形成正式应收，不是这批还欠0，也不是已经收清。",
                  MARGIN,499,important=True)

    def debt(self):
        self.page("出库后，在哪看这批还欠", "销售 / 财务")
        self.screen("shipment_list",MARGIN,112,WIDTH,148,region=self.manifest.get("list_region",[355,174,895,95]))
        self.steps([
            ("按出货单号找这批", "同一订货单可以分多批出货。看出货单号，不拿订单总额当本批应收。"),
            ("看表格最后的已收、还欠", "示例货款1000，已收400，还欠600。正数还欠用红色提示，说明这批还有余额。"),
            ("找老欠款，打开只看还欠", "“只看还欠（全部日期）”按服务器未清批次查询，不只看最近一个月，也不是只过滤当前可见页。"),
        ],MARGIN,278,WIDTH,13)
        self.note("财务在另一台电脑审核后，销售催款前先点刷新。看不到新列时，横向滚到表尾或检查表头设置。",
                  MARGIN,509)

    def partial(self):
        self.page("这次只收400，就只填400", "财务经办 / 财务审核")
        self.screen("receipt",MARGIN,111,WIDTH,174)
        self.para("图中XC-1000-A仍在填写草稿，还欠还是1000；这笔400审核成功后，再刷新看还欠600。",
                  MARGIN,205,WIDTH,10.5,17,MUTED)
        self.steps([
            ("点按出货单收款", "引用本次要收的出货批次，核对出货单号、客户、币种和当前还欠。"),
            ("明确填本次金额", "货款1000但这次只收到400，就填400。不要把货款总额或还欠全额误当这次实收。"),
            ("核对实际到账再保存、审核", "选择收款账户和收款方式，再核对实际到账、发生时间及费用。有真实流水号可填写，便于核对。"),
            ("刷新本批结果", "审核成功后应是已收400、还欠600。仅保存或还在待审，不能按已收400处理。"),
        ],MARGIN,255,WIDTH,8)
        self.note("多批一起收款，要给每批填写本次分配金额；一笔总到账不能原样复制到每一行。",
                  MARGIN,500,important=True)

    def tail(self):
        self.page("尾款到货后再给，怎么继续", "销售跟进 / 财务收尾款")
        self.money(MARGIN,112,455,"1000","400","600")
        self.steps([
            ("先核对约定", "红字说明还有余额，不等于已经逾期。按正式收款期限、原结款方式和备注约定联系客户。"),
            ("未到账时保留还欠", "系统已出库不等于客户已经到货。只是说到货后给钱，不能先把600记成已收。"),
            ("尾款真实到后，再收同一批", "新建本次收款，仍引用原出货单，金额填600，保存并审核。不要把原来400那笔直接改成1000。"),
        ],MARGIN,246,455,15)
        self.screen("detail_mobile",548,112,225,283)
        self.box(548,417,225,70,PALE,PALE)
        self.text("尾款审核后",562,428,11,TEAL)
        self.text("已收1000 / 还欠0",562,451,17,TEAL)
        self.note("本例400+600现金审核后已结清。开启只看还欠时，这批会从结果中消失；关闭筛选、日期选全部，再按原出货号找。",
                  MARGIN,514)

    def allocate(self):
        self.page("分批出货，定金不要重复用", "财务抵款 / 销售核对")
        self.text("另一独立订单例：货款1000，定金300，分两批出货",MARGIN,111,15,TEAL)
        rows=[("第一批","600","200","400"),("第二批","400","100","300")]
        widths=[130,150,190,150]
        xs=[MARGIN]
        for width in widths:xs.append(xs[-1]+width)
        headers=["出货批次","本批货款","已用定金抵款","本批还欠"]
        for i,head in enumerate(headers):
            self.box(xs[i],157,widths[i],41,PALE,PALE,0)
            self.text(head,xs[i]+12,169,11,TEAL)
        for n,row in enumerate(rows):
            y=198+n*56
            for i,value in enumerate(row):
                self.box(xs[i],y,widths[i],56,colors.white,BORDER,0)
                self.text(value,xs[i]+12,y+17,17,RED if i==3 else TEXT,numeric=i>0)
        self.steps([
            ("用定金抵款到具体批次", "收款页勾选该客户的一行，点用定金抵款，选预收来源；再点选择应收，选本批、填本次抵款与抵扣说明，确认后刷新。本例第一批抵200、第二批抵100，合计仅300。"),
            ("后来各批分别收尾款", "第一批再收400，第二批再收300，各自审核后各自结清。未分配的定金或别批的款不冒成本批已收。"),
        ],MARGIN,339,WIDTH,18)
        self.note("订单预收记录、抵款记录和本批收款记录都保留。用定金抵款不会再给银行账户增加一笔新收入。",
                  MARGIN,505,important=True)

    def fees(self):
        self.page("手续费和客户少付，分清楚", "财务重点")
        panel=(WIDTH-20)/2
        for i,(title,body,paid,debt) in enumerate([
            ("公司承担银行费", "本例货款200，同币种结算。银行扣10：主表本次收款填200；结算设置费用填10、费用方式选从到账扣除、实际到账填190。审核后货款已收仍是200。", "200", "0"),
            ("客户真的只付190", "本例货款200，客户实际只给190，银行没有扣费，就记收款190、费用0。不能把差10随便填成手续费。", "190", "10"),
        ]):
            x=MARGIN+i*(panel+20)
            self.box(x,112,panel,270)
            self.text(title,x+15,128,17,TEAL)
            self.para(body,x+15,166,panel-30,12,20)
            self.text("已收",x+15,264,11,MUTED)
            self.text(paid,x+15,286,28,numeric=True)
            self.text("还欠",x+panel/2,264,11,MUTED)
            self.text(debt,x+panel/2,286,28,RED if debt!="0" else TEAL,numeric=True)
        self.para("以上为同币种、审核后的独立费用例子，不叠加前面的400/600。客户结算、银行净到账和公司费用分别核对。",
                  MARGIN,403,WIDTH,11,18)
        self.note("退货、减免或其他抵款必须有正式依据并由有权财务处理。结清可能含退减，不代表银行收到全部原货款。",
                  MARGIN,486,important=True)

    def exceptions(self):
        self.page("遇到这些情况，先这样处理", "全员速查")
        items=[
            ("保存后还欠没变", "先看收款单是否仍是草稿或待审。未审核不计已收，别重复新建同一笔。"),
            ("定金到账还没抵本批", "请财务办理抵到这批；不要在两批里同时把同一笔定金算成已收。"),
            ("页面数字没更新", "财务另一电脑处理后，先刷新再催款；不要拿旧截图当当前余额。"),
            ("显示需核对", "把出货单号、收款单号和状态交给财务核对原来源与真实流水，不能当成0。"),
            ("网络中断或不知道存没存", "保留原单和草稿，先核对原结果，按原记录重试；不要另造一笔相同收款。"),
            ("录错款、退货或真实退款", "由有权财务按正式流程更正并核对银行。反审是账目更正，不等于银行已经退钱。"),
            ("客户多付款", "明确记录预收/多付款及实际到账，抵清本批后剩余保留核对；不当收入、不自动挪给别批。"),
            ("历史期初没有出货单", "按已核验的原始来源处理，不编造新出货单；来源不全先由财务核对。"),
            ("币种不同", "欠款跟原出货币种，银行金额跟实际账户币种。不要把不同币种直接合成一个数。"),
            ("没有金额列或选不到来源", "先核对岗位权限、负责范围、单据是否已出库/未清。不要靠随意开全档案权限消提示。"),
        ]
        col=(WIDTH-24)/2
        for i,(title,body) in enumerate(items):
            x=MARGIN+(i//5)*(col+24);y=110+(i%5)*85
            self.text(title,x,y,12,TEAL)
            self.para(body,x,y+23,col,10.5,16)

    def quick(self):
        self.page("每天照这张速查表做", "岗位与练习")
        self.steps([
            ("销售催款前", "找对出货单，刷新，看已收和还欠；核对约定再联系客户。红字是余额提醒，是否逾期另看收款期限。"),
            ("财务登记前", "核对真实到账，找对批次，只填这次金额；账户、币种、费用和时间按实际，不按承诺。"),
            ("财务审核前", "核对原单、真实凭据和是否重复；制作与审核按系统职责分离。未实际发生的款不提前审核。"),
            ("仓库操作时", "按已放行任务和实际数量出库；不为收款提前出库，也不通过仓库状态代记尾款。"),
        ],MARGIN,110,WIDTH,13)
        self.box(MARGIN,432,WIDTH,80,PALE,PALE)
        self.text("一分钟练习",MARGIN+14,444,13,TEAL)
        self.para("同批货款1000，已审核收400，今天又真实收200：本次填多少？还欠多少？\n答案：本次填200；再审核后累计已收600，还欠400。",MARGIN+14,469,WIDTH-28,11,17)
        self.para("学习核对版本："+self.manifest.get("revision","本次验收源码"),MARGIN,535,WIDTH,8.5,12,MUTED)

    def build(self):
        for method in (self.cover,self.overview,self.deposit,self.release,self.debt,self.partial,
                       self.tail,self.allocate,self.fees,self.exceptions,self.quick):
            method()
        self.c.save()
        return self.pages


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--manifest",type=Path,required=True)
    parser.add_argument("--output",type=Path,default=ROOT/"output/pdf/销售与财务联动操作手册.pdf")
    args=parser.parse_args()
    manifest=json.loads(args.manifest.read_text(encoding="utf-8-sig"))
    if not manifest.get("implementation_verified"):
        raise SystemExit("Finish implementation acceptance before authoring the final training PDF")
    register_training_fonts(manifest)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    pages=Training(manifest,args.output).build()
    print(json.dumps({"output":str(args.output.resolve()),"pages":pages},ensure_ascii=False))


if __name__=="__main__":
    main()
