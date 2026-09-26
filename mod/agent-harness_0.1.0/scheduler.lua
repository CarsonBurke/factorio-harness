-- Short-horizon plans execute at simulation speed. No coroutines or host clock.
return function(api)
  local M = {handlers={}}
  local MAX_PENDING, MAX_HISTORY, MAX_INSTANT, MAX_BYTES = 128, 64, 4, 1048576
  local forbidden = {attach=true, detach=true, recipes=true, technologies=true, inspect=true, blueprint_export=true, blueprint_list=true, stop=true, describe=true, status=true, observe=true, screenshot=true}
  local function queue(index)
    local s=api.state()
    s.queues=s.queues or {}
    s.queues[index]=s.queues[index] or {revision=0,sequence=0,pending={},history={},paused=true}
    return s.queues[index]
  end
  local function revision(q,a)
    if a.expected_revision~=nil then assert(a.expected_revision==q.revision,'queue revision conflict; inspect queue_status') end
  end
  local function steps(a)
    assert(type(a.steps)=='table' and #a.steps<=MAX_PENDING,'steps must be an array of at most 128 entries')
    local out={}
    for _,step in ipairs(a.steps) do
      assert(type(step)=='table' and type(step.action)=='string','each step needs an action')
      assert(not step.action:match('^queue_') and not forbidden[step.action],'action is not queueable')
      assert(step.action=='wait_ticks' or api.handlers[step.action],'unknown action in plan')
      assert(step.args==nil or type(step.args)=='table','step args must be an object')
      assert(step.wait==nil or type(step.wait)=='boolean','step wait must be boolean')
      if step.action=='wait_ticks' then
        local ticks=step.args and step.args.ticks
        assert(type(ticks)=='number' and ticks==math.floor(ticks) and ticks>=1 and ticks<=36000,'wait_ticks requires ticks 1..36000')
      end
      out[#out+1]={action=step.action,args=step.args or {},wait=step.wait~=false}
    end
    return out
  end
  -- Conservative JSON-size estimate, independent of Factorio's serializer.
  -- Count keys even for arrays; this slightly overestimates rather than allowing
  -- many blueprint imports to grow pending work without a memory bound.
  local function bytes(value,depth)
    assert(depth<=32,'queue arguments exceed maximum nesting depth')
    if type(value)=='string' then
      local _,escaped=value:gsub('[%z\1-\31\\"]','')
      return #value+escaped*5+2
    end
    if type(value)~='table' then return 32 end
    local size=2
    for key,item in pairs(value) do
      size=size+bytes(tostring(key),depth+1)+bytes(item,depth+1)+2
      assert(size<=MAX_BYTES,'queue argument byte budget exceeded')
    end
    return size
  end
  local function total(items)
    local size=0
    for _,step in ipairs(items) do size=size+bytes(step,0) end
    return size
  end
  local function assign(q,items)
    for _,step in ipairs(items) do q.sequence=q.sequence+1; step.id='job-'..q.sequence end
  end
  local function copy_steps(items)
    local out={}
    for _,step in ipairs(items) do out[#out+1]={action=step.action,args=step.args,wait=step.wait} end
    return out
  end
  local function snapshot(q)
    return {revision=q.revision,paused=q.paused,pending=q.pending,active=q.current or false,history=q.history,
      repeating=q.loop~=nil,cycle=q.cycle,next_cycle_tick=q.next_cycle_tick,
      limits={pending=MAX_PENDING,history=MAX_HISTORY,instant_per_tick=MAX_INSTANT,argument_bytes=MAX_BYTES}}
  end
  local function record(q,step,ok,result)
    q.history[#q.history+1]={id=step.id,action=step.action,ok=ok,result=result,started_tick=step.started_tick,finished_tick=game.tick}
    if #q.history>MAX_HISTORY then table.remove(q.history,1) end
    q.revision=q.revision+1
  end
  function M.pause(index)
    local q=queue(index)
    if q.current then record(q,q.current,false,{reason='interrupted'}); q.current=nil end
    q.paused=true; q.revision=q.revision+1
  end
  function M.pause_all()
    for index in pairs(api.state().queues or {}) do M.pause(index) end
  end
  function M.handlers.queue_status(p) return snapshot(queue(p.index)) end
  function M.handlers.queue_submit(p,a)
    local q=queue(p.index); revision(q,a)
    local items=steps(a)
    assert(a.mode==nil or a.mode=='append' or a.mode=='replace','mode must be append or replace')
    assert((a.mode=='replace' and 0 or #q.pending)+#items<=MAX_PENDING,'queue capacity exceeded')
    assert((a.mode=='replace' and 0 or total(q.pending))+total(items)<=MAX_BYTES,'queue argument byte budget exceeded')
    -- Replace affects pending work only; active cancellation is always explicit.
    assign(q,items)
    if a.mode=='replace' then q.pending={}; q.loop=nil; q.next_cycle_tick=nil end
    for _,step in ipairs(items) do q.pending[#q.pending+1]=step end
    if a.start~=false then q.paused=false end
    q.revision=q.revision+1
    return snapshot(q)
  end
  function M.handlers.queue_repeat(p,a)
    local q=queue(p.index); revision(q,a)
    local items=steps(a)
    assert(#items>0,'repeating plan must not be empty')
    assert(total(items)<=MAX_BYTES,'queue argument byte budget exceeded')
    local interval=a.interval_ticks or 1800
    assert(type(interval)=='number' and interval==math.floor(interval) and interval>=60 and interval<=36000,'interval_ticks must be 60..36000')
    api.stop(p)
    M.pause(p.index)
    q.loop=copy_steps(items); q.interval=interval; q.next_cycle_tick=nil; q.cycle=1
    assign(q,items); q.pending=items; q.paused=false; q.revision=q.revision+1
    return snapshot(q)
  end
  function M.handlers.queue_edit(p,a)
    local q=queue(p.index)
    assert(a.expected_revision~=nil,'queue_edit requires expected_revision')
    revision(q,a)
    local index=a.index
    assert(type(index)=='number' and index==math.floor(index) and index>=1 and index<=#q.pending+1,'index outside pending queue (1-based)')
    local remove=a.remove or 0
    assert(type(remove)=='number' and remove==math.floor(remove) and remove>=0 and remove<=#q.pending-index+1,'invalid remove count')
    local items=steps(a)
    assert(#q.pending-remove+#items<=MAX_PENDING,'queue capacity exceeded')
    local size=total(q.pending)+total(items)
    for n=index,index+remove-1 do size=size-bytes(q.pending[n],0) end
    assert(size<=MAX_BYTES,'queue argument byte budget exceeded')
    assign(q,items)
    for _=1,remove do table.remove(q.pending,index) end
    for n=#items,1,-1 do table.insert(q.pending,index,items[n]) end
    q.revision=q.revision+1
    return snapshot(q)
  end
  function M.handlers.queue_cancel(p,a)
    local q=queue(p.index); revision(q,a)
    api.stop(p)
    M.pause(p.index)
    if a.clear~=false then q.pending={}; q.loop=nil; q.next_cycle_tick=nil end
    return snapshot(q)
  end
  function M.handlers.queue_resume(p,a)
    local q=queue(p.index); revision(q,a)
    q.paused=false; q.revision=q.revision+1
    return snapshot(q)
  end
  function M.tick()
    for index,q in pairs(api.state().queues or {}) do
      if not q.paused then
        local valid,p=pcall(api.player,index)
        if not valid then
          api.stop_index(index); M.pause(index)
        else
          if q.current then
            local step=q.current
            local waiting=step.action=='wait_ticks' and game.tick<step.until_tick or
              step.action~='wait_ticks' and api.busy(p,step.action)
            if not waiting then
              local outcome=step.action~='wait_ticks' and api.outcome and api.outcome(p,step.action) or nil
              local success=not outcome or outcome=='duration_elapsed' or outcome=='target_mined' or outcome=='repair_completed' or outcome=='arrived'
              record(q,step,success,{accepted=step.result,outcome=outcome or 'completed'})
              q.current=nil
              if not success then q.paused=true; api.stop(p) end
            end
          end
          if not q.paused and not q.current and #q.pending==0 and q.loop then
            if not q.next_cycle_tick then q.next_cycle_tick=game.tick+q.interval end
            if game.tick>=q.next_cycle_tick then
              q.pending=copy_steps(q.loop); assign(q,q.pending)
              q.next_cycle_tick=nil; q.cycle=q.cycle+1; q.revision=q.revision+1
            end
          end
          for _=1,MAX_INSTANT do
            if q.paused or q.current or #q.pending==0 then break end
            local step=table.remove(q.pending,1)
            step.started_tick=game.tick
            q.revision=q.revision+1
            if step.action=='wait_ticks' then
              step.until_tick=game.tick+step.args.ticks
              q.current=step
            else
              local ok,result=pcall(api.handlers[step.action],p,step.args)
              if not ok then
                record(q,step,false,{reason=tostring(result)})
                q.paused=true; api.stop(p)
              elseif step.wait and api.busy(p,step.action) then
                step.result=result; q.current=step
              else record(q,step,true,result) end
            end
          end
        end
      end
    end
  end
  M.schema={
    queue_status={},
    queue_repeat={steps='replace the queue with a repeating plan; errors pause it; cancel clear=true removes the loop',interval_ticks='60..36000 pause between cycles; default 1800',expected_revision='optional'},
    queue_submit={steps='array of {action,args,wait?}; max 128; wait defaults true; use shoot wait=false for firing while walking',mode='append|replace pending only',start='default true',expected_revision='optional optimistic concurrency guard'},
    queue_edit={expected_revision='required from queue_status',index='1-based pending index',remove='count to remove',steps='replacement steps'},
    queue_cancel={clear='default true; false retains pending steps; always cancels active controls and pauses',expected_revision='optional'},
    queue_resume={expected_revision='optional'},
    wait_ticks={ticks='queue-only delay: 1..36000 simulation ticks'}
  }
  return M
end
