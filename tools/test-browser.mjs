// Core browser checks use only local fixtures; real release-download probes are
// separate integration checks. Each driver owns a fresh Chrome profile/server.
import {spawn} from 'node:child_process';
import {appendFile} from 'node:fs/promises';
import {performance} from 'node:perf_hooks';
import {fileURLToPath,pathToFileURL} from 'node:url';
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
// Each worker owns a complete driver process, including Chrome/profile/server.
// Buffer its log so parallel suites still produce readable GitHub log groups.
function runSuite([label,page,script,viewport]) {
  const [name,query]=page.split('?');
  const args=[driver,'--page',`web/${name}.html${query===undefined?'':'?'+query}`,'--timeout','180000'];
  if(script)args.push('--script',fileURLToPath(new URL(script,import.meta.url)));
  if(viewport)args.push('--viewport',viewport);
  return new Promise(resolve=>{
    const child=spawn(process.execPath,args,{stdio:['ignore','pipe','pipe']});
    const chunks=[];
    child.stdout.on('data',chunk=>chunks.push(chunk));
    child.stderr.on('data',chunk=>chunks.push(chunk));
    child.on('error',error=>chunks.push(Buffer.from(error.stack+'\n')));
    child.on('close',code=>resolve({code:code??1,log:Buffer.concat(chunks).toString()}));
  });
}

export async function runSuites(items,{jobs=2,run=runSuite,report=()=>{}}={}) {
  if(!Number.isInteger(jobs)||jobs<1)throw new Error('Browser jobs must be a positive integer');
  const results=new Array(items.length);
  let next=0;
  await Promise.all(Array.from({length:Math.min(jobs,items.length)},async()=>{
    while(next<items.length) {
      const index=next++,start=performance.now();
      let result;
      try {result=await run(items[index]);}
      catch(error) {result={code:1,log:String(error.stack??error)};}
      results[index]={...result,label:items[index][0],seconds:(performance.now()-start)/1000};
      report(results[index]);
    }
  }));
  return results;
}

if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) {
  const jobs=Number(process.env.ROCLET_BROWSER_JOBS??2),start=performance.now();
  const results=await runSuites(suites,{jobs,report:result=>{
    console.log(`::group::${result.label} (${result.seconds.toFixed(1)}s)`);
    process.stdout.write(result.log);
    console.log('::endgroup::');
  }});
  const summary=[
    `Browser suites: ${((performance.now()-start)/1000).toFixed(1)}s elapsed, ${jobs} workers.`,
    '', '| Suite | Time | Result |', '| --- | ---: | --- |',
    ...[...results].sort((a,b)=>b.seconds-a.seconds).map(r=>`| ${r.label} | ${r.seconds.toFixed(1)}s | ${r.code===0?'PASS':'FAIL'} |`),
    '',
  ].join('\n');
  console.log(summary);
  if(process.env.GITHUB_STEP_SUMMARY)await appendFile(process.env.GITHUB_STEP_SUMMARY,summary+'\n');
  if(results.some(result=>result.code!==0))process.exitCode=1;
}
