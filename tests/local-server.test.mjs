import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,mkdir,symlink,rm,access,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {request} from 'node:http';
import {ServerProject} from '../web/server-project.mjs';
const root=resolve(import.meta.dirname,'..'),binary=join(root,'zig-out/bin/roclet');
const available=await access(binary).then(()=>true,()=>false);
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function port(){const s=createServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p;}
async function launch(project,home,args=[]){
  const p=await port(),base=`http://127.0.0.1:${p}`;
  const child=spawn(binary,['serve',project,'--assets',root,'--port',String(p),'--no-browser',...args],{env:{...process.env,HOME:home},stdio:['ignore','pipe','pipe']});
  let log='';child.stderr.on('data',b=>log+=b);
  for(let i=0;i<100;i++){
    const token=log.match(/\?token=([a-f0-9]{64})/)?.[1];
    const response=token?await fetch(`${base}/api/local/config`,{headers:{'X-Roclet-Token':token}}).catch(()=>null):null;
    if(response?.ok){const config=await response.json();return {base,child,config,client:new ServerProject(config,{fetch:(path,options)=>fetch(base+path,options)})};}
    if(child.exitCode!==null)throw new Error(log);await pause(30);
  }
  child.kill();throw new Error(`Server did not start: ${log}`);
}
async function stop(server){server.child.kill();await new Promise(r=>server.child.once('exit',r));}
test('local project files, conflict protection, confinement, package cache and restart',{skip:!available},async()=>{
  const temp=await mkdtemp(join(tmpdir(),'roclet-local-')),project=join(temp,'project'),home=join(temp,'home');let server;
  try {
    await mkdir(project);await mkdir(home);await mkdir(join(project,'nested'));await mkdir(join(project,'.git'));
    await writeFile(join(project,'note.roc'),'a = 1');await writeFile(join(project,'Helper.roc'),'module [answer]\nanswer = 42');
    await writeFile(join(project,'nested/data.txt'),'hello');await writeFile(join(project,'nested/other.md'),'# Other');
    await writeFile(join(project,'.git/config'),'secret');await writeFile(join(temp,'outside.roc'),'secret');
    await symlink(join(temp,'outside.roc'),join(project,'linked.roc'));await symlink(temp,join(project,'escape'));
    server=await launch(project,home);let {client,base,config}=server;
    const fetch=(url,options={})=>globalThis.fetch(url,{...options,headers:{'X-Roclet-Token':server.config.token,...options.headers}});
    assert.equal(config.root,await realpath(project));assert.equal(config.initial,null);
    assert.deepEqual((await client.call('list')).paths.sort(),['nested/other.md','note.roc']);
    assert.equal((await client.call('read','note.roc')).source,'a = 1');
    const files=(await client.call('workspace','note.roc')).files;
    assert.equal(files.find(f=>f.path==='Helper.roc').source,'module [answer]\nanswer = 42');
    assert.equal(files.find(f=>f.path==='nested/data.txt').source,'hello');
    assert(!files.some(f=>f.path==='note.roc'));
    for(const path of ['../outside.roc','/etc/passwd','.git/config','escape/outside.roc','linked.roc','nested/../note.roc'])await assert.rejects(client.call('read',path));
    assert.equal((await globalThis.fetch(base+'/api/local/files',{method:'POST',headers:{Cookie:`roclet_session_${new URL(base).port}=${config.token}`},body:'{}'})).status,403);
    assert.equal((await fetch(base+'/api/local/config',{headers:{Origin:'https://evil.example'}})).status,403);
    assert.equal(await new Promise((resolve,reject)=>{const req=request(base+'/api/local/config',{headers:{Host:'evil.example'}},res=>{res.resume();resolve(res.statusCode);});req.on('error',reject);req.end();}),403);
    const handle=client.handle('note.roc');await handle.getFile();const stream=await handle.createWritable();await stream.write('a = 2');await stream.close();
    assert.equal(await readFile(join(project,'note.roc'),'utf8'),'a = 2');
    await handle.getFile();const stale=await handle.createWritable();await stale.write('a = 3');await writeFile(join(project,'note.roc'),'external');
    await assert.rejects(stale.close(),/changed outside/);assert.equal(await readFile(join(project,'note.roc'),'utf8'),'external');
    const saves=await Promise.allSettled([client.call('write','note.roc',{source:'winner A',expected:'external'}),client.call('write','note.roc',{source:'winner B',expected:'external'})]);
    assert.equal(saves.filter(r=>r.status==='fulfilled').length,1);
    await client.call('write','new.md',{source:'# New',expected:null});
    await assert.rejects(client.call('write','new.md',{source:'overwrite',expected:null}),/changed outside/);
    await assert.rejects(client.call('write','../outside.roc',{source:'overwrite',expected:'secret'}));
    assert.equal(await readFile(join(temp,'outside.roc'),'utf8'),'secret');
    assert.deepEqual(await (await fetch(base+'/web/package-config.json')).json(),{endpoint:null});
    // Seed a verified archive in the persistent cache and request it with no download.
    const hash='FPCEjLpsoY5fJ6nDBCeJQ1s6aMTQjMWUYAVQu6QdNuzr';
    const alphabet='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';let n=0n;for(const c of hash)n=n*58n+BigInt(alphabet.indexOf(c));
    const cache=join(home,'.cache/roclet/packages');await mkdir(cache,{recursive:true});
    const archive=await readFile(join(root,'artifacts',hash+'.tar.zst'));await writeFile(join(cache,n.toString(16).padStart(64,'0')),archive);
    const packagePath=`/api/packages/test/test/1/${hash}.tar.zst`;
    const response=await fetch(base+packagePath);assert.equal(response.status,200);assert.equal(response.headers.get('X-Roclet-Package-Cache'),'disk');
    assert.deepEqual(Buffer.from(await response.arrayBuffer()),archive);
    await stop(server);server=await launch(join(project,'note.roc'),home);assert.equal(server.config.initial,'note.roc');assert.notEqual(server.config.token,config.token);
    assert.equal((await fetch(server.base+packagePath)).headers.get('X-Roclet-Package-Cache'),'disk');
    assert.match((await server.client.call('read','note.roc')).source,/winner/);
  }finally{if(server && server.child.exitCode===null)await stop(server);await rm(temp,{recursive:true,force:true});}
});

