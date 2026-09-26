local factory=dofile('mod/agent-harness_0.1.0/scheduler.lua')
game={tick=0}
local state,active,combat,calls={},{},{},{}
local players={[1]={index=1}}
local handlers={
  walk=function(p,a) active[p.index]=game.tick+(a.ticks or 3); calls[#calls+1]='walk'; return {accepted=true} end,
  shoot=function(p,a) combat[p.index]=game.tick+(a.ticks or 5); calls[#calls+1]='shoot'; return {} end,
  craft=function() calls[#calls+1]='craft'; return {started=1} end,
  broken=function() error('fixture failure') end,
}
local function stop(p) active[p.index]=nil; combat[p.index]=nil end
local scheduler=factory{
  state=function() return state end,
  player=function(i) assert(players[i],'player unavailable'); return players[i] end,
  handlers=handlers,
  busy=function(p,action) return action=='shoot' and combat[p.index]~=nil or action=='walk' and active[p.index]~=nil end,
  stop=stop,stop_index=function(i) active[i]=nil;combat[i]=nil end,
}
local h=scheduler.handlers
local p=players[1]
local assertions=0
local function check(condition) assertions=assertions+1; assert(condition,'assertion '..assertions) end
local function tick()
  game.tick=game.tick+1
  for i,expiry in pairs(active) do if game.tick>=expiry then active[i]=nil end end
  for i,expiry in pairs(combat) do if game.tick>=expiry then combat[i]=nil end end
  scheduler.tick()
end
local q=h.queue_submit(p,{steps={{action='shoot',args={ticks=8},wait=false},{action='walk',args={ticks=3}},{action='craft'}}})
check(#q.pending==3)
tick(); check(combat[1] and active[1]); check(#calls==2)
tick(); tick(); check(#calls==2)
tick(); check(calls[3]=='craft'); check(combat[1]~=nil)
q=h.queue_status(p); check(#q.history==3 and not q.active)
-- Edit only pending steps and reject stale revisions before side effects.
q=h.queue_submit(p,{steps={{action='wait_ticks',args={ticks=10}},{action='craft'}}})
tick(); q=h.queue_status(p)
local revision=q.revision
check(not pcall(h.queue_edit,p,{expected_revision=revision-1,index=1,remove=1,steps={}}))
check(h.queue_status(p).active.action=='wait_ticks')
q=h.queue_edit(p,{expected_revision=revision,index=1,remove=1,steps={{action='walk'}}})
check(#q.pending==1 and q.pending[1].action=='walk')
q=h.queue_cancel(p,{clear=false})
check(q.paused and not q.active and #q.pending==1)
check(not active[1] and not combat[1])
tick(); check(not active[1])
h.queue_resume(p,{}); tick(); check(active[1]~=nil)
h.queue_cancel(p,{})
-- A failed step pauses, leaves later work untouched, and records evidence.
h.queue_submit(p,{steps={{action='broken'},{action='craft'}}})
tick(); q=h.queue_status(p)
check(q.paused and #q.pending==1)
check(q.history[#q.history].ok==false)
check(q.history[#q.history].result.reason:find('fixture failure')~=nil)
h.queue_cancel(p,{})
-- Instant work is bounded per tick.
local steps={}; for i=1,10 do steps[i]={action='craft'} end
h.queue_submit(p,{steps=steps});tick();q=h.queue_status(p)
check(#q.pending==6)
-- Invalid whole plans must not partially append.
local count=#q.pending
check(not pcall(h.queue_submit,p,{steps={{action='craft'},{action='unknown'}}}))
check(#h.queue_status(p).pending==count)
check(not pcall(h.queue_submit,p,{steps={{action='queue_submit'}}}))
check(not pcall(h.queue_submit,p,{steps={{action='wait_ticks',args={ticks=-1}}}}))
-- Death/disappearance pauses instead of continuing mutations.
players[1]=nil;tick();check(h.queue_status(p).paused)
-- Large blueprint-like payloads are bounded across successive submissions.
h.queue_cancel(p,{})
h.queue_submit(p,{steps={{action='craft',args={payload=string.rep('x',600000)}}}})
check(not pcall(h.queue_submit,p,{steps={{action='craft',args={payload=string.rep('x',600000)}}}}))
check(#h.queue_status(p).pending==1)
players[1]=p
h.queue_cancel(p,{})
local before=#calls
h.queue_repeat(p,{steps={{action='craft'}},interval_ticks=60})
for _=1,65 do tick() end
q=h.queue_status(p)
check(q.repeating and q.cycle==2 and #calls==before+2)
h.queue_cancel(p,{clear=false})
for _=1,70 do tick() end
check(#calls==before+2 and h.queue_status(p).repeating)
h.queue_resume(p,{}); tick(); check(#calls==before+3)
h.queue_cancel(p,{})
check(not h.queue_status(p).repeating)
h.queue_repeat(p,{steps={{action='broken'},{action='craft'}},interval_ticks=60})
tick(); check(h.queue_status(p).paused)
before=#calls
for _=1,70 do tick() end
check(#calls==before)
h.queue_submit(p,{mode='replace',steps={}})
check(not h.queue_status(p).repeating)
print('scheduler: '..assertions..' assertions passed')
