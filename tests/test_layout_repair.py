import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'layout_repair', Path(__file__).resolve().parents[1] / 'zellij-layout-repair.py'
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
repair = module.repair_layout
grant = module.grant_status_bar

STATUS_BAR = '/home/user/.local/share/zellij-improve/plugins/status-bar.wasm'
PATCHED = f'location="file:{STATUS_BAR}"'


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


class StatusBarSwitchTests(unittest.TestCase):
    fixed_layout = (Path(__file__).resolve().parents[1] / 'statusbar-fixed.kdl').read_text()

    def test_saved_bars_follow_the_installed_one(self):
        # Live panes and swap-layout slots must carry the same string.
        patched = repair(self.fixed_layout, STATUS_BAR)
        stock = 'location="zellij:status-bar"'
        self.assertNotIn(stock, patched)
        self.assertEqual(patched.count(PATCHED), self.fixed_layout.count(stock))
        self.assertEqual(repair(patched, STATUS_BAR), patched)
        self.assertEqual(repair(patched), self.fixed_layout)

    def test_restored_template_gets_the_installed_bar(self):
        original = LayoutRepairTests.prefix + '    new_tab_template {\n        pane cwd="/"\n    }\n}\n'
        template = repair(original, STATUS_BAR).split('new_tab_template', 1)[1]
        self.assertIn(PATCHED, template)

    def test_common_root_repair_applies_with_patched_bar(self):
        original = (
            'layout {\n    cwd "/"\n'
            '    tab name="Project" {\n'
            '        pane size=1 borderless=true { plugin location="zellij:tab-bar"; }\n'
            '        pane cwd="home/user/project"\n'
            f'        pane size=1 borderless=true {{ plugin {PATCHED}; }}\n'
            '    }\n'
            '    new_tab_template {\n'
            '        pane size=1 borderless=true { plugin location="zellij:tab-bar"; }\n'
            '        pane\n'
            f'        pane size=1 borderless=true {{ plugin {PATCHED}; }}\n'
            '    }\n}\n'
        )
        fixed = repair(original, STATUS_BAR)
        self.assertNotIn('    cwd "/"', fixed)
        self.assertIn('cwd="/home/user/project"', fixed)
        self.assertEqual(fixed.count(PATCHED), 2)


class StatusBarGrantTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.cache = Path(directory.name) / 'permissions.kdl'

    def test_grant_is_added_once(self):
        self.assertTrue(grant(self.cache, STATUS_BAR))
        text = self.cache.read_text()
        self.assertIn(f'"{STATUS_BAR}" {{', text)
        self.assertIn('ReadApplicationState', text)
        self.assertIn('ChangeApplicationState', text)
        self.assertFalse(grant(self.cache, STATUS_BAR))
        self.assertEqual(self.cache.read_text(), text)

    def test_other_grants_are_kept_and_partial_grant_completed(self):
        self.cache.write_text(
            '"/other/plugin.wasm" {\n    RunCommands\n}\n'
            f'"{STATUS_BAR}" {{\n    ReadApplicationState\n}}\n'
        )
        self.assertTrue(grant(self.cache, STATUS_BAR))
        text = self.cache.read_text()
        self.assertIn('"/other/plugin.wasm" {\n    RunCommands\n}', text)
        self.assertEqual(text.count(f'"{STATUS_BAR}"'), 1)
        self.assertIn('ChangeApplicationState', text)


if __name__ == '__main__':
    unittest.main()
