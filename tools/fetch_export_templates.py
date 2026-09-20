"""下载并安装 Godot 官方导出模板（Web 导出必需，1.19 GB），带校验与断点续传。

为什么要有这个脚本，而不是手点编辑器：
    `--export-release` 在没有导出模板时会直接失败，而"要下载 1.19 GB 模板"这件事在交付
    文档里只写成一句话——接收方到了导出这一步才发现缺东西。把它写成可重跑的脚本，
    "怎么从零把 Web 版导出来"就变成了两条命令，而不是一段口述流程。

它做的事：
    1. 下载官方 4.7.2-stable 的 export_templates.tpz 到 tools/（已在 .gitignore 里）。
       支持断点续传：中途断了再跑一次会从断点接着下。
    2. **核对大小与 SHA-256**。这两个值取自 GitHub 发布 API 对该 tag 的元数据
       （releases/tags/4.7.2-stable），不是抄来的——1 GB 的二进制不校验等于不设防。
    3. 把 `templates/` 里的文件解到引擎的模板目录，然后逐项确认关键文件就位。

模板目录默认是 `%APPDATA%/Godot/export_templates/<版本>`（引擎自己找的位置），
也可以用 `--target` 指到别处；自动化里常用的是把 APPDATA 指到工程内，
让引擎状态与模板都不落到真实用户目录（见 tools/export_web.py）。

拿不到网络时的手工路径：
    浏览器下载 https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz
    存成 tools/godot-4.7.2-export-templates.tpz，再跑
    `python tools/fetch_export_templates.py --archive tools/godot-4.7.2-export-templates.tpz`
    （落地文件同样会过一遍大小与 SHA-256 校验，写坏了会当场失败而不是等到导出时才炸。）

用法：
    python tools/fetch_export_templates.py                     # 下载 + 安装
    python tools/fetch_export_templates.py --check             # 只看现在装好没有
    python tools/fetch_export_templates.py --archive <file>    # 用本地文件安装
    python tools/fetch_export_templates.py --target <dir>      # 装到指定目录
"""

from pathlib import Path
import argparse
import hashlib
import os
import shutil
import sys
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
VERSION = '4.7.2'
VERSION_DIR = '4.7.2.stable'
ARCHIVE = ROOT / 'tools' / f'godot-{VERSION}-export-templates.tpz'
URL = (
    f'https://github.com/godotengine/godot/releases/download/'
    f'{VERSION}-stable/Godot_v{VERSION}-stable_export_templates.tpz'
)
#: 官方发布 API 报出的元数据（releases/tags/4.7.2-stable）。
EXPECTED_BYTES = 1281349702
EXPECTED_SHA256 = 'f298490b8d44d934be425a5a65a51bf15f422428b229a06a6e11d9ffea248011'
#: 装好之后必须存在的文件。Web 导出只用到 nothreads 那个变体——GitHub Pages 这类静态托管
#: 发不了 COOP/COEP 响应头，带线程的 Web 导出在那种环境下根本起不来。
REQUIRED = ('web_nothreads_release.zip', 'web_nothreads_debug.zip')


def default_target() -> Path:
    override = os.environ.get('GODOT_TEMPLATE_DIR')
    if override:
        return Path(override)
    return Path(os.environ['APPDATA']) / 'Godot' / 'export_templates' / VERSION_DIR


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def verify(path: Path) -> None:
    """大小与 SHA-256 都要对。对不上就失败——不要带着一个可能被截断的 1 GB 文件往下走。"""
    size = path.stat().st_size
    if size != EXPECTED_BYTES:
        raise SystemExit(f'{path} 大小不对：{size} != {EXPECTED_BYTES}（下载不完整？）')
    digest = sha256_of(path)
    if digest != EXPECTED_SHA256:
        raise SystemExit(f'{path} SHA-256 不匹配：\n  实际 {digest}\n  期望 {EXPECTED_SHA256}')


def templates_ready(target: Path) -> bool:
    return all((target / name).is_file() for name in REQUIRED)


def report(target: Path) -> None:
    print(f'导出模板目录：{target}')
    for name in REQUIRED:
        path = target / name
        size = f'{path.stat().st_size / 1048576:.1f} MB' if path.is_file() else '缺失'
        print(f'  {name}: {size}')


def download(attempts: int) -> None:
    """流式下载 + 断点续传 + 重试。"""
    if ARCHIVE.is_file() and ARCHIVE.stat().st_size == EXPECTED_BYTES:
        print(f'已存在且大小一致，跳过下载：{ARCHIVE}（{EXPECTED_BYTES / 1073741824:.2f} GB）')
        return
    for attempt in range(1, attempts + 1):
        have = ARCHIVE.stat().st_size if ARCHIVE.is_file() else 0
        headers = {'User-Agent': 'fetch_export_templates'}
        mode = 'wb'
        if 0 < have < EXPECTED_BYTES:
            headers['Range'] = f'bytes={have}-'
            mode = 'ab'
            print(f'从断点继续（已有 {have / 1073741824:.2f} GB）')
        try:
            request = urllib.request.Request(URL, headers=headers)
            with urllib.request.urlopen(request, timeout=60) as response, ARCHIVE.open(mode) as sink:
                done = have
                mark = done
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    sink.write(chunk)
                    done += len(chunk)
                    if done - mark >= 128 * 1048576:
                        mark = done
                        print(f'  下载中 {done / 1073741824:.2f} / '
                              f'{EXPECTED_BYTES / 1073741824:.2f} GB', flush=True)
            break
        except Exception as error:  # noqa: BLE001 - 网络层的任何失败都重试，最后一次才抛出
            if attempt >= attempts:
                raise SystemExit(
                    f'下载失败（已试 {attempts} 次）：{type(error).__name__}: {error}\n'
                    f'可以改用浏览器下载后本地安装：\n  {URL}\n'
                    f'  python tools/fetch_export_templates.py --archive <下载到的文件>'
                ) from error
            wait = min(30, 5 * attempt)
            print(f'第 {attempt} 次失败（{type(error).__name__}），{wait} 秒后重试', flush=True)
            time.sleep(wait)


def install(archive: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    installed = 0
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.namelist():
            if not member.startswith('templates/') or member.endswith('/'):
                continue
            with bundle.open(member) as source, (target / Path(member).name).open('wb') as sink:
                shutil.copyfileobj(source, sink)
            installed += 1
    print(f'已安装 {installed} 个模板文件到 {target}')


def main() -> int:
    parser = argparse.ArgumentParser(description='下载并安装 Godot 导出模板')
    parser.add_argument('--check', action='store_true', help='只检查是否已安装')
    parser.add_argument('--archive', help='用本地已下载的 tpz 安装（跳过下载）')
    parser.add_argument('--target', help='模板安装目录（默认按引擎的查找规则）')
    parser.add_argument('--attempts', type=int, default=3, help='下载失败重试次数')
    parser.add_argument('--force', action='store_true', help='已装好也重新安装')
    args = parser.parse_args()

    target = Path(args.target) if args.target else default_target()
    if args.check:
        report(target)
        return 0 if templates_ready(target) else 1
    if templates_ready(target) and not args.force:
        print('导出模板已就位，无需重复安装。')
        report(target)
        return 0

    archive = Path(args.archive) if args.archive else ARCHIVE
    if args.archive:
        if not archive.is_file():
            raise SystemExit(f'找不到本地文件：{archive}')
    else:
        download(args.attempts)
    print(f'校验 {archive} …')
    verify(archive)
    install(archive, target)
    report(target)
    if not templates_ready(target):
        raise SystemExit('安装后仍缺少必需模板文件')
    print('OK：导出模板已可用。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
