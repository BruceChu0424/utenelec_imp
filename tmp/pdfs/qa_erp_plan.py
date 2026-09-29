from pathlib import Path
from PIL import Image,ImageOps,ImageDraw
from pypdf import PdfReader
import json,re
root=Path(__file__).parent
pdf=next((root.parents[1]/'output'/'pdf').glob('Uten_IMP_*2026-09-27.pdf'))
reader=PdfReader(str(pdf))
texts=[page.extract_text() or '' for page in reader.pages]
assert len(texts)==28
alltext='\n'.join(texts)
for bad in ['待构建核对','具体包路径以','补充证据页','\ufffd','占位文本']:
    assert bad not in alltext,bad
for required in ['测试数据','24 个月','30 天','6-12 周','WAL','337 MiB','V733','V735','物化视图','冻结','恢复']:
    assert required in alltext,required
links=sum(len(p.get('/Annots',[])) for p in reader.pages)
assert links>=13
for n,text in enumerate(texts,1):
    assert len(text)>200,(n,len(text))
imgs=sorted(root.glob('erp-plan-*.png'))
assert len(imgs)==28,len(imgs)
for start in range(0,len(imgs),4):
    sheet=Image.new('RGB',(1260,1820),'#dce5e0')
    draw=ImageDraw.Draw(sheet)
    for offset,f in enumerate(imgs[start:start+4]):
        im=Image.open(f).convert('RGB'); im.thumbnail((600,850))
        x=20+(offset%2)*630; y=30+(offset//2)*910
        sheet.paste(im,(x,y)); draw.text((x,y+855),f'PAGE {start+offset+1}',fill='#163c31')
    sheet.save(root/f'contact-{start//4+1:02}.png')
summary={'pages':len(texts),'links':links,'bytes':pdf.stat().st_size,'text_chars':len(alltext),'page_char_counts':[len(x) for x in texts]}
(root/'qa_result.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
(root/'extracted_text.txt').write_text(alltext,encoding='utf-8')
print(json.dumps(summary))
