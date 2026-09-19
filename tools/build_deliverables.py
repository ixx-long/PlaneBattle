from pathlib import Path
import base64
import hashlib
import html
import re
import zipfile
from document_sections import INTRO, AFTER_PROJECT, BEFORE_SCRIPTS, AFTER_SCRIPTS
from godot_log import annotate_benign, require_clean, smoke_totals

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'outputs'
PROJECT = OUT / 'PlaneBattle'

# 交付文档引用回归日志时，把已放行的环境诊断替换成本行，避免读者误当成缺陷。
ENV_DIAGNOSTIC_NOTE = '（引擎环境诊断：本次运行环境读取 Windows 根证书库失败，非项目代码问题，已按精确匹配放行）'


#: 交付物里必须逐字嵌入文档、并且一定出现在 ZIP 中的核心文件。
#: 场景与脚本的名字列表分开写：WaveTuning 只有脚本、没有对应场景，
#: 共用一个列表会去找一个并不存在的 scenes/WaveTuning.tscn。
SCENE_NAMES = ('Main', 'Player', 'PlayerBullet', 'Enemy', 'EnemyBullet', 'Explosion', 'Boss', 'HUD')
SCRIPT_NAMES = ('Main', 'Player', 'PlayerBullet', 'Enemy', 'EnemyBullet', 'Explosion', 'Boss', 'HUD', 'WaveTuning')
TEST_NAMES = ('SmokeTest', 'StressTest', 'VisualTest', 'ThreatTest', 'SoakTest')
#: 项目根目录下必须一起打包的文本资源。default_bus_layout.tres 漏掉的话，
#: 解压出来的项目里没有 Music/SFX 总线，代码里的 bus="Music" 会静默回落到 Master。
ROOT_FILES = ('project.godot', 'default_bus_layout.tres')


def count_sections(markdown: str) -> int:
    """数二级标题，**跳过代码块内部**。

    嵌入的源码注释里完全可能出现 “## 1. …” 这样的行（Boss.gd 第一版就写了这种编号），
    粗糙地全文正则会把它们当成文档章节，让章节数校验得出一个莫名其妙的数字。
    """
    total = 0
    in_fence = False
    for line in markdown.splitlines():
        if line.startswith('```'):
            in_fence = not in_fence
            continue
        if not in_fence and re.match(r'^## \d+\.', line):
            total += 1
    return total


def source(relative: str, language: str) -> str:
    content = (PROJECT / relative).read_text(encoding='utf-8').rstrip()
    return f'\n### `res://{relative}`\n\n```{language}\n{content}\n```\n'


def inline(text: str) -> str:
    parts = re.split(r'(`[^`]+`)', text)
    rendered = []
    for part in parts:
        if part.startswith('`') and part.endswith('`'):
            rendered.append('<code>' + html.escape(part[1:-1]) + '</code>')
        else:
            value = html.escape(part)
            value = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', value)
            value = re.sub(r'(https://[^\s<]+)', r'<a href="\1" target="_blank" rel="noopener noreferrer">\1</a>', value)
            rendered.append(value)
    return ''.join(rendered)


def render_markdown(markdown: str) -> str:
    lines = markdown.splitlines()
    output = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.startswith('```'):
            language = line[3:]
            body = []
            i += 1
            while i < len(lines) and not lines[i].startswith('```'):
                body.append(lines[i])
                i += 1
            output.append('<div class="codeblock"><div class="codebar"><span>' + html.escape(language or 'text') + '</span><button type="button" class="copy">复制完整代码</button></div><pre><code>' + html.escape('\n'.join(body)) + '</code></pre></div>')
            i += 1
            continue
        match = re.match(r'^(#{1,4}) (.*)', line)
        if match:
            level = len(match.group(1))
            title = match.group(2)
            section = re.match(r'(\d+)\.', title)
            anchor = ' id="section-' + section.group(1) + '"' if level == 2 and section else ''
            output.append(f'<h{level}{anchor}>' + inline(title) + f'</h{level}>')
            i += 1
            continue
        if line.startswith('|'):
            rows = []
            while i < len(lines) and lines[i].startswith('|'):
                row = [cell.strip() for cell in lines[i].strip().strip('|').split('|')]
                if not all(re.fullmatch(r'[:\- ]+', cell or '-') for cell in row):
                    rows.append(row)
                i += 1
            output.append('<div class="tablewrap"><table>')
            for index, row in enumerate(rows):
                tag = 'th' if index == 0 else 'td'
                output.append('<tr>' + ''.join(f'<{tag}>' + inline(cell) + f'</{tag}>' for cell in row) + '</tr>')
            output.append('</table></div>')
            continue
        if line.startswith('>'):
            body = []
            while i < len(lines) and lines[i].startswith('>'):
                body.append(inline(lines[i].lstrip('> ').strip()))
                i += 1
            output.append('<blockquote>' + '<br>'.join(body) + '</blockquote>')
            continue
        if line.startswith('- ') or re.match(r'^\d+\. ', line):
            ordered = bool(re.match(r'^\d+\. ', line))
            tag = 'ol' if ordered else 'ul'
            output.append(f'<{tag}>')
            while i < len(lines):
                item = re.match(r'^\d+\. (.*)', lines[i]) if ordered else re.match(r'^- (.*)', lines[i])
                if not item:
                    break
                output.append('<li>' + inline(item.group(1)) + '</li>')
                i += 1
            output.append(f'</{tag}>')
            continue
        output.append('<p>' + inline(line) + '</p>')
        i += 1
    return '\n'.join(output)


smoke = (OUT / 'smoke-results.txt').read_text(encoding='utf-8')
require_clean(smoke, 'smoke')
# 断言项数量会随测试增长。写死会让文档在改测试后说谎，因此从日志的实际结果读取。
passed, total, _ = smoke_totals(smoke)
feature_badge = f'<span>{passed} / {total} 自动检查通过</span>'
for kind in ('import', 'launch', 'visual', 'stress', 'threat', 'soak'):
    require_clean((OUT / f'{kind}-results.txt').read_text(encoding='utf-8'), kind)
