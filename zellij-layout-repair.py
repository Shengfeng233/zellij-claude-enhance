#!/usr/bin/env python3
"""Repair known stock-UI serialization defects without rewriting custom layouts."""
import argparse
import os
from pathlib import Path
import re
import shutil
import time


def repair_layout(text):
    text = re.sub(
        r'location="(tab-bar|status-bar|compact-bar)"',
        r'location="zellij:\1"',
        text,
    )
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('layout', type=Path)
    args = parser.parse_args()
    original = args.layout.read_text()
    repaired = repair_layout(original)
    if repaired == original:
        return
    backup = args.layout.with_name(args.layout.name + '.backup.' + str(time.time_ns()))
    shutil.copy2(args.layout, backup)
    temporary = args.layout.with_name(args.layout.name + '.tmp.' + str(os.getpid()))
    try:
        temporary.write_text(repaired)
        temporary.chmod(args.layout.stat().st_mode & 0o777)
        os.replace(temporary, args.layout)
    finally:
        temporary.unlink(missing_ok=True)
    print(f'fixed: {args.layout.parent.name} (backup: {backup.name})')


if __name__ == '__main__':
    main()
