"""The retired scheduler must never read DB settings, launch an updater or access OSS."""
import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
import unittest


class ManualUpdateOnlyTest(unittest.TestCase):
    def test_retired_entry_has_no_network_database_or_process_capability(self):
        path = Path(__file__).parents[1] / 'simple' / 'update_schedule.py'
        source = path.read_text(encoding='utf-8-sig')
        spec = importlib.util.spec_from_file_location('retired_update_schedule', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for capability in ('subprocess', 'socket', 'urllib', 'psycopg', 'UPDATER'):
            self.assertNotIn(capability, module.__dict__)
        with redirect_stdout(io.StringIO()) as output:
            self.assertEqual(0, module.main())
        self.assertIn('"manualOnly": true', output.getvalue())
        self.assertNotIn('read_config(', source)

    def test_installation_disables_auto_timer_and_only_enables_local_bridge(self):
        path = Path(__file__).parents[1] / 'simple' / 'install-server-operations.sh'
        source = path.read_text()
        self.assertIn('systemctl disable --now uten-imp-updater.timer', source)
        self.assertIn('systemctl enable uten-imp-operations.service', source)
        self.assertIn('systemctl restart uten-imp-operations.service', source)
        self.assertNotIn('enable --now uten-imp-updater', source)
        self.assertNotIn('updater check', source)
        self.assertNotIn('updater activate', source)


if __name__ == '__main__':
    unittest.main()
