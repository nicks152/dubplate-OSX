#!/usr/bin/env python3
"""Renders Documentation/design/screens.html to PNGs.

These are design renderings, not screenshots of the running application — see the
comment at the top of screens.html. They exist so the layout, density, hierarchy and
palette can be reviewed on a machine with no Apple toolchain.

Requires Chromium and playwright-core (Node). Run:

    python3 Tools/render_design.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HTML = os.path.join(ROOT, "Documentation", "design", "screens.html")
OUT = os.path.join(ROOT, "Documentation", "design", "renders")

SCREENS = [
    "mac-library", "mac-release", "mac-versions", "mac-preview",
    "phone-home", "phone-release", "phone-stream", "phone-motion",
]

SCRIPT = """
const {chromium} = require(process.env.PW_MODULE);
(async () => {
  const browser = await chromium.launch({executablePath: process.env.PW_CHROMIUM});
  const page = await browser.newPage({deviceScaleFactor: 2});
  await page.goto('file://' + process.env.PAGE);
  await page.waitForTimeout(400);
  for (const id of JSON.parse(process.env.SCREENS)) {
    const element = await page.$('#' + id);
    if (!element) { console.error('missing screen ' + id); continue; }
    await element.screenshot({path: process.env.OUT + '/' + id + '.png'});
    console.log('rendered ' + id);
  }
  await browser.close();
})().catch(error => { console.error(error.message); process.exit(1); });
"""


def find(paths):
    for path in paths:
        if os.path.exists(path):
            return path
    return None


def main() -> int:
    chromium = find([
        "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
        "/opt/pw-browsers/chromium/chrome-linux/chrome",
        shutil.which("chromium") or "",
        shutil.which("google-chrome") or "",
    ])
    if not chromium:
        print("render_design: no Chromium found; skipping", file=sys.stderr)
        return 0

    module = find([
        os.path.expanduser("~/.node_modules/playwright-core"),
        "/tmp/claude-0/-home-user-dubplate-OSX/7adbec76-78e0-544c-beba-3ce33cfe5fd0/"
        "scratchpad/node_modules/playwright-core",
        os.path.join(ROOT, "node_modules", "playwright-core"),
    ])
    if not module:
        print("render_design: playwright-core not installed; run "
              "`npm install playwright-core` first", file=sys.stderr)
        return 0

    os.makedirs(OUT, exist_ok=True)
    environment = dict(
        os.environ,
        PW_MODULE=module,
        PW_CHROMIUM=chromium,
        PAGE=HTML,
        OUT=OUT,
        SCREENS=json.dumps(SCREENS),
    )
    result = subprocess.run(
        ["node", "-e", SCRIPT], env=environment, capture_output=True, text=True
    )
    print(result.stdout.strip())
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
