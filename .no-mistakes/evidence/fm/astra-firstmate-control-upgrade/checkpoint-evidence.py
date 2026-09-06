import os, pathlib, re, subprocess, tempfile, threading, time
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/nick/.no-mistakes/evidence/01M1TR9XAY6HWM7X9ZJP9Q5HWR')
log = []
def call(home, args, expected=None):
    env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
    env.update(FM_HOME=str(home), FM_GATE_REFUSE_BYPASS='1', FM_POLL='1', FM_SIGNAL_GRACE='1', FM_CHECK_INTERVAL='999999', FM_GUARD_GRACE='300')
    result = subprocess.run(args, cwd=root, env=env, text=True, capture_output=True, timeout=90)
    log.extend(['$ ' + ' '.join(args), result.stdout.rstrip(), result.stderr.rstrip(), f'exit={result.returncode}', ''])
    if expected is not None:
        assert result.returncode == expected, (args, result.returncode, result.stderr)
    return result
with tempfile.TemporaryDirectory(prefix='.checkpoint-evidence-', dir=root) as tmp:
    def home(name):
        p = pathlib.Path(tmp)/name
        for d in ['state','data','config']: (p/d).mkdir(parents=True, exist_ok=True)
        return p
    p = home('signal')
    (p/'state/demo.status').write_text('done: PR https://example.invalid/pr/42 checks green\n')
    result = call(p, ['bin/fm-watch-checkpoint.sh','--seconds','30'], 0)
    assert 'signal:' in result.stdout
    first = call(p, ['bin/fm-wake-drain.sh'], 0)
    again = call(p, ['bin/fm-wake-drain.sh'], 0)
    assert '\tsignal\tdemo.status\t' in first.stdout and '\tsignal\tdemo.status\t' in again.stdout
    log.append('Observed: the same wake remains available on a second drain before acknowledgement.')
    ack = re.search(r'bin/fm-wake-drain.sh --ack-through (\d+) --recovery-generation (\S+)', again.stdout + again.stderr)
    assert ack, again
    call(p, ['bin/fm-wake-drain.sh','--ack-through',ack[1],'--recovery-generation',ack[2]], 0)
    final = call(p, ['bin/fm-wake-drain.sh'], 0)
    assert '\tsignal\tdemo.status\t' not in final.stdout
    assert 'WAKE_ACK_REQUIRED' not in final.stderr
    log.append('Observed: acknowledgement consumes the presented wake; subsequent drain does not replay it.\n')
    call(home('quiet'), ['bin/fm-watch-checkpoint.sh','--seconds','1'], 124)
    p = home('singleton'); lock = p/'state/.watch.lock'; lock.mkdir(); (lock/'pid').write_text(str(os.getpid())+'\n')
    call(p, ['bin/fm-watch-checkpoint.sh','--seconds','5'], 1)
    assert (lock/'pid').read_text().strip() == str(os.getpid())
    base = subprocess.check_output(['git','show','c499f84:bin/fm-watch-checkpoint.sh'], text=True)
    with tempfile.NamedTemporaryFile(mode='w',prefix='.checkpoint-base-',suffix='.sh',dir=root/'bin',delete=False) as f:
        f.write(base); baseline = pathlib.Path(f.name)
    baseline.chmod(0o700)
    try:
        for name, executable, expected in [('base',str(baseline),0),('target','bin/fm-watch-checkpoint.sh',1)]:
            p = home(name); errors=[]
            def replace_owner():
                deadline=time.monotonic()+60
                while time.monotonic()<deadline:
                    if (p/'state/.last-watcher-beat').exists():
                        (p/'state/.watch.lock/pid').write_text(str(os.getpid())+'\n'); return
                    time.sleep(.1)
                errors.append('watcher never published beacon')
            t=threading.Thread(target=replace_owner); t.start()
            result=call(p,[executable,'--seconds','70'],expected); t.join()
            assert not errors, errors
            assert (p/'state/.watch.lock/pid').read_text().strip()==str(os.getpid())
            if name=='target': assert 'ended without an actionable wake' in result.stderr
            log.append(f'Observed {name}: replacement ownership preserved.\n')
    finally:
        baseline.unlink()
    p=home('brief')
    call(p,['bin/fm-brief.sh','delivery-probe','sample-project','--mode','no-mistakes'],0)
    brief=(p/'data/delivery-probe/brief.md').read_text()
    assert 'working: implementation committed; starting validation' in brief
    assert 'done: PR {url} checks green' in brief
    (evidence/'generated-delivery-brief.md').write_text(brief)
    rendered=call(p,['bin/fm-supervision-instructions.sh','--harness','codex'],0)
    (evidence/'generated-codex-supervision.txt').write_text(rendered.stdout)
(evidence/'checkpoint-cli-transcript.txt').write_text('\n'.join(log))
print('Evidence saved: checkpoint-cli-transcript.txt, generated-delivery-brief.md, generated-codex-supervision.txt')
