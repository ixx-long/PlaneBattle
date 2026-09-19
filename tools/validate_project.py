"""用真实 Godot 引擎跑一种验证模式，并判读日志。

模式（第一个位置参数，必填）：
    import  无界面编辑器导入与资源扫描，确认脚本能解析、资源能加载
    launch  正式主场景启动测试
    smoke   285 项 GDScript 自动回归断言
    visual  渲染 6 张验收截图
    stress  最坏情况压力基准

参数写法由 argparse 严格校验。早期版本直接读 sys.argv[1] 当模式、忽略其余参数，
于是 `--project X --mode visual` 会静默退化成 smoke：不报错、跑的还是上一次的截图，
很容易让人拿着旧产物得出错误结论。现在模式名拼错或参数不认识都会立刻失败。
"""

from pathlib import Path
import argparse
import os
import subprocess

from godot_log import classify

ROOT = Path(__file__).resolve().parent.parent
ENGINE = ROOT / 'tools/godot-4.7.2/Godot_v4.7.2-stable_win64_console.exe'

# 压力/威胁/浸泡基准都要跑满若干秒测量 + 等待清场，给它们的上限比其它模式宽一些；
# 它们自带的看门狗（75 / 75 / 150 秒）仍会先于这里触发并给出明确原因。
TIMEOUTS = {'stress': 150, 'threat': 150, 'soak': 240}
DEFAULT_TIMEOUT = 90

parser = argparse.ArgumentParser(description='用真实引擎验证 Godot 项目')
parser.add_argument('mode', choices=('import', 'launch', 'smoke', 'visual', 'stress', 'threat', 'soak'))
# 默认就是本仓库的工程；显式传入是为了验证交付 ZIP 解压出来的那一份（干净环境验证），
# 而不是验证仓库里被各种缓存和中间产物覆盖过的工作副本。
parser.add_argument('--project', default='outputs/PlaneBattle', help='要验证的工程目录')
parser.add_argument('--log-dir', default='outputs', help='验证日志写到哪个目录')
parser.add_argument('--profile', default='tools/test-profile',
                    help='引擎 user:// 目录，干净环境验证时指到新的空目录')
args = parser.parse_args()


def resolve(path_text: str) -> Path:
    path = Path(path_text)
    return path if path.is_absolute() else ROOT / path


PROJECT = resolve(args.project)
LOG_DIR = resolve(args.log_dir)
PROFILE = resolve(args.profile)
for directory in (LOG_DIR, PROFILE):
    directory.mkdir(parents=True, exist_ok=True)

# 把引擎的 user:// 隔离到工程外，避免测试读写真实用户目录里的存档。
env = os.environ.copy()
env['APPDATA'] = str(PROFILE)

if args.mode == 'visual':
    cli = ['--rendering-method', 'gl_compatibility', '--script', 'res://tests/VisualTest.gd']
elif args.mode == 'stress':
    cli = ['--headless', '--script', 'res://tests/StressTest.gd']
elif args.mode == 'threat':
    cli = ['--headless', '--script', 'res://tests/ThreatTest.gd']
elif args.mode == 'soak':
    cli = ['--headless', '--script', 'res://tests/SoakTest.gd']
elif args.mode == 'import':
    cli = ['--headless', '--editor', '--import', '--quit']
elif args.mode == 'launch':
    cli = ['--headless', '--quit-after', '180']
else:
    cli = ['--headless', '--script', 'res://tests/SmokeTest.gd']

result = subprocess.run([str(ENGINE), '--path', str(PROJECT), *cli], env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        encoding='utf-8', errors='replace',
                        timeout=TIMEOUTS.get(args.mode, DEFAULT_TIMEOUT))
log = result.stdout
log_path = LOG_DIR / f'{args.mode}-results.txt'
log_path.write_text(log, encoding='utf-8')
print(log)
print(f'LOG: {log_path}')

# 日志判读集中在 godot_log：真实错误一律失败，已登记的环境诊断单独列出而不隐藏。
errors, benign = classify(log)
for line in benign:
    print(f'NOTE: {args.mode} 已放行的环境诊断 -> {line}')
if errors:
    raise SystemExit(f'{args.mode}: 日志中存在 {len(errors)} 条错误：\n' + '\n'.join(errors))
if result.returncode != 0:
    raise SystemExit(f'{args.mode}: 引擎退出码 {result.returncode}')
