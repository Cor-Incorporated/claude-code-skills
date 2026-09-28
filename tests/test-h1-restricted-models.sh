#!/usr/bin/env bash
# H1: 推定予算は全モデル、無進捗・反復停止は従来のモデル範囲。
# H1_HOOK_UNDER_TEST / H1_LIB_UNDER_TEST で配備済みファイルも同じfixtureで検証。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile, time
root = pathlib.Path(sys.argv[1])
hook = pathlib.Path(os.environ.get('H1_HOOK_UNDER_TEST', root/'hooks/codex/h1-stall-runtime.sh'))
lib = pathlib.Path(os.environ.get('H1_LIB_UNDER_TEST', root/'scripts/lib/h1-runtime.sh'))
checks = 0
with tempfile.TemporaryDirectory(prefix='h1-all-model-') as tmp:
    home = pathlib.Path(tmp)
    ledgerlib = home/'.claude/hooks/lib'
    ledgerlib.mkdir(parents=True)
    (ledgerlib/'aidd-ledger.sh').write_bytes((root/'hooks/lib/aidd-ledger.sh').read_bytes())
    env = {k:v for k,v in os.environ.items() if not k.startswith(('CODEX_H1_', 'H1_'))}
    env.update(HOME=tmp, CODEX_H1_STATE_DIR=str(home/'state'),
               CODEX_H1_SESSIONS_DIR=str(home/'sessions'), AIDD_LEDGER_SOURCE='test',
               AIDD_LEDGER_PATH=str(home/'.claude/hooks/ledger/guard-ledger.jsonl'))
    def check(condition, label):
        global checks
        if not condition: raise AssertionError(label)
        checks += 1
        print('PASS:', label)
    def transcript(sid, model, tokens):
        path = home/(sid+'.jsonl')
        rows = [dict(type='session_meta', payload=dict(id=sid,model=model)),
                dict(type='turn_context',payload=dict(turn_id='old',model=model)),
                dict(type='token_usage_record',payload=dict(response_id=sid+'-old',turn_id='old',
                     usage=dict(input_tokens=tokens, cached_input_tokens=0, output_tokens=0,total_tokens=tokens),
                     thread_token_usage=dict(total_tokens=tokens)))]
        path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
        return path
    def event(key, sid, model, path, kind='PreToolUse', turn='old', prompt='continue', extras=None, cwd=None):
        p=dict(hook_event_name=kind,session_id=sid,model=model,turn_id=turn,
               cwd=cwd or tmp,transcript_path=str(path),tool_name='Bash',tool_input={'command':'pwd'})
        if kind=='UserPromptSubmit': p['prompt']=prompt
        proc=subprocess.run(['bash',str(hook)],input=json.dumps(p),text=True,capture_output=True,
                            env=dict(env,CODEX_H1_DELEGATION=key,**(extras or {})))
        check(proc.returncode==0, key+' hook exit=0')
        return json.loads(proc.stdout or "{}")
    def decision(out): return out.get('hookSpecificOutput',{}).get('permissionDecision','allow')
    def state(key): return json.loads((home/'state'/(key+'.json')).read_text())
    def watchdog(key):
        return subprocess.check_output(['bash','-c','source "$1"; h1_check "$2"','bash',str(lib),key],
                                       env=env,text=True).strip()
    # Use the actual built-in estimates: unknown models 1.25/in, nano 0.05/in.
    for model,exact in [('gpt-6-luna',40000000),('gpt-6-sol',40000000),
                        ('gpt-6-terra',40000000),('future-model',40000000),('',40000000),
                        ('gpt-5-nano',1000000000)]:
        for suffix,tokens,want in [('under',exact-1000,'allow'),('at',exact,'deny'),('over',exact+1000,'deny')]:
            key=(model or 'undetected')+'-'+suffix
            path=transcript(key,model,tokens)
            out=event(key,key,model,path)
            check(decision(out)==want,f'{key}: default $50 {want}')
            s=state(key)
            check(s['budget_usd']==50,key+': default budget=50')
            if model in ('gpt-6-luna','gpt-6-sol'):
                print('OBSERVED',json.dumps(dict(case=key,output=out,state={k:s.get(k) for k in ('model','budget_usd','budget_epoch','budget_epoch_spend_usd','last_block_rule','budget_source')}),ensure_ascii=False))
            check(watchdog(key)==('budget-cap' if want=='deny' else ''),key+': hook/watchdog agree')
    # Wrapper creation/restart shares the $50 contract without clearing usage.
    subprocess.run(['bash','-c','source "$1"; h1_init wrapper "$2"','bash',str(lib),tmp],
                   env=env,check=True)
    check(state('wrapper')['budget_usd']==50,'wrapper default budget=50')
    old=state('wrapper')
    old.update(budget_usd=25,spend_usd=30,budget_epoch_spend_usd=30,
               budget_epoch=2,last_block_rule='budget-cap',tool_calls=7)
    (home/'state/wrapper.json').write_text(json.dumps(old))
    subprocess.run(['bash','-c','source "$1"; h1_init wrapper "$2"','bash',str(lib),tmp],
                   env=env,check=True)
    check(state('wrapper')['budget_usd']==50,'wrapper restart refreshes budget=50')
    check(all(state('wrapper')[k]==old[k] for k in ('spend_usd','budget_epoch_spend_usd',
              'budget_epoch','last_block_rule','tool_calls')),'wrapper restart preserves history and epoch')
    check(watchdog('wrapper')=='','raising cap is not a stale last-block denial')
    # Missing transcripts still carry a labeled proxy estimate, including model not detected.
    out=event('proxy','proxy','',home/'missing.jsonl',extras={'CODEX_H1_PROXY_TOKENS_PER_CALL':'40000000'})
    check(decision(out)=='deny','undetected-model proxy at $50 denies')
    check(state('proxy')['budget_source'].startswith('proxy:'),'proxy remains visibly estimated')
    # The installed hook must no longer exempt the former exhibition project.
    for name in ('kotoba-robocon','nfc-profile-card'):
        key='project-'+name
        path=transcript(key,'gpt-6-sol',40000000)
        out=event(key,key,'gpt-6-sol',path,cwd='/Users/teradakousuke/Developer/'+name)
        check(decision(out)=='deny',name+': default $50 denies without project relief')
        check(state(key)['budget_usd']==50,name+': project budget matches default')
    for key,tokens in [('warn-below',31999000),('warn-at',32000000)]:
        path=transcript(key,'gpt-6-sol',tokens)
        check(decision(event(key,key,'gpt-6-sol',path))=='allow',key+': below-cap warning cannot deny')
        check(bool(state(key)['last_warn_80'])==(key=='warn-at'),key+': 80% warning boundary')
    # Session or model change alone cannot reset a stopped delegation.
    for transition in ('session','model'):
        key='transition-'+transition
        path=transcript(key,'gpt-6-sol',41000000)
        check(decision(event(key,'old','gpt-6-sol',path))=='deny',key+': old epoch stopped')
        sid='new' if transition=='session' else 'old'
        model='gpt-6-sol' if transition=='session' else 'gpt-6-luna'
        check(decision(event(key,sid,model,path))=='deny',key+': transition alone denies')
        check(state(key)['budget_epoch']==0,key+': transition alone keeps epoch')
        # Missing IDs, quoted or negated text cannot authorize reset.
        for turn,prompt in [('', 'continue'),('quote','"continue"'),('negate','do not continue')]:
            event(key,sid,model,path,'UserPromptSubmit',turn,prompt)
            check(state(key)['budget_epoch']==0,key+': invalid resume keeps epoch')
        event(key,'',model,path,'UserPromptSubmit','missing-session','continue')
        check(state(key)['budget_epoch']==0,key+': missing session cannot grant')
        event(key,sid,model,path,'UserPromptSubmit','resume','作業を続けて下さい')
        check(state(key)['budget_epoch']==1,key+': explicit resume grants one epoch')
        check(state(key)['last_block_rule']=='budget-cap',key+': stop history preserved')
        event(key,sid,model,path,'UserPromptSubmit','resume','作業を続けて下さい')
        check(state(key)['budget_epoch']==1,key+': repeated turn is idempotent')
        check(decision(event(key,sid,model,path,turn='resume'))=='allow',key+': new epoch allows')
        check(watchdog(key)=='',key+': watchdog allows new epoch')
        event(key,sid,model,path,'UserPromptSubmit','same-scope','continue')
        check(state(key)['budget_epoch']==1,key+': same scope continuation cannot regrant')
    # The budget scope fills in on the first non-empty observation. A first
    # PreToolUse without a session ID or model must not pin an empty scope that
    # later blocks an explicit resume after a real transition (Codex review, 2026-09-28).
    for missing in ('session','model'):
        key='late-scope-'+missing
        path=transcript(key,'' if missing=='model' else 'gpt-6-sol',41000000)
        event(key,'' if missing=='session' else 'old','' if missing=='model' else 'gpt-6-sol',path)
        check(decision(event(key,'old','gpt-6-sol',path))=='deny',key+': cap reached with known ids')
        sid='new' if missing=='session' else 'old'
        model='gpt-6-luna' if missing=='model' else 'gpt-6-sol'
        check(decision(event(key,sid,model,path))=='deny',key+': transition alone denies')
        event(key,sid,model,path,'UserPromptSubmit','resume','作業を続けて下さい')
        check(state(key)['budget_epoch']==1,key+': explicit resume after a late scope grants one epoch')
    # A resume prompt without a model leaves the new scope's model unconfirmed. The
    # first real observation confirms it, so a second resume in the same session and
    # model cannot pass as a model change and grant another epoch (#402).
    key='nomodel-resume'
    old_path=transcript(key,'gpt-6-sol',41000000)
    check(decision(event(key,'old','gpt-6-sol',old_path))=='deny',key+': old session reaches the cap')
    new_path=transcript(key+'-new','gpt-6-luna',1000)
    event(key,'new','',new_path,'UserPromptSubmit','resume','作業を続けて下さい')
    check(state(key)['budget_epoch']==1,key+': session change with resume grants one epoch')
    check(decision(event(key,'new','gpt-6-luna',new_path,turn='resume'))=='allow',key+': new epoch allows')
    event(key,'new','gpt-6-luna',new_path,'UserPromptSubmit','resume-again','作業を続けて下さい')
    check(state(key)['budget_epoch']==1,key+': same session and model cannot regrant')
    # The pending scope is confirmed only by a model attributable to the current turn
    # (the hook payload). A model read from an older transcript turn must not pin it
    # and later pass as a model change (Codex review of #403).
    def transcript_with_total(sid, model, tokens):
        # Rollouts that carry total_token_usage make measure_spend() read the model
        # from the latest "model" string in the file, which can be an older turn's.
        path = home/(sid+'.jsonl')
        rows = [dict(type='session_meta', payload=dict(id=sid,model=model)),
                dict(type='turn_context',payload=dict(turn_id='old',model=model)),
                dict(type='event_msg',payload=dict(type='token_count',info=dict(total_token_usage=dict(
                     input_tokens=tokens, cached_input_tokens=0, output_tokens=0, total_tokens=tokens))))]
        path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
        return path
    key='pending-payload-only'
    old_path=transcript(key,'gpt-6-sol',41000000)
    check(decision(event(key,'old','gpt-6-sol',old_path))=='deny',key+': old session reaches the cap')
    new_path=transcript_with_total(key+'-new','gpt-6-luna',1000)
    event(key,'new','',new_path,'UserPromptSubmit','resume','作業を続けて下さい')
    check(state(key)['budget_epoch']==1,key+': session change with resume grants one epoch')
    check(decision(event(key,'new','',new_path,turn='resume'))=='allow',key+': tool call without a payload model allows')
    check(state(key).get('budget_scope_model_pending') is True,key+': transcript-only model does not confirm the scope')
    event(key,'new','gpt-6-sol',new_path,'UserPromptSubmit','resume-again','作業を続けて下さい')
    check(state(key)['budget_epoch']==1,key+': transcript-only model cannot evidence a model change')
    # Without a session ID or delegation, separate runs keep separate state (keyed by
    # transcript) instead of pooling into default.json and sharing one budget (#402).
    # A late PreToolUse from the old session (same delegation) must not confirm the
    # new session's pending scope with its own model (Codex review of #403).
    key='pending-other-session'
    old_path=transcript(key,'gpt-6-sol',41000000)
    check(decision(event(key,'old','gpt-6-sol',old_path))=='deny',key+': old session reaches the cap')
    new_path=transcript(key+'-new','gpt-6-sol',1000)
    event(key,'new','',new_path,'UserPromptSubmit','resume','作業を続けて下さい')
    check(state(key)['budget_epoch']==1,key+': session change with resume grants one epoch')
    event(key,'old','gpt-6-luna',old_path,turn='late')
    check(state(key).get('budget_scope_model_pending') is True,key+': another session cannot confirm the scope')
    event(key,'new','gpt-6-sol',new_path,'UserPromptSubmit','resume-again','作業を続けて下さい')
    check(state(key)['budget_epoch']==1,key+': unchanged model in the resumed session cannot regrant')
    # A model-bearing prompt from the resumed session confirms a scope left pending
    # by model-less payloads; otherwise a later authorized model change could never
    # reset the epoch (Codex review of #403, round 4).
    key='pending-prompt-confirm'
    old_path=transcript(key,'gpt-6-sol',41000000)
    check(decision(event(key,'old','gpt-6-sol',old_path))=='deny',key+': old session reaches the cap')
    new_path=transcript(key+'-new','',1000)
    event(key,'new','',new_path,'UserPromptSubmit','resume','作業を続けて下さい')
    check(state(key)['budget_epoch']==1,key+': session change with resume grants one epoch')
    event(key,'new','',new_path,turn='resume')
    event(key,'new','gpt-6-sol',new_path,'UserPromptSubmit','status','進捗を教えて')
    s=state(key)
    check(s.get('budget_scope_model')=='gpt-6-sol' and not s.get('budget_scope_model_pending'),
          key+': a model-bearing prompt from the resumed session confirms the scope')
    event(key,'new','gpt-6-luna',new_path,'UserPromptSubmit','switch','作業を続けて下さい')
    check(state(key)['budget_epoch']==2,key+': a later authorized model change still grants an epoch')
    def event_without_ids(label, model, path):
        p=dict(hook_event_name='PreToolUse',session_id='',model=model,turn_id='old',
               cwd=tmp,transcript_path=str(path),tool_name='Bash',tool_input={'command':'pwd'})
        run_env={k:v for k,v in env.items() if k!='CODEX_H1_DELEGATION'}
        proc=subprocess.run(['bash',str(hook)],input=json.dumps(p),text=True,capture_output=True,env=run_env)
        check(proc.returncode==0, label+' hook exit=0')
        return json.loads(proc.stdout or "{}")
    # Documented limitation (#402, #403): runs with neither a session ID nor a
    # delegation share default.json and one budget, failing closed. Splitting them
    # by transcript_path let a run escape its cap whenever the key changed, so it was
    # reverted. Pin the pooled behavior so a change that splits the state fails here.
    first=transcript('noid-a','gpt-6-luna',30000000)
    check(decision(event_without_ids('noid-a','gpt-6-luna',first))=='allow','noid-a: first run under the cap is allowed')
    second=transcript('noid-b','gpt-6-luna',30000000)
    check(decision(event_without_ids('noid-b','gpt-6-luna',second))=='deny',
          'noid-b: runs without ids share one budget and fail closed')
    check((home/'state'/'default.json').exists(),'runs without ids use default.json')
    # RESTRICTED_MODELS cannot exempt any model from the budget cap.
    path=transcript('not-exempt','gpt-6-luna',41000000)
    check(decision(event('not-exempt','luna','gpt-6-luna',path,extras={'CODEX_H1_RESTRICTED_MODELS':'terra'}))=='deny',
          'restricted-model override cannot exempt budget')
    # Preserve existing non-budget model gating (including watchdog).
    for model,want in [('gpt-6-luna','allow'),('gpt-6-sol','deny')]:
        key='nonbudget-'+model
        path=transcript(key,model,1000)
        event(key,key,model,path)
        s=state(key)
        s.update(iterations=11, last_progress_ts=int(time.time())-4000,
                 watchdog_started_ts=0, same_cmd_streak=3)
        (home/'state'/(key+'.json')).write_text(json.dumps(s))
        out=event(key,key,model,path)
        check(decision(out)==want,key+': no-progress scope unchanged')
        check(watchdog(key)==('no-progress-timeout' if want=='deny' else ''),key+': watchdog scope unchanged')
    ledger=home/'.claude/hooks/ledger/guard-ledger.jsonl'
    rows=[json.loads(line) for line in ledger.read_text().splitlines()]
    luna=[r for r in rows if r.get('event')=='block' and r.get('subject',{}).get('model')=='gpt-6-luna']
    check(bool(luna),'Luna budget denial reaches isolated H1 ledger')
    check(all(r['subject']['budget_restricted'] and not r['subject']['restricted'] for r in luna),
          'ledger distinguishes universal budget from other model restriction')
    # A stop made only by the wrapper watchdog must carry the same scope fields.
    def stop_record(key, rule):
        out = subprocess.check_output(['bash','-c','source "$1"; h1_stop_record "$2" "$3"','bash',str(lib),key,rule],
                                      env=env,text=True).strip()
        return json.loads(out)['subject']
    luna_stop = stop_record('not-exempt', 'budget-cap')
    check(luna_stop.get('model')=='gpt-6-luna', 'wrapper stop record carries model')
    check(luna_stop.get('budget_restricted') is True and luna_stop.get('restricted') is False,
          'wrapper stop record distinguishes universal budget from model restriction')
    check('budget_epoch_spend_usd' in luna_stop, 'wrapper stop record carries epoch spend')
    sol_stop = stop_record('nonbudget-gpt-6-sol', 'no-progress-timeout')
    check(sol_stop.get('restricted') is True, 'wrapper stop record marks restricted models')
print(f'--- {checks} passed, 0 failed ---')
PY
