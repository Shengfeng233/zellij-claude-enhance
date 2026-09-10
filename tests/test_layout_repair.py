import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'layout_repair', Path(__file__).resolve().parents[1] / 'zellij-layout-repair.py'
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
repair = module.repair_layout


class LayoutRepairTests(unittest.TestCase):
    prefix = 'layout {\n    tab { pane { plugin location="zellij:tab-bar"; } }\n'

    def test_restored_tab_template_keeps_ui_and_inherits_cwd(self):
        original = self.prefix + '    new_tab_template {\n        pane cwd="/"\n    }\n}\n'
        fixed = repair(original)
        template = fixed.split('new_tab_template', 1)[1]
        self.assertIn('zellij:tab-bar', template)
        self.assertIn('zellij:status-bar', template)
        self.assertNotIn('cwd=', template)
        self.assertEqual(repair(fixed), fixed)

    def test_custom_template_is_preserved(self):
        original = self.prefix + '    new_tab_template { pane cwd="/projects"; }\n}\n'
        self.assertEqual(repair(original), original)

    def test_custom_minimal_session_is_preserved(self):
        original = 'layout {\n    new_tab_template { pane cwd="/"; }\n}\n'
        self.assertEqual(repair(original), original)

    def test_common_root_does_not_override_new_tab_cwd(self):
        original = self.prefix.replace('layout {\n', 'layout {\n    cwd "/"\n')
        original += '    tab name="Project" { pane cwd="home/user/project"; }\n'
        original += '    new_tab_template { pane cwd="/"; }\n}\n'
        fixed = repair(original)
        self.assertNotIn('    cwd "/"', fixed)
        self.assertIn('cwd="/home/user/project"', fixed)
        self.assertEqual(repair(fixed), fixed)

    def test_default_fixed_layout_does_not_change(self):
        original = (Path(__file__).resolve().parents[1] / 'statusbar-fixed.kdl').read_text()
        self.assertEqual(repair(original), original)


if __name__ == '__main__':
    unittest.main()
