"""Seed public synthetic production operations in an explicitly supplied local PG.
Wait for the final source migration before invoking; never call against company PG.
Credentials stay in environment/private config, never commands or evidence JSON.
"""
from pathlib import Path
import argparse,json,os,re,subprocess as sp
parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2]);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--build-dir',type=Path,required=True);parser.add_argument('--deps',type=Path,required=True);parser.add_argument('--runtime-config',type=Path,required=True);parser.add_argument('--compile-only',action='store_true')
a=parser.parse_args();root=a.root.resolve();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True);src=Path(__file__).resolve().parent
if (out/'browser-production-seed.json').exists():raise SystemExit('Existing seed evidence must be kept; choose a fresh --output')
config=json.loads(a.runtime_config.read_text(encoding='utf-8-sig'));url=config['jdbcUrl'];assert url.startswith('jdbc:postgresql://127.0.0.1:'), 'Only explicit loopback PG is supported'
port=re.search(r':(\d+)/',url).group(1);deps=a.deps.read_text(encoding='utf-8-sig').strip();assert all(Path(x).is_file() and x.endswith('.jar') for x in deps.split(';'))
classes=out/'classes';classes.mkdir(exist_ok=True);tmp=out/'tmp';tmp.mkdir(exist_ok=True)
# The three-material variant retains public business commands from the owning
# fixture; it changes only synthetic BOM cardinality and receipt quantities.
code=(root/'server/src/test/java/com/uten/imp/businesschain/WorkshopPublicSurplusEndToEndTest.java').read_text(encoding='utf8').replace('WorkshopPublicSurplusEndToEndTest','FeedbackThreeMaterialFixture')
replacements=[('UUID extraMaterial=secondMaterial?UUID.randomUUID():null;','UUID thirdMaterial=UUID.randomUUID(); fixture.insertGoods(thirdMaterial,"QA3-"+thirdMaterial,"第三原料","采购",world.unitId(),world.unitLegacy());fixture.insertBom(product,thirdMaterial,"1");\n        UUID extraMaterial=secondMaterial?UUID.randomUUID():null;'),('fixture.insertBom(product,extraMaterial,"2")','fixture.insertBom(product,extraMaterial,"1")'),('if(secondMaterial)receiveMaterial(c,extraMaterial);','if(secondMaterial)receiveMaterial(c,extraMaterial); receiveMaterial(c,thirdMaterial);'),('line.setQty(new BigDecimal("2000")); line.setPrice','line.setQty(new BigDecimal("10000")); line.setPrice'),('line.setAmountOriginal(new BigDecimal("20000")); line.setAmountLocal(new BigDecimal("20000"));','line.setAmountOriginal(new BigDecimal("100000")); line.setAmountLocal(new BigDecimal("100000"));')]
for before,after in replacements:
 if before not in code:raise SystemExit('Owning fixture changed: '+before)
 code=code.replace(before,after)
fixture=out/'FeedbackThreeMaterialFixture.java';fixture.write_text(code,encoding='utf8')
cp=';'.join(str(x.resolve()) for x in [classes,a.build_dir/'test-classes',a.build_dir/'classes'])+';'+deps
env=dict(os.environ,TMP=str(tmp),TEMP=str(tmp),UTEN_RUN_DB_TESTS='true',AUDIT_LEGACY_DIR=str(out),AUDIT_KIT_PG_PORT=port,AUDIT_KIT_JDBC=url,AUDIT_KIT_USERNAME=config['username'],AUDIT_KIT_PASSWORD=config['password'],AUDIT_BROWSER_PASSWORD=config['syntheticAccountPassword'])
def run(cmd,args,label):
 arg=out/(label+'.args');arg.write_text('\n'.join('"'+str(x).replace('\\','/')+'"' for x in args),encoding='utf8')
 with (out/(label+'.log')).open('wb') as stream:
  ret=sp.run([cmd,'@'+str(arg)],cwd=root/'server',env=env,stdout=stream,stderr=stream)
 if ret.returncode:raise SystemExit(label+' failed; original log retained')
run('javac',['-proc:none','-encoding','UTF-8','-cp',cp,'-d',classes,src/'FeedbackLegacyMaterialUpgradeFixture.java',src/'FeedbackBrowserSeedFixture.java',src/'FeedbackBrowserSeedRunner.java',fixture],'seed-javac')
if a.compile_only:
 print('Browser seed fixtures compiled; no database connection was opened')
 raise SystemExit(0)
run('java',['-Xshare:off','-javaagent:'+next(x for x in deps.split(';') if '/mockito-core/' in x.replace('\\','/')),'-Xmx1500m','-Djava.io.tmpdir='+str(tmp),'-Dlogging.file.name='+str(out/'seed-spring.log'),'-cp',cp,'FeedbackBrowserSeedRunner','seed'],'seed-business')
print('Created synthetic production IDs in '+str(out/'browser-production-seed.json')+'; credentials omitted')
