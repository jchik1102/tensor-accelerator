import hashlib
import json
import re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]

def main():
    result={'scope':'simulation plus exact-device compilation; upgraded board not programmed',
            'baseline_cycles':228537,'baseline_clock_mhz':50,'builds':{},'simulations':{},'mutations':{}}
    manifest=json.loads((ROOT/'artifacts/vectors/manifest.json').read_text())
    for size in (4,8):
        folder=ROOT/('artifacts/sim' if size==4 else 'artifacts/sim-n8')
        seeds={}
        for seed in (1,42,20261008):
            text=(folder/f'core-{seed}.log').read_text(encoding='utf-8-sig')
            assert 'Fatal:' not in text
            marker=re.search(r'CORE_PASS checks=(\d+) transactions=(\d+) assertion_hits=(\d+) coverage=([\d.]+).*digest=([a-fA-F0-9]+)',text)
            assert marker
            cycles=list(map(int,re.findall(r'COMPUTE_CYCLES (\d+)',text)))
            assert len(set(cycles[-8:]))==1
            seeds[str(seed)]={'checks':int(marker[1]),'transactions':int(marker[2]),'assertion_hits':int(marker[3]),
                              'selected_functional_coverage_percent':float(marker[4]),'gap_digest':marker[5],
                              'trained_inference_cycles':cycles[-1]}
        replay=(folder/'core-replay-42.log').read_text(encoding='utf-8-sig')
        original=(folder/'core-42.log').read_text(encoding='utf-8-sig')
        assert re.search(r'CORE_PASS[^\r\n]+',replay)[0]==re.search(r'CORE_PASS[^\r\n]+',original)[0]
        result['simulations'][str(size)]={'seeds':seeds,'seed_42_replay':True,
            'matrix_benchmarks':[{'M':shape[0],'K':shape[1],'N':shape[2],'cycles':c}
                                  for shape,c in zip(manifest['matrix_cases'],cycles)]}
        build=ROOT/f'artifacts/board-n{size}-75'
        fit=(build/'output_files/de10_lite.fit.summary').read_text()
        sta=(build/'output_files/de10_lite.sta.summary').read_text()
        checks=[{'check':kind,'slack_ns':float(slack),'tns_ns':float(tns)} for kind,slack,tns in
                re.findall(r'Type\s*:\s*(.*?)\nSlack\s*:\s*(-?[\d.]+)\nTNS\s*:\s*(-?[\d.]+)',sta)]
        assert checks and all(x['slack_ns']>=0 and x['tns_ns']==0 for x in checks)
        values={key:int(re.search(pattern,fit)[1].replace(',','')) for key,pattern in {
            'logic_elements':r'Total logic elements : ([\d,]+)',
            'registers':r'Total registers : (\d+)',
            'logical_memory_bits':r'Total memory bits : ([\d,]+)',
            'multiplier_9bit_elements':r'Embedded Multiplier 9-bit elements : (\d+)'}.items()}
        details=(build/'output_files/de10_lite.fit.rpt').read_text(encoding='cp1252')
        values['m9k_blocks']=int(re.search(r'; M9Ks\s*; (\d+) /',details)[1])
        values['clock_mhz']=75
        values['compute_ms_from_simulated_cycles']=cycles[-1]/75000
        values['baseline_compute_speedup']=228537/50000/values['compute_ms_from_simulated_cycles']
        values['timing_checks']=checks
        values['min_setup_slack_ns']=min(x['slack_ns'] for x in checks if ' Setup ' in x['check'])
        values['min_hold_slack_ns']=min(x['slack_ns'] for x in checks if ' Hold ' in x['check'])
        ucp=(build/'unconstrained-paths.rpt').read_text()
        values['unconstrained']={key:int(re.search(r'; '+key+r'\s*; (\d+)',ucp)[1]) for key in
            ['Unconstrained Clocks','Unconstrained Input Ports','Unconstrained Input Port Paths','Unconstrained Output Ports','Unconstrained Output Port Paths']}
        values['sof_sha256']=hashlib.sha256((build/'output_files/de10_lite.sof').read_bytes()).hexdigest()
        frozen=json.loads((build/'source-sha256.json').read_text(encoding='utf-8-sig'))
        for path,digest in frozen.items():
            local=Path('/mnt/c/'+path[3:].replace('\\','/')) if path.startswith('C:') else Path(path)
            assert hashlib.sha256(local.read_bytes()).hexdigest().lower()==digest.lower(),path
        values['frozen_source_manifest_matches']=True
        result['builds'][str(size)]=values
    for size,mutation in ((4,'pe'),(4,'round'),(8,'bank')):
        folder=ROOT/('artifacts/sim' if size==4 else 'artifacts/sim-n8')
        text=(folder/f'mutation-{mutation}.log').read_text(encoding='utf-8-sig')
        assert 'MISMATCH' in text
        result['mutations'][mutation]={'size':size,'detected':True}
    dest=ROOT/'artifacts/upgrade-results.json'
    dest.write_text(json.dumps(result,indent=2)+'\n')
    for size,data in result['builds'].items():
        print(f"{size}x{size}: {data['logic_elements']} LEs, {data['m9k_blocks']} M9Ks, setup {data['min_setup_slack_ns']} ns, hold {data['min_hold_slack_ns']} ns, compute {data['compute_ms_from_simulated_cycles']:.6f} ms (cycles/75 MHz)")
    print(dest)

if __name__=='__main__':main()
