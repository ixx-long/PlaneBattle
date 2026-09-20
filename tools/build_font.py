"""把一份 OFL 授权的中文字体裁成**只含本作界面用字**的子集，供 Web 版显示中文。

为什么必须有它：桌面版的中文靠 `SystemFont` 从系统里取（微软雅黑 / 苹方 / Noto CJK），
而 **Web 上没有系统字体可查**——`SystemFont` 取不到任何字面，正文就全变成方块（□）。
这条限制文档里早就登记过，这一轮被真人截图证实了。

做法与取舍：
    · 字体选 **Noto Sans SC**，授权是 **SIL OFL 1.1**，允许随包再分发（许可证文本一并附上）；
    · 只保留"项目里真的会渲染到的字符"：`.tscn/.tres` 取全文，`.gd` 只取**字符串字面量**
      （注释里出现的字永远显示不出来，带上它们只会把字体撑大）；
    · 子集化之后**再验一遍覆盖率**：收集到的字符必须一个不少地出现在子集的 cmap 里，
      少一个就报出来——子集化的典型故障就是"界面上偶尔缺一个字"，那种问题靠肉眼很难发现；
    · 变量字体先固化到 wght=400，否则 Godot 侧还要处理字体变体。

用法：
    python tools/build_font.py                          # 下载源字体（首次）并生成子集
    python tools/build_font.py --source <字体文件路径>    # 用本地已有的源字体
    python tools/build_font.py --report                 # 只报告当前子集的字符数与大小
"""

from pathlib import Path
import argparse
import hashlib
import re
import sys
import time
import urllib.request

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.subset import Subsetter, Options

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / 'outputs' / 'PlaneBattle'
CACHE = ROOT / 'tools' / 'fonts'
SOURCE = CACHE / 'NotoSansSC-VF.ttf'
OUT_DIR = PROJECT / 'assets' / 'fonts'
OUT_FONT = OUT_DIR / 'NotoSansSC-Regular.subset.ttf'
OUT_LICENSE = OUT_DIR / 'OFL.txt'
#: 源字体走 jsDelivr 的 GitHub 镜像，而不是 raw.githubusercontent.com。
#: 原因很实际：本项目所在环境从 raw 拉十几 MB 的文件会被对端提前断开（实测多次），
#: 而 jsDelivr 是给大文件用的 CDN，**同一个文件、同一个 commit**，分块拉取稳定。
#: 两份都是 google/fonts 仓库里的原件，字节一致；要换源请连同 SOURCE_SHA256 一起改。
FONT_URL = ('https://cdn.jsdelivr.net/gh/google/fonts@main/'
            'ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf')
LICENSE_URL = 'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosanssc/OFL.txt'
#: 源字体的 SHA-256。源文件换了（比如上游更新）必须能发现，否则"同一个脚本跑出不同子集"
#: 这件事会悄悄发生，而没人会去看那几百 KB 的差异。
SOURCE_SHA256 = 'a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da'
WEIGHT = 400
#: 无论界面怎么写都要有的字符：ASCII 可打印 + 常用中英标点 + 本作界面里出现的符号。
ALWAYS = ''.join(chr(code) for code in range(0x20, 0x7F)) + '·×…—→←↑↓／（）【】“”‘’、。，！？：；'

TRIPLE = re.compile(r'"""(.*?)"""', re.S)
DOUBLE = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
SINGLE = re.compile(r"'((?:[^'\\\n]|\\.)*)'")


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _download(url: str, target: Path, chunk: int = 512 * 1024, attempts: int = 4) -> bytes:
    """分块下载（可续传、逐块重试）并返回内容。

    为什么要分块：本项目所在的环境里一次性拉一个十几 MB 的文件会被对端提前断开
    （`RemoteDisconnected`，实测多次），而切成 512 KB 一段、每段各自重试就能稳定拿完。
    顺带也就有了断点续传——重跑时已下到的部分不会白费。
    """
    headers = {'User-Agent': 'build_font'}
    with urllib.request.urlopen(urllib.request.Request(url, method='HEAD', headers=headers),
                                timeout=60) as response:
        total = int(response.headers.get('Content-Length', 0))
    if not total:
        return urllib.request.urlopen(
            urllib.request.Request(url, headers=headers), timeout=120).read()
    target.parent.mkdir(parents=True, exist_ok=True)
    done = target.stat().st_size if target.is_file() else 0
    if done > total:
        done = 0
        target.unlink()
    with target.open('ab' if done else 'wb') as sink:
        start = done
        mark = start
        while start < total:
            end = min(start + chunk - 1, total - 1)
            for attempt in range(1, attempts + 1):
                try:
                    request = urllib.request.Request(
                        url, headers={**headers, 'Range': f'bytes={start}-{end}'})
                    with urllib.request.urlopen(request, timeout=60) as response:
                        blob = response.read()
                    if not blob:
                        raise RuntimeError('空响应')
                    sink.write(blob)
                    start += len(blob)
                    break
                except Exception:  # noqa: BLE001 - 分块失败就重试，最后一次才抛
                    if attempt >= attempts:
                        raise
                    time.sleep(2 * attempt)
            if start - mark >= 4 * 1024 * 1024 or start >= total:
                mark = start
                print(f'  下载中 {start / 1048576:.1f} / {total / 1048576:.1f} MB', flush=True)
    return target.read_bytes()


