"""Recording selection and replay regression checks; no hardware is involved."""
import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import numpy as np
import pandas as pd

import replay_dataset_live as replay


class ReplayTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)

    def recording(self, member):
        path = self.root / member
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
        return path

    def test_kfall_picks_existing_sorted_recording(self):
        self.recording("SA07/S07T20R01.csv")
        expected = self.recording("SA06/S06T20R02.csv")
        self.assertEqual(replay.resolve_recording("kfall", self.root, task=20), expected)

    def test_univr_uses_sensor_folder_not_labels(self):
        self.recording("laboratory/labels_data/SA01/S01T20R01.csv")
        expected = self.recording("laboratory/sensors_data/SA09/S09T20R01.csv")
        self.assertEqual(replay.resolve_recording("univrfall", self.root, task=20), expected)

    def test_univr_field_selection(self):
        expected = self.recording("OnField/20241106/20241106_1000.csv")
        self.assertEqual(replay.resolve_recording("univrfall", self.root, task=88), expected)

    def test_existing_member_interface(self):
        expected = self.recording("SA06/S06T20R01.csv")
        self.assertEqual(replay.resolve_recording("kfall", self.root, member="SA06/S06T20R01.csv"), expected)

    def test_invalid_or_missing_task(self):
        for dataset, task in (("kfall", 0), ("kfall", 37), ("kfall", 88), ("univrfall", 45)):
            with self.subTest(dataset=dataset, task=task), self.assertRaisesRegex(ValueError, "must be"):
                replay.resolve_recording(dataset, self.root, task=task)
        with self.assertRaisesRegex(ValueError, "No recording"):
            replay.resolve_recording("kfall", self.root, task=20)

    def test_missing_folder_and_malformed_member(self):
        with self.assertRaisesRegex(ValueError, "Dataset folder not found"):
            replay.resolve_recording("kfall", self.root / "missing", task=20)
        with self.assertRaisesRegex(ValueError, "Use --task 20"):
            replay.resolve_recording("kfall", self.root, member="printfSA06/S06T%sR%s.csv1 01")

    def test_default_roots_follow_project_location(self):
        with patch.object(replay, "__file__", "/project/InflateBody/Python/replay_dataset_live.py"):
            self.assertEqual(replay.default_dataset_root("kfall"), Path("/project/Data Collection/sensor_data_new_2"))
            self.assertEqual(replay.default_dataset_root("univrfall"), Path("/project/Data Collection/UniVrFall_Dataset"))

    def test_listing_does_not_open_graph(self):
        self.recording("SA06/S06T20R01.csv")
        output = io.StringIO()
        with patch.object(replay, "LiveSensorGraph") as graph, contextlib.redirect_stdout(output):
            replay.main(["--dataset", "kfall", "--dataset-root", str(self.root), "--list-tasks"])
        graph.assert_not_called()
        self.assertIn("20,1,SA06/S06T20R01.csv", output.getvalue())

    def test_check_only_and_zero_padded_task(self):
        self.recording("SA06/S06T01R01.csv")
        data = pd.DataFrame([[0, 0, 1, 0, 0, 0]], columns=["ax", "ay", "az", "gx", "gy", "gz"])
        with patch.object(replay, "read_sensor_csv", return_value=data), \
                patch.object(replay, "LiveSensorGraph") as graph, contextlib.redirect_stderr(io.StringIO()):
            replay.main(["--dataset", "kfall", "--dataset-root", str(self.root), "--task", "01", "--check-only"])
        graph.assert_not_called()

    def test_cli_errors_are_concise(self):
        for extra in (("--speed", "nan"), ("--speed", "inf"), ("--speed", "0"), ("--print-every", "0")):
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                replay.main(["--dataset", "kfall", "--task", "20", *extra])
            self.assertEqual(error.exception.code, 2)
        output = io.StringIO()
        with contextlib.redirect_stderr(output), self.assertRaises(SystemExit):
            replay.main(["--dataset", "kfall", "--dataset-root", str(self.root), "--task", "20"])
        self.assertIn("No recording", output.getvalue())
        self.assertNotIn("Traceback", output.getvalue())

    def test_replay_passes_si_to_graph_and_prints_original_units(self):
        self.recording("SA06/S06T20R01.csv")
        data = pd.DataFrame([[0, 0, 1, 180, 0, 0], [1, 0, 0, 0, 90, 0]],
                            columns=["ax", "ay", "az", "gx", "gy", "gz"])
        graph = MagicMock()
        graph.closed = False
        graph.poll.return_value = True
        output = io.StringIO()
        with patch.object(replay, "read_sensor_csv", return_value=data), \
                patch.object(replay, "LiveSensorGraph", return_value=graph), \
                patch.object(replay.time, "monotonic", side_effect=[0, 0.1]), \
                patch.object(replay.time, "sleep"), contextlib.redirect_stdout(output), \
                contextlib.redirect_stderr(io.StringIO()):
            replay.main(["--dataset", "kfall", "--dataset-root", str(self.root), "--task", "20", "--print-every", "1"])
        self.assertEqual(graph.add_sample.call_count, 2)
        np.testing.assert_allclose(graph.add_sample.call_args_list[0].args[1], [0, 0, replay.GRAVITY, np.pi, 0, 0])
        self.assertEqual(graph.add_sample.call_args_list[1].args[0], 0.01)
        self.assertIn("0,0.00,0.00000,0.00000,1.00000,180.00000", output.getvalue())
        self.assertEqual(len(output.getvalue().splitlines()), 3)
        graph.finish.assert_called_once()


if __name__ == "__main__":
    unittest.main()
