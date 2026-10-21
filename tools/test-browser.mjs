// Core browser checks use only local fixtures; real release-download probes are
// separate integration checks. Each driver owns a fresh Chrome profile/server.
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const driver=fileURLToPath(new URL('./browser-check.mjs',import.meta.url));
const suites=[
  ['Document parity','document-conformance'],
  ['Reactive evaluation','m4-conformance'],
  ['Notebook lifecycle','edit-conformance'],
  ['Notebook startup','startup-conformance'],
  ['Desktop notebook UI','edit-ui-conformance'],
  ['Compact notebook UI','edit-ui-conformance',null,'390x960'],
  ['Sharing and offline','m3-conformance'],
  ['Rich outputs','m5-conformance'],
  ['Math','math-conformance'],
  ['Workspace and packages','workspace-conformance'],
  ['Side-by-side notebooks','dual-conformance'],
  ['Side-by-side notebooks, medium width','dual-conformance?medium'],
  ['Side-by-side notebooks as tabs','dual-conformance?compact'],
  ['Demos','demos-conformance'],
  ['Desktop assertions','edit','browser-expect-probe.mjs'],
  ['Compact assertions','edit','browser-expect-probe.mjs','390x960'],
];
for(const [label,page,script,viewport] of suites) {
  console.log(`::group::${label}`);
  const [name,query]=page.split('?');
  const args=[driver,'--page',`web/${name}.html${query===undefined?'':'?'+query}`,'--timeout','180000'];
  if(script)args.push('--script',fileURLToPath(new URL(script,import.meta.url)));
  if(viewport)args.push('--viewport',viewport);
  const result=spawnSync(process.execPath,args,{stdio:'inherit'});
  console.log('::endgroup::');
  if(result.error)throw result.error;
  if(result.status!==0)process.exit(result.status??1);
}