# 压力基准的结论要进文档，所以这里把它量出来的关键数字读出来核对一遍。
stress_log = (OUT / 'stress-results.txt').read_text(encoding='utf-8')
stress_match = re.search(r'STRESS:.*?峰值子弹=(\d+).*?峰值Actors=(\d+).*?平均帧=([\d.]+)ms.*?帧p99=([\d.]+)ms', stress_log)
assert stress_match, '压力基准日志里找不到 STRESS 汇总行'
peak_bullets, peak_actors, avg_frame_ms, p99_frame_ms = stress_match.groups()
# 威胁基准的结论同样要进文档：它量的是“敌方火力有多少真的能穿过玩家弹幕到达玩家面前”，
# 也就是“后期还有没有威胁”。基准现已**遍历全部战机**，所以这里把每台在最高难度档的
# 结果都取出来——文档要能反映"两台战机各有各的量值"，而不是只报一台。
threat_rows = re.findall(
    r'THREAT: 战机=(\S+) 难度=(\d+) .*?每架开火=([\d.]+) .*?通过率=([\d.]+)% 到达/秒=([\d.]+)',
    (OUT / 'threat-results.txt').read_text(encoding='utf-8'))
assert threat_rows, '威胁基准日志里找不到 THREAT 汇总行'
# 最高难度那一档（每台战机各一条）。
threat_late = [row for row in threat_rows if row[1] == '30']
assert threat_late, '威胁基准日志里找不到最高难度档的结果'
# 文档里那句"修复后同一基准"沿用默认战机（第一台）的数值。
threat_level, threat_shots_per_enemy, threat_pass_rate, threat_arrivals = \
    threat_late[0][1], threat_late[0][2], threat_late[0][3], threat_late[0][4]
threat_per_ship = ' · '.join(
    f'{name} {shots}/架、{arrivals} 发/秒' for name, _level, shots, _rate, arrivals in threat_late)
# 浸泡基准：长时局有没有随时间退化。压力基准只测 6 秒，证明不了这一点。
soak_match = re.search(
    r'SOAK: 时长=(\d+)s 前半帧=([\d.]+)ms 后半帧=([\d.]+)ms 早期实体峰值=(\d+) 后期实体峰值=(\d+) '
    r'.*?残留Actors=(\d+) 对象净增=(\d+)',
    (OUT / 'soak-results.txt').read_text(encoding='utf-8'))
assert soak_match, '浸泡基准日志里找不到 SOAK 汇总行'
soak_seconds, soak_first_frame, soak_second_frame, soak_early_peak, soak_late_peak, \
    soak_residual, soak_object_growth = soak_match.groups()

