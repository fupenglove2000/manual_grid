"""汇总 run_compare.ps1 的各组回测：解析 logs/cmp_*/agent.log 里 GridEA_bt 打印的
BTSTAT / BTSTARTS / BTSTOPS 和开网格、拒绝行，输出 Markdown 表格。
用法：python -I compare_summary.py [--out=文件]
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REASONS = {
    '1': '硬止损(价格)', '2': '硬止损(成交)', '5': '周五平仓', '6': '补执行周五平仓', '9': '请求数上限',
    '22': '拒绝:价格已越过止损', '23': '拒绝:周末/开盘前', '24': '拒绝:当天已止损', '26': '拒绝:最小手数',
    '27': '拒绝:区间太窄',
}


def read_text(path):
    with open(path, 'rb') as f:
        raw = f.read()
    for enc in ('utf-8-sig', 'utf-16'):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            pass
    return raw.decode('utf-8', 'replace')


def parse_group(name):
    m = re.match(r'cmp_(\w)_r(\d+)_(long|short)_fri(\d)_(s\d)$', name)
    if not m:
        return None
    rng, risk, d, fri, start = m.groups()
    return {
        'range': rng, 'risk': int(risk) / 100.0, 'dir': d, 'fri': fri == '1', 'start': start,
    }


def parse_log(path):
    text = read_text(path)
    res = {'stat': None, 'starts': '', 'stops': '', 'opens': [], 'refuse': []}
    for line in text.splitlines():
        msg = line.split('\t')[-1]
        if 'BTSTAT ' in msg:
            kv = msg.split('BTSTAT ', 1)[1].split()
            res['stat'] = dict(x.split('=', 1) for x in kv if '=' in x)
        elif 'BTSTARTS ' in msg:
            res['starts'] = msg.split('BTSTARTS ', 1)[1].strip()
        elif 'BTSTOPS ' in msg:
            res['stops'] = msg.split('BTSTOPS ', 1)[1].strip()
        elif '开网格 ' in msg and '｜' in msg:
            res['opens'].append(msg.strip())
        elif '拒绝开网格：' in msg and '周末' not in msg:
            res['refuse'].append(msg.strip())
    return res


def money(v):
    return '{:+,.0f}'.format(v) if abs(v) >= 0.5 else '0'


def actual_risk(open_line):
    """开网格那一行里的手数按 0.01 取整后，全部成交并打到硬止损的总亏损（XAUUSD 1 手 = 100 盎司）"""
    m = re.search(r'开网格 (做多|做空) ([\d.]+)-([\d.]+) .*?格距([\d.]+)=.*?止损([\d.]+)｜((?:G\d+ [\d.]+ ?)+)｜', open_line)
    if not m:
        return None
    lower, step, sl = float(m.group(2)), float(m.group(4)), float(m.group(5))
    total = 0.0
    for k, lots in re.findall(r'G(\d+) ([\d.]+)', m.group(6)):
        total += float(lots) * abs(lower + int(k) * step - sl) * 100
    return total


def main():
    out = None
    for a in sys.argv[1:]:
        if a.startswith('--out='):
            out = a[6:]
    rows = []
    for path in sorted(glob.glob(os.path.join(HERE, 'logs', 'cmp_*', 'agent.log'))):
        name = os.path.basename(os.path.dirname(path))
        g = parse_group(name)
        if not g:
            continue
        r = parse_log(path)
        r.update(g)
        r['name'] = name
        rows.append(r)

    lines = []
    w = lines.append
    for rng, title in (('c', '核心震荡区间 4066.30～4225.38'), ('w', '全段影线最高 / 最低 4021.00～4275.05')):
        sel = [r for r in rows if r['range'] == rng]
        if not sel:
            continue
        w('## ' + title)
        w('')
        w('| # | 风险 | 方向 | 周五平仓 | 开始 | 格数·格距 | 实际总风险 | 已实现净盈亏 | 期末浮动 | 合计 | 止盈次数 | 周五平仓已实现 | 隔夜利息 | 手续费 | 最大浮亏 | 单日最大亏损 | 暂缓 | 硬止损 | 重开 |')
        w('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
        sel.sort(key=lambda r: (r['start'], r['risk'], r['dir'] != 'long', not r['fri']))
        for i, r in enumerate(sel, 1):
            s = r['stat']
            base = '| {} | {:.2g}% | {} | {} | {} |'.format(
                i, r['risk'], '做多' if r['dir'] == 'long' else '做空', '开' if r['fri'] else '关',
                '①9-28' if r['start'] == 's1' else '②10-15')
            if not s:
                w(base + ' 没有统计行 |' + ' |' * 13)
                continue
            if not r['starts'] or r['starts'] == '-':
                why = r['refuse'][0].split('拒绝开网格：', 1)[1] if r['refuse'] else '见日志'
                w(base + ' 未开出网格：{} |'.format(why[:60]) + ' |' * 13)
                continue
            first = r['starts'].split()[0].split('_')
            nstep = '{}格·{}'.format(first[2][1:], first[3][4:])
            ar = actual_risk(r['opens'][0]) if r['opens'] else None
            nstep += ' | {}'.format('{:,.0f}'.format(ar) if ar is not None else '-')
            realized = float(s['realized'])
            endf = float(s['endFloat'])
            sl = '是 ' + s['firstSl'].replace('_', ' ') if int(s['slN']) > 0 or '_RS1' in r['stops'] else '否'
            w(base + ' {} | {} | {} | **{}** | {} | {}（{}笔） | {} | {} | {}（{}） | {}（{}） | {} | {} | {} |'.format(
                nstep, money(realized), money(endf), money(realized + endf), s['tpN'],
                money(float(s['friP'])), s['friN'], money(float(s['swap'])), '{:+.2f}'.format(float(s['comm'])),
                money(float(s['minFloat'])), s['minFloatT'].replace('_', ' '),
                money(-float(s['maxDayLoss'])), s['maxDayLossD'].split('_')[0],
                s['defers'], sl, s['restarts']))
        w('')
        w('开 / 停记录：')
        w('')
        for i, r in enumerate(sel, 1):
            stops = ' '.join('{}:{}'.format(x.rsplit('_RS', 1)[0].replace('_', ' '), REASONS.get(x.rsplit('_RS', 1)[1], x))
                             for x in r['stops'].split() if '_RS' in x)
            w('- #{} {}：开网格 {}；停止 {}'.format(i, r['name'], r['starts'].replace('_', ' '), stops or '-'))
        w('')

    # 成对比较（只比较两边都开出网格的组）
    def total(r):
        s = r['stat']
        if not s or not r['starts'] or r['starts'] == '-':
            return None
        return float(s['realized']) + float(s['endFloat'])

    core = [r for r in rows if r['range'] == 'c']
    idx = {(r['risk'], r['dir'], r['fri'], r['start']): r for r in core}
    pairs = [
        ('① 9-28 开始 vs ② 10-15 开始', lambda k: (k[0], k[1], k[2], 's1'), lambda k: (k[0], k[1], k[2], 's2'),
         lambda k: '{:.2g}% {} 周五平仓{}'.format(k[0], '做多' if k[1] == 'long' else '做空', '开' if k[2] else '关')),
        ('做多 vs 做空', lambda k: (k[0], 'long', k[2], k[3]), lambda k: (k[0], 'short', k[2], k[3]),
         lambda k: '{:.2g}% 周五平仓{} {}'.format(k[0], '开' if k[2] else '关', '①' if k[3] == 's1' else '②')),
        ('周五平仓 开 vs 关', lambda k: (k[0], k[1], True, k[3]), lambda k: (k[0], k[1], False, k[3]),
         lambda k: '{:.2g}% {} {}'.format(k[0], '做多' if k[1] == 'long' else '做空', '①' if k[3] == 's1' else '②')),
        ('总风险 0.5% vs 0.75%', lambda k: (0.5, k[1], k[2], k[3]), lambda k: (0.75, k[1], k[2], k[3]),
         lambda k: '{} 周五平仓{} {}'.format('做多' if k[1] == 'long' else '做空', '开' if k[2] else '关', '①' if k[3] == 's1' else '②')),
    ]
    w('## 成对比较（核心区间，合计 = 已实现 + 期末浮动）')
    w('')
    for title, fa, fb, label in pairs:
        seen = set()
        w('### ' + title)
        w('')
        w('| 条件 | 前者 | 后者 | 差（前 − 后） |')
        w('|---|---|---|---|')
        for k in sorted(idx):
            a, b = idx.get(fa(k)), idx.get(fb(k))
            key = (fa(k), fb(k))
            if not a or not b or key in seen:
                continue
            seen.add(key)
            ta, tb = total(a), total(b)
            fmt = lambda v: money(v) if v is not None else '未开出'
            diff = money(ta - tb) if ta is not None and tb is not None else '-'
            w('| {} | {} | {} | {} |'.format(label(k), fmt(ta), fmt(tb), diff))
        w('')
    text = '\n'.join(lines) + '\n'
    if out:
        with open(out, 'w', encoding='utf-8') as f:
            f.write(text)
        print('written', out, len(rows))
    else:
        sys.stdout.buffer.write(text.encode('utf-8'))


if __name__ == '__main__':
    main()
