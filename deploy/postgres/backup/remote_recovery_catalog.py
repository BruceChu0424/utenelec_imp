"""Exact company remote gateway recovery scope, never a recursive /etc export."""
from __future__ import annotations

from pathlib import Path, PurePosixPath
import os
import re

BASE='etc/uten-remote-ca/'
LE=BASE+'letsencrypt/'
FIXED=(
    BASE+'dns01.json',
    *(BASE+name+suffix for name in ('transport-server-ca','cloud-client-ca') for suffix in ('.key','.crt','.srl')),
    BASE+'dr-cert-publish.key',BASE+'dr-cert-publish.key.pub',BASE+'cloud-known-hosts',
    'etc/uten-remote/wireguard/private.key',
    *('etc/uten-remote/tls/'+name for name in ('transport-server.key','transport-server.crt',
        'cloud-client-ca.crt','employee.key','employee-fullchain.crt')),
    LE+'renewal/uten-erp-employee.conf',
)
ACCOUNT=re.compile(re.escape(LE)+r'accounts/acme-v02\.api\.letsencrypt\.org/directory/[a-f0-9]{32}/(?:private_key|regr|meta)\.json\Z')
ARCHIVE=re.compile(re.escape(LE)+r'archive/uten-erp-employee/(?:privkey|cert|chain|fullchain)[1-9][0-9]{0,4}\.pem\Z')
LIVE=LE+'live/uten-erp-employee/'
LINK_NAMES=('privkey.pem','cert.pem','chain.pem','fullchain.pem')
MAX_FILES=512


def allowed(name):
    return isinstance(name,str) and (name in FIXED or ACCOUNT.fullmatch(name) is not None or ARCHIVE.fullmatch(name) is not None)


def validate_metadata(value, archive_names):
    if (not isinstance(value,dict) or set(value)!={'format','files','controlledSymlinks'}
            or value['format']!='uten-company-remote-recovery-v1'
            or not isinstance(value['files'],list) or not len(FIXED)<=len(value['files'])<=MAX_FILES
            or len(value['files'])!=len(set(value['files'])) or not all(allowed(name) for name in value['files'])
            or not set(FIXED).issubset(value['files'])
            or not {'recovery/'+name for name in value['files']}.issubset(archive_names)):
        raise ValueError('Incomplete remote recovery catalog')
    links=value['controlledSymlinks']
    if not isinstance(links,dict) or set(links)!={LIVE+name for name in LINK_NAMES}:
        raise ValueError('Incomplete controlled certificate link map')
    for name,target in links.items():
        if target not in value['files'] or not ARCHIVE.fullmatch(target) or PurePosixPath(name).stem!=re.sub(r'[0-9]+$','',PurePosixPath(target).stem):
            raise ValueError('Certificate link escapes its exact archive')
    if len({re.search(r'([1-9][0-9]*)\.pem$',target).group(1) for target in links.values()})!=1:
        raise ValueError('Certificate links crossed a renewal boundary; retry a coherent version')
    accounts={name.rsplit('/',1)[0] for name in value['files'] if ACCOUNT.fullmatch(name)}
    if not accounts:raise ValueError('ACME account recovery is missing')
    for account in accounts:
        if not {account+'/'+name+'.json' for name in ('private_key','regr','meta')}.issubset(value['files']):
            raise ValueError('ACME account recovery is incomplete')
    versions={re.search(r'([1-9][0-9]*)\.pem$',name).group(1) for name in value['files'] if ARCHIVE.fullmatch(name)}
    if not versions:raise ValueError('Certificate archive is missing')
    for version in versions:
        if not {LE+'archive/uten-erp-employee/'+name+version+'.pem' for name in ('privkey','cert','chain','fullchain')}.issubset(value['files']):
            raise ValueError('Certificate archive version is incomplete')


def collect(root,safe_path):
    selected=set(FIXED)
    directory=root/(LE+'accounts/acme-v02.api.letsencrypt.org/directory')
    safe_path(directory,directory=True)
    for account in directory.iterdir():
        if not re.fullmatch(r'[a-f0-9]{32}',account.name):continue
        safe_path(account,directory=True)
        selected.update((account/name).relative_to(root).as_posix() for name in ('private_key.json','regr.json','meta.json'))
    archive=root/(LE+'archive/uten-erp-employee')
    safe_path(archive,directory=True)
    for path in archive.iterdir():
        name=path.relative_to(root).as_posix()
        if ARCHIVE.fullmatch(name):selected.add(name)
    if len(selected)>MAX_FILES:raise ValueError('Remote recovery catalog exceeds its bounded scope')
    links={}
    for name in LINK_NAMES:
        path=root/(LIVE+name);safe_path(path.parent,directory=True)
        if not path.is_symlink():raise ValueError('Expected controlled certificate symbolic link')
        target=os.readlink(path)
        if not re.fullmatch(r'\.\./\.\./archive/uten-erp-employee/(?:privkey|cert|chain|fullchain)[1-9][0-9]{0,4}\.pem',target):
            raise ValueError('Certificate symbolic link leaves the reviewed archive')
        destination=(path.parent/target).resolve(strict=True)
        relative=destination.relative_to(root.resolve()).as_posix()
        links[LIVE+name]=relative
    metadata={'format':'uten-company-remote-recovery-v1','files':sorted(selected),'controlledSymlinks':links}
    validate_metadata(metadata,{'recovery/'+name for name in selected})
    result=[]
    for name in sorted(selected):
        path=root/name;details=safe_path(path)
        secret=name.endswith(('.key','private_key.json')) or '/privkey' in name or name.endswith('dns01.json')
        if details.st_nlink!=1 or details.st_size>4*1024**2 or secret and details.st_mode&0o037:
            raise ValueError('Unsafe remote recovery material')
        result.append((path,'recovery/'+name))
    return result,metadata
