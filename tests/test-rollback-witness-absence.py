"""Exact product helper, temporary filesystem and explicit systemctl fake only."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'deploy/bot/pdg.sh').read_text()
helper = re.search(r'^_pdg_witness_absence\(\)\{\n.*?^\}\n', source, re.M | re.S).group()
stub = r'''#!/usr/bin/python3
import json, os, pathlib, sys
p=pathlib.Path(os.environ['BOX']); a=sys.argv[1:]
s=json.loads((p/'state.json').read_text())
with (p/'calls').open('a') as f: f.write(json.dumps(a)+'\n')
if a[0]=='show':
    if s.get('query_fail'): print('LoadState=not-found'); sys.exit(1)
    for k in ('LoadState','FragmentPath','DropInPaths','ActiveState','UnitFileState','Names'): print(k+'='+s[k])
elif s.get('fail')==a[0]: sys.exit(1)
elif a[0]=='stop': s['ActiveState']='inactive'
elif a[0]=='disable':
    if not s.get('no_disable'):
        s['UnitFileState']='disabled'
        for name in ('etc','run'):
            link=p/('fs/'+name+'/systemd/system/multi-user.target.wants/pdg-dotwitness.service')
            if link.is_symlink(): link.unlink()
elif a[0]=='daemon-reload' and not (p/'fs/etc/systemd/system/pdg-dotwitness.service').exists():
    s.update(LoadState='not-found',FragmentPath='',DropInPaths='',ActiveState='inactive',UnitFileState='')
else: sys.exit(2)
(p/'state.json').write_text(json.dumps(s))
'''

def case(name, fault=None, negative=False):
    with tempfile.TemporaryDirectory() as temp:
        box=Path(temp); fs=box/'fs'; repo=box/'repo'; snap=box/'snap'; snap.mkdir()
        paths=[fs/'etc/systemd/system/pdg-dotwitness.service', fs/'etc/privdns-gateway/dotwitness.env', fs/'opt/pdg-bot/dotwitness.py']
        for p in paths: p.parent.mkdir(parents=True, exist_ok=True)
        (fs/'opt/pdg-bot/dot-domain').write_text('test.example\n')
        (repo/'deploy/bot').mkdir(parents=True)
        expected=[b'unit template\n',b'PDG_DOTWITNESS_SUFFIX=probe.test.example\n',b'module body\n']
        for p, data in zip((repo/'deploy/bot/pdg-dotwitness.service',repo/'deploy/bot/dotwitness.py'),(expected[0],expected[2])): p.write_bytes(data)
        with tarfile.open(snap/'snap.tar.gz','w:gz'): pass
        state=dict(LoadState='not-found',FragmentPath='',DropInPaths='',ActiveState='inactive',UnitFileState='',Names='pdg-dotwitness.service')
        link=fs/'etc/systemd/system/multi-user.target.wants/pdg-dotwitness.service'
        if fault=='pre-link':
            link.parent.mkdir(); link.symlink_to(paths[0])
        if fault=='existing':
            paths[0].write_bytes(b'custom existing\n')
            state.update(LoadState='loaded',FragmentPath=str(paths[0]),UnitFileState='disabled')
        if fault=='pre-query': state['query_fail']=True
        (box/'state.json').write_text(json.dumps(state))
        bindir=box/'bin'; bindir.mkdir(); executable=bindir/'systemctl'; executable.write_text(stub); executable.chmod(0o755)
        text=helper.replace('"/etc/', '"'+str(fs)+'/etc/').replace('"/opt/', '"'+str(fs)+'/opt/').replace('"/run/', '"'+str(fs)+'/run/')
        if negative:
            old='if p.read_bytes() != expected:'
            assert text.count(old)==1
            text=text.replace(old,'if False:  # negative control: identity gate removed')
        script=box/'helper.sh'; script.write_text(text+'\nREPO_DIR="$3"; _pdg_witness_absence "$1" "$2"\n')
        env=dict(os.environ,BOX=str(box),PATH=str(bindir)+':'+os.environ['PATH'])
        def run(mode):
            r=subprocess.run(['bash',str(script),mode,str(snap),str(repo)],capture_output=True,text=True,env=env)
            print(name,mode,r.returncode,r.stdout.strip(),r.stderr.strip())
            return r
        saved=run('save')
        if fault in ('pre-query','pre-link'):
            assert saved.returncode!=0 and not (snap/'witness-absence.json').exists(); return
        assert saved.returncode==0
        if fault=='existing':
            assert json.loads((snap/'witness-absence.json').read_text())['absent']==[]
            assert run('restore').returncode==0 and paths[0].read_bytes()==b'custom existing\n'; return
        if fault!='no-mutation':
            for p,data in zip(paths,expected): p.write_bytes(data)
            state.update(LoadState='loaded',FragmentPath=str(paths[0]),ActiveState='active',UnitFileState='enabled')
        if fault in ('custom-unit','custom-env','custom-module'):
            paths[('custom-unit','custom-env','custom-module').index(fault)].write_bytes(b'custom\n')
        if fault=='symlink':
            paths[0].unlink(); paths[0].symlink_to(repo/'deploy/bot/pdg-dotwitness.service')
        if fault=='directory': paths[1].unlink(); paths[1].mkdir()
        if fault=='dropin': state['DropInPaths']='/custom/override.conf'
        if fault=='foreign-unit': state['FragmentPath']='/custom/unit'
        if fault=='alias': state['Names']='pdg-dotwitness.service custom.service'
        if fault=='no-disable': state['no_disable']=True
        if fault in ('link','foreign-link'):
            link.parent.mkdir(); link.symlink_to(paths[0] if fault=='link' else '/custom/unit')
        if fault=='post-query': state['query_fail']=True
        if fault in ('stop','disable','daemon-reload'): state['fail']=fault
        if fault=='binding': (snap/'snap.tar.gz').write_bytes(b'changed')
        if fault=='record-truncated': (snap/'witness-absence.json').write_text('{')
        if fault=='record-duplicate':
            f=snap/'witness-absence.json'; f.write_text(f.read_text().replace('{','{"version":1,',1))
        if fault=='record-extra-path':
            f=snap/'witness-absence.json'; d=json.loads(f.read_text()); d['absent'].append('/etc/other'); f.write_text(json.dumps(d))
        if fault=='record-missing': (snap/'witness-absence.json').unlink()
        (box/'state.json').write_text(json.dumps(state)); (box/'calls').write_text('')
        r=run('restore')
        if fault in (None,'no-mutation','link') or negative:
            assert r.returncode==0 and all(not p.exists() for p in paths)
            assert not link.is_symlink()
        elif fault=='record-missing':
            assert r.returncode==0 and all(p.exists() for p in paths) and (box/'calls').read_text()==''
        else:
            assert r.returncode!=0
            if fault!='daemon-reload': assert all(p.exists() for p in paths)
            if fault not in ('stop','disable','daemon-reload','no-disable'):
                assert not any(json.loads(x)[0] in ('stop','disable','daemon-reload') for x in (box/'calls').read_text().splitlines())
        print('PASS',name)

cases=[None,'existing','no-mutation','pre-query','custom-unit','custom-env','custom-module','symlink','directory','dropin','foreign-unit','post-query','stop','disable','daemon-reload','binding','record-truncated','record-duplicate','record-extra-path','record-missing','pre-link','alias','no-disable','link','foreign-link']
for i,c in enumerate(cases): case('W%02d'%i,c)
case('NC-identity','custom-unit',negative=True)
print('WITNESS_ABSENCE_PASS',len(cases),'cases + 1 negative control')
