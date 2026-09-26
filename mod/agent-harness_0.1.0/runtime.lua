-- This file is also the hot-reload payload. Top-level execution must be pure:
-- Factorio executes it during on_load, when game and storage writes are forbidden.
local M = {}
local MAX_TICKS = 600
local blueprint_module = require('blueprints')
local scheduler_module = require('scheduler')
local scheduler
local directions = {north=0, northeast=2, east=4, southeast=6, south=8, southwest=10, west=12, northwest=14}
local function integer(value, default, low, high, name)
  if value == nil then value = default end
  assert(type(value) == 'number' and value == math.floor(value) and value >= low and value <= high, name .. ' out of range')
  return value
end
local function position(value)
  assert(type(value) == 'table' and type(value.x) == 'number' and type(value.y) == 'number', 'position requires x and y')
  assert(math.abs(value.x) < 1000000 and math.abs(value.y) < 1000000, 'invalid position')
  return {x=value.x, y=value.y}
end
local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
local function state() return storage.agent_harness end
local function combat_targets()
  local s=state()
  -- Target selection affects simulation. Persist both entity and scan deadline
  -- so clients joining between scans reproduce the server's exact inputs.
  s.combat_targets=s.combat_targets or {}
  return s.combat_targets
end
local function player(index)
  local p = game.get_player(index or 1)
  assert(p and p.valid, 'player does not exist')
  local controlled=state().controlled and state().controlled[p.index]
  assert(p.connected, 'join a graphical Factorio client: disconnected players have no controllable character')
  assert(p.controller_type == defines.controllers.character and p.character and p.character.valid, 'a living survival character is required')
  assert((not p.cheat_mode or (controlled and controlled.allow_cheat_mode)) and not p.driving, 'cheat mode requires explicit testing opt-in; vehicles are unsupported')
  return p
end
local function stop(p)
  if p and p.valid and p.character and p.character.valid then
    p.walking_state = {walking=false, direction=defines.direction.north}
    p.mining_state = {mining=false}
    p.picking_state = false
    p.repair_state = {repairing=false,position=p.position}
  end
end
local function finish(index, outcome)
  local s=state()
  s.last=s.last or {}
  local action=s.active[index]
  s.last[index]={kind=action and action.kind, outcome=outcome, tick=game.tick}
  stop(game.get_player(index))
  if action and action.borrowed_cursor then
    local p=game.get_player(index)
    if p and p.valid and p.connected and p.character and p.character.valid and p.cursor_stack then pcall(p.clear_cursor) end
  end
  s.active[index]=nil
end
local function stop_combat(index,outcome)
  combat_targets()[index]=nil
  local p=game.get_player(index)
  if p and p.valid and p.character and p.character.valid then
    p.shooting_state={state=defines.shooting.not_shooting,position=p.position}
  end
  if state().combat then state().combat[index]=nil end
  state().last_combat=state().last_combat or {}
  state().last_combat[index]={outcome=outcome,tick=game.tick}
end
function M.stop_player(index)
  if scheduler then scheduler.pause(index) end
  finish(index,'interrupted')
  stop_combat(index,'interrupted')
end
function M.stop_all()
  if scheduler then scheduler.pause_all() end
  for index in pairs(state().active) do finish(index,'interrupted') end
  for index in pairs(state().combat or {}) do stop_combat(index,'interrupted') end
end
local function active(index)
  local action=state().active[index]
  if not action then
    local combat=state().combat and state().combat[index]
    return combat and {kind='shoot',until_tick=combat.until_tick} or false
  end
  return {kind=action.kind,until_tick=action.until_tick,direction=action.direction,
    target=action.entity and action.entity.valid and {name=action.entity.name,position=action.entity.position} or nil}
end
local function visible(p,pos)
  return distance(p.position,pos) <= 32 and p.force.is_chunk_visible(p.surface, {x=math.floor(pos.x/32), y=math.floor(pos.y/32)})
end
local function entity(p,args)
  local pos = position(args.position)
  assert(visible(p,pos), 'target is outside local visible area')
  local candidates = p.surface.find_entities_filtered{position=pos, radius=0.2, name=args.name}
  local found
  for _, e in pairs(candidates) do
    if e.valid and (not args.unit_number or e.unit_number == args.unit_number) and e.type ~= 'character' then
      assert(not found, 'ambiguous target; specify name or unit_number')
      found = e
    end
  end
  assert(found, 'entity not found')
  assert(p.can_reach_entity(found), 'entity is out of reach')
  return found
end
local function friendly(p,e) assert(e.force == p.force or e.force.name == 'neutral', 'cannot manipulate another force') end
local entity_status_names={}
for name,value in pairs(defines.entity_status or {}) do entity_status_names[value]=name end
local function summary(e)
  return {name=e.name, type=e.type, position=e.position, unit_number=e.unit_number,
    direction=e.direction, health=e.health, force=e.force.name, status_name=entity_status_names[e.status], amount=e.type == 'resource' and e.amount or nil}
