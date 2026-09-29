from pathlib import Path
from xml.sax.saxutils import escape
import json, re
from reportlab.pdfgen import canvas
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import Paragraph, Table, TableStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parents[1] / 'output' / 'pdf' / 'Uten_IMP_长期性能稳定性与数据生命周期方案_2026-09-27.pdf'
OUT.parent.mkdir(parents=True, exist_ok=True)
pdfmetrics.registerFont(TTFont('CN', 'C:/Windows/Fonts/simhei.ttf'))
pdfmetrics.registerFont(TTFont('Latin', 'C:/Windows/Fonts/arial.ttf'))
W,H = 595.276,841.89
INK=colors.HexColor('#203C36'); GREEN=colors.HexColor('#145B4C'); TEAL=colors.HexColor('#178877')
GRAY=colors.HexColor('#52655F'); PALE=colors.HexColor('#EAF3EF'); LINE=colors.HexColor('#D5E1DC')
M=43; CW=W-2*M
styles={
 'body':ParagraphStyle('body',fontName='CN',fontSize=11.5,leading=19.2,textColor=INK,wordWrap='CJK',spaceAfter=8),
 'small':ParagraphStyle('small',fontName='CN',fontSize=9.2,leading=14.3,textColor=GRAY,wordWrap='CJK'),
 'cell':ParagraphStyle('cell',fontName='CN',fontSize=10.4,leading=16.5,textColor=INK,wordWrap='CJK'),
 'th':ParagraphStyle('th',fontName='CN',fontSize=10.4,leading=16,textColor=colors.white,wordWrap='CJK'),
 'h2':ParagraphStyle('h2',fontName='CN',fontSize=13.5,leading=19.5,textColor=GREEN,wordWrap='CJK'),
}
def markup(t):
    t=escape(t)
    t=re.sub(r'\*\*(.*?)\*\*',r'<font color="#145B4C">\1</font>',t)
    return t.replace('\n','<br/>')
def p(t,kind='body'): return Paragraph(markup(t),styles[kind])

data=json.loads((ROOT/'erp_plan_content.json').read_text(encoding='utf-8'))
c=canvas.Canvas(str(OUT),pagesize=(W,H),pageCompression=1)
c.setTitle('Uten IMP 长期性能、稳定性与数据生命周期优化方案')
c.setAuthor('Uten IMP · 项目调查与方案设计')
c.setSubject('审批稿 | 只读调查 | 2026-09-27')
layout=[]

def draw_para(t,y,kind='body',x=M,width=CW):
    obj=p(t,kind); _,height=obj.wrap(width,H)
    obj.drawOn(c,x,y-height)
    return y-height-(8 if kind=='body' else 6)

def draw_table(headers,rows,widths,y):
    cells=[[p(str(x),'th') for x in headers]]+[[p(str(x),'cell') for x in row] for row in rows]
    t=Table(cells,colWidths=[CW*x for x in widths],hAlign='LEFT')
    t.setStyle(TableStyle([
        ('BACKGROUND',(0,0),(-1,0),GREEN),('VALIGN',(0,0),(-1,-1),'TOP'),
        ('LEFTPADDING',(0,0),(-1,-1),8),('RIGHTPADDING',(0,0),(-1,-1),8),
        ('TOPPADDING',(0,0),(-1,-1),7),('BOTTOMPADDING',(0,0),(-1,-1),7),
        ('ROWBACKGROUNDS',(0,1),(-1,-1),[colors.white,PALE]),
        ('LINEBELOW',(0,0),(-1,0),0.6,GREEN),('LINEBELOW',(0,1),(-1,-1),0.35,LINE)
    ]))
    _,ht=t.wrap(CW,H); t.drawOn(c,M,y-ht)
    return y-ht-12

def diagram(y):
    boxes=[('业务操作','当前余额 / 活跃单据 / 同步事务'),('历史查询','统一单号与权限 / 在线历史索引'),('报表统计','日月汇总 / 更新时点 / 异步导出'),('长期保存','原始证据 / 分层附件 / 独立备份')]
    for i,(a,b) in enumerate(boxes):
        top=y-i*67
        c.setFillColor(PALE if i%2==0 else colors.HexColor('#F3F6F4'))
        c.roundRect(M,top-54,CW,54,7,fill=1,stroke=0)
        c.setFillColor(GREEN); c.setFont('CN',12); c.drawString(M+15,top-21,a)
        c.setFillColor(GRAY); c.setFont('CN',10); c.drawString(M+113,top-21,b)
        c.setFont('CN',8.5); c.drawString(M+113,top-39,['立即生效，余额与流水同成同败','跨年份可查；冷数据有取回状态','统计不争抢办理业务的资源','校验、冻结与恢复证明贯穿全过程'][i])
    return y-281

for idx,page in enumerate(data['pages'],1):
    c.bookmarkPage(f'p{idx}'); c.addOutlineEntry(page['title'],f'p{idx}',0,False)
    c.setFillColor(GREEN); c.rect(0,H-10,W,10,fill=1,stroke=0)
    c.setFont('Latin',8.5); c.setFillColor(GRAY); c.drawString(M,H-34,'UTEN IMP  /  LONG-TERM RELIABILITY')
    c.setFont('CN',8.5); c.drawRightString(W-M,H-34,'方案审批稿 · 2026-09-27')
    c.setFont('CN',21); c.setFillColor(GREEN); c.drawString(M,H-77,page['title'])
    y=H-97
    if page.get('subtitle'): y=draw_para(page['subtitle'],y,'small')-7
    for block in page['blocks']:
        if block['type']=='p': y=draw_para(block['text'],y)
        elif block['type']=='h': y=draw_para(block['text'],y-4,'h2')
        elif block['type']=='small': y=draw_para(block['text'],y,'small')
        elif block['type']=='table': y=draw_table(block['headers'],block['rows'],block['widths'],y)
        elif block['type']=='diagram': y=diagram(y)
        elif block['type']=='callout':
            ob=p(block['text']); _,hh=ob.wrap(CW-26,H)
            c.setFillColor(PALE); c.roundRect(M,y-hh-24,CW,hh+24,6,fill=1,stroke=0)
            ob.drawOn(c,M+13,y-hh-12); y-=hh+36
        elif block['type']=='refs':
            for label,url in block['items']:
                obj=Paragraph(f'<link href="{escape(url)}" color="#178877">{escape(label)}</link>',styles['small'])
                _,hh=obj.wrap(CW,H); obj.drawOn(c,M,y-hh); y-=hh+5
    if y<65: raise RuntimeError(f'Page {idx} overflow: bottom={y:.1f} {page["title"]}')
    layout.append({'page':idx,'title':page['title'],'bottom':round(y,1)})
    c.setStrokeColor(LINE); c.line(M,51,W-M,51)
    c.setFont('CN',8); c.setFillColor(GRAY); c.drawString(M,36,'只读调查与建议；批准后实施。保留业务原始证据与来源关联。')
    c.setFont('Latin',8); c.drawRightString(W-M,36,f'{idx:02d} / {len(data["pages"]):02d}')
    c.showPage()
c.save()
(ROOT/'layout.json').write_text(json.dumps(layout,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'pdf':str(OUT),'pages':len(data['pages']),'min_bottom':min(x['bottom'] for x in layout)},ensure_ascii=False))