def ensure_source(explicit: str | None) -> Path:
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise SystemExit(f'找不到源字体：{path}')
        return path
    if SOURCE.is_file():
        if SOURCE_SHA256 and sha256_of(SOURCE) != SOURCE_SHA256:
            raise SystemExit('缓存字体的 SHA-256 与脚本记录的不一致，删掉重下或核对来源')
        return SOURCE
    print(f'下载源字体（约 17 MB）：{FONT_URL}')
    _download(FONT_URL, SOURCE)
    print(f'  已缓存到 {SOURCE}')
    print(f'  源字体 SHA-256：{sha256_of(SOURCE)}（填进脚本的 SOURCE_SHA256 可锁版本）')
    return SOURCE


def string_literals(text: str) -> list[str]:
    """取出 .gd 里的字符串字面量（含三引号）。注释不取：注释里的字永远显示不出来。"""
    literals: list[str] = []
    for match in TRIPLE.finditer(text):
        literals.append(match.group(1))
    text = TRIPLE.sub('""', text)
    literals += [match.group(1) for match in DOUBLE.finditer(text)]
    literals += [match.group(1) for match in SINGLE.finditer(text)]
    return literals


def collect_characters() -> set[str]:
    characters: set[str] = set(ALWAYS)
    sources = 0
    for path in sorted(PROJECT.rglob('*')):
        if not path.is_file():
            continue
        if path.suffix in ('.tscn', '.tres', '.godot'):
            characters.update(path.read_text(encoding='utf-8', errors='replace'))
            sources += 1
        elif path.suffix == '.gd':
            for literal in string_literals(path.read_text(encoding='utf-8', errors='replace')):
                characters.update(literal)
            sources += 1
    # 去掉换行/制表这类控制字符：它们不是字形，收进去只会让"覆盖率复验"报一个假缺口。
    characters = {character for character in characters if character.isprintable()}
    print(f'从 {sources} 个场景/脚本/资源文件里收集到 {len(characters)} 个不同字符')
    return characters


def build(characters: set[str], source: Path) -> None:
    font = TTFont(source)
    # 变量字体先固化到 Regular，避免 Godot 侧还要处理字体变体。
    if 'fvar' in font:
        font = instancer.instantiateVariableFont(font, {'wght': WEIGHT}, inplace=False)
    available = set(font.getBestCmap().keys())
    wanted = {ord(character) for character in characters}
    missing = sorted(code for code in wanted if code not in available)
    if missing:
        # 源字体本身就没有的字无法收进去；报出来而不是静默丢掉，否则界面上会出现方块而没人知道来源。
        print('注意：源字体里没有这些字符，界面上会显示为方块 -> '
              + ' '.join(f'{chr(code)}(U+{code:04X})' for code in missing))
    options = Options()
    options.layout_features = ['*']
    options.drop_tables += ['DSIG']
    options.notdef_outline = True
    subsetter = Subsetter(options=options)
    subsetter.populate(unicodes=[code for code in wanted if code in available])
    subsetter.subset(font)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    font.flavor = None
    font.save(OUT_FONT)
    font.close()

    # 覆盖率复验：子集里必须真的有每一个我们打算显示的字符。
    check = TTFont(OUT_FONT)
    covered = set(check.getBestCmap().keys())
    check.close()
    lost = sorted(code for code in wanted if code in available and code not in covered)
    if lost:
        raise SystemExit('子集缺少本应包含的字符：'
                         + ' '.join(f'{chr(code)}(U+{code:04X})' for code in lost))
    print(f'子集已生成：{OUT_FONT}')
    print(f'  覆盖 {len(covered)} 个码位，{OUT_FONT.stat().st_size / 1024:.0f} KB')

    if not OUT_LICENSE.is_file():
        text = urllib.request.urlopen(
            urllib.request.Request(LICENSE_URL, headers={'User-Agent': 'build_font'}),
            timeout=60).read().decode('utf-8')
        OUT_LICENSE.write_text(text, encoding='utf-8')
        print(f'许可证已附上：{OUT_LICENSE}（SIL OFL 1.1，允许随包再分发）')


def report() -> int:
    if not OUT_FONT.is_file():
        print('还没有生成子集。先跑 python tools/build_font.py')
        return 1
    font = TTFont(OUT_FONT)
    print(f'{OUT_FONT}：{len(font.getBestCmap())} 个码位，{OUT_FONT.stat().st_size / 1024:.0f} KB')
    font.close()
    print(f'许可证：{OUT_LICENSE}（{"存在" if OUT_LICENSE.is_file() else "缺失"}）')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description='生成中文字体子集')
    parser.add_argument('--source', help='本地已有的源字体（跳过下载）')
    parser.add_argument('--report', action='store_true', help='只报告当前子集')
    args = parser.parse_args()
    if args.report:
        return report()
    build(collect_characters(), ensure_source(args.source))
    return 0


if __name__ == '__main__':
    sys.exit(main())
