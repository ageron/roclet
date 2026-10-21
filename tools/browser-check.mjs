// Optional browser test driver: Node 22+ and a locally installed Chrome.
// It uses Chrome's DevTools protocol directly and needs no npm packages.
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';
import {resolve,extname,sep} from 'node:path';
import {tmpdir} from 'node:os';

const args=process.argv.slice(2),option=(key,fallback)=>{const i=args.indexOf(key);return i<0?fallback:args[i+1];};
const root=resolve(import.meta.dirname,'..'),page=option('--page','web/workspace-conformance.html');
const timeout=Number(option('--timeout','120000')),profile=await mkdtemp(resolve(tmpdir(),'roclet-browser-'));
const networkLog=option('--network-log',null),requests=new Map(),networkFailures=[];
const packageEndpoint=option('--package-endpoint',null);
const uploadPlanFile=option('--upload-plan',null),uploads=uploadPlanFile?JSON.parse(await readFile(uploadPlanFile,'utf8')):[];
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const types={'.mjs':'text/javascript','.js':'text/javascript','.wasm':'application/wasm','.html':'text/html; charset=utf-8','.json':'application/json','.css':'text/css','.svg':'image/svg+xml'};
const server=createServer(async(req,res)=>{
  try {
    if(packageEndpoint && new URL(req.url,'http://localhost').pathname==='/web/package-config.json') {
      res.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify({endpoint:packageEndpoint}));return;
    }
    const pathname=new URL(req.url,'http://localhost').pathname;
    const path=resolve(root,pathname==='/'?'index.html':'.'+decodeURIComponent(pathname));
    if(!path.startsWith(root+sep)) {res.writeHead(403);res.end();return;}
    const bytes=await readFile(path);res.writeHead(200,{'Content-Type':types[extname(path)]??'application/octet-stream','Cache-Control':'no-store'});res.end(bytes);
  } catch {res.writeHead(404);res.end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const base=option('--base-url',`http://127.0.0.1:${server.address().port}`);
const chrome=spawn(option('--chrome',process.env.CHROME_PATH??'google-chrome'),['--headless=new','--no-sandbox','--disable-gpu','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{stdio:['ignore','ignore','pipe']});
let startupError;chrome.on('error',error=>{startupError=error;});
let stderr='';chrome.stderr.on('data',chunk=>{stderr+=chunk;});
let socket;
try {
  const started=Date.now();let port;
  while(!port) {
    if(startupError)throw startupError;
    if(chrome.exitCode!=null)throw new Error(`Chrome exited: ${stderr}`);
    try {port=Number((await readFile(resolve(profile,'DevToolsActivePort'),'utf8')).split('\n')[0]);} catch {}
    if(Date.now()-started>15000)throw new Error(`Chrome startup timed out: ${stderr}`);
    if(!port)await sleep(100);
  }
  const pages=await fetch(`http://127.0.0.1:${port}/json/list`).then(r=>r.json());
  const target=pages.find(page=>page.type==='page');
  if(!target)throw new Error('Chrome did not create a browser page');
  socket=new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let id=0;const pending=new Map(),exceptions=[];
  socket.addEventListener('message',({data})=>{
    const value=JSON.parse(data);
    if(value.id){const item=pending.get(value.id);pending.delete(value.id);value.error?item.reject(new Error(JSON.stringify(value.error))):item.resolve(value.result);}
    else if(value.method==='Runtime.exceptionThrown')exceptions.push(value.params.exceptionDetails.exception?.description??value.params.exceptionDetails.text);
    else if(value.method==='Page.fileChooserOpened' && uploadPlanFile) {
      const files=uploads.shift();
      if(!files) exceptions.push('Unexpected file picker: upload plan exhausted');
      else send('DOM.setFileInputFiles',{backendNodeId:value.params.backendNodeId,files:files.map(path=>resolve(path))}).catch(error=>exceptions.push(error.message));
    }
    else if(value.method==='Runtime.bindingCalled' && value.params.name==='__rocletFilePicker') {
      send('Runtime.evaluate',{expression:`document.querySelector(${JSON.stringify(value.params.payload)}).click()`,userGesture:true}).catch(error=>exceptions.push(error.message));
    }
    else if(networkLog && value.method==='Network.requestWillBeSent')requests.set(value.params.requestId,{url:value.params.request.url,type:value.params.type});
    else if(networkLog && value.method==='Network.loadingFailed')networkFailures.push({...requests.get(value.params.requestId),errorText:value.params.errorText,blockedReason:value.params.blockedReason,corsErrorStatus:value.params.corsErrorStatus});
  });
  const send=(method,params={})=>new Promise((resolve,reject)=>{pending.set(++id,{resolve,reject});socket.send(JSON.stringify({id,method,params}));});
  const evaluate=async expression=>{
    const result=await send('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true,timeout});
    if(result.exceptionDetails)throw new Error(result.exceptionDetails.exception?.description??result.exceptionDetails.text);
    return result.result?.value;
  };
  await send('Page.enable');await send('Runtime.enable');
  if(uploadPlanFile) {await send('Page.setInterceptFileChooserDialog',{enabled:true});await send('Runtime.addBinding',{name:'__rocletFilePicker'});}
  if(networkLog)await send('Network.enable');
  // Native focus events are required by editor and iframe UI contracts.
  // Headless Chrome otherwise changes activeElement in a background document
  // without dispatching those events.
  await send('Page.bringToFront');
  const [width,height]=option('--viewport','1280x960').split('x').map(Number);
  await send('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:width<680});
  const navigation=await send('Page.navigate',{url:new URL(page,base+'/').href});
  if(navigation.errorText)throw new Error(`Browser navigation failed: ${navigation.errorText}`);
  await sleep(250);
  const script=option('--script',null);
  if(script)console.log(JSON.stringify(await evaluate(await readFile(script,'utf8')),null,2));
  else {
    const start=Date.now();let state;
    do {
      state=await evaluate('({result:document.documentElement.dataset.result,status:document.querySelector("#status")?.textContent,log:document.querySelector("#log")?.textContent,summary:document.documentElement.dataset.summary})');
      if(!state?.result)await sleep(200);
    } while(!state?.result && Date.now()-start<timeout);
    console.log(JSON.stringify(state,null,2));
    if(state?.result!=='pass') {
      console.error(JSON.stringify(await evaluate('({url:location.href,ready:document.readyState,body:document.body?.innerText?.slice(0,3000)})'),null,2));
      throw new Error(state?.result==='fail'?'Browser conformance failed':'Browser conformance timed out');
    }
  }
  const screenshot=option('--screenshot',null);
  if(screenshot){const {data}=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:!args.includes('--viewport-screenshot')});await writeFile(screenshot,Buffer.from(data,'base64'));console.log(`Screenshot: ${screenshot}`);}
  if(networkLog)await writeFile(networkLog,JSON.stringify(networkFailures,null,2)+'\n');
  if(exceptions.length)throw new Error(exceptions.join('\n'));
  if(uploads.length)throw new Error(`${uploads.length} file selections from the upload plan were not exercised`);
} finally {
  socket?.close();chrome.kill();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));
  if(chrome.exitCode==null)await new Promise(resolve=>{chrome.once('exit',resolve);setTimeout(resolve,3000);});
  await rm(profile,{recursive:true,force:true,maxRetries:10,retryDelay:100});
}
