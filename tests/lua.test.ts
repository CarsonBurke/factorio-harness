import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
for (const path of ['tests/scheduler.lua','tests/blueprints.lua','mod/tests/runtime_test.lua','mod/tests/control_test.lua']) {
  test(`Lua contract: ${path}`, () => {
    execFileSync(process.env.LUA_BIN ?? 'lua',[path],{stdio:'pipe'});
  });
}