end
local function contents(inv) return inv and inv.get_contents() or {} end
local inventories = {
  chest = {'container','logistic-container','linked-container'},
  fuel = {'furnace','assembling-machine','boiler','burner-generator','inserter','mining-drill','lab'},
  furnace_source = {'furnace'}, furnace_result = {'furnace'},
  assembling_machine_input = {'assembling-machine'}, assembling_machine_output = {'assembling-machine'},
  lab_input = {'lab'}
}
local function inventory(e, name)
  local allowed = inventories[name]
  assert(allowed, 'unsupported inventory name')
  local matches = false
  for _, kind in ipairs(allowed) do if e.type == kind then matches=true end end
  assert(matches, 'inventory is not applicable to this entity type')
  local inv = e.get_inventory(defines.inventory[name])
  assert(inv and inv.valid, 'inventory unavailable')
  return inv
end
local handlers = {}
function handlers.describe()
  local description = {protocol=1, version='0.1.0', max_action_ticks=MAX_TICKS, deduplication_window=256, deduplication_bytes=8*1024*1024,
    target='position:{x,y}, optional name and unit_number; targets require local visibility and character reach',
    actions={
      attach={allow_cheat_mode='boolean; TESTING ONLY default false'},detach={},
      equipment={operation='insert|remove',item='owned equipment item for insert',position='{x,y} grid cell; optional for insert',quality='default normal'},revive_ghost={position='{x,y}',name='optional entity-ghost'},
      shoot={position='{x,y} or auto=true',ticks='1..600',radius='1..32',gun_slot='1..3'},equip={slot='gun|ammo|armor',item='owned item name',index='default 1'},
      describe={}, observe={radius='1..32 (default 16)', limit='1..512 (default 128)', tiles='boolean (default false)',entity_types='optional array of entity types',entity_names='optional array of names',exclude_resources='boolean',resources='summary (default)|tiles|none'},
      status={}, stop={}, walk={direction='north|northeast|east|southeast|south|southwest|west|northwest', ticks='1..600'},
      move_to={position='{x,y}, within 512 tiles',ticks='1..36000, default 3600',tolerance='0.25..4, default 0.5; direct steering, stops if blocked'},
      pickup={ticks='1..600'},repair={position='{x,y}',ticks='1..600',item='repair-pack by default'},
      mine={position='{x,y}', ticks='1..600', name='optional'},
      craft={recipe='name',count='1..100'},cancel_craft={index='1-based crafting queue index',count='number to cancel; refunds through normal game rules'}, build={item='name',position='{x,y}',direction='compass name (default north)'},
      inspect={position='{x,y}'}, rotate={position='{x,y}',reverse='boolean'},
      configure={position='{x,y}',recipe='enabled recipe; machine must be empty and idle'},
      transfer={position='{x,y}',inventory='chest|fuel|furnace_source|furnace_result|assembling_machine_input|assembling_machine_output|lab_input',item='name',quality='default normal',count='1..10000',direction='to_entity|to_player',keep='optional source reserve count',up_to='optional target total cap'},
      research={technology='name'},research_next={technologies='prioritized list; starts first available only when research is idle'}, recipes={prefix='optional',limit='1..256'}, technologies={prefix='optional',limit='1..256'},
      blueprint_import={blueprint='export string',slot='default clipboard'},blueprint_export={slot='default clipboard',layout='true returns normalized relative layout and material costs instead of export string'},blueprint_list={},blueprint_delete={slot='name'},
      blueprint_capture={area='{left_top:{x,y},right_bottom:{x,y}}',slot='default clipboard',tiles='boolean',station_names='boolean'},copy={area='{left_top:{x,y},right_bottom:{x,y}}'},cut={area='{left_top:{x,y},right_bottom:{x,y}}'},paste={position='{x,y}',slot='default clipboard',direction='north|east|south|west',flip_horizontal='boolean',flip_vertical='boolean',book_path='array of 1-based book indices'},blueprint_place={position='{x,y}',slot='default clipboard',direction='north|east|south|west',flip_horizontal='boolean',flip_vertical='boolean',book_path='array of 1-based book indices'},deconstruct={area='{left_top:{x,y},right_bottom:{x,y}}'},cancel_deconstruction={area='{left_top:{x,y},right_bottom:{x,y}}'},
      screenshot={path='relative .png path under script-output',width='320..1920',height='240..1080'}},
    limitations={'No teleport, resource creation, free crafting, direct mining, remote building, or map reveal',
      'Runtime source installation is trusted operator code, not a security sandbox',
      'Screenshots require a graphical client controlling the requested player; headless hosts do not render',
      'Vehicles, rail placement, tile placement, circuit wiring, and fluid transfers are unsupported',
      'Walk/mine completion is bounded by ticks; inspect status and observe to verify outcomes'}}
  for name,schema in pairs(scheduler and scheduler.schema or {}) do description.actions[name]=schema end
  description.runtime_fault=state().runtime_fault or false
  return description