summary = f'''- 实际引擎：`4.7.2.stable.official.ed1daf0bf`（Windows x86_64 Standard 官方发行包）。
- 引擎下载包 SHA-256 已与官方发行 API 的摘要核对一致；引擎二进制不打包进源码交付物。
- 已执行无界面编辑器导入、资源扫描与脚本加载；无解析/资源错误。
- 已运行正式主场景启动测试；无运行时错误。
- 已执行 **{passed}/{total}** 项 GDScript 自动回归断言；真实 Area2D 碰撞、输入映射、无敌计时、R键重开、难度、重复计分和清场均通过；除下方已登记的环境诊断外，日志无 ERROR。
- 已覆盖最高分持久化：无存档时从 0 开始、结算刷新纪录并写盘、低分不覆盖既有纪录、新实例从磁盘读回、存档内容无效时退回 0 且不影响开局。这组用例会故意写入一份非法存档来验证回退，因此回归日志中会出现一条来自 `push_warning` 的预期 WARNING，它不代表缺陷。
- 已覆盖等级与能力系统：经验只能由击毁敌机获得、满格进入抉择、抉择期间整棵树确实暂停、给出的选项互不重复、选择后升级并扣经验、**16 项能力逐项验证真实生效**（不是只在文案里存在）、连升多级不会吞掉多余经验、叠满或生命已满时不再出现死选项、重开后等级与能力全部复位且不会卡在暂停。行为类断言都配了对照组或隔离措施：多发弹真的生成 3 发且**全部竖直向上、水平等距对称**（不是扇形发散），侧翼炮在主弹道外侧平行排开、多发与侧翼炮组合后仍是 5 条不重叠的平行弹道、弹体增幅真的落到生成子弹的缩放上、穿透弹一发击毁两个敌机（并有“无穿透只击毁一个”的对照）、拦截弹击落敌弹（并有“未开启时互不影响”的对照）、紧急清屏只清敌弹而不动敌机与自己子弹、得分倍率不加快升级、幸运补给后升级真的给出 5 个选项并显示 5 张卡。
- 已实现并验证**本局战报与对局记录**：结算面板从 5 行扩成 6 行实数据小结（生存/难度/到达等级、击毁数、最高倍率、受伤次数、漏敌架数、本局能力路线），刻意不重复顶栏已有的分数与最高分；每局结束向 `user://runs.jsonl` 追加一行 JSON，只保留最近 50 局。为此新增 `kills` / `hits_taken` / `peak_combo_multiplier` 三个计数器，并补上了“结算是跨局边界，连击要在此清零”这一处遗漏——不清的话结算后顶栏会一直挂着一个看起来仍在生效的倍率标签。回归断言覆盖：击毁数只认真击毁（有“漏过的不计入”的对照）、峰值倍率不因受伤清零而回退、结算清空连击并收起顶栏倍率、记录字段逐项与本局值核对、上限裁剪后保留的确实是最新的、记录文件被写坏后坏行被丢弃且新记录照常追加、战报宽高都不溢出。**记录文件的用途是拿真人游玩数据来调难度**，而不是继续用机器人试玩的结果猜。
- 排障过程中踩到并修掉的两个坑：其一，容错读取用了静态的 `JSON.parse_string()`，它在解析失败时会直接往引擎日志写一条 ERROR——容错是我们有意设计的行为，不该在日志里留下像故障的报错，已改为用返回错误码的 JSON 实例 `parse()`；其二，一键启动脚本最初把中文写在 `.bat` 里，cmd.exe 按 ANSI 代码页逐字节解析批处理文件，中文会被拆坏甚至把命令行断错，`chcp 65001` 也救不回已经读进来的行，现改为 `.bat` 只写 ASCII 并转发给 UTF-8 带 BOM 的 `tools/play.ps1`。
- 回归套件已消除对随机抽取的依赖：升级选项是随机抽的，早期版本曾有两条断言会因抽到特定能力而漂移，现已改为夹具测试前统一调用生产代码的 `_reset_upgrades()` 回到基线，并连续多次运行确认结果一致。
- 已实现并验证第 9 节的三项表现类增强：**爆炸粒子**（CPUParticles2D + 内置 GradientTexture2D，零外部图片）在敌机被击毁的位置生成、播完自行释放，并同样遵守跨局票据规则；**受伤屏幕震动**（Camera2D.offset + Tween）立刻产生非零偏移、按时长自动归零、可被 `screen_shake_enabled` 完全关闭，且开局与结算都会清零不留歪画面；**视觉反馈**含击毁白闪、受伤全屏红闪与得分脉冲，三者都是“立刻生效再补间回落”，因此回归断言不必依赖时序侥幸。
- 已实现并验证第 9 节的音频增强：**程序合成的音效与循环背景音乐**。七个 WAV（合计约 469 KB，其中含一段 Boss 登场警告音）由 `tools/generate_audio.py` 只用 Python 标准库生成，固定随机种子、逐字节可复现，因此没有第三方素材与授权问题；音乐走 Music 总线、音效走 SFX 总线（`default_bus_layout.tres`），后者由 6 路音效池播放以避免连射时后一发掐断前一发。
- 音频相关的关键坑都验证过：导入默认 `edit/loop_mode=0`（不循环）与 `compress/mode=2`（QOA 压缩），因此循环必须在运行时开启、循环点必须用“时长 × 采样率”换算而不是拿 `data` 字节数去推；Music 与每一路音效都设 `process_mode = Always`，否则升级抉择暂停整树时音乐与提示音会一起消失。以上都有对应断言。
- 修掉了一个会让流水线偶发失败的退出期竞态：播放器还握着 AudioStream 时退出，Godot 会报 “N resources still in use at exit”。两个测试脚本现在都会先停音频、再放开流引用、多等几帧才退出；修复前 smoke 为 2/12 偶发失败，修复后 smoke 0/14、visual 0/20。
- 三个测试脚本都带看门狗定时器。此前一次改动删掉了 Main 的某个导出属性、测试脚本仍在访问它，GDScript 的运行时不支持 try/catch，协程当场中断、末尾的 `quit()` 永远执行不到，进程一直挂到外层超时，报错只有一条看不出原因的 `TimeoutExpired`。现在超时会打印明确原因并以非零码退出；看门狗上限也刻意设得**明显小于**外层子进程超时，否则超时先由外层触发，日志还停留在上一次运行的内容上，会把人带偏。
- 已实现并验证第 9 节的“更丰富难度”：难度曲线、生成节奏、敌机数值与波次编排全部抽到 `assets/wave_tuning.tres`（脚本 `scripts/WaveTuning.gd`），Main 只读不写。敌机改为**成波出现**：五套编队（随机散开 / 横列铺满 / 两翼夹击）循环播放，一波放完留出波间停顿，每走完一整轮每波再多来几架且封顶。速度、弹速、射击间隔、开火概率、生成间隔全部保留上下限，回归测试逐项验证了夹紧确实生效、波次倍率确实作用在每一架敌机上、以及主程只读参数表（运行时副本另存，避免把共享资源改脏）。
- 已执行真实图形渲染，检查开始、战斗、爆炸特效、**Boss 战**、升级抉择、结算六种界面截图。战斗与升级截图由可复现测试布置敌机/子弹、示例140分与260分历史最高纪录，并经真实升级路径触发面板；Boss 截图走真实登场路径并把机体推到位，能同时看到 Boss 与顶部血条；特效截图特意关掉震动以便看清爆炸本身。以上均用于视觉验收，不是玩家实际战绩。音频为程序合成，听感接近 8-bit，属于可用的占位素材而非成品音源。
- 已实现并验证第 9 节的 Boss：每走完一整轮波次后登场，生命与火力随轮次增长且都有上限；它带入场阶段、横向巡航与扇形齐射三段行为，生命 > 1 所以挨打只扣血、归零才崩解。撞到玩家时它自己不消耗（否则拿机身去撞就能秒掉 Boss）。**它是无限模式下的里程碑，不是通关条件**——文档第 1.1 节写的“无固定通关条件”保持不变；击破后的处理收在 `Main._on_boss_destroyed()` 一个函数里，若要改成“击破即胜利”，只需动这一处。
- 针对“玩久了觉得简单”做了一轮**玩法层**修正（不只是数值）：①**漏敌要付代价**——敌机从底部溜走会清零连击并**永久抬高本局难度压力**（有上限），因为此前漏敌零代价，“躲着不打”是严格最优解；②**连击倍率**——每 5 次连续击毁升一档得分倍率（×1→×5），受伤或漏敌清零，让“打得凶”成为有回报的选择；③**提高基础开火概率** 0.22→0.45，并把瞄准射击从第三波起提前到第一波就有（15% 起步）。三条互补：前两条治“没有目标也没有压力”，第三条治“前几分钟敌人基本不还手”。以上每条都有对应断言。
- 在此之前还做过一次难度重平衡：难度基准上限 12 → 30、每级 15 → 12 秒；同时抬高了 `speed_cap`、`bullet_speed_cap` 与两个 floor。当时的判断是"上限太低导致参数没机会生效"，**但这个诊断只对了一半、后来被证伪**：真正把难度冻住的是**下限触底的等级**（生成间隔在难度 13 触底、射击间隔在 18 触底），与上限无关——把上限从 12 抬到 30 之后，这两个参数照样在十几级后一动不动。**难度上限会随玩家等级继续放宽**（`有效上限 = max_level + (玩家等级 - 1) × max_level_per_player_level`），本意是解决"玩家一直在变强、敌人早就封顶"，但因为上述冻结，这条机制一度形同空转：它发出的高等级里不含任何新增威胁。**Boss 血量改为按玩家当前输出反推**（每秒发数 × `boss_target_seconds`，默认 7 秒）而不是按轮次线性增长，以适配二十多倍的输出跨度。**新增瞄准射击**：一部分敌机改为朝玩家当前位置打（精锐波基础 60%、最高难度封顶 85%）并用紫色区分——这是唯一能制造"必须移动"压力的手段，只堆弹幕密度只会变成"密不透风的下落弹"。玩家侧同步收紧了冗余（护盾延时上限 6→4、紧急清屏 2→1、升级曲线 60/30 → 80/45）。以上每条都有对应断言。
- 已实现并验证**按真人第一局数据做的难度重塑**。那局记录（存活 253.6 秒、难度 25、285 击毁、9 漏敌、峰值倍率 ×5、5 次受伤）先用来交叉验证了难度公式：25 = 1 + int(253.6 / 12) + int(9 × 0.34)，完全吻合。但真正的问题在参数表里：**"线性衰减 + 下限"的写法撞底即冻结**，压力参数分别在难度 11 / 13 / 18 触底，于是那局 L18→L25 的最后 84 秒里所有压力参数都是常数——难度数字在涨、实际威胁一点没变，玩家反馈"中段太顺，像在等死"。修法是给每个间隔类参数补一段**撞底之后的尾巴**（`spawn_interval_tail` / `shoot_interval_tail`：每多出一级再乘一次系数），**线性段逐值保持不变**，因此前中期手感零回归，改的只有尾段。难度 25 处的实际效果约为：生成密度 +24%、射击频率 +16%，合计敌弹压力约 +43%，且此后继续上升而不再冻死。回归断言新增了三条针对性守卫：难度 1~12 的生成间隔必须与线性公式逐值一致（证明前期没被顺手改坏）、难度 20/30/40 必须逐档更密（平台期一旦复发就失败）、射击间隔越过下限后仍须收紧且不会滑到 0。
- 同时修正了 **Boss 的经验收益**：击破额外补的经验从**一整级降为半级**（`boss_xp_levels`）。原因是算出来的——一个 Boss 的总经验收益（奖励分 ×经验倍率 + 一整级）约等于 **100 架普通敌机**，真人第一局里 9 个 Boss 贡献了约 **71%** 的总经验，升级节奏因此由 Boss 的固定排程决定，而不是由"打得多准"决定。半级保留了"熬到 Boss 就能变强"的奖励感，又把主动权还给击毁数。断言按半级逐项算出期望值再比对，并带一条"确实低于旧行为"的对照，避免写死数字在抽到经验倍率能力时误报。
- **一次建立在“删失数据”上的错误分析，以及由此补上的判据。** 第二局真人试玩后，我据其记录得出“玩家跑在曲线前面、需要继续加压”的结论；随后本人说明**两局都是自己主动送死的**——也就是说记录里的“存活 253.6 / 308.5 秒”根本不是“活了多久”，而是“选择玩了多久”，整段推论随之作废。问题在于：对局记录当时只有“存活 N 秒、受伤 M 次”这类汇总数字，**主动送死与被逼死在记录里长得一模一样**，而记录本身没有任何字段能揭示这一点。修法是新增 `hit_times`（每次受伤发生时的生存秒数）：真实玩法下两次受伤至少隔一次无敌时间，所以主动送死的特征很好认——最后几次受伤以约 1 秒的间隔连续出现，而不是几十秒一次。回归测试走真实受伤路径复现“连续送死”，断言时间点挨得极近且被完整写进记录。**结论：分析任何对局数据前先看这个序列**，否则会把“玩家自己结束的对局”当成难度证据。
- 基于长期反馈（而非那两局删失数据）落地的两项参数调整：`level_step_seconds` 12 → 9（曲线提前到达，难度 30 从 348 秒提前到 261 秒）、`aim_ratio_per_level` 0.01 → 0.02（难度 30 时第一波约 73% 的敌机朝玩家位置打）。同时明确记录了一个取舍：瞄准比例有 0.85 的硬上限，属于“前置”杠杆，高瞄准波次会在难度 11~30 陆续撞顶，此后的压力靠间隔尾段与齐射承担。
- **建立了一条“威胁基准”并据此修掉了真正的病因：威胁是在源头被掐死的。** 真人反馈“一点威胁都没有，玩家强度升起来太快”，而我此前几轮一直在**敌人那一侧**加码（密度、速度、开火概率、瞄准比例、难度曲线），方向就错了。新基准量的是两件事：**敌弹通过率**（敌方火力有多少真的穿过玩家弹幕到达玩家面前）与**每架敌机开了几枪**。基线数据（满配 build、玩家全程不动）：难度 30 时 6 秒只生成 45 发敌弹、**每架敌机平均只开 0.69 枪**（按存活时间本该 2~4 枪），通过率却有 65~80%。也就是说拦截弹**不是**瓶颈（我最初怀疑错了），真正的瓶颈是：**玩家每秒 148 发、11 条弹道，把敌机在开火窗口之前就打死了**——密度、速度、开火概率乘的都是“敌机能开几枪”，而那个数已经被压到接近 0，所以怎么调都没用。修法是**齐射**（`volley_every_levels` / `volley_cap` / `volley_spread_degrees`）：难度每高 10 级，敌机一次多打一发（最高 3 发，左右对称散开），把总输出改成由**首发**决定，绕开“活多久”这个被玩家火力支配的变量。修复后同一基准：每架 **{threat_shots_per_enemy}** 发、每秒 **{threat_arrivals}** 发到达（改前 0.69 发 / 3.33 发），通过率 {threat_pass_rate}%。该指标已固化成断言，且**每台战机都必须达标**（最高难度下每架 ≥ 2.5 发、每秒 ≥ 12 发到达）——'
 '形态把平衡面翻了一倍，靠手调守不住，所以把它变成构建级断言。两台当前实测：{threat_per_ship}。**这里还补了一个方法论修正**：门槛原来是 1.5 / 8.0，理由是“容忍抖动”，但干净环境复验时偶发失败——实测最小值恰好是 8.17，下限压在了边缘上。根子不是门槛而是基准本身波动太大（“到达/秒”在 8~19 之间跳，因为出生位置、开火与瞄准判定都走随机数）。于是给基准**固定随机种子**：连跑三次变成 19.83 / 20.33 / 19.83，只剩帧时序带来的零点几。门槛这才敢收回到 2.5 / 12.0——**一个守不住东西的下限等于没有下限**。
- 齐射的回归断言覆盖三件事：发数阶梯与封顶（难度 1/10 为 1 发、11 起 2 发、21 起 3 发、再高也不涨）、一次齐射真的生成 3 颗敌弹且中间一发保持基准方向、左右两发相对基准方向严格对称；另有一条对照，确认**单发敌机的弹道与旧行为逐值一致**（偏移恰好为 0），避免齐射悄悄改掉所有敌人的既有弹道。
- 随后按真人反馈又做了两处**规则与手感**修正，都朝“让威胁真的存在”的方向：① **拦截弹改为一发换一发**——早先击落敌弹后自身继续飞，还被当成优点写进文档；满配时它等于一面无限次拦截的盾。**这里要如实说明**：实测这条对敌弹通过率几乎没有影响（73.5% → 73.9%），因为玩家每秒 148 发对约 20 发敌弹，弹幕怎么都能扫到——它去掉的是免费优势，不是补上威胁。② **玩家子弹出屏即失效**：`play_area_top`（默认 90，取顶部信息栏下沿）成为有效范围上界。这一条修的是一个具体的手感问题——敌机在 y=-48 出生，而顶部色块盖住 0~90，子弹原本一直有效到 y=-48，于是**能在玩家看不见的地方把敌机打死**，表现为“敌人刚露头就没了”；边界取 90 而不是 0，正因为那 90 像素同样被色块挡着。实测这一条把难度 10 处的“每架敌机开火数”从 0.38 抬到 **1.06 发**（+179%）：敌机终于活到了能还手的时候。两处修正的断言都是**成对**写的，防止“只修好一半”——拦截弹一边断言敌弹被击落、一边断言自身也被消耗；出屏失效一边断言栏下的敌机打不到、一边断言露头之后照常打得死。
- 随后完成了一批**视觉收尾**（6 项，都是此前登记过但一直没动的观感问题），并全部补上回归守卫——这类退化不会报任何错，只能靠断言拦：① **升级面板底部约 120 像素空白**：面板原本固定到 y=690，而最常见的 4 选 1 只用到 y=570；现在下沿按“最后一张实际可见卡片 + 26”动态设定，且取的是卡片真实的 `offset_bottom` 而非把几何抄一遍，改卡片高度时面板会自动跟随（断言 4 张与 5 张两种情况都要紧贴）。② **Boss 血条贴住机体**：机体轮廓在中心上方延伸 46 像素，而 `boss_hold_y` 只有 150，顶边 104 正好顶到血条下沿 113；改为 180 后顶边落到 134，留出 21 像素（断言至少 15）。③ **Boss 顶部是一条平直横边**：原 Hull 顶边是 `(44,-40) → (-44,-40)` 一条 88 像素水平线，看着像块板；改成中央尖顶加两侧缺口的轮廓，Plate 与 Core 同步做出内层尖顶（断言顶部至少有三种不同高度）。④ **受伤红闪 0.38 → 0.26**：0.38 时整屏泛红会短暂盖住敌机弹道，而受伤那一下恰恰最需要看清弹幕（断言不超过 0.30）。⑤ **爆炸粒子偏小**：14 粒 / 16px 贴图 / 缩放 0.6~1.5 → 20 粒 / 24px / 0.9~2.4，白光八角形半径 19 → 24（断言粒数与尺寸下限）。⑥ **背景偏素**：`Background` 从纯色 `ColorRect` 换成由内置 `Gradient` + `GradientTexture2D` 程序生成的竖向渐变贴图，航道线从 3 条加密到 5 条并分浓淡两层——依然零外部图片。**六项都用 VisualTest 生成实机截图逐张核对过**，不是只看断言放行。
- **长时浸泡基准：把“长期局会不会越打越卡”从猜测变成数据。** 压力基准只测 6 秒，能证明"瞬时负载在预算内"，证明不了"时间长了会不会变差"；外部评估据此提出过"满配每秒 instantiate/free 上百节点，长期局有 GC 抖动风险"的担忧。新增的 `SoakTest` 让满配玩家连续打满 **{soak_seconds} 秒**（压力基准的十倍），对比前后半段的帧时间与实体峰值：实测 **前半 {soak_first_frame}ms → 后半 {soak_second_frame}ms**（毫无漂移）、早期实体峰值 {soak_early_peak} → 后期 {soak_late_peak}（没有增长）、停火后残留 {soak_residual}、对象净增 {soak_object_growth}。**结论：这条担忧不成立**，对象池依然不做。基准本身也固化成了断言（后半帧不超过前半的 1.25 倍、后期实体峰值不超过早期的 1.3 倍、残留必须为 0、对象净增有上限）。**它的边界也如实写明了**：60 秒仍不是完整的一局（真人一局 2~5 分钟），没有覆盖到那么长。
- 按外部评估里**确实成立**的条目做了四项小修，并逐条补上回归：① **低速模式 + 判定范围**（Shift）：按住移速按 `focus_speed_scale` 降半，并显示**真实碰撞范围**。这里做了一个与评估建议不同的判断——它建议"中心画 2px 红点"，但本作命中盒是 34×42 的矩形而不是一个点，画点会让玩家以为自己更难被击中；所以改为显示真实矩形，且尺寸**直接从碰撞形状推导**，杜绝"提示与判定不符"。② **暂停 + 设置面板**（Esc）：震动开关、音乐/音效音量滑条、继续、重新开始，设置写进 `user://save.cfg` 的 `settings` 节并读回。暂停键由 HUD 处理而不是 Main——Main 是 PAUSABLE，整树一暂停它的输入回调就不再执行，那样就再也按不回来了。③ **逃敌压力的台阶消除**：原先 `int(逃敌压力)` 与 `int(时间)` 各自取整后相加，漏 3 架（+1.02）会在那一瞬间凭空多跳一级；改为把压力累加到时间轴上再取整，漏敌只是把下一次升级提前。④ **`boss_kills` 单独记录**：Boss 仍计入击毁总数（击毁就是击毁），但另存一份，事后分析才能把 1 点血的敌机与多血 Boss 分开。
- **被评估指出、但核对后不成立的条目，也一并记录在案**，避免以后有人照着去修不存在的问题：`Player.gd` 的"monitoring 关闭时仍调 `get_overlapping_areas()`"早就有 `if not invulnerable and monitoring` 守卫（白名单里只有证书那一条，而全部验证日志与引擎日志中该错误零次出现）；"不射击的敌机颜色没赋值"实为设计色——红色按注释就是"不还手"的默认色。此外它引用的 ThreatTest 门槛（1.5 发/架、8 发/秒）是加随机种子之前的旧值，现已收紧到 2.5 / 12.0。
- **实现了“开局选战机”（武器形态分叉）**。评估指出"所有升级都是 +1 条平行直线，build 到后期就是 11 条直线"，这个结构比中途发形态卡更好：形态不进抽卡池、不稀释 16 项能力的抽取，也不会出现"什么都拿一点"导致覆盖形状与输出同时膨胀，还避开了"中途改武器会让前几级投资作废"。当前两台：**标准型**（平行弹幕，基线）与**游隼型**（追踪弹）。战机只改**武器行为与外形**，不碰移速/生命/冷却——两台各自换一套武器，需要验证的组合已经翻倍，再叠加数值取舍就无法干净归因。选择会写进存档，结算页也补了"更换战机"的回路（没有它，READY 只在启动时出现一次，等于战机只能选一次、永远不能改）。
- **追踪弹的平衡过程值得单独记一笔，因为第一次设计被数据推翻了。** 直觉上"追踪 = 命中率高"，于是想用转向速率当成本——**实测发现完全无效**：把转向降到 1.0 rad/s，击毁率仍是 92~96%、敌方弹幕被打到 **0**。原因是结构性的：敌机是朝玩家下来的，只要射程不受限，追踪一定撞得上；而满配每秒 148 发、在飞约 170 发，弹群密度极高，上半屏会被整个清空。真正的支点是**锁定射程**——只在近距离锁定，更远的敌机照直飞。实测曲线（难度 30 的"到达/秒"，门槛 12）：射程 70 → 15.17、**110 → 15.33（采用）**、300 → 6.50、600 → 5.17、不限制 → ~0。断点很陡，所以它是平衡参数而不是手感参数。这台战机的身份也随之定为"打不到远处，只能近程拦阻"。
- **威胁基准因此扩成了遍历全部战机**：形态把平衡面翻了一倍，靠手调守不住，所以"每台战机都必须达标"变成了构建级断言——游隼型第一次跑出来就是 `每架开火 0.00 / 到达每秒 0.00`，直接被拦下。这正是把主观感受变成可回归指标的价值。
- 期间修掉两个**我自己引入**的缺陷：① 指示器在没有锁定目标时被摆到玩家正上方当替身，导致两侧车道的子弹全朝中间拐、弹幕从"一排平行车道"变成"一束"（症状是射程参数怎么改都量出**逐位相同**的结果，说明它根本没参与）；② 战机按钮只靠 `ButtonGroup` 的默认按下态，截图里两台看起来一模一样，改挂深青底白字的 `pressed` 样式才可辨。另外 `const` 里不能写 `PackedVector2Array([...])`（不是常量表达式），改为存 `Vector2` 字面量、运行时转换。
- **一项被评估建议、实测后决定不做**：HUD 每帧刷新的脏标记。做了 A/B：把 `_refresh_hud()` 临时改成空函数再跑压力基准，**平均帧 8.24ms、帧 p99 13.88ms，与开启时完全一致**。省不到东西却会引入"界面不刷新"的回归风险，所以不做——判断依据写在文档里，不是凭直觉否决。
- 压力基准本身也修了两处，都是**结论大于证据**的毛病：① 它原先按写死的 0.3 秒一架补敌机，比游戏在最高难度下的真实刷怪率还稀疏，所以"峰值 Actors 在预算内"这条结论对敌机密度并不成立——现改为直接取 `get_spawn_interval()`，压的是真实密度；② 它原先报"最差帧"，而同一个最大值在四次完全相同的运行里量到 14.21 / 17.13 / 14.21 / **78.85** ms（平均帧稳定在 8.24 ms），已被调度噪声主导，拿它论证"仍在 60 FPS 预算内"是错的证据——现改为报 p99。修正后实测：峰值子弹 **{peak_bullets}** 发、峰值 Actors **{peak_actors}** 个、平均帧 {avg_frame_ms} ms、帧时间 p99 {p99_frame_ms} ms，停火后残留 0。
- 已对第 9 节最后一项“对象池”做了**实测评估，结论是不做**。最坏情况（射速与全部弹道类能力叠满、难度封顶、按住射击打满 6 秒、并按真实刷怪间隔持续补敌机）实测：峰值并发子弹 **{peak_bullets}** 发、峰值 Actors **{peak_actors}** 个、平均帧 {avg_frame_ms} ms、帧时间 p99 {p99_frame_ms} ms、停火后实体全部释放。对象周转远未到需要池化的量级；而池化必须重做 `spent`/`dead` 幂等锁、`run_id` 跨局票据与 `_clear_entities` 这三处最要命的约定，收益为零、风险不小。因此保留 `queue_free`，并把这条基准固化成 `tests/StressTest.gd`——弹幕密度若被改到远超今天的水平，它会先失败并提醒重新评估，而不是等玩家感到卡顿。
- 顺带修掉了一个一直存在、但没有测试覆盖的缺陷：爆炸是帧末延迟生成的，而击杀可能当帧就触发升级抉择把 state 变成 LEVEL_UP，原先的守卫只允许 PLAYING，导致“击杀瞬间触发升级”时**一点爆炸都没有**。Boss 因为给分多必然触发升级，这条路径一定会走到。守卫现在只排除 READY/GAME_OVER。
- 自动化在受限进程沙箱下运行时，引擎会额外打印一条 `Failed to read the root certificate store`（`os_windows.cpp` / `get_system_ca_certificates`）环境诊断；它来自引擎初始化读取 Windows 根证书库，本项目为纯离线原型、不发起 TLS 连接，因此与验收项无关。两个校验脚本已按“消息 + 引擎源码位置”精确放行该诊断，并在日志中原样标注，不放宽任何真实错误的检出。
- 初次回归发现重开后的第一帧可能在monitoring延迟生效前查询重叠；已增加monitoring检查并重新通过全部测试。
- 自动化终端初次缺少APPDATA造成编辑器用户配置目录提示；复验使用项目内隔离测试配置目录，正常桌面启动无需改系统环境变量。
- 未执行跨平台导出和长期手工压力测试；无头回归不等于已经认证所有平台。导出步骤见第8.6节。'''

