// Inserted before user HTML. The sandbox keeps this API inside the frame.
export const widgetBootstrap = `<script>
(() => {
  let port, value, notifying=false;
  const callbacks=new Set();
  const notify=callback=>{notifying=true;try{callback(value);}finally{notifying=false;}};
  window.roclet=Object.freeze({
    setValue(next) { if(!notifying && typeof next==='number' && Number.isFinite(next)) port?.postMessage({type:'value',value:next}); },
    onValue(callback) { if(typeof callback!=='function') throw new TypeError('Expected a function'); callbacks.add(callback); if(value!==undefined) notify(callback); return ()=>callbacks.delete(callback); }
  });
  window.addEventListener('message',event=>{
    if(event.source!==parent || event.data?.type!=='roclet-connect' || !event.ports[0] || port) return;
    port=event.ports[0];
    port.onmessage=event=>{
      if(event.data?.type!=='value' || !Number.isFinite(event.data.value)) return;
      value=event.data.value;
      for(const callback of callbacks) {try{notify(callback);}catch(error){console.error(error);}}
    };
    port.start();port.postMessage({type:'ready'});
  });
})();
</script>`;

export function connectWidget(root,frame,config,onInput) {
  let port, disposed=false, current=config.value;
  const send=()=>port?.postMessage({type:'value',value:current});
  frame.onload=()=>{
    port?.close();
    if(disposed || !root.isConnected) return;
    const channel=new MessageChannel();port=channel.port1;
    port.onmessage=event=>{
      if(disposed || !root.isConnected || !frame.isConnected) return;
      const message=event.data;
      if(message?.type==='ready') {send();return;}
      if(message?.type!=='value' || typeof message.value!=='number' || !Number.isFinite(message.value) || message.value<config.min || message.value>config.max) return;
      if(message.value===current) return;
      current=message.value;onInput(config.key,current);
    };
    port.start();
    // Opaque sandbox origins require '*'; delivery is restricted to this frame.
    frame.contentWindow.postMessage({type:'roclet-connect'},'*',[channel.port2]);
  };
  root.setWidgetValue=value=>{current=value;send();};
  root.dispose=()=>{disposed=true;frame.onload=null;port?.close();};
}
