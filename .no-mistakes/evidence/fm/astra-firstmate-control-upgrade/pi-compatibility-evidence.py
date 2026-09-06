import os,pathlib,subprocess,tempfile
root=pathlib.Path.cwd()
out=pathlib.Path('/Users/nick/.no-mistakes/evidence/01M1TR9XAY6HWM7X9ZJP9Q5HWR')
logs=[]
for revision in ['c499f84','HEAD']:
    source=subprocess.check_output(['git','show',revision+':tests/fm-calm-pi-extension.test.sh'],text=True)
    source=source.rsplit('\ntest_home_resolution\n',1)[0]
    if revision=='HEAD':
        source=source.replace('  fm_test_cleanup\n', '  if [ -f "$TMP_ROOT/calm-export.html" ]; then cp "$TMP_ROOT/calm-export.html" "$FM_EVIDENCE_DIR/pi-calm-export.html"; fi\n  fm_test_cleanup\n')
    source+='\ntest_rendering_and_session_lifecycle\n'
    if revision=='HEAD': source+='test_interactive_terminal_e2e\n'
    with tempfile.NamedTemporaryFile(mode='w',prefix='.pi-evidence-',suffix='.sh',dir=root/'tests',delete=False) as f:
        f.write(source); p=pathlib.Path(f.name)
    try:
        env=dict(os.environ,FM_EVIDENCE_DIR=str(out))
        result=subprocess.run(['bash',str(p)],cwd=root,env=env,capture_output=True,text=True,timeout=150)
        logs += [f'{revision}: test_rendering_and_session_lifecycle'+(' + test_interactive_terminal_e2e' if revision=='HEAD' else ''),result.stdout,result.stderr,f'exit={result.returncode}']
        if revision=='c499f84':
            assert result.returncode!=0 and 'read collapsed rendering changed while calm mode was off' in result.stderr, result
        else: assert result.returncode==0, result
    finally: p.unlink()
package=subprocess.check_output(['npm','root','-g'],text=True).strip()
import json
version=json.loads((pathlib.Path(package)/'@earendil-works/pi-coding-agent/package.json').read_text())['version']
logs.insert(0,f'Installed importable Pi package: {version}; production Calm extension unchanged between probes.')
(out/'pi-compatibility-transcript.txt').write_text('\n'.join(logs))
print('Captured prior fixture failure, corrected fixture success, and native Pi HTML export.')