md = INTRO + source('project.godot', 'ini') + AFTER_PROJECT
for filename in SCENE_NAMES:
    md += source(f'scenes/{filename}.tscn', 'ini')
md += (
    source('assets/ui_theme.tres', 'ini')
    + source('assets/wave_tuning.tres', 'ini')
    + source('default_bus_layout.tres', 'ini')
    + BEFORE_SCRIPTS
)
for filename in SCRIPT_NAMES:
    md += source(f'scripts/{filename}.gd', 'gdscript')
md += '\n### 附：可选开发测试脚本（不影响正式游戏）\n\n这两个文件无需手工复制也能运行游戏；完整项目附带它们供复验。\n'
md += (
    source('tests/SmokeTest.gd', 'gdscript')
    + source('tests/VisualTest.gd', 'gdscript')
    + source('tests/StressTest.gd', 'gdscript')
)
md += AFTER_SCRIPTS.replace('{{TEST_SUMMARY}}', summary)
assert '{{' not in md
(OUT / '飞机大作战-完整开发文档.md').write_text(md, encoding='utf-8')

screens = []
for filename, caption in [
    ('start-preview.png', '01 / 开始界面'),
    ('playing-preview.png', '02 / 战斗测试场景'),
    ('effects-preview.png', '03 / 爆炸与受伤红闪'),
    ('boss-preview.png', '04 / Boss 与血条'),
    ('levelup-preview.png', '05 / 升级抉择界面'),
    ('gameover-preview.png', '06 / 结算界面'),
]:
    data = base64.b64encode((OUT / filename).read_bytes()).decode('ascii')
    screens.append('<figure><img src="data:image/png;base64,' + data + '" alt="' + caption + '"><figcaption>' + caption + '</figcaption></figure>')
