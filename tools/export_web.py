"""把工程导出成可以直接放到 GitHub Pages（或任何静态托管）上的 Web 版。

为什么单独写脚本，而不是在编辑器里点 Export：
    1. 导出这件事有前提（导出模板）和产物（4 个文件），把它写成脚本才能被复验；
    2. `variant/thread_support` 必须为 false —— 带线程的 Web 导出要求服务器发
       COOP/COEP 两个响应头，GitHub Pages 发不了，页面会卡在加载；
    3. 导出用的 `APPDATA` 指到工程内的隔离目录，引擎状态（编辑器设置、着色器缓存、
       导出模板）都落在这里，不污染真实用户目录，也不需要额外权限。

**`export_presets.cfg` 里不要写 `#` 注释**：Godot 的 ConfigFile 只认 `;`，一行的 `#`
会让解析错位，引擎随后报的是一个看起来毫不相干的错——实测报的是
`Couldn't find the given section "preset.0" and key "exclude_filter", and no default was given`，
顺着"缺 exclude_filter"去查会一路查到错的方向。这条 ERROR 会把 import/launch 的日志弄脏，
让流水线失败（`godot_log.py` 只放行证书那一条环境诊断）。

Web 版的四个产物里没有字体——中文能不能显示，取决于工程里有没有随包的中文字体：
`assets/ui_theme.tres` 的默认字体是"随包子集 + SystemFont fallback"，子集由
`tools/build_font.py` 从 OFL 授权的 Noto Sans SC 裁出。浏览器里没有系统字体可查，
只靠 SystemFont 会让界面上的中文全变成方块（真机上已经发生过一次）。

用法：
    python tools/export_web.py                 # 导出并自检
    python tools/export_web.py --publish       # 导出后推到 gh-pages 分支
"""

from pathlib import Path
import argparse
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ENGINE = ROOT / 'tools' / 'godot-4.7.2' / 'Godot_v4.7.2-stable_win64_console.exe'
PROJECT = ROOT / 'outputs' / 'PlaneBattle'
OUT = ROOT / 'outputs' / 'web'
PROFILE = ROOT / 'tools' / 'test-profile'
PRESET = 'Web'
#: 导出必须产出的文件。少一个就不是一个能跑的 Web 版。
REQUIRED = ('index.html', 'index.js', 'index.wasm', 'index.pck')


def engine_env() -> dict:
    env = os.environ.copy()
    # 引擎按 APPDATA 找 user:// 与 export_templates/：指到工程内，安装模板与导出都在这里完成。
    env['APPDATA'] = str(PROFILE)
    return env


def templates_ready() -> bool:
    target = PROFILE / 'Godot' / 'export_templates' / '4.7.2.stable'
    return (target / 'web_nothreads_release.zip').is_file()


def export() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    command = [
        str(ENGINE), '--headless', '--path', str(PROJECT),
        '--export-release', PRESET, str(OUT / 'index.html'),
    ]
    print(' '.join(command))
    result = subprocess.run(command, env=engine_env(), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, encoding='utf-8', errors='replace')
    log = result.stdout or ''
    # 导出过程会顺带打印文件扫描进度，只挑出错行和结尾来看，免得刷屏。
    for line in log.splitlines():
        if 'ERROR' in line or 'SAVE' in line.upper() or 'DONE' in line:
            print(line.rstrip())
    if result.returncode != 0:
        raise SystemExit(f'导出失败，引擎退出码 {result.returncode}')
    (OUT / 'export-log.txt').write_text(log, encoding='utf-8')
    print(f'导出日志：{OUT / "export-log.txt"}')


def verify() -> None:
    missing = [name for name in REQUIRED if not (OUT / name).is_file()]
    if missing:
        raise SystemExit(f'导出产物不完整，缺：{", ".join(missing)}')
    total = 0
    for name in REQUIRED:
        size = (OUT / name).stat().st_size
        total += size
        print(f'  {name}: {size / 1048576:.2f} MB')
    print(f'合计 {total / 1048576:.2f} MB')
    index = (OUT / 'index.html').read_text(encoding='utf-8', errors='replace')
    if 'crossOriginIsolated' in index or 'SharedArrayBuffer' in index:
        print('注意：index.html 里出现了 SharedArrayBuffer 相关代码，确认导出时关掉了线程支持')
    # GitHub Pages 默认走 Jekyll；加一个 .nojekyll 免得以下划线开头的资源被忽略。
    (OUT / '.nojekyll').write_text('', encoding='utf-8')


def _git(args: list, cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(['git', *args], cwd=cwd, check=check,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          encoding='utf-8', errors='replace')


def publish() -> None:
    """把产物提交到 gh-pages 分支。用 worktree，不污染主干工作区。

    **必须可重复跑**：第一版只会 `checkout --orphan gh-pages`，于是第二次运行直接
    以 128 失败（分支已存在）——"改一版、重新发布一次"是这个脚本最主要的用法，
    不可重跑的发布脚本等于没有。现在先看分支在不在，在就正常切过去。
    """
    worktree = ROOT / '.web-publish'
    _git(['worktree', 'remove', '--force', str(worktree)], ROOT, check=False)
    if worktree.exists():
        shutil.rmtree(worktree, ignore_errors=True)
    branch_exists = _git(['rev-parse', '--verify', '--quiet', 'gh-pages'], ROOT,
                         check=False).returncode == 0
    _git(['worktree', 'add', '--force', '--detach', str(worktree)], ROOT)
    if branch_exists:
        _git(['checkout', '--force', 'gh-pages'], worktree)
    else:
        _git(['checkout', '--orphan', 'gh-pages'], worktree)
    # 整棵替换目录内容（保留 .git）：只 add 不删的话，上一版删掉的文件会永远留在分支上。
    for item in worktree.iterdir():
        if item.name == '.git':
            continue
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()
    for item in OUT.iterdir():
        if item.name == 'export-log.txt':
            continue
        if item.is_dir():
            shutil.copytree(item, worktree / item.name)
        else:
            shutil.copy2(item, worktree / item.name)
    _git(['add', '-A'], worktree)
    commit = _git(['commit', '-m', 'Web 版：由 tools/export_web.py 导出，可直接在浏览器里玩'],
                  worktree, check=False)
    if commit.returncode != 0:
        if 'nothing to commit' in (commit.stdout or ''):
            print('产物与上一版一致，gh-pages 不需要新的提交。')
        else:
            raise SystemExit(f'提交 gh-pages 失败：{commit.stdout}')
    else:
        print('已提交到 gh-pages（工作树 .web-publish）。')
    print('推送：git push origin gh-pages')
    print('首次发布还需要在仓库 Settings → Pages 里把 Source 选成 gh-pages 分支。')


def main() -> int:
    parser = argparse.ArgumentParser(description='导出 Web 版')
    parser.add_argument('--publish', action='store_true', help='导出后提交到 gh-pages 分支')
    args = parser.parse_args()
    if not ENGINE.is_file():
        raise SystemExit(f'找不到引擎：{ENGINE}')
    if not templates_ready():
        raise SystemExit(
            '缺少 Web 导出模板。先运行：\n'
            '  python tools/fetch_export_templates.py\n'
            '（拿不到网络时：浏览器下载 tpz，再用 --archive 本地安装）'
        )
    export()
    verify()
    if args.publish:
        publish()
    return 0


if __name__ == '__main__':
    sys.exit(main())
