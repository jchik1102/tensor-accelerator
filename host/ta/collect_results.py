import hashlib
import json
import re
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo

ROOT=Path(__file__).resolve().parents[2]

def read(path):return (ROOT/path).read_text(encoding='utf-8-sig')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    result={'recorded_at':datetime.now(ZoneInfo('America/Vancouver')).isoformat(),
            'physical_board_verified':False,'physical_transfers_executed':False,'physical_inference_executed':False}
    result['model']=json.loads(read('artifacts/model/report.json'))
    assert result['model']['targets_pass']
    result['rtl']={}
    for seed in [1,42,20261008]:
        log=read(f'artifacts/sim/core-{seed}.log')
        match=re.search(r'CORE_PASS checks=(\d+) transactions=(\d+) assertion_hits=(\d+) coverage=([\d.]+) gaps=([\d,]+) digest=(\w+)',log)
        assert match and 'Fatal:' not in log
        result['rtl'][seed]={'checks':int(match[1]),'transactions':int(match[2]),'response_assertion_hits':int(match[3]),
            'selected_shape_coverage_percent':float(match[4]),'gap_counts':[int(x) for x in match[5].split(',')],'gap_digest':match[6],
            'compute_cycles':[int(x) for x in re.findall(r'COMPUTE_CYCLES (\d+)',log)]}
        coverage_log=read(f'artifacts/sim/coverage-{seed}.log')
        assert 'EXIT_CODE=0' in coverage_log
    result['replay_identical']=re.search(r'^CORE_PASS.*',read('artifacts/sim/core-42.log'),re.M)[0]==re.search(r'^CORE_PASS.*',read('artifacts/sim/core-replay-42.log'),re.M)[0]
    assert result['replay_identical']
    result['requantization_cases']=int(re.search(r'QUANT_PASS cases=(\d+)',read('artifacts/sim/quant-clean.log'))[1])
    result['adapter_checks']=int(re.search(r'ADAPTER_PASS checks=(\d+)',read('artifacts/sim/adapter-clean.log'))[1])
    result['mutations']={}
    for name,marker,pass_marker in [('pe','Fatal: MISMATCH','CORE_PASS'),('round','Fatal: QUANT_MISMATCH','QUANT_PASS')]:
        log=read(f'artifacts/sim/mutation-{name}.log')
        assert marker in log and pass_marker not in log
        result['mutations'][name]=next(x for x in log.splitlines() if marker in x)
    test_log=read('artifacts/python-tests.log')
    assert 'failed' not in test_log and 'ERROR' not in test_log
    result['python_tests']=re.search(r'\d+ passed[^\n]*',test_log)[0]
    assert 'OFFLINE_TCL_PASS' in read('artifacts/board/offline-tcl-test.log')
    result['tcl_mock_checks_pass']=True
    result['builds']={}
    for label,folder,name in [('core','synthesis','ta_core'),('board','board','de10_lite')]:
        fit=read(f'artifacts/{folder}/output_files/{name}.fit.summary')
        assert 'Fitter Status : Successful' in fit and '10M50DAF484C7G' in fit
        timing=read(f'artifacts/{folder}/output_files/{name}.sta.summary')
        paths=[{'type':kind.strip(),'slack_ns':float(slack),'tns_ns':float(tns)} for kind,slack,tns in
               re.findall(r'Type\s+: ([^\n]+)\s+Slack\s+: ([-\d.]+)\s+TNS\s+: ([-\d.]+)',timing)]
        assert paths and all(x['slack_ns']>=0 and x['tns_ns']==0 for x in paths)
        result['builds'][label]={'fit_summary':fit,'timing':paths,'scope':'constrained paths only; physical operation untested'}
    unconstrained=read('artifacts/board/unconstrained-paths.rpt')
    result['reserved_jtag_external_io_unconstrained']={}
    for key,label in [('input_ports','Unconstrained Input Ports'),('input_paths','Unconstrained Input Port Paths'),
                      ('output_ports','Unconstrained Output Ports'),('output_paths','Unconstrained Output Port Paths')]:
        count=re.search(r';\s*'+label+r'\s*;\s*(\d+)\s*;',unconstrained)
        assert count
        result['reserved_jtag_external_io_unconstrained'][key]=int(count[1])
    demo_logs=[]
    for path in (ROOT/'artifacts/demo-sim').glob('*/xsim.log'):
        text=path.read_text(encoding='utf-8-sig')
        if 'CORE_PASS' in text and len(re.findall('READBACK ',text))==106:
            demo_logs.append(str(path.relative_to(ROOT)))
    assert demo_logs
    result['browser_rtl_logs']=demo_logs
    files=[ROOT/'requirements-lock.txt']
    for folder in ['rtl','fpga','host','tb','tests','scripts']:
        files.extend(p for p in (ROOT/folder).rglob('*') if p.suffix in {'.sv','.sdc','.tcl','.py','.ps1'} and '__pycache__' not in p.parts)
    files.extend([ROOT/'demo/index.html',ROOT/'README.md',ROOT/'artifacts/model/model.json',ROOT/'artifacts/model/model.onnx',ROOT/'artifacts/board/output_files/de10_lite.sof'])
    result['sha256']={str(p.relative_to(ROOT)):sha(p) for p in sorted(files)}
    (ROOT/'artifacts/results.json').write_text(json.dumps(result,indent=2))
    print('RESULTS_COLLECTED artifacts/results.json; all required offline markers present, hardware still pending')

if __name__=='__main__':main()