nav = ''.join(f'<a href="#section-{number}"><span>{number:02d}</span>{title}</a>' for number, title in enumerate(['项目概览', '目录结构', '输入映射', '碰撞层与遮罩', '场景与资源', '完整脚本', '信号连接', '搭建与导出', '可选增强', '兼容与验证', '最短上手'], 1))
css = '''*{box-sizing:border-box}html{scroll-behavior:smooth;scroll-padding-top:30px}body{margin:0;background:#f5f8fa;color:#243d49;font:16px/1.85 "Microsoft YaHei",system-ui,sans-serif}a{color:#096b83;overflow-wrap:anywhere}aside{position:fixed;inset:0 auto 0 0;width:230px;background:#fff;border-right:1px solid #dce6eb;padding:32px 18px;overflow:auto}aside .brand{font-weight:800;font-size:23px;padding:0 12px;color:#075970}aside .minor{font-size:12px;color:#6e858f;padding:2px 12px 25px}nav a{display:flex;gap:14px;text-decoration:none;padding:8px 12px;border-radius:8px;font-size:14px;color:#375766}nav a:hover{background:#edf6f8}nav span{color:#8da2ac;font:13px/26px monospace}main{max-width:1240px;margin-left:230px;padding:44px 5vw 90px}.hero{background:#fff;border:1px solid #d7e5e9;border-radius:20px;padding:30px;margin-bottom:32px}.eyebrow{letter-spacing:2px;color:#307b8d;font-size:12px}.hero h1{font-size:40px;line-height:1.3;color:#123d50;margin:10px 0}.hero p{color:#65808d;margin:10px 0}.badges{display:flex;flex-wrap:wrap;gap:8px;margin:20px 0}.badges span{background:#ecf6f5;border:1px solid #cae5de;padding:4px 12px;border-radius:20px;font-size:12px;color:#237463}.gallery{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:20px;margin-top:26px}.gallery figure{margin:0}.gallery img{width:100%;border-radius:12px;border:1px solid #d6e2e8;display:block}.gallery figcaption{font-size:12px;color:#65808d;margin-top:6px}article{background:#fff;padding:30px;border:1px solid #dce6eb;border-radius:16px}article>h1{font-size:26px}h2{margin:56px 0 20px;padding-bottom:12px;border-bottom:2px solid #d4e9ef;color:#0a586f;font-size:26px}h3{margin:30px 0 14px;color:#274f61;font-size:19px}p{margin:15px 0}li{margin:7px 0}code{font-family:Consolas,"Microsoft YaHei",monospace;font-size:0.9em;background:#eff4f6;padding:2px 5px;border-radius:4px;overflow-wrap:anywhere}blockquote{border-left:4px solid #67aabd;background:#f0f8fa;margin:20px 0;padding:14px 20px;color:#3c6373;font-size:14px}.tablewrap{overflow-x:auto;margin:20px 0;border:1px solid #dce6eb;border-radius:9px}table{border-collapse:collapse;width:100%;font-size:13px;line-height:1.65;min-width:600px}th,td{text-align:left;padding:12px 14px;vertical-align:top;border-bottom:1px solid #e5edf0}th{background:#eaf4f7;color:#19576c}tr:last-child td{border-bottom:0}tr:nth-child(even){background:#fbfdfe}.codeblock{border:1px solid #d5e2e8;border-radius:10px;overflow:hidden;margin:18px 0 28px}.codebar{display:flex;justify-content:space-between;align-items:center;padding:6px 12px;background:#eaf2f5;font-size:12px;color:#597884}.copy{border:1px solid #b4d0da;border-radius:5px;background:#fff;color:#21657a;padding:5px 10px;cursor:pointer}.copy:hover{background:#dff0f4}pre{margin:0;padding:18px;overflow-x:auto;background:#f8fbfc;color:#183e52;font:13px/1.65 Consolas,"Microsoft YaHei",monospace;tab-size:4}pre code{background:none;padding:0;font-size:inherit;border-radius:0;overflow-wrap:normal}.footer{font-size:12px;color:#7b929c;text-align:center;margin-top:30px}@media(max-width:1000px){aside{display:none}main{margin:0;padding:20px}article{padding:18px}.hero h1{font-size:32px}}@media(max-width:600px){.hero{padding:18px}.gallery{gap:6px}table{min-width:540px}h2{font-size:22px}main{padding:10px}pre{font-size:12px}}@media print{aside,.copy{display:none}main{margin:0;padding:0}body,article{background:white}pre{white-space:pre-wrap}.codeblock{break-inside:auto}.hero{break-after:page}}'''
js = '''document.querySelectorAll('.copy').forEach(button=>button.addEventListener('click',async()=>{const text=button.closest('.codeblock').querySelector('code').textContent;let ok=false;try{await navigator.clipboard.writeText(text);ok=true}catch(error){const area=document.createElement('textarea');area.value=text;document.body.appendChild(area);area.select();ok=document.execCommand('copy');area.remove()}button.textContent=ok?'已复制':'请手动选择代码复制';setTimeout(()=>button.textContent='复制完整代码',1800)}));'''
page = '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>飞机大作战 · Godot 4.7.2 完整开发文档</title><style>' + css + '</style></head><body><aside><div class="brand">FLIGHT SCHOOL</div><div class="minor">GODOT 4.7.2 / 开发手册</div><nav>' + nav + '</nav></aside><main><section class="hero"><div class="eyebrow">BUILD • PLAY • UNDERSTAND</div><h1>飞机大作战</h1><p>从第一架飞机，到一个完整的生存射击原型。</p><div class="badges"><span>Godot 4.7.2 实测</span>' + feature_badge + '<span>最高分本地存档</span><span>等级与能力抉择</span><span>全部源码可复制</span><span>零外部美术依赖</span></div><div class="gallery">' + ''.join(screens) + '</div></section><article>' + render_markdown(md) + '</article><div class="footer">完整源码逐字嵌入 · 离线可读 · 游戏运行请导入 project.godot</div></main><script>' + js + '</script></body></html>'
(OUT / '飞机大作战-完整开发文档.html').write_text(page, encoding='utf-8')