test('wildcard binding accepts IP hosts but rejects foreign origins and DNS hosts',{skip:!available},async()=>{
  const temp=await mkdtemp(join(tmpdir(),'roclet-bind-'));let server;
  const status=(host,origin)=>new Promise((resolve,reject)=>{
    const req=request(server.base+'/api/local/config',{headers:{'X-Roclet-Token':server.config.token,Host:host,...(origin?{Origin:origin}:{})}},res=>{res.resume();resolve(res.statusCode);});
    req.on('error',reject);req.end();
  });
  try {
    server=await launch(temp,temp,['--bind','0.0.0.0']);
    const p=new URL(server.base).port,host=`192.0.2.10:${p}`;
    assert.equal(await status(host,`http://${host}`),200);
    assert.equal(await status(host,'http://evil.example'),403);
    assert.equal(await status(`evil.example:${p}`),403);
    assert.equal(await status('192.0.2.10:1'),403);
    assert.equal(await status('127.0.0.1'),403);
  } finally {if(server)await stop(server);await rm(temp,{recursive:true,force:true});}
});

test('both executables offer explicit commands and useful help',{skip:!available},async()=>{
  const {spawnSync}=await import('node:child_process');
  for(const executable of [binary,join(root,'zig-out/bin/roclet-serve')]) {
    for(const args of [[],['--help'],['serve','--help'],['serve-static','-h']]) {
      const result=spawnSync(executable,args,{encoding:'utf8',timeout:5000});
      assert.equal(result.status,0,result.stderr);
      assert.match(result.stdout,/roclet serve-static/);
      assert.match(result.stdout,/--bind ADDRESS/);
      assert.match(result.stdout,/127\.0\.0\.1/);
    }
    const result=spawnSync(executable,['demos'],{encoding:'utf8',timeout:5000});
    assert.notEqual(result.status,0);assert.match(result.stderr,/roclet serve demos/);
  }
});

test('serve-static serves the selected assets without the local file API',{skip:!available},async()=>{
  const p=await port(),base=`http://127.0.0.1:${p}`;
  const child=spawn(binary,['serve-static',root,'--port',String(p),'--bind','127.0.0.1'],{stdio:'ignore'});
  try {
    let response;
    for(let i=0;i<100;i++) {response=await fetch(base).catch(()=>null);if(response)break;await pause(30);}
    assert.equal(response?.status,200);
    assert.match(await response.text(),/Roclet/);
    assert.equal((await fetch(base+'/api/local/config')).status,404);
  } finally {await stop({child});}
});

test('private startup URL protects pages, APIs and proxy; cookie login and token rotation',{skip:!available},async()=>{
  const temp=await mkdtemp(join(tmpdir(),'roclet-auth-'));let server;
  try {
    server=await launch(temp,temp);
    const oldToken=server.config.token;
    assert.match(oldToken,/^[a-f0-9]{64}$/);
    for(const path of ['/','/web/edit.html','/artifacts/manifest.json','/api/local/config','/api/local/files','/api/packages/test']) {
      const response=await fetch(server.base+path);
      assert.equal(response.status,401,path);
      assert.equal(response.headers.get('Cache-Control'),'no-store');
      assert.ok(!(await response.text()).includes(oldToken));
    }
    assert.equal((await fetch(server.base+'/?token=bad')).status,401);
    const login=await fetch(server.base+'/?token='+oldToken,{redirect:'manual'});
    assert.equal(login.status,303);
    assert.equal(login.headers.get('Location'),'/');
    assert.equal(login.headers.get('Referrer-Policy'),'no-referrer');
    const cookie=login.headers.get('Set-Cookie');
    assert.match(cookie,/HttpOnly/);assert.match(cookie,/SameSite=Strict/);
    const headers={Cookie:cookie.split(';')[0]};
    assert.equal((await fetch(server.base+'/web/edit.html',{headers})).status,200);
    assert.equal((await fetch(server.base+'/api/local/config',{headers})).status,200);
    assert.equal((await fetch(server.base+'/api/local/files',{method:'POST',headers,body:'{}'})).status,403);
    await stop(server);server=await launch(temp,temp);
    assert.notEqual(server.config.token,oldToken);
    assert.equal((await fetch(server.base+'/?token='+oldToken)).status,401);
    assert.equal((await fetch(server.base+'/api/local/config',{headers:{'X-Roclet-Token':oldToken}})).status,401);
    // Even a cookie with this server's name cannot reuse the old secret.
    assert.equal((await fetch(server.base+'/api/local/config',{headers:{Cookie:`roclet_session_${new URL(server.base).port}=${oldToken}`}})).status,401);
  } finally {if(server && server.child.exitCode===null)await stop(server);await rm(temp,{recursive:true,force:true});}
});
