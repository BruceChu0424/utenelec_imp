"""Regenerate tiny, non-executable VERSIONINFO data from the pinned real compiler.

The temporary installers contain only payload.txt and are never executed or
committed. Only unchanged RT_VERSION bytes are retained as reviewable hex.
"""
from pathlib import Path
import argparse,hashlib,json,struct,subprocess

COMPILER_SHA256='d06ebd38f38e3cee60a3c50cc45bd449d77e0bc6a5cabc607ea9886808e4de1a'
HERE=Path(__file__).resolve().parent
def sha(data):return hashlib.sha256(data).hexdigest()
def version_resource(data):
    word=lambda at:struct.unpack_from('<H',data,at)[0]
    dword=lambda at:struct.unpack_from('<I',data,at)[0]
    assert data[:2]==b'MZ';pe=dword(60);assert data[pe:pe+4]==b'PE\0\0'
    sections=word(pe+6);optional=pe+24;table=optional+word(pe+20)
    def offset(rva,length):
        matches=[]
        for i in range(sections):
            entry=table+40*i;base=dword(entry+12);size=min(dword(entry+8),dword(entry+16))
            if 0<=rva-base<=size-length:matches.append(dword(entry+20)+rva-base)
        assert len(matches)==1 and matches[0]+length<=len(data)
        return matches[0]
    root=offset(dword(optional+112),dword(optional+116))
    def entries(relative):
        at=root+relative;count=word(at+12)+word(at+14)
        return[(dword(at+16+i*8),dword(at+20+i*8))for i in range(count)]
    versions=[target for name,target in entries(0)if name==16]
    assert len(versions)==1 and versions[0]&0x80000000
    names=entries(versions[0]&0x7fffffff);assert len(names)==1 and names[0][1]&0x80000000
    languages=entries(names[0][1]&0x7fffffff);assert len(languages)==1 and not languages[0][1]&0x80000000
    entry=root+languages[0][1];length=dword(entry+4);start=offset(dword(entry),length)
    result=data[start:start+length]
    assert 92<=len(result)<=4000 and struct.unpack_from('<H',result)[0]==len(result)
    assert result[6:38]=='VS_VERSION_INFO\0'.encode('utf-16le')
    return result

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--iscc',required=True,type=Path);parser.add_argument('--work',required=True,type=Path);args=parser.parse_args()
    compiler=args.iscc.resolve(strict=True);assert sha(compiler.read_bytes())==COMPILER_SHA256,'Unreviewed Inno compiler'
    work=args.work.resolve();assert not work.is_relative_to(HERE),'Keep executable scratch outside committed fixtures'
    work.mkdir(parents=True,exist_ok=False)
    records={}
    for local,name in((False,'normal'),(True,'local-test')):
        command=[str(compiler),'/Qp','/O'+str(work),'/F'+name,*(['/DLocalTest']if local else[]),str(HERE/'fixture.iss')]
        result=subprocess.run(command,capture_output=True,check=True)
        (work/(name+'.compile.log')).write_bytes(result.stdout+result.stderr)
        binary=(work/(name+'.exe')).read_bytes();resource=version_resource(binary)
        target=HERE/(name+'.versioninfo.hex')
        target.write_text('\n'.join(resource[i:i+32].hex()for i in range(0,len(resource),32))+'\n',encoding='ascii',newline='\n')
        records[target.name]={'resourceBytes':len(resource),'resourceSha256':sha(resource),'compiledSyntheticInstallerSha256':sha(binary)}
    license_file=compiler.parent/'license.txt'
    license_text=license_file.read_text(encoding='utf8').replace('\r\n','\n')
    (HERE/'INNO-LICENSE.txt').write_text(license_text,encoding='utf8',newline='\n')
    manifest={'format':'uten-inno-version-resource-fixture-v1','compilerVersion':'7.1.0','compilerSha256':COMPILER_SHA256,'compilerLicenseSha256':sha(license_file.read_bytes()),'includedLicenseCanonicalSha256':sha((HERE/'INNO-LICENSE.txt').read_bytes()),'scriptSha256':sha((HERE/'fixture.iss').read_bytes()),'payloadSha256':sha((HERE/'payload.txt').read_bytes()),'applicationVersion':'2.5.31','buildNumber':2531,'architecture':'x64','fixtures':records,'installerExecuted':False,'erpOrCustomerPayloadIncluded':False}
    (HERE/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf8',newline='\n')
    print(json.dumps(manifest))
if __name__=='__main__':main()
