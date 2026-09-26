-- Run from repository root: lua mod/tests/runtime_test.lua
local assertions=0
local function eq(a,b,message) assertions=assertions+1; assert(a==b,(message or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,pattern)
  local ok,err=pcall(fn); eq(ok,false,'expected error'); assert(tostring(err):find(pattern,1,true),tostring(err))
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={shooting={not_shooting=0,shooting_enemies=1},controllers={character=1},direction={north=0},inventory={chest=1},build_mode={normal=1}}
local p={index=1,valid=true,connected=true,controller_type=1,character={valid=true},position={x=0,y=0},cheat_mode=false,driving=false}
p.force={name='player',is_chunk_visible=function() return true end}
p.surface={name='nauvis'}
p.can_reach_entity=function() return true end
local tick=0
game={tick=tick,get_player=function(index) if index==1 then return p end end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function call(action,args) return runtime.dispatch{action=action,args=args,player=1} end
local function advance(n)
  for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end
end
call('walk',{direction='east',ticks=2})
eq(call('status').active.kind,'walk')
advance(1); eq(p.walking_state.walking,true); eq(p.walking_state.direction,4)
advance(1); eq(p.walking_state.walking,true)
advance(1); eq(p.walking_state.walking,false); eq(call('status').active,false)
eq(call('status').last.outcome,'duration_elapsed')
-- Tick steering uses actual position, tolerates speed changes, and stops safely.
call('move_to',{position={x=10,y=0}})
advance(1); eq(p.walking_state.direction,4)
p.position={x=9.8,y=0}; advance(1)
eq(call('status').last.outcome,'arrived'); eq(p.walking_state.walking,false)
p.position={x=0,y=0}
call('move_to',{position={x=10,y=0}}); advance(120)
eq(call('status').last.outcome,'blocked'); eq(p.walking_state.walking,false)
call('move_to',{position={x=10,y=0},ticks=1}); advance(2)
eq(call('status').last.outcome,'timed_out')
call('move_to',{position={x=0.3,y=0},tolerance=0.25})
advance(1); p.position={x=0.6,y=0}; advance(1); p.position={x=0,y=0}; advance(1)
eq(call('status').last.outcome,'oscillating'); eq(p.walking_state.walking,false)
call('queue_submit',{steps={{action='walk',args={direction='east',ticks=10}}}})
advance(1)
game.take_screenshot=function() end
call('screenshot',{path='queue.png'})
eq(call('queue_status').paused,false); eq(call('status').active.kind,'walk')
call('queue_cancel',{})
call('queue_submit',{steps={{action='move_to',args={position={x=2,y=0}}},{action='walk',args={direction='north',ticks=10}}}})
advance(1); eq(call('queue_status').active.action,'move_to')
eq(#call('queue_status').pending,1)
p.position={x=2,y=0}; advance(1)
eq(call('queue_status').active.action,'walk')
call('queue_cancel',{}); p.position={x=0,y=0}
fails(function() call('walk',{direction='east',ticks=601}) end,'ticks out of range')
p.cheat_mode=true; fails(function() call('walk',{direction='east'}) end,'cheat mode'); p.cheat_mode=false
call('walk',{direction='north',ticks=10}); p.connected=false; advance(1)
eq(storage.agent_harness.active[1],nil); eq(p.walking_state.walking,false); p.connected=true
local ore={valid=true,name='iron-ore',type='resource',position={x=1,y=0},force={name='neutral'},minable=true}
p.surface.find_entities_filtered=function() return {ore} end
call('mine',{position=ore.position,ticks=10})
eq(call('status').active.target.name,'iron-ore')
advance(1); eq(p.selected,ore); eq(p.mining_state.mining,true)
ore.valid=false; advance(1); eq(p.mining_state.mining,false); eq(call('status').last.outcome,'target_mined')
-- Building must return the borrowed stack after a rejected placement.
local function stack(name,count)
  local s={name=name,count=count,valid_for_read=count>0,quality={name='normal'},prototype={place_result={type='container'}}}
  s.swap_stack=function(other)
    s.name,other.name=other.name,s.name
    s.count,other.count=other.count,s.count
    s.valid_for_read,other.valid_for_read=other.valid_for_read,s.valid_for_read
    return true
  end
  s.transfer_stack=function(other,amount)
    if s.valid_for_read and s.name~=other.name then return false end
    local moved=math.min(amount,other.count,100-s.count)
    s.name=other.name; s.count=s.count+moved; s.valid_for_read=s.count>0
    other.count=other.count-moved; other.valid_for_read=other.count>0
    return moved==amount
  end
  return s
end
local wood=stack('wooden-chest',3); local main={wood}
main.find_item_stack=function() return wood end
p.get_main_inventory=function() return main end
p.cursor_stack=stack(nil,0); p.build_distance=10
p.can_build_from_cursor=function() return false end
fails(function() call('build',{item='wooden-chest',position={x=2,y=0}}) end,'placement blocked')
eq(wood.count,3); eq(p.cursor_stack.valid_for_read,false)
p.can_build_from_cursor=function() return true end
local placed
p.surface.find_entities_filtered=function() return placed and {placed} or {} end
p.build_from_cursor=function()
  p.cursor_stack.count=p.cursor_stack.count-1
  placed={valid=true,name='wooden-chest',type='container',position={x=2.5,y=0.5},force=p.force}
end
local built=call('build',{item='wooden-chest',position={x=2,y=0}})
eq(built.consumed,1); eq(built.entity.position.x,2.5); eq(built.entity.position.y,0.5)
eq(wood.count,2); eq(p.cursor_stack.valid_for_read,false)
-- Factorio reports false when swapping two empty stacks after the last item.
wood.count=1
local swap=p.cursor_stack.swap_stack
p.cursor_stack.swap_stack=function(other)
  if not p.cursor_stack.valid_for_read and not other.valid_for_read then return false end
  return swap(other)
end
p.build_from_cursor=function() p.cursor_stack.count=0; p.cursor_stack.valid_for_read=false end
eq(call('build',{item='wooden-chest',position={x=2,y=0}}).consumed,1)
eq(p.cursor_stack.valid_for_read,false)
-- transfer_stack amount must preserve exact requested counts and metadata path.
local input=stack('iron-plate',20); main={input}
local output=stack(nil,0)
local chest={valid=true,name='wooden-chest',type='container',position={x=1,y=0},force=p.force}
chest.get_inventory=function() return setmetatable({output,valid=true},{}) end
p.surface.find_entities_filtered=function() return {chest} end
local result=call('transfer',{position=chest.position,inventory='chest',item='iron-plate',count=7,direction='to_entity'})
eq(result.transferred,7); eq(input.count,13); eq(output.count,7)
call('walk',{direction='west',ticks=10}); runtime.stop_all()
eq(call('status').active,false); eq(call('status').last.outcome,'interrupted')
-- Explicit offline attachment is required; combat remains active during movement.
p.connected=false
fails(function() call('walk',{direction='east'}) end,'join a graphical Factorio client')
fails(function() call('attach',{offline=true}) end,'join a graphical Factorio client')
p.connected=true
call('attach',{})
call('shoot',{position={x=3,y=0},ticks=4})
call('walk',{direction='east',ticks=2})
advance(1); eq(p.walking_state.walking,true); eq(p.shooting_state.state,1)
advance(2); eq(p.walking_state.walking,false); eq(p.shooting_state.state,1)
advance(2); eq(p.shooting_state.state,0); eq(call('status').active,false)
call('detach'); p.connected=false; fails(function() call('walk',{direction='east'}) end,'join a graphical Factorio client')
-- Direct intervention cancels queued controls while preserving pending work.
p.connected=true
call('queue_submit',{steps={{action='walk',args={direction='east',ticks=20}},{action='wait_ticks',args={ticks=5}}}})
advance(1); eq(call('queue_status').active.action,'walk')
call('pickup',{ticks=1})
eq(call('queue_status').paused,true); eq(call('queue_status').active,false)
eq(storage.agent_harness.active[1].kind,'pickup'); eq(#call('queue_status').pending,1)
advance(2); eq(call('status').active,false)
-- Enemy queries run at 10Hz while normal shooting input stays at 60Hz.
local enemy={name='enemy'}
game.forces={p.force,enemy}
p.force.get_friend=function() return false end; p.force.get_cease_fire=function() return false end
local scans=0
p.surface.find_entities_filtered=function(filter)
  scans=scans+1; eq(filter.limit,256)
  return {{valid=true,position={x=2,y=0},force=enemy}}
end
call('shoot',{auto=true,ticks=12})
advance(3); eq(scans,1)
runtime=dofile('mod/agent-harness_0.1.0/runtime.lua') -- simulate saved source reconstruction during on_load
advance(3); eq(scans,1); eq(p.shooting_state.state,1)
advance(6); eq(scans,2); eq(p.shooting_state.state,1)
advance(1); eq(p.shooting_state.state,0)
-- One observation exposes small queue/combat summaries without queue history.
p.surface.find_entities_filtered=function() return {} end
main.get_contents=function() return {} end
p.get_inventory=function() return {get_contents=function() return {} end} end
local observation=call('observe',{})
eq(observation.queue.pending,1); eq(observation.queue.paused,true)
eq(observation.queue.history,nil); eq(observation.combat,false)
-- Resource summaries must not crowd structures out of a small entity budget.
local function resource(name,x,y,amount)
  return {valid=true,type='resource',name=name,position={x=x,y=y},amount=amount,force={name='neutral'}}
end
local belt={valid=true,type='transport-belt',name='transport-belt',position={x=5,y=0},force=p.force}
p.surface.find_entities_filtered=function() return {
  resource('copper-ore',0.5,0.5,10),resource('copper-ore',1.5,0.5,20),
  resource('copper-ore',8.5,0.5,30),resource('iron-ore',0.5,1.5,40),belt,
  resource('copper-ore',100.5,0.5,999),
} end
local compact=call('observe',{limit=1})
eq(#compact.entities,1); eq(compact.entities[1].name,'transport-belt')
eq(compact.truncated,false); eq(#compact.resource_patches,3)
eq(compact.resource_patches[1].tiles,2); eq(compact.resource_patches[1].amount,30)
eq(compact.resource_patches[1].left,0); eq(compact.resource_patches[1].right,2)
local detailed=call('observe',{resources='tiles',limit=1})
eq(detailed.entities[1].name,'copper-ore'); eq(detailed.truncated,true)
eq(detailed.resource_patches,nil)
local none=call('observe',{resources='none'})
eq(#none.entities,1); eq(none.resource_patches,nil)
fails(function()call('observe',{resources='invalid'})end,'resources must be')
print('runtime: '..assertions..' assertions passed')
