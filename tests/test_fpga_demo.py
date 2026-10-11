import json
import tempfile
import unittest
from pathlib import Path
from host.ta.board_session import BoardSession, ROOT, winpath, model_layout
from host.ta.runtime import predict, reference, write_inference_plan

TCL = '/mnt/c/intelFPGA_lite/24.1std/quartus/bin64/tclsh86.exe'
MODEL = {'layers': [
    {'weights': [[2, -1], [-1, 3]], 'bias': [1, -2], 'multipliers': [1, 1], 'shifts': [0, 0], 'relu': True},
    {'weights': [[1, -2]], 'bias': [3], 'multipliers': [1], 'shifts': [0], 'relu': False},
]}

class BoardDemoTests(unittest.TestCase):
    def setUp(self):
        base=ROOT/'artifacts/test-persistent'
        base.mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=base)
        self.directory=Path(self.temp.name)
        command=[TCL, winpath(ROOT/'tests/mock_board_session.tcl'), winpath(self.directory/'launch.tcl')]
        self.board=BoardSession(MODEL,'/mock/master',directory=self.directory,command=command,startup_timeout=10,request_timeout=2)

    def tearDown(self):
        self.board.close()
        self.temp.cleanup()

    def fault(self, name):
        (self.directory/'fault').write_text(name)

    def test_reuses_model_and_blocks_actual_readback(self):
        first=predict(MODEL,[4,2],'fpga',board=self.board)
        second=predict(MODEL,[1,5],'fpga',board=self.board)
        self.assertNotEqual(first['scores'],second['scores'])
        self.assertEqual(first['scores'],reference(MODEL,[4,2])[-1])
        self.assertEqual(second['scores'],reference(MODEL,[1,5])[-1])
        self.assertTrue(first['timings']['cold_start'])
        self.assertFalse(second['timings']['cold_start'])
        self.assertEqual(second['timings']['setup_seconds'],0)
        self.board.close()
        traffic=(self.directory/'traffic.log').read_text().splitlines()
        self.assertEqual(traffic.count('CLAIM'),1)
        self.assertEqual(traffic.count('CLOSE'),1)
        self.assertEqual(traffic.count('W 8 4'),1)
        self.assertEqual(traffic.count('W 8 1'),2)
        self.assertEqual(sum(x.startswith('W 131072 ') for x in traffic),1)
        self.assertEqual(traffic.count('R 65544 2'),2)
        self.assertEqual(traffic.count('R 65552 1'),2)

    def test_wrong_id_no_writes(self):
        self.fault('wrong_id')
        with self.assertRaisesRegex(RuntimeError,'identity'):
            self.board.infer([4,2])
        self.assertNotIn('W ',(self.directory/'traffic.log').read_text())

    def test_display_only_after_verified_layers(self):
        result=predict(MODEL,[4,2],'fpga',board=self.board)
        self.assertTrue(result['hex_display_updated'])
        traffic=(self.directory/'traffic.log').read_text().splitlines()
        self.assertIn('W 32 0',traffic)
        self.assertGreater(traffic.index('W 32 0'),traffic.index('R 65552 1'))
        self.board.clear_display()
        self.assertTrue((self.directory/'traffic.log').read_text().endswith('R 32 1\n'))

    def test_old_image_rejected_before_writes(self):
        self.fault('old_image')
        with self.assertRaisesRegex(RuntimeError,'HEX1 image'):
            self.board.infer([4,2])
        self.assertNotIn('W ',(self.directory/'traffic.log').read_text())

    def test_display_readback_failure_invalidates(self):
        self.fault('display_readback')
        with self.assertRaisesRegex(RuntimeError,'readback mismatch'):
            predict(MODEL,[4,2],'fpga',board=self.board)
        self.assertIsNotNone(self.board.failure)

    def test_duplicate_commit_rejected(self):
        predict(MODEL,[4,2],'fpga',board=self.board)
        with self.assertRaisesRegex(RuntimeError,'uncommitted'):
            self.board.display(0)

    def test_reset_invalidates_without_reload_or_retry(self):
        self.board.infer([4,2])
        self.fault('reset')
        with self.assertRaisesRegex(RuntimeError,'configuration lost'):
            self.board.infer([4,2])
        before=(self.directory/'traffic.log').read_text()
        with self.assertRaisesRegex(RuntimeError,'session unavailable'):
            self.board.infer([4,2])
        self.assertEqual(before,(self.directory/'traffic.log').read_text())

    def test_short_read_invalidates(self):
        self.fault('short')
        with self.assertRaisesRegex(RuntimeError,'Short read'):
            self.board.infer([4,2])

    def test_corruption_cannot_report_exact_match(self):
        self.fault('corrupt')
        with self.assertRaisesRegex(RuntimeError,'Independent integer'):
            predict(MODEL,[4,2],'fpga',board=self.board)
        self.assertIsNotNone(self.board.failure)
        traffic=(self.directory/'traffic.log').read_text().splitlines()
        self.assertFalse(any(line.startswith('W 32 ') and line!='W 32 255' for line in traffic))

    def test_request_timeout_no_retry(self):
        self.fault('stall')
        self.board.request_timeout=.15
        with self.assertRaises(TimeoutError):self.board.infer([4,2])
        self.assertIsNotNone(self.board.failure)
        self.assertEqual((self.directory/'traffic.log').read_text().count('W 8 1\n'),1)

    def test_requires_explicit_session(self):
        with self.assertRaises(ValueError):predict(MODEL,[4,2],'fpga')

    def test_layout_matches_existing_verified_plan(self):
        artifact=json.loads((ROOT/'artifacts/model/model.json').read_text())
        count,blocks,descriptors,outputs=model_layout(artifact)
        plan=self.directory/'plan.txt'
        write_inference_plan(artifact,[0]*count,plan)
        expected=[]
        for line in plan.read_text().splitlines():
            op,*fields=line.split();a,b,*_=map(lambda x:int(x,16),fields)
            if op=='W' and a!=8 and not 0x10000<=a<0x18000:expected.append((a,b))
        actual=[(base+4*i,v) for base,words in blocks for i,v in enumerate(words)]
        self.assertEqual(dict(actual),dict(expected))
        self.assertEqual(len(actual),len(expected))

if __name__=='__main__':unittest.main()
