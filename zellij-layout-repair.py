#!/usr/bin/env python3
"""Repair known stock-UI serialization defects without rewriting custom layouts.

Also points saved status bars at the installed one (stock or Move Tab hint).
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import time

# The status bar with the Move Tab hint (status-bar/ in this repository).
PATCHED_STATUS_BAR = r'location="file:[^"]*/zellij-improve/plugins/status-bar\.wasm"'
STATUS_BAR_PERMISSIONS = ('ReadApplicationState', 'ChangeApplicationState')


def repair_layout(text, status_bar=None):
    """Repair a serialized layout; status_bar selects the patched bar's path."""
    text = re.sub(
        r'location="(tab-bar|status-bar|compact-bar)"',
        r'location="zellij:\1"',
        text,
    )
    # Repair in the stock spelling, then switch every status bar (live panes
    # and swap-layout slots alike) to the installed one, so the strings match.
    text = re.sub(PATCHED_STATUS_BAR, 'location="zellij:status-bar"', text)
    text = repair_stock_layout(text)
    if status_bar is not None:
        text = text.replace(
            'location="zellij:status-bar"', f'location="file:{status_bar}"'
        )
    return text


def repair_stock_layout(text):
    # A restored stock session can lose its new-tab UI and acquire the layout's
    # common-root cwd. Only repair this exact broken shape when existing tabs
    # already use the stock tab bar; leave custom new-tab templates alone.
    if 'plugin location="zellij:tab-bar"' not in text:
        return text
    pattern = r'(?m)^([ \t]*)new_tab_template\s*\{\s*pane\s+cwd="/"\s*;?\s*\}'

    def template(match):
        indent = match.group(1)
        lines = [
            'new_tab_template {',
            '    pane size=1 borderless=true {',
            '        plugin location="zellij:tab-bar"',
            '    }',
            '    pane',
            '    pane size=1 borderless=true {',
            '        plugin location="zellij:status-bar"',
            '    }',
            '}',
        ]
        return '\n'.join(indent + line for line in lines)

    text = re.sub(pattern, template, text)
    stock_template = (
        r'new_tab_template\s*\{\s*'
        r'pane\s+size=1\s+borderless=true\s*\{\s*plugin\s+location="zellij:tab-bar"\s*;?\s*\}\s*'
        r'pane\s*;?\s*'
        r'pane\s+size=1\s+borderless=true\s*\{\s*plugin\s+location="zellij:status-bar"\s*;?\s*\}\s*\}'
    )
    common_root = r'(?m)^(layout\s*\{\s*\n)[ \t]*cwd "/"[ \t]*\n'
    if re.search(stock_template, text) and re.search(common_root, text):
        # A dump's common ancestor is useful for shortening pane paths, but
        # loading it applies '/' to new_tab_template too. Make the explicit
        # saved pane paths absolute, then let new tabs inherit the active cwd.
        text = re.sub(r'cwd="(?!/)((?:\\.|[^"\\])*)"', r'cwd="/\1"', text)
        text = re.sub(common_root, r'\1', text, count=1)
    return text


def grant_status_bar(permissions, status_bar):
    """Pre-grant the patched bar; Zellij keys grants by the plugin's path.

    Without a grant it asks in its own pane, which is one row high and never
    focused, so the question could not be answered.
    """
    try:
        text = permissions.read_text()
    except FileNotFoundError:
        text = ''
    name = '"' + str(status_bar).replace('\\', '\\\\').replace('"', '\\"') + '"'
    node = re.compile(r'(?m)^' + re.escape(name) + r'\s*\{([^}]*)\}\n?')
    match = node.search(text)
    if match and set(STATUS_BAR_PERMISSIONS) <= set(match.group(1).split()):
        return False
    text = node.sub('', text)
    if text and not text.endswith('\n'):
        text += '\n'
    text += name + ' {\n' + ''.join(f'    {p}\n' for p in STATUS_BAR_PERMISSIONS) + '}\n'
    replace_file(permissions, text)
    return True


def replace_file(path, text):
    temporary = path.with_name(path.name + '.tmp.' + str(os.getpid()))
    try:
        temporary.write_text(text)
        if path.exists():
            temporary.chmod(path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('layout', type=Path, nargs='?')
    parser.add_argument('--status-bar', type=Path,
                        help='installed patched status bar (default: stock zellij:status-bar)')
    parser.add_argument('--grant', type=Path, metavar='PERMISSIONS_KDL',
                        help="pre-grant --status-bar in Zellij's permission cache")
    args = parser.parse_args()
    if args.grant and not args.status_bar:
        parser.error('--grant requires --status-bar')
    if args.grant and grant_status_bar(args.grant, args.status_bar):
        print(f'granted status bar permissions in {args.grant}')
    if args.layout is None:
        return
    original = args.layout.read_text()
    repaired = repair_layout(original, args.status_bar)
    if repaired == original:
        return
    backup = args.layout.with_name(args.layout.name + '.backup.' + str(time.time_ns()))
    shutil.copy2(args.layout, backup)
    replace_file(args.layout, repaired)
    print(f'fixed: {args.layout.parent.name} (backup: {backup.name})')


if __name__ == '__main__':
    main()