report = '飞机大作战 Godot 4.7.2 验证报告\n\n' + summary + '\n\n完整回归日志\n' + annotate_benign(smoke, ENV_DIAGNOSTIC_NOTE)
(OUT / '验证报告.txt').write_text(report, encoding='utf-8')
archive = OUT / 'PlaneBattle-Godot-4.7.2.zip'
source_files = []
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as bundle:
    for path in sorted(PROJECT.rglob('*')):
        if path.is_file() and '.godot' not in path.relative_to(PROJECT).parts:
            relative = path.relative_to(PROJECT)
            if relative.parts[0] not in ('scenes', 'scripts', 'assets', 'tests') and relative.name not in ROOT_FILES:
                continue
            bundle.write(path, 'PlaneBattle/' + relative.as_posix())
            source_files.append(relative.as_posix())
    for name in ('飞机大作战-完整开发文档.md', '飞机大作战-完整开发文档.html', '验证报告.txt'):
        bundle.write(OUT / name, name)
    # 音频是二进制、无法嵌进文档，所以把生成脚本一并放进包里：
    # 收到交付物的人既能直接用现成 WAV，也能重跑出逐字节相同的文件。
    bundle.write(ROOT / 'tools' / 'generate_audio.py', 'tools/generate_audio.py')

expected = (
    ['project.godot', 'assets/ui_theme.tres', 'assets/wave_tuning.tres', 'default_bus_layout.tres']
    + [f'scenes/{name}.tscn' for name in SCENE_NAMES]
    + [f'scripts/{name}.gd' for name in SCRIPT_NAMES]
)
for name in expected:
    assert name in source_files, f'交付包缺少文件：{name}'
    assert (PROJECT / name).read_text(encoding='utf-8').rstrip() in md, f'文档未逐字嵌入：{name}'

# 回归脚本与 .uid 不进文档，但必须出现在包里。
# .uid 是 Godot 4.4+ 生成的稳定资源标识，官方要求随源码一起提交。早先的版本把它们
# 当缓存排除掉了：工程仍然能跑，但用户第一次导入时目录里会凭空多出这批文件，
# 交付树也就不再等于被验证过的那一棵。
for name in (f'tests/{test}.gd' for test in TEST_NAMES):
    assert name in source_files, f'交付包缺少回归脚本：{name}'
for name in (f'{folder}/{target}.gd.uid'
             for folder, names in (('scripts', SCRIPT_NAMES), ('tests', TEST_NAMES))
             for target in names):
    assert name in source_files, f'交付包缺少 UID 文件：{name}'
assert count_sections(md) == 11, f'文档章节数不对：{count_sections(md)}'
print('Project files:', len(source_files))
print('Guide lines:', len(md.splitlines()))
print(f'All {len(expected)} core files are fully embedded and match source.')
print('11 sections verified.')
print('ZIP SHA256:', hashlib.sha256(archive.read_bytes()).hexdigest())
print('ZIP bytes:', archive.stat().st_size)
