// Regenerates mac/Fixtures/js-format.tsv: how JavaScript's JSON.parse + JSON.stringify treat tricky inputs.
// Each line: base64(input) TAB base64(compact) TAB base64(pretty, 2 spaces). Compact "!" = JSON.parse must fail.
//     node mac/Fixtures/make-js-format.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const cases = [
  // numbers
  '0', '-0', '1', '-1', '0.1', '0.0084', '0.0042', '0.000015', '0.000001', '1e-7', '1.5e-7', '-0.0000012345',
  '123456789012', '1795549492135', '9007199254740993', '1e20', '1e21', '1.5e21', '123e-20', '3.0', '2.5e300',
  '1E5', '1e+2', '5e-324', '1.7976931348623157e308', '0.30000000000000004', '100', '1234.5678',
  // strings
  '"plain"', '"q\\"b\\\\s\\/"', '"\\b\\f\\n\\r\\t"', '"\\u0001\\u001f\\u007f"', '"\\u00e9\\u2028\\u2029"',
  '"\\ud83d\\ude80 é ñ 🚀"', '"</script>"', '""',
  // structure
  '[]', '{}', '[[]]', '{"a":{}}', '{"a":1,"b":2,"a":3}', '[1,"two",true,false,null,{"k":[1,{"x":null}]}]',
  ' \n\t{ "sp" : [ 1 , 2 ] } \r\n', '{"":0,"é":"ü"}',
  '{"b":1,"2":2,"10":3,"1":4,"01":5,"4294967295":6,"4294967294":7}',   // JS lists integer-like keys first
  // invalid
  '{', '[1,]', '01', '1.', '.5', '+1', 'NaN', 'Infinity', '"\\x"', '"a\nb"', 'tru', '{} x', "{'a':1}", '', '[1 2]',
  '{"a" 1}', '-', '1e', '"\\u12"',
];
const b64 = (s) => Buffer.from(s, 'utf8').toString('base64');
const lines = cases.map((c) => {
  let v;
  try { v = JSON.parse(c); } catch { return `${b64(c)}\t!\t!`; }
  return `${b64(c)}\t${b64(JSON.stringify(v))}\t${b64(JSON.stringify(v, null, 2))}`;
});
const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'js-format.tsv');
fs.writeFileSync(out, `${lines.join('\n')}\n`);
console.log(`wrote ${out} (${cases.length} cases)`);
