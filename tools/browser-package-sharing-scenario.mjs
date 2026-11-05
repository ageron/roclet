// Exercise origin-wide locks with real compiler workers owned by two tabs.
export default async function({evaluate,send}) {
  await evaluate(`(async()=>{while(document.documentElement.dataset.ready!=='true')await new Promise(resolve=>setTimeout(resolve,25));})()`);
  await send('Runtime.evaluate',{expression:"globalThis.__packagePeer=window.open('about:blank','roclet-package-sharing');",userGesture:true});
  return evaluate(`(${probe.toString()})()`);
}

async function probe() {
  const peer=globalThis.__packagePeer;
  if(!peer)throw Error('The peer tab did not open');
  const assert=(value,message)=>{if(!value)throw Error(message);};
  const workers=[],pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const until=async(predicate,label)=>{const end=Date.now()+30000;while(!predicate()){if(Date.now()>end)throw Error('Timed out: '+label);await pause(20);}};
  const module=path=>JSON.stringify(new URL(path,location.href).href);
  const source='https://github.com/ageron/roc-ascii/releases/download/v0.5.1/3mkSijmaYYGXbT6EvDAXyV4Y9YzYncztbWNDfRSr3z3f.tar.zst';
  const archive=new URL('/web/vendor/roc-packages/archives/3mkSijmaYYGXbT6EvDAXyV4Y9YzYncztbWNDfRSr3z3f.tar.zst',location.href).href;
  const bytes=await fetch('/artifacts/roclet.wasm').then(r=>r.arrayBuffer());
  const workerSource=`
    import {createWasmTransport} from ${module('/compiler-adapter/wasm.mjs')};
    import {BrowserPackages} from ${module('/web/packages.mjs')};
    import {BuildCache} from ${module('/web/build-cache.mjs')};
    let release;const gate=new Promise(resolve=>{release=resolve;});
    onmessage=async({data})=>{
      if(data.release){release();return;}
      try {
        if(!navigator.locks)throw Error('Web Locks unavailable');
        const raw=await createWasmTransport(data.bytes);
        const packages=new BrowserPackages(new BuildCache(data.namespace),{
          onProgress:progress=>postMessage({progress}),
          fetch:async(_url,options)=>{
            if(!data.allowDownload)throw Error('A shared verified archive was downloaded again');
            postMessage({fetching:true});await gate;
            return fetch(data.archive,options);
          },
        });
        const installed=await packages.install(raw,data.source);
        const checked=raw({operation:'document',action:'evaluate',format:'roc',source:data.notebook});
        if(checked.status!=='ok' || checked.evaluation.values[0]?.text!=='True')throw Error(JSON.stringify(checked));
        postMessage({installed});
      }catch(error){postMessage({error:error.stack});}
    };
  `;
  const blob=URL.createObjectURL(new Blob([workerSource],{type:'text/javascript'}));
  const notebook=`app [] { ascii: "${source}" }\n\nimport ascii.Ascii\nout_ok = Ascii.from_str("hello").is_ok()\n`;
  function start(owner,namespace,allowDownload=true) {
    const worker=new owner.Worker(blob,{type:'module'}),events=[];
    const result=new Promise((resolve,reject)=>{
      worker.onmessage=({data})=>{events.push(data);if(data.error)reject(Error(data.error));if(data.installed)resolve(data.installed);};worker.onerror=reject;
    });
    // A deliberately terminated owner never settles. Keep rejections observed
    // while the scenario waits for particular progress messages.
    result.catch(()=>{});
    const item={worker,events,result};workers.push(item);
    worker.postMessage({bytes,namespace,source,archive,notebook,allowDownload});return item;
  }
  const fetching=item=>item.events.some(event=>event.fetching);
  const waiting=item=>item.events.some(event=>event.progress?.phase==='waiting');
  const release=item=>item.worker.postMessage({release:true});
  const namespace=()=>`sharing-probe:${crypto.randomUUID()}:packages`;
  try {
    const shared=namespace(),a=start(window,shared);
    await until(()=>fetching(a),'first owner');
    const b=start(peer,shared);await until(()=>waiting(b),'peer waiting for archive');
    assert(!fetching(b),'Peer fetched while the first owner held the lock');
    release(a);
    assert(JSON.stringify(await Promise.all([a.result,b.result]))===JSON.stringify(['downloaded','cached']),'Peer did not reuse the verified download');
    a.worker.terminate();b.worker.terminate();
    const fresh=start(peer,shared,false);assert(await fresh.result==='cached','Fresh peer worker did not restore the shared archive');fresh.worker.terminate();

    const cancelled=namespace(),owner=start(window,cancelled);
    await until(()=>fetching(owner),'cancellable owner');
    const successor=start(peer,cancelled);await until(()=>waiting(successor),'successor waiting');
    owner.worker.terminate();
    await until(()=>fetching(successor),'successor taking released lock');release(successor);
    assert(await successor.result==='downloaded','Terminating the owner did not release its lock');successor.worker.terminate();

    const stopped=namespace(),remaining=start(window,stopped);
    await until(()=>fetching(remaining),'remaining owner');
    const waiter=start(peer,stopped);await until(()=>waiting(waiter),'cancellable waiter');
    waiter.worker.terminate();release(remaining);
    assert(await remaining.result==='downloaded','Cancelling a waiter aborted the owner');
    return {result:'pass',crossTabDeduplication:'pass',freshWorkerReuse:'pass',ownerCancellation:'pass',waiterCancellation:'pass'};
  } finally {
    for(const item of workers)item.worker.terminate();
    URL.revokeObjectURL(blob);peer.close();delete globalThis.__packagePeer;
  }
}
