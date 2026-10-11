import json
import uuid
from host.ta.board_session import BoardSession, ROOT, CONSOLE, winpath, tcl_literal
from host.ta.runtime import predict
from tests.test_fpga_demo import MODEL

directory=ROOT/'artifacts/test-persistent'/('system-console-'+uuid.uuid4().hex)
directory.mkdir(parents=True)
wrapper=directory/'mock-launch.tcl'
wrapper.write_text('set argv [list '+tcl_literal(winpath(directory/'launch.tcl'))+']\nsource '+
                   tcl_literal(winpath(ROOT/'tests/mock_board_session.tcl'))+'\n')
board=BoardSession(MODEL,'/mock/master',directory=directory,
                   command=[CONSOLE,'--cli','--script='+winpath(wrapper)])
try:
    first=predict(MODEL,[4,2],'fpga',board=board)
    second=predict(MODEL,[1,5],'fpga',board=board)
    assert first['scores']!=second['scores']
    assert first['timings']['cold_start'] and not second['timings']['cold_start']
finally:
    board.close()
traffic=(directory/'traffic.log').read_text().splitlines()
assert traffic.count('CLAIM')==1 and traffic.count('CLOSE')==1
assert traffic.count('W 8 4')==1 and traffic.count('W 8 1')==2
(directory/'summary.json').write_text(json.dumps({'scope':'installed System Console with mocked bus; no hardware access',
    'one_connection':True,'one_model_load':True,'two_distinct_inputs_verified':True,'clean_close':True},indent=2))
print('PERSISTENT_CONSOLE_MOCK_PASS '+str(directory),flush=True)
