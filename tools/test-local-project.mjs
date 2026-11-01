// End-to-end local-project check with the real Zig server and Chrome.
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createServer} from 'node:net';
import {spawn} from 'node:child_process';
const root=resolve(import.meta.dirname,'..'),temp=await mkdtemp(join(tmpdir(),'roclet-project-browser-'));
const socket=createServer();await new Promise(r=>socket.listen(0,'127.0.0.1',r));const port=socket.address().port;await new Promise(r=>socket.close(r));
let server;
try {
  const project=join(temp,'project');await mkdir(project);
  await writeFile(join(project,'Notebook.roc'),'app [main!] {}\n\n# %%\nimport Helper\nout_1 = Helper.answer\n');
  await writeFile(join(project,'Helper.roc'),'module [answer]\nanswer = 42\n');
  server=spawn(join(root,'zig-out/bin/roclet'),['serve',project,'--assets',root,'--port',String(port),'--no-browser'],{stdio:['ignore','ignore','inherit']});
  const base=`http://127.0.0.1:${port}`;
  for(let i=0;i<100;i++){
    if((await fetch(base+'/api/local/config').catch(()=>null))?.ok)break;
    if(server.exitCode!==null)throw new Error('Local server exited');
    await new Promise(r=>setTimeout(r,30));
  }
  const browser=spawn(process.execPath,[join(root,'tools/browser-check.mjs'),'--page',base+'/?home=1','--script',join(root,'tests/local-project-browser.mjs'),'--timeout','90000'],{stdio:'inherit'});
  const code=await new Promise((r,reject)=>{browser.once('error',reject);browser.once('exit',r);});
  if(code!==0)throw new Error('Local project browser checks failed');
} finally {
  if(server && server.exitCode===null){server.kill();await new Promise(r=>server.once('exit',r));}
  await rm(temp,{recursive:true,force:true});
}
