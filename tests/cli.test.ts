import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);
async function engine(reply: (request:any)=>any, run:(port:number)=>Promise<void>) {
  const sockets = new Set<Socket>();
  const server = createServer(socket => {
    sockets.add(socket);socket.on('close',()=>sockets.delete(socket));
    let buffered=Buffer.alloc(0);
    socket.on('data',data=>{
      buffered=Buffer.concat([buffered,data]);
      while (buffered.length>=4 && buffered.length>=buffered.readInt32LE(0)+4) {
        const size=buffered.readInt32LE(0), frame=buffered.subarray(4,size+4);
        buffered=buffered.subarray(size+4);
        const id=frame.readInt32LE(0), kind=frame.readInt32LE(4), text=frame.subarray(8,-2).toString();
        let body='';
        if(kind===2) {
          const match=text.match(/\n(\{.*\})\]\]/);
          assert(match,`bad dispatch: ${text}`);
          const request=JSON.parse(match[1]!);
          body=JSON.stringify({id:request.id,tick:1,...reply(request)});
        }
        const out=Buffer.alloc(Buffer.byteLength(body)+14);
        out.writeInt32LE(out.length-4,0);out.writeInt32LE(id,4);out.writeInt32LE(kind===3?2:0,8);out.write(body,12);
        socket.write(out);
      }
    });
  }).listen(0,'127.0.0.1');
  await once(server,'listening');
  const address=server.address();assert(address && typeof address!=='string');
  try { await run(address.port); }
  finally {for(const socket of sockets)socket.destroy();await new Promise<void>(resolve=>server.close(()=>resolve()));}
}
function cli(port:number,args:string[]) {
  return exec(process.execPath,['dist/host/cli.js','--format','json','--port',String(port),...args],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
}
test('CLI help works without a server or credentials',async()=>{
  const {stdout}=await exec(process.execPath,['dist/host/cli.js','--help']);
  assert.match(stdout,/queue submit/);assert.match(stdout,/blueprint import/);
});
test('queue command maps to runtime protocol with JSON-only stdout',async()=>{
  await engine(request=>{
    assert.equal(request.action,'queue_status');assert.equal(request.player,2);
    return {ok:true,result:{revision:5,pending:[]}};
  },async port=>{
    const {stdout,stderr}=await cli(port,['queue','status','--player','2']);
    assert.equal(stderr,'');assert.equal(JSON.parse(stdout).result.revision,5);
  });
});
test('--wait waits for shoot channel and reports interrupted completion',async()=>{
  let polls=0;
  await engine(request=>{
    if(request.action==='shoot')return {ok:true,result:{until_tick:60}};
    assert.equal(request.action,'status');polls++;
    return {ok:true,result:polls===1?{active:{kind:'shoot'},combat:{until_tick:60}}:{active:false,combat:false,last_combat:{outcome:'interrupted'}}};
  },async port=>{
    try {
      await cli(port,['call','shoot','--args','{"auto":true,"ticks":60}','--wait']);
      assert.fail('interrupted action must exit nonzero');
    } catch(error:any) {
      assert.equal(error.code,1);
      assert.equal(JSON.parse(error.stdout).error.code,'action_interrupted');
      assert.equal(polls,2);
    }
  });
});
test('compact CLI output preserves failure details and nonzero exit status',async()=>{
  await engine(()=>({ok:false,error:{code:'placement_blocked',message:'Cannot build here'}}),async port=>{
    await assert.rejects(cli(port,['call','build','--format','compact']), (error:any)=>{
      assert.equal(error.code,1);
      assert.match(error.stdout,/ok: false/);
      assert.match(error.stdout,/code: placement_blocked/);
      assert.match(error.stdout,/message: "Cannot build here"/);
      return true;
    });
  });
});

test('CLI defaults to compact output',async()=>{
  await engine(()=>({ok:true,result:{revision:5}}),async port=>{
    const {stdout}=await exec(process.execPath,['dist/host/cli.js','--port',String(port),'queue','status'],{env:{...process.env,FACTORIO_RCON_PASSWORD:'test-only'}});
    assert.match(stdout,/revision: 5/);
    assert.throws(()=>JSON.parse(stdout));
  });
});
