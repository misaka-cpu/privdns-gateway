#!/usr/bin/env python3
"""A-off decision contract; real route tests cover the full update chain separately."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile


def blocks(text):
    begin = '  local _update_keep_mitm_stopped=0\n'
    end = '  local pre_sha;'
    assert text.count(begin) == 1
    a = text.index(begin)
    b = text.index(end, a)
    decision = text[a:b]
    begin = '  if (( _update_keep_mitm_stopped )); then\n'
    a = text.index(begin)
    b = text.index('\n  sleep 2\n', a)
    action = text[a:b]
    assert action.endswith('  fi')
    return decision, action


def run(decision, action, state, config, enabled=True):
    with tempfile.TemporaryDirectory(prefix='aoff-contract-') as t:
        p = Path(t)
        (p/'svcstate.tsv').write_text(
            '#pdg-svcstate\t1\nunit\tpdg-mitm\t'+state+'\tdead\t-\n')
        if config is not None:
            (p/'mitm.json').write_text(config)
        # Only relocate the config read into this test's private input.
        decision = decision.replace('/etc/privdns-gateway/mitm.json', '"$snap_dir/mitm.json"')
        script = '''set -uo pipefail
c_g(){ printf 'MESSAGE %s\\n' "$*"; }
systemctl(){
  printf 'CALL %s\\n' "$*"
  [[ "$1" != is-enabled ]] || return "$enabled_rc"
}
test_body(){
'''+decision+action+'\nreturn 0\n}\nsnap_dir=$1; enabled_rc=$2; test_body\n'
        r = subprocess.run(['bash', '-c', script, 'test', t, '0' if enabled else '1'],
                           text=True, capture_output=True, timeout=15)
        assert r.returncode == 0 and r.stderr == '', (r.returncode, r.stdout, r.stderr)
        # is-enabled output is redirected by product. Mutations must not hide restart.
        # Product redirects stderr only for restart/reset; their stdout is observable here.
        calls = [x[5:] for x in r.stdout.splitlines() if x.startswith('CALL ')]
        return calls


def migration_handoff(text):
    line = next(x.strip() for x in text.splitlines() if x.strip().startswith('if ! _PDG_UPDATE_KEEP_MITM_STOPPED='))
    command = line.removeprefix('if ! ').removesuffix('; then')
    for flag in ('0', '1'):
        script = '''set -uo pipefail
bash(){ printf 'child=%s args=%s\\n' "$_PDG_UPDATE_KEEP_MITM_STOPPED" "$*"; }
snap_dir=/test-snapshot
_update_keep_mitm_stopped=$1
'''+command+'\nprintf "after=%s\\n" "${_PDG_UPDATE_KEEP_MITM_STOPPED-unset}"\n'
        result = subprocess.run(['bash','-c',script,'test',flag], text=True, capture_output=True, timeout=10)
        assert result.returncode == 0 and not result.stderr, result
        assert result.stdout == f'child={flag} args=/usr/local/bin/pdg __migrate\nafter=unset\n', result.stdout
    print('PASS migration handoff: 0 and 1, no ambient leak')


def extra_contract(text):
    migration_handoff(text)
    activate = re.search(r'^_activate_mihomo_core\(\)\{.*?^\}', text, re.M|re.S)[0]
    start = '  if [[ "${_PDG_UPDATE_KEEP_MITM_STOPPED:-0}" == 1 ]]; then\n'
    block = activate[activate.index(start):activate.index('  rm -f /etc/nftables.conf.scbak', activate.index(start))]
    restore = re.search(r'^_pdg_restore_svcstate\(\).*?^\}', text, re.M|re.S)[0]
    def invoke(body, flag, expected_rc, rollback=False):
        with tempfile.TemporaryDirectory() as tmp:
            calls = Path(tmp)/'calls'
            script = '''set -uo pipefail
c_g(){ :; }; c_y(){ :; }
systemctl(){ printf '%s\\n' "$*" >> "$CALLS"; return 0; }
_pdg_svcstate_plan(){ _PDG_SVC_MODE=blind; return 1; }
_pdg_svcstate_units(){ echo pdg-mitm; }
test_body(){
  local -a unrestored=()
  local plat=ios
'''+(flag+'\n' if flag else '')+body+('\n  _pdg_restore_svcstate /bad; r=$?; [[ $r == 1 && ${#unrestored[@]} == 1 ]] || exit 88; return "$r"\n' if rollback else '\nreturn 0\n')+'}\nCALLS=$1; test_body\n'
            result = subprocess.run(['bash','-c',script,'test',str(calls)],text=True,capture_output=True,timeout=10)
            assert result.returncode == expected_rc and not result.stderr, result
            return [x for x in calls.read_text().splitlines() if 'pdg-mitm' in x] if calls.exists() else []
    old_activate = next(x for x in block.splitlines() if 'systemctl enable --now pdg-mitm' in x)
    for label, flag in [('off','local _PDG_UPDATE_KEEP_MITM_STOPPED=1'),('on','local _PDG_UPDATE_KEEP_MITM_STOPPED=0'),('manual','')]:
        expected = [] if label=='off' else ['reset-failed pdg-mitm','enable --now pdg-mitm']
        assert invoke(block,flag,0)==expected
        print('PASS core activation',label)
    assert invoke(old_activate,'local _PDG_UPDATE_KEEP_MITM_STOPPED=1',0)==['reset-failed pdg-mitm','enable --now pdg-mitm']
    service = re.search(r'^migrate_pdg_mitm_service\(\)\{.*?^\}', text, re.M|re.S)[0]
    svc_block=service[service.index(start):service.index('  c_g "  ✅ 已补 iOS')]
    modules=re.search(r'^migrate_deploy_botfiles\(\)\{.*?^\}', text, re.M|re.S)[0]
    mod_block=modules[modules.index('  local _svcs='):modules.index('  c_g "  运行模块已更新')]
    mod_block='_pdg_platform(){ echo ios; }\n'+mod_block
    for label, flag in [('off','local _PDG_UPDATE_KEEP_MITM_STOPPED=1'),('on','local _PDG_UPDATE_KEEP_MITM_STOPPED=0'),('manual','')]:
        expected=[] if label=='off' else ['reset-failed pdg-mitm','enable --now pdg-mitm']
        assert invoke(svc_block,flag,0)==expected
        expected=[] if label=='off' else ['try-restart pdg-bot pdg-probe81 pdg-mitm']
        assert invoke(mod_block,flag,0)==expected
        print('PASS service completion and module refresh',label)
    old_svc=next(x for x in svc_block.splitlines() if 'systemctl enable --now pdg-mitm' in x)
    assert invoke(old_svc,'local _PDG_UPDATE_KEEP_MITM_STOPPED=1',0)==['reset-failed pdg-mitm','enable --now pdg-mitm']
    old_mod=mod_block.replace(' && "${_PDG_UPDATE_KEEP_MITM_STOPPED:-0}" != 1','')
    assert old_mod!=mod_block
    assert invoke(old_mod,'local _PDG_UPDATE_KEEP_MITM_STOPPED=1',0)==['try-restart pdg-bot pdg-probe81 pdg-mitm']
    for label, flag in [('off','local _update_keep_mitm_stopped=1'),('on','local _update_keep_mitm_stopped=0'),('manual','')]:
        expected = [] if label=='off' else ['is-enabled pdg-mitm','reset-failed pdg-mitm','restart pdg-mitm']
        assert invoke(restore,flag,1,True)==expected
        print('PASS blind rollback',label,'still incomplete')
    start='    if [[ "${_update_keep_mitm_stopped:-0}" == 1 ]]; then\n'
    a=restore.index(start); b=restore.index('    fi\n',a)+len('    fi\n')
    original=next(x for x in restore[a:b].splitlines() if 'systemctl is-enabled pdg-mitm' in x)+'\n'
    reverted=restore[:a]+original+restore[b:]
    assert invoke(reverted,'local _update_keep_mitm_stopped=1',1,True)==['is-enabled pdg-mitm','reset-failed pdg-mitm','restart pdg-mitm']
    print('EXTENDED_AOFF_PASS 14 cases, 4 reversions; invalid snapshot still returns failure')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    text = (root/'deploy/bot/pdg.sh').read_text()
    decision, action = blocks(text)
    inactive = 'enabled\t0\tinactive\t3'
    active = 'enabled\t0\tactive\t0'
    cases = [
        ('off-inactive', inactive, '{"wloc":{"enabled":false}}', True, 0),
        ('off-active', active, '{"wloc":{"enabled":false}}', True, 1),
        ('on-inactive', inactive, '{"wloc":{"enabled":true}}', True, 1),
        ('on-active', active, '{"wloc":{"enabled":true}}', True, 1),
        ('config-missing', inactive, None, True, 1),
        ('config-bad', inactive, '{bad', True, 1),
        ('config-array', inactive, '[]', True, 1),
        ('wloc-missing', inactive, '{}', True, 1),
        ('wloc-null', inactive, '{"wloc":null}', True, 1),
        ('enabled-missing', inactive, '{"wloc":{}}', True, 1),
        ('enabled-zero', inactive, '{"wloc":{"enabled":0}}', True, 1),
        ('enabled-string', inactive, '{"wloc":{"enabled":"false"}}', True, 1),
        ('state-failed', 'enabled\t0\tfailed\t3', '{"wloc":{"enabled":false}}', True, 1),
        ('state-unobtained', 'enabled\t0\tQUERY-FAILED\t1', '{"wloc":{"enabled":false}}', True, 1),
        ('inactive-wrong-rc', 'enabled\t0\tinactive\t1', '{"wloc":{"enabled":false}}', True, 1),
        ('enabled-wrong-rc', 'enabled\t1\tinactive\t3', '{"wloc":{"enabled":false}}', True, 1),
        ('runtime-enabled', 'enabled-runtime\t0\tinactive\t3', '{"wloc":{"enabled":false}}', True, 1),
        ('disabled', 'disabled\t1\tinactive\t3', '{"wloc":{"enabled":false}}', False, 0),
    ]
    old_line = next(x for x in text.splitlines() if x.lstrip().startswith('systemctl is-enabled pdg-mitm') and '# iOS/WLOC:' in x)
    if args.baseline:
        base = args.baseline.read_text()
        assert '_update_keep_mitm_stopped' not in base
        assert old_line.strip() in base
        calls = run('', old_line, inactive, cases[0][2])
        assert calls == ['reset-failed pdg-mitm', 'restart pdg-mitm'], calls
        print('REPRODUCED baseline off-inactive restarts')
    for name, state, cfg, en, count in cases:
        calls = run(decision, action, state, cfg, en)
        expected = ['reset-failed pdg-mitm', 'restart pdg-mitm'] if count else []
        assert calls == expected, (name, calls, expected)
        print('PASS', name, json.dumps(calls))
    # One-rule reversions on the same healthy and faulty materials.
    reverted = run(decision, old_line, inactive, cases[0][2])
    assert reverted == ['reset-failed pdg-mitm', 'restart pdg-mitm']
    weakened = decision.replace('is False', '== False')
    assert weakened != decision
    assert run(weakened, action, inactive, cases[10][2]) == []
    assert run(weakened, action, active, cases[1][2]) == ['reset-failed pdg-mitm', 'restart pdg-mitm']
    print('PASS negative-controls: action-revert and boolean-type-revert; healthy cross-control')
    print('AOFF_CONTRACT_PASS 18 cases, 2 reversions, 1 cross-control')
    extra_contract(text)


if __name__ == '__main__':
    main()