end
function handlers.attach(p,a)
  state().controlled=state().controlled or {}
  assert(a.offline~=true,'offline control is unsupported; join a graphical Factorio client')
  state().controlled[p.index]={allow_cheat_mode=a.allow_cheat_mode==true}
  return {player=p.index,connected=p.connected,allow_cheat_mode=a.allow_cheat_mode==true}
end
function handlers.detach(p)
  M.stop_player(p.index)
  if state().controlled then state().controlled[p.index]=nil end
  return {detached=true}
end
function handlers.status(p)
  local controllable,reason=pcall(player,p.index)
  return {runtime_fault=state().runtime_fault or false,connected=p.connected,alive=p.character and p.character.valid or false,cheat_mode=p.cheat_mode,
    supported_control=controllable,control_error=not controllable and tostring(reason) or nil,active=active(p.index), last=state().last and state().last[p.index] or false, combat=state().combat and state().combat[p.index] or false, last_combat=state().last_combat and state().last_combat[p.index] or false, tick=game.tick, position=p.position}
end
-- Connected visible resource tiles are summarized separately from structures so a
-- large ore patch cannot consume the entity budget and hide machines or enemies.
local function resource_patches(entities)
  local remaining, patches = {}, {}
  local function key(name,x,y) return name..':'..x..':'..y end
  for _,e in ipairs(entities) do remaining[key(e.name,math.floor(e.position.x),math.floor(e.position.y))]=e end
  for _,seed in ipairs(entities) do
    local sx,sy=math.floor(seed.position.x),math.floor(seed.position.y)
    if remaining[key(seed.name,sx,sy)] then
      local patch={name=seed.name,tiles=0,amount=0,left=sx,top=sy,right=sx+1,bottom=sy+1}
      local queue,head={{sx,sy,seed.amount or 0}},1
      remaining[key(seed.name,sx,sy)]=nil
      while head<=#queue do
        local cell=queue[head]; head=head+1
        local x,y=cell[1],cell[2]
        patch.tiles=patch.tiles+1
        patch.amount=patch.amount+cell[3]
        patch.left=math.min(patch.left,x); patch.top=math.min(patch.top,y)
        patch.right=math.max(patch.right,x+1); patch.bottom=math.max(patch.bottom,y+1)
        for _,d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
          local nx,ny=x+d[1],y+d[2]
          local k=key(seed.name,nx,ny); local e=remaining[k]
          if e then remaining[k]=nil; queue[#queue+1]={nx,ny,e.amount or 0} end
        end
      end
      patches[#patches+1]=patch
    end
  end
  return patches
end
function handlers.observe(p,a)
  local mode=a.exclude_resources and 'none' or a.resources or 'summary'
  assert(mode=='summary' or mode=='tiles' or mode=='none','resources must be summary, tiles, or none')
  local radius=integer(a.radius,16,1,32,'radius')
  local limit=integer(a.limit,128,1,512,'limit')
  for _,key in ipairs({'entity_types','entity_names'}) do
    if a[key] then
      assert(type(a[key])=='table' and #a[key]>0 and #a[key]<=32,key..' requires 1..32 names')
      for _,name in ipairs(a[key]) do assert(type(name)=='string',key..' requires strings') end
    end
  end
  local out={player={index=p.index, position=p.position, surface=p.surface.name, health=p.character.health, max_health=p.character.max_health, selected_gun_slot=p.character.selected_gun_index,
    inventory=contents(p.get_main_inventory()), guns=contents(p.get_inventory(defines.inventory.character_guns)), ammo=contents(p.get_inventory(defines.inventory.character_ammo)), armor=contents(p.get_inventory(defines.inventory.character_armor)), crafting_queue=p.crafting_queue or {}}, entities={}, tiles={}, truncated=false,
    active=active(p.index)}
  local candidates=p.surface.find_entities_filtered{position=p.position, radius=radius,type=a.entity_types,name=a.entity_names}
  table.sort(candidates,function(x,y)
    local dx,dy=distance(p.position,x.position),distance(p.position,y.position)
    if dx ~= dy then return dx < dy end
    if x.position.x ~= y.position.x then return x.position.x < y.position.x end
    if x.position.y ~= y.position.y then return x.position.y < y.position.y end
    return x.name < y.name
  end)
  local resources={}
  for _, e in ipairs(candidates) do
    if visible(p,e.position) then
      if e.type=='resource' and mode~='tiles' then
        if mode=='summary' then resources[#resources+1]=e end
      elseif #out.entities >= limit then out.truncated=true
      else out.entities[#out.entities+1]=summary(e) end
    end
  end
  if mode=='summary' then
    out.resource_patches=resource_patches(resources)
    out.resource_scope='visible tiles inside this observation only; bounds do not imply every enclosed tile has ore'
  end
  if a.tiles then
    for _,tile in ipairs(p.surface.find_tiles_filtered{position=p.position,radius=radius}) do
      if visible(p,tile.position) then
        if #out.tiles >= integer(a.tiles_limit,4096,1,4096,'tiles_limit') then out.tiles_truncated=true; break end
        out.tiles[#out.tiles+1]={name=tile.name,position=tile.position}
      end
    end
  end
  local grid=p.character.grid
  out.player.equipment={}
  if grid then
    for _,e in pairs(grid.equipment) do
      out.player.equipment[#out.player.equipment+1]={name=e.name,position=e.position,quality=e.quality.name,energy=e.energy,shield=e.shield}
    end
  end
  local r=p.force.current_research
  out.research=r and {name=r.name, progress=p.force.research_progress} or false
  out.research_queue={}
  for _,technology in ipairs(p.force.research_queue or {}) do out.research_queue[#out.research_queue+1]=technology.name end
  out.combat=state().combat and state().combat[p.index] or false
  local q=state().queues and state().queues[p.index]
  out.queue=q and {revision=q.revision,paused=q.paused,pending=#q.pending,
    active=q.current and {id=q.current.id,action=q.current.action,started_tick=q.current.started_tick} or false} or false
  return out
end
function handlers.stop(p) if scheduler then scheduler.pause(p.index) end; finish(p.index,'stopped'); stop_combat(p.index,'stopped'); return {stopped=true} end
function handlers.walk(p,a)
  local direction=directions[a.direction]
  assert(direction,'invalid compass direction')
  local ticks=integer(a.ticks,60,1,MAX_TICKS,'ticks')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]={kind='walk',direction=direction,until_tick=game.tick+ticks}
  return {until_tick=game.tick+ticks}
end
function handlers.move_to(p,a)
  local target=position(a.position)
  assert(distance(p.position,target)<=512,'movement target must be within 512 tiles')
  local ticks=integer(a.ticks,3600,1,36000,'ticks')
  local tolerance=a.tolerance or 0.5
  assert(type(tolerance)=='number' and tolerance>=0.25 and tolerance<=4,'tolerance out of range')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]={kind='move_to',position=target,tolerance=tolerance,
    until_tick=game.tick+ticks,last_position=p.position,stalled=0}
  return {until_tick=game.tick+ticks,position=target}
end
function handlers.mine(p,a)
  local e=entity(p,a); friendly(p,e)
  assert(e.minable,'entity is not mineable')
  local ticks=integer(a.ticks,60,1,MAX_TICKS,'ticks')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]={kind='mine',entity=e,until_tick=game.tick+ticks}
  -- LuaEntity cannot be serialized to JSON; only tick is returned.
  return {until_tick=game.tick+ticks}
end
function handlers.pickup(p,a)
  local ticks=integer(a.ticks,30,1,MAX_TICKS,'ticks')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]={kind='pickup',until_tick=game.tick+ticks}
  return {until_tick=game.tick+ticks}
end
function handlers.repair(p,a)
  local e=entity(p,a); friendly(p,e)
  assert(e.health and e.health<e.max_health,'entity does not need repair')
  local ticks=integer(a.ticks,60,1,MAX_TICKS,'ticks')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  local borrowed=false
  if not p.cursor_stack.valid_for_read then
    local tool=p.get_main_inventory().find_item_stack(a.item or 'repair-pack')
    assert(tool and tool.prototype.type=='repair-tool','no repair tool in inventory')
    assert(p.cursor_stack.swap_stack(tool),'cannot hold repair tool')
    borrowed=true
  end
  assert(p.cursor_stack.prototype.type=='repair-tool','cursor must hold a repair tool')
  state().active[p.index]={kind='repair',entity=e,borrowed_cursor=borrowed,until_tick=game.tick+ticks}
  return {until_tick=game.tick+ticks}
end
function handlers.craft(p,a)
  assert(type(a.recipe)=='string' and p.force.recipes[a.recipe] and p.force.recipes[a.recipe].enabled,'recipe is unavailable')
  return {started=p.begin_crafting{recipe=a.recipe,count=integer(a.count,1,1,100,'count')}}
end
function handlers.cancel_craft(p,a)
  local index=integer(a.index,1,1,10000,'index')
  local entry=(p.crafting_queue or {})[index]
  assert(entry,'crafting queue entry does not exist')
  local count=integer(a.count,entry.count,1,entry.count,'count')
  p.cancel_crafting{index=index,count=count}
  return {cancelled=count,recipe=entry.recipe,crafting_queue=p.crafting_queue or {}}
end
function handlers.build(p,a)
  local pos=position(a.position)
  assert(visible(p,pos) and distance(p.position,pos)<=p.build_distance,'position is out of build reach')
  assert(type(a.item)=='string','item is required')
  assert(not p.cursor_stack.valid_for_read,'cursor must be empty; clear it in the client first')
  local stack=p.get_main_inventory().find_item_stack{name=a.item,quality=a.quality or 'normal'}
  assert(stack,'item is not in main inventory')
  assert(stack.prototype.place_result and stack.prototype.place_result.type ~= 'rail-ramp','only ordinary entity placement is supported')
  local direction=directions[a.direction or 'north']; assert(direction,'invalid direction')
  local filter={position=pos,radius=2,name=stack.prototype.place_result.name,limit=64}
  local existing={}
  for _,e in pairs(p.surface.find_entities_filtered(filter)) do existing[e.unit_number or e]=true end
  assert(p.cursor_stack.swap_stack(stack),'could not borrow inventory stack')
  local before=p.cursor_stack.count
  local ok,err=pcall(function()
    assert(p.can_build_from_cursor{position=pos,direction=direction,build_mode=defines.build_mode.normal},'placement blocked')
    p.build_from_cursor{position=pos,direction=direction,build_mode=defines.build_mode.normal}
  end)
  local after=p.cursor_stack.valid_for_read and p.cursor_stack.count or 0
  local restored=not p.cursor_stack.valid_for_read or
    (not stack.valid_for_read and p.cursor_stack.swap_stack(stack)) or p.clear_cursor()
  assert(restored,'build finished but could not restore cursor; items remain in cursor')
  assert(ok,err)
  local placed={}
  if before>after then
    for _,e in pairs(p.surface.find_entities_filtered(filter)) do
      if e.valid and not existing[e.unit_number or e] then placed[#placed+1]=summary(e) end
    end
  end
  return {consumed=before-after,entities=placed,entity=#placed==1 and placed[1] or nil}
end
function handlers.inspect(p,a)
  local e=entity(p,a)
  local out=summary(e); out.inventories={}
  out.status=e.status
  out.status_name=entity_status_names[out.status]
  out.energy=e.energy
  out.fluids=e.get_fluid_contents()
  out.electric_network_id=e.electric_network_id
  if e.type=='inserter' then out.pickup_position=e.pickup_position; out.drop_position=e.drop_position end
  if e.type=='transport-belt' or e.type=='underground-belt' or e.type=='splitter' then
    out.belt_lines={}
    for i=1,e.get_max_transport_line_index() do out.belt_lines[i]=e.get_transport_line(i).get_contents() end
  end
  for name in pairs(inventories) do
    local ok,inv=pcall(inventory,e,name)
    if ok then out.inventories[name]=contents(inv) end
  end
  if e.type=='assembling-machine' or e.type=='furnace' then
    local recipe=e.get_recipe(); out.recipe=recipe and recipe.name or false
    out.crafting_progress=e.crafting_progress
  end
  return out
end
function handlers.rotate(p,a)
  local e=entity(p,a); friendly(p,e)
  return {rotated=e.rotate{reverse=a.reverse == true,by_player=p}}
end
function handlers.configure(p,a)
  local e=entity(p,a); friendly(p,e)
  assert(e.type=='assembling-machine','only assembling machines support recipe configuration')
  assert(type(a.recipe)=='string' and p.force.recipes[a.recipe] and p.force.recipes[a.recipe].enabled,'recipe is unavailable')
  assert(not e.is_crafting() and e.crafting_progress==0,'machine must be idle without partial production')
  for _,name in ipairs({'assembling_machine_input','assembling_machine_output','fuel'}) do
    local ok,inv=pcall(inventory,e,name)
    if ok then assert(inv.is_empty(),'empty the machine before changing its recipe') end
  end
  for i=1,#e.fluidbox do assert(not e.fluidbox[i],'empty machine fluids before changing its recipe') end
  e.set_recipe(a.recipe)
  local recipe=e.get_recipe()
  assert(recipe and recipe.name==a.recipe,'recipe incompatible with machine')
  return {recipe=recipe.name}
end
function handlers.transfer(p,a)
  local e=entity(p,a); friendly(p,e)
  local target=inventory(e,a.inventory)
  local source=p.get_main_inventory()
  assert(a.direction=='to_entity' or a.direction=='to_player','invalid transfer direction')
  if a.direction=='to_player' then source,target=target,source end
  assert(type(a.item)=='string','item is required')
  local requested=integer(a.count,1,1,10000,'count')
  local quality=a.quality or 'normal'
  local function count(inv)
    local n=0
    for i=1,#inv do local s=inv[i]; if s.valid_for_read and s.name==a.item and s.quality.name==quality then n=n+s.count end end
    return n
  end
  local wanted=requested
  if a.keep~=nil then wanted=math.min(wanted,math.max(0,count(source)-integer(a.keep,0,0,100000,'keep'))) end
  if a.up_to~=nil then wanted=math.min(wanted,math.max(0,integer(a.up_to,1,1,100000,'up_to')-count(target))) end
  local remaining=wanted
  for i=1,#source do
    local stack=source[i]
    if stack.valid_for_read and stack.name==a.item and stack.quality.name==quality then
      for j=1,#target do
        if remaining==0 or not stack.valid_for_read then break end
        local before=stack.count
        target[j].transfer_stack(stack,math.min(before,remaining))
        local moved=before-(stack.valid_for_read and stack.count or 0)
        remaining=remaining-moved
      end
    end
    if remaining==0 then break end
  end
  return {transferred=wanted-remaining,requested=requested}
end
function handlers.research(p,a)
  local technology=p.force.technologies[a.technology or '']
  assert(technology and technology.enabled and not technology.researched,'technology unavailable')
  for _,pre in pairs(technology.prerequisites) do assert(pre.researched,'prerequisite research incomplete') end
  return {queued=p.force.add_research(technology)}
end
function handlers.research_next(p,a)
  assert(type(a.technologies)=='table' and #a.technologies>0 and #a.technologies<=64,'technologies requires 1..64 names')
  for _,name in ipairs(a.technologies) do assert(type(name)=='string' and p.force.technologies[name],'unknown technology') end
  if p.force.current_research then return {current=p.force.current_research.name,started=false} end
  for _,name in ipairs(a.technologies) do
    local t=p.force.technologies[name]
    local ready=t.enabled and not t.researched and not t.prototype.research_trigger
    for _,pre in pairs(t.prerequisites) do if not pre.researched then ready=false end end
    if ready then return {started=p.force.add_research(t),current=name} end
  end
  return {started=false,current=false}
end
local function catalog(p,a,kind)
  local limit=integer(a.limit,64,1,256,'limit')
  local prefix=a.prefix or ''; assert(type(prefix)=='string','prefix must be a string')
  local names={}
  for name,entry in pairs(p.force[kind]) do if entry.enabled and name:sub(1,#prefix)==prefix then names[#names+1]=name end end
  table.sort(names)
  local out={entries={},truncated=#names>limit}
  for i=1,math.min(#names,limit) do
    local entry=p.force[kind][names[i]]
    if kind=='recipes' then out.entries[i]={name=entry.name,ingredients=entry.ingredients,products=entry.products,energy=entry.energy}
    else
      local prerequisites={}
      for name,pre in pairs(entry.prerequisites) do prerequisites[#prerequisites+1]={name=name,researched=pre.researched} end
      table.sort(prerequisites,function(x,y) return x.name<y.name end)
      out.entries[i]={name=entry.name,researched=entry.researched,level=entry.level,
        prerequisites=prerequisites,ingredients=entry.research_unit_ingredients,
        count=entry.research_unit_count,energy=entry.research_unit_energy,
        trigger=entry.prototype.research_trigger}
    end
  end
  return out
end
function handlers.recipes(p,a) return catalog(p,a,'recipes') end
function handlers.technologies(p,a) return catalog(p,a,'technologies') end
function handlers.screenshot(p,a)
  assert(type(a.path)=='string' and #a.path<=160 and a.path:match('^[%w_/-]+%.png$') and not a.path:find('..',1,true) and a.path:sub(1,1)~='/','path must be a relative PNG path')
  game.take_screenshot{player=p,by_player=p,surface=p.surface,position=p.position,path=a.path,resolution={x=integer(a.width,1280,320,1920,'width'),y=integer(a.height,720,240,1080,'height')},zoom=1,show_entity_info=true}
  return {queued=true,path=a.path,requires_graphical_client=true}
end
function handlers.revive_ghost(p,a)
  local e=entity(p,a); friendly(p,e)
  assert(e.type=='entity-ghost','target must be an entity ghost')
  local needed=e.ghost_prototype
  local quality=e.quality.name
  local item
  for i=1,#p.get_main_inventory() do
    local stack=p.get_main_inventory()[i]
    if stack.valid_for_read and stack.quality.name==quality and stack.prototype.place_result==needed then item=stack.name; break end
  end
  assert(item,'no matching building item and quality in inventory')
  local direction
  for name,value in pairs(directions) do if value==e.direction then direction=name end end
  assert(direction,'unsupported ghost direction')
  local result=handlers.build(p,{item=item,quality=quality,position=e.position,direction=direction})
  result.revived=not e.valid
  return result
end
function handlers.equipment(p,a)
  local grid=p.character.grid; assert(grid,'equipped armor has no equipment grid')
  local inv=p.get_main_inventory()
  if a.operation=='insert' then
    assert(type(a.item)=='string','item required')
    local stack=inv.find_item_stack{name=a.item,quality=a.quality or 'normal'}
    assert(stack and stack.prototype.place_as_equipment_result,'equipment item missing')
    local pos=a.position and position(a.position)
    if pos then integer(pos.x,nil,0,grid.width-1,'x'); integer(pos.y,nil,0,grid.height-1,'y') end
    local equipment=grid.put{name=stack.prototype.place_as_equipment_result.name,quality=stack.quality,position=pos,by_player=p}
    assert(equipment,'equipment does not fit')
    stack.count=stack.count-1
    return {inserted=equipment.name,position=equipment.position}
  end
  assert(a.operation=='remove','operation must be insert or remove')
  local pos=position(a.position)
  local equipment=grid.get(pos); assert(equipment,'equipment not found')
  local item={name=equipment.prototype.take_result.name,quality=equipment.quality.name,count=1}
  assert(inv.can_insert(item),'main inventory has no space for removed equipment')
  local removed=grid.take{equipment=equipment,by_player=p}
  assert(removed,'equipment removal failed')
  local inserted=inv.insert(removed)
  if inserted<removed.count then
    p.surface.spill_item_stack{position=p.position,stack={name=removed.name,quality=removed.quality,count=removed.count-inserted},enable_looted=true,force=p.force}
  end
  return {removed=removed.name}
end
function handlers.shoot(p,a)
  local ticks=integer(a.ticks,60,1,MAX_TICKS,'ticks')
  local pos=a.position and position(a.position)
  assert(a.auto==true or pos,'specify position or auto=true')
  if pos then assert(visible(p,pos),'firing position must be locally visible') end
  if a.gun_slot then p.character.selected_gun_index=integer(a.gun_slot,nil,1,3,'gun_slot') end
  state().combat=state().combat or {}
  combat_targets()[p.index]=nil
  state().combat[p.index]={until_tick=game.tick+ticks,position=pos,auto=a.auto==true,radius=integer(a.radius,24,1,32,'radius')}
  return {until_tick=game.tick+ticks}
end
function handlers.equip(p,a)
  local names={gun='character_guns',ammo='character_ammo',armor='character_armor'}
  assert(names[a.slot],'slot must be gun, ammo, or armor')
  local inv=p.get_inventory(defines.inventory[names[a.slot]])
  local index=integer(a.index,1,1,#inv,'index')
  assert(type(a.item)=='string','item required')
  local source=p.get_main_inventory().find_item_stack(a.item)
  assert(source,'item is not in inventory')
  assert(inv[index].swap_stack(source),'item incompatible with slot or displaced item cannot fit')
  return {equipped=a.item,slot=a.slot,index=index}
end
local blueprint_handlers=blueprint_module{position=position,visible=visible,distance=distance,entity=entity,friendly=friendly,integer=integer}
for name,handler in pairs(blueprint_handlers) do handlers[name]=handler end
local permissions={walk='start_walking',move_to='start_walking',mine='begin_mining',pickup='change_picking_state',repair='start_repair',craft='craft',cancel_craft='cancel_craft',build='build',revive_ghost='build',rotate='rotate_entity',configure='setup_assembling_machine',transfer='inventory_transfer',research='start_research',research_next='start_research',shoot='change_shooting_state',equip='inventory_transfer'}
for name,input in pairs(permissions) do
  local handler=handlers[name]
  handlers[name]=function(p,a)
    assert(not p.permission_group or p.permission_group.allows_action(defines.input_action[input]),'permission denied: '..input)
    return handler(p,a)
  end
end
local equipment_handler=handlers.equipment
handlers.equipment=function(p,a)
  local input=a.operation=='remove' and 'take_equipment' or 'place_equipment'
  assert(not p.permission_group or p.permission_group.allows_action(defines.input_action[input]),'permission denied: '..input)
  return equipment_handler(p,a)
end
local timed={walk=true,move_to=true,mine=true,pickup=true,repair=true}
scheduler=scheduler_module{
  state=state,player=player,handlers=handlers,
  busy=function(p,action)
    if action=='shoot' then return state().combat and state().combat[p.index]~=nil end
    return timed[action] and state().active[p.index]~=nil or false
  end,
  stop=function(p) M.stop_player(p.index) end,stop_index=M.stop_player,
  outcome=function(p,action)
    local last=action=='shoot' and state().last_combat or timed[action] and state().last
    return last and last[p.index] and last[p.index].outcome
  end
}
for name,handler in pairs(scheduler.handlers) do handlers[name]=handler end
-- Rendering observes the world without taking over character controls.
local reads={describe=true,status=true,observe=true,inspect=true,recipes=true,technologies=true,blueprint_export=true,blueprint_list=true,screenshot=true}

function M.dispatch(request)
  local handler=handlers[request.action]; assert(handler,'unsupported action; call describe')
  if request.action=='describe' then return handler() end
  if request.action=='attach' then
    local p=game.get_player(request.player or 1)
    assert(p and p.valid and p.connected,'join a graphical Factorio client: disconnected players have no controllable character')
    assert(p.character and p.character.valid and p.controller_type==defines.controllers.character,'a living survival character is required')
    local a=request.args or {}
    assert(not p.cheat_mode or a.allow_cheat_mode==true,'cheat mode requires explicit testing opt-in')
    return handler(p,a)
  end
  if request.action=='status' or request.action=='queue_status' or request.action=='queue_cancel' then
    local p=game.get_player(request.player or 1); assert(p and p.valid,'player does not exist')
    return handler(p,request.args or {})
  end
  local p=player(request.player)
  if not reads[request.action] and not request.action:match('^queue_') then
    local q=state().queues and state().queues[p.index]
    if q and not q.paused then M.stop_player(p.index) end
  end
  return handler(p,request.args or {})
end
function M.tick(event)
  for index,action in pairs(state().active) do
    local ok,p=pcall(player,index)
    if not ok then
      finish(index,'player_unavailable')
    elseif event.tick>action.until_tick then
      finish(index,action.kind=='move_to' and 'timed_out' or 'duration_elapsed')
    elseif action.kind=='walk' then
      p.walking_state={walking=true,direction=action.direction}
    elseif action.kind=='move_to' then
      local pos=p.position
      local dx,dy=action.position.x-pos.x,action.position.y-pos.y
      if distance(pos,action.position)<=action.tolerance then finish(index,'arrived')
      else
        action.stalled=distance(pos,action.last_position)<0.005 and action.stalled+1 or 0
        local oscillating=action.previous_position and distance(pos,action.previous_position)<0.005
          and distance(pos,action.last_position)>0.005
        action.previous_position=action.last_position
        action.last_position=pos
        if oscillating then finish(index,'oscillating')
        elseif action.stalled>=120 then finish(index,'blocked')
        else
          local ax,ay=math.abs(dx),math.abs(dy)
          local direction
          if math.min(ax,ay)>math.max(ax,ay)*0.4142 then
            direction=(dy<0 and 'north' or 'south')..(dx<0 and 'west' or 'east')
          elseif ax>ay then direction=dx<0 and 'west' or 'east'
          else direction=dy<0 and 'north' or 'south' end
          p.walking_state={walking=true,direction=directions[direction]}
        end
      end
    elseif action.kind=='pickup' then
      p.picking_state=true
    elseif action.kind=='repair' then
      local e=action.entity
      if not e or not e.valid then finish(index,'target_lost')
      elseif not p.can_reach_entity(e) then finish(index,'out_of_reach')
      elseif e.health>=e.max_health then finish(index,'repair_completed')
      elseif not p.cursor_stack.valid_for_read or p.cursor_stack.prototype.type~='repair-tool' then finish(index,'repair_tool_exhausted')
      else p.selected=e; p.repair_state={repairing=true,position=e.position} end
    elseif action.kind=='mine' then
      local e=action.entity
      if not e or not e.valid then finish(index,'target_mined')
      elseif not p.can_reach_entity(e) then finish(index,'out_of_reach')
      else p.selected=e; p.mining_state={mining=true,position=e.position} end
    end
  end
  for index,action in pairs(state().combat or {}) do
    local ok,p=pcall(player,index)
    if not ok or event.tick>action.until_tick then stop_combat(index,ok and 'duration_elapsed' or 'player_unavailable')
    else
      local target=action.position
      if action.auto then
        local cached=combat_targets()[index]
        if not cached or event.tick>=cached.next_scan then
          local enemies={}
          for _,force in pairs(game.forces) do
            if force~=p.force and force.name~='neutral' and not p.force.get_friend(force) and not p.force.get_cease_fire(force) then enemies[#enemies+1]=force end
          end
          local best=action.radius+1
          cached={next_scan=event.tick+6}
          if #enemies>0 then
            for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=action.radius,force=enemies,limit=256,type={'unit','unit-spawner','turret','ammo-turret','electric-turret','character'}}) do
              local d=distance(p.position,e.position)
              if e.valid and visible(p,e.position) and d<best then best=d; cached.entity=e end
            end
          end
          combat_targets()[index]=cached
        end
        local e=cached.entity
        if e and e.valid and distance(p.position,e.position)<=action.radius and visible(p,e.position) then target=e.position end
      end
      p.shooting_state={state=target and defines.shooting.shooting_enemies or defines.shooting.not_shooting,position=target or p.position}
    end
  end
  scheduler.tick()
end
return M
