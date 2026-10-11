import hashlib
import json
import re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]

def read(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    results={'scope':'offline only; physical tests pending user board connection',
             'completed_date':'2026-10-10','builds':{}}
    assert '34 passed' in read('artifacts/tests-hex-v2.log')
    assert 'PERSISTENT_CONSOLE_MOCK_PASS' in read('artifacts/console-mock-hex-v2.log')
    assert 'HEX_MISMATCH' in read('artifacts/hex-check-n4-mutated/run.log')
    assert 'ADAPTER_PASS checks=56' in read('artifacts/hex-check-n8-clean/run.log')
    for n in (4,8):
        folder=Path(f'artifacts/board-n{n}-75-hex-v2')
        launch=read('artifacts/build-hex-v2-launch.log' if n==8 else 'artifacts/build-hex-v2-n4-launch.log')
        assert 'TIMING_PASS' in launch, 'Build not yet qualified'
        manifest=json.loads(read(folder/'source-sha256.json'))
        for path,expected in manifest.items():
            relative=path.replace('\\','/').split('tensor-accelerator/',1)[1]
            assert sha(ROOT/relative).upper()==expected.upper(),relative
        timing=read(folder/'output_files/de10_lite.sta.summary')
        pairs=re.findall(r'Type\s*:\s*([^\n]+)\s*\nSlack\s*:\s*(-?[\d.]+)',timing)
        assert pairs and min(float(slack) for _,slack in pairs)>=0
        fit=read(folder/'output_files/de10_lite.fit.summary')
        assert 'Fitter Status : Successful' in fit
        sim=Path('artifacts/sim-n8' if n==8 else 'artifacts/sim')
        core=read(sim/'core-42.log')
        assert 'CORE_PASS checks=21264' in core
        assert 'QUANT_PASS' in read(sim/'quant-clean.log')
        trained_cycles=list(map(int,re.findall(r'COMPUTE_CYCLES (\d+)',core)))[-8:]
        assert len(trained_cycles)==8 and len(set(trained_cycles))==1
        results['builds'][str(n)]={
            'sof':str(folder/'output_files/de10_lite.sof'),
            'sof_sha256':sha(ROOT/folder/'output_files/de10_lite.sof'),
            'min_setup_slack_ns':min(float(s) for t,s in pairs if ' Setup ' in t),
            'min_hold_slack_ns':min(float(s) for t,s in pairs if ' Hold ' in t),
            'fit_summary':fit,
            'model_sim_cycles':trained_cycles[0],
            'rtl_seed':42,'rtl_checks':21264,
            'timing_limit':'LED pins intentionally false-pathed; reserved JTAG ports lack external delays'}
    results['accuracy']=json.loads(read('artifacts/accuracy-comparison.json'))
    results['model_report']=json.loads(read('artifacts/model/report.json'))
    results['selected_model_sha256']=sha(ROOT/'artifacts/model/model.json')
    results['source_sha256']={str(p.relative_to(ROOT)):sha(p) for folder in ('host','rtl','fpga','scripts','tests','tb','demo')
        for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts}
    (ROOT/'artifacts/hex-v2-results.json').write_text(json.dumps(results,indent=2))
    print('HEX_V2_OFFLINE_QUALIFIED; physical board checks pending')

if __name__=='__main__':main()
