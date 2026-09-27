#!/usr/bin/env bash
# Counter snapshots belong to transcript streams, not the shared delegation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT/hooks/codex/h1-stall-runtime.sh" <<'PY'
import ast, copy, json, pathlib, sys, tempfile

hook = pathlib.Path(sys.argv[1]).read_text()
code = hook.split("python3 - <<'PY'", 1)[1].split("\nPY\n", 1)[0].split("\n", 1)[1]
tree = ast.parse(code)
tree.body = [node for node in tree.body if not (
    isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
    and isinstance(node.value.func, ast.Name) and node.value.func.id == 'main'
)]
ns = {}
exec(compile(tree, str(sys.argv[1]), 'exec'), ns)
ns['PAYLOAD_MODEL'] = 'gpt-5-codex'
ns['SID'] = 'delegation'
keys = ('input_tokens', 'cached_input_tokens', 'output_tokens', 'total_tokens')
def usage(inp, out=0, cached=0):
    return dict(zip(keys, (inp, cached, out, inp + out)))
def event(total, last=None):
    info = {'total_token_usage': total}
    if last is not None: info['last_token_usage'] = last
    return {'type': 'event_msg', 'payload': {'type': 'token_count', 'info': info}}
def record(rid, value, thread):
    return {'type': 'token_usage_record', 'payload': {
        'response_id': rid, 'turn_id': 'turn', 'usage': value,
        'thread_token_usage': {'total_tokens': thread}}}
def append(path, *rows):
    with path.open('a') as f:
        for row in rows: f.write(json.dumps(row) + '\n')
def tick(state, path):
    state['tool_calls'] = state.get('tool_calls', 0) + 1
    ns['find_rollout'] = lambda _started: path
    rows = ns['usage_records'](path, state)
    ns['apply_meter'](state, rows, ns['measure_spend'](state['tool_calls'], 0, state))
def check(name, actual, expected):
    assert actual == expected, (name, actual, expected)
    print('PASS:', name)

with tempfile.TemporaryDirectory() as folder:
    worker, fork = [pathlib.Path(folder) / (name + '.jsonl') for name in ('worker', 'fork')]
    append(worker, record('worker-1', usage(1000), 1000), event(usage(1000), usage(1000)))
    state = {'spend_usd': 0.0, 'started_ts': 0}
    tick(state, worker)
    before = state['spend_usd']
    # NFC stream shape: the inherited event and record lifetime counters have
    # different offsets. Neither can be compared with the worker's 1000 total.
    first = usage(77707, 312, 22144)
    inherited = usage(107868139, 208701, 106687872)
    append(fork, {'type': 'session_meta', 'payload': {'forked_from_id': 'parent'}},
           record('fork-1', first, 109080013), event(inherited, first))
    tick(state, fork)
    cost = ns['usd_from'](first, 'gpt-5-codex')[0]
    check('new fork stream excludes inherited event count', round(state['spend_usd']-before, 6), cost)
    check('thread total is not an event snapshot', state['usage_snapshot']['total_tokens'], 108076840)
    before = state['spend_usd']
    tick(state, worker)
    check('returning to unchanged stream does not recharge', state['spend_usd'], before)
    missing = usage(1000000)
    append(worker, event(usage(1001000), missing))
    tick(state, worker)
    check('unrecorded usage on restored stream stays billed', round(state['spend_usd']-before, 6), 1.25)
    before = state['spend_usd']
    tick(state, fork)
    check('returning to inherited stream restores its snapshot', state['spend_usd'], before)
    append(fork, record('fork-1', first, 109080013))
    tick(state, fork)
    check('response id is charged once across stream switches', state['spend_usd'], before)
    # First event may appear later than an already billed response record.
    delayed = pathlib.Path(folder) / 'delayed.jsonl'
    append(delayed, {'type': 'session_meta', 'payload': {'forked_from_id': 'parent'}},
           record('delayed-1', usage(2000), 9002000))
    tick(state, delayed)
    before = state['spend_usd']
    append(delayed, event(usage(8002000), usage(2000)))
    tick(state, delayed)
    check('late first event does not recharge the first record', state['spend_usd'], before)
    # Multiple events in a new stream must use the earliest baseline, not the
    # last event minus last response, which would silently discard missing use.
    multi = pathlib.Path(folder) / 'multi.jsonl'
    append(multi, {'type': 'session_meta', 'payload': {'forked_from_id': 'parent'}},
           event(usage(6001000), usage(1000)), event(usage(7001000), usage(1000000)))
    before = state['spend_usd']
    tick(state, multi)
    check('all unrecorded usage after first event is billed', round(state['spend_usd']-before, 6), 1.25125)

    # Cumulative-only mode must also take its first baseline from its own
    # stream, never from the shared delegation snapshot or an absolute parent
    # total. This is the no-record fallback used by older rollout files.
    plain = pathlib.Path(folder) / 'plain.jsonl'
    plain_fork = pathlib.Path(folder) / 'plain-fork.jsonl'
    append(plain, event(usage(1001000), usage(1000)))
    cumulative = {'spend_usd': 0.0, 'started_ts': 0}
    tick(cumulative, plain)
    check('cumulative-only first stream charges its local delta', cumulative['spend_usd'], 0.00125)
    append(plain_fork, {'type': 'session_meta', 'payload': {'forked_from_id': 'parent'}},
           event(usage(2001000), usage(1000)))
    tick(cumulative, plain_fork)
    check('cumulative-only fork charges its own delta', cumulative['spend_usd'], 0.0025)

    unknown = pathlib.Path(folder) / 'unknown-baseline.jsonl'
    append(unknown, event(usage(500000000)))
    unknown_state = {'spend_usd': 0.0, 'started_ts': 0}
    tick(unknown_state, unknown)
    check('missing stream baseline does not price inherited lifetime', unknown_state['spend_usd'], 0.0)
    check('missing stream baseline is labeled', 'stream-baseline-unavailable' in unknown_state['budget_source'], True)
print('--- 12 passed, 0 failed ---')
PY
