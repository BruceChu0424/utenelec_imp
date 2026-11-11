"""Read downloaded XLSX bytes without rewriting them; verify every synthetic source row."""
from pathlib import Path
from decimal import Decimal
import argparse,hashlib,json,xml.etree.ElementTree as E,zipfile
p=argparse.ArgumentParser();p.add_argument('file',type=Path);p.add_argument('--codes');p.add_argument('--output',required=True,type=Path);a=p.parse_args()
if a.output.exists():raise SystemExit('Preserve previous validation receipt')
ns={'m':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
with zipfile.ZipFile(a.file) as z:
 shared=[]
 if 'xl/sharedStrings.xml' in z.namelist():shared=[''.join(x.itertext()) for x in E.fromstring(z.read('xl/sharedStrings.xml'))]
 header=None;rows=[]
 for row in E.fromstring(z.read('xl/worksheets/sheet1.xml')).findall('.//m:row',ns):
  cells={}
  for c in row.findall('m:c',ns):
   v=c.find('m:v',ns);value=v.text if v is not None else ''
   if c.get('t')=='s':value=shared[int(value)]
   elif c.get('t')=='inlineStr':value=''.join(c.find('m:is',ns).itertext())
   col=''.join(t for t in c.get('r') if t.isalpha());cells[col]=value
  if header is None:
   if '模具编号' in cells.values() and '套数' in cells.values():header=cells
  else:rows.append(cells)
 assert header is not None,'Missing actual mould headers'
 assert '模具类型' not in header.values(),'mouldType must not be downloadable'
 code_col=next(k for k,v in header.items() if v=='模具编号');qty_col=next(k for k,v in header.items() if v=='套数')
 expected=a.codes.split(',') if a.codes else ['AU-'+str(i).zfill(5) for i in range(1626,0,-1)]
 actual=[r.get(code_col) for r in rows]
 assert actual==expected,{'expectedRows':len(expected),'actualRows':len(actual),'first':actual[:3],'last':actual[-3:]}
 for r,code in zip(rows,expected):assert Decimal(r[qty_col])==Decimal(1627-int(code[3:]))+Decimal('.125'),code
 raw=a.file.read_bytes();r={'rawFile':str(a.file.resolve()),'byteContract':'actual downloaded XLSX bytes; read only','bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'rows':len(rows),'headers':list(header.values()),'everyCodeInExactOrder':True,'everyQuantityExact':True,'mouldTypeAbsent':True,'first':{'code':actual[0],'qty':rows[0][qty_col]},'last':{'code':actual[-1],'qty':rows[-1][qty_col]}}
 a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(r,ensure_ascii=False,indent=2),encoding='utf8');print(json.dumps(r,ensure_ascii=False))
