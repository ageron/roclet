// Run with browser-check.mjs --page 'web/edit.html?new=1' --script <this file>.
// Uses a released package intentionally absent from the production mirror.
(async()=>{
  const assert=(value,message)=>{if(!value)throw Error(message);};
  const url='https://github.com/niclas-ahden/roc-crc32/releases/download/2.0.0/Dpu6zTP4s6bYRC2U9jWK7CcNBNGEfViKQbp35xSRC2Cr.tar.zst';
  const [config,mirror,bytes]=await Promise.all([
    fetch('/web/package-config.json').then(r=>r.json()),
    fetch('/web/vendor/roc-packages/manifest.json').then(r=>r.json()),
    fetch('/artifacts/roclet.wasm').then(r=>r.arrayBuffer()),
  ]);
  assert(config.endpoint,'Configure a public fetcher endpoint for this probe');
  assert(!mirror.packages.some(entry=>entry.url===url),'The test package must remain outside the static mirror');
  const {DocumentSession}=await import('/web/document-session.mjs');
  const session=new DocumentSession(bytes),waiting=[],progress=[];
  const source=`app [] { crc: "${url}" }\n\nimport crc.Crc32\nout_ok = Crc32.checksum("123456789".to_utf8()) == 0xCBF43926\n`;
  const request={operation:'document',action:'evaluate',format:'roc',source};
  const options={onPackageWaiting:value=>waiting.push(value),onPackageProgress:details=>progress.push(details),loadPackage:details=>{throw Error('Unexpected manual package prompt: '+JSON.stringify(details));}};
  const check=result=>assert(result.status==='ok' && result.evaluation.values[0]?.text==='True',JSON.stringify(result));
  try {
    check(await session.request(request,options));
    assert(waiting.includes(true) && waiting.at(-1)===false,'Automatic download progress was not balanced');
    assert(progress.some(details=>details.phase==='downloading' && details.received>0) && progress.some(details=>details.phase==='verifying'),'Download and verification progress was not reported');
    const edited={...request,source:source.replace('"123456789"','""').replace('0xCBF43926','0')};
    check(await session.request(edited,options));
    session.stop();check(await session.request(edited,options));
    const [{createWasmTransport},{BuildCache,compilerNamespace},{BrowserPackages}]=await Promise.all([
      import('/compiler-adapter/wasm.mjs'),import('/web/build-cache.mjs'),import('/web/packages.mjs'),
    ]);
    const raw=await createWasmTransport(bytes),namespace=await compilerNamespace(bytes,raw.cacheIdentity());
    const packages=new BrowserPackages(new BuildCache(namespace+':packages'),{fetch:()=>{throw Error('Package networking disabled');}});
    check(await packages.evaluate(raw,request));
    const invalid=await fetch(new URL('not-a-package',config.endpoint));
    assert(invalid.status===400,'Public validation error is not readable through CORS');
    return {result:'pass',endpoint:config.endpoint,package:url,checksum:'pass',edited:'pass',workerRestart:'pass',offlinePackageReuse:'pass',corsErrorsReadable:'pass',progress:'pass',waiting};
  } finally {session.stop();}
})()
