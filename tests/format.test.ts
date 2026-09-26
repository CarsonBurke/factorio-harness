import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatCompact } from '../host/format.js';

test('compact tables share nested keys and preserve absent, null, false, and hostile strings', () => {
  const output = formatCompact({ok:false,id:'retry-id',truncated:true,entities:[
    {name:'belt',position:{x:1,y:2},extra:null},
    {name:'line\n | spoof',position:{x:3,y:4},enabled:false},
  ]});
  assert.match(output,/name \| position.x \| position.y \| extra \| enabled/);
  assert.match(output,/belt \| 1 \| 2 \| null \| <absent>/);
  assert.match(output,/"line\\n \| spoof" \| 3 \| 4 \| <absent> \| false/);
  assert.match(output,/ok: false\nid: retry-id\ntruncated: true/);
});
test('compact distinguishes empty containers and string scalars from literals', () => {
  assert.equal(formatCompact({a:[],b:{},c:'null',d:'42',e:'<absent>'}),
    'a: []\nb: {}\nc: "null"\nd: "42"\ne: "<absent>"\n');
});
test('literal dotted keys cannot overwrite nested column paths', () => {
  const output = formatCompact([{a:{b:1},'a.b':2},{a:{b:3},'a.b':4}]);
  assert.match(output,/a.b \| "a.b"/);
  assert.match(output,/1 \| 2/);
  assert.match(output,/3 \| 4/);
});
