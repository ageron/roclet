// Plume's Chart.to_json produces {data, layout}. Validate imported snapshots too.
export function plotlyFigure(content) {
  if(typeof content!=='string' || new TextEncoder().encode(content).length>131072) return null;
  try {
    const figure=JSON.parse(content),object=v=>v!==null && typeof v==='object' && !Array.isArray(v);
    if(!object(figure) || !Array.isArray(figure.data) || !figure.data.every(object) || !object(figure.layout)) return null;
    return {data:figure.data,layout:figure.layout};
  } catch {return null;}
}

const plotlyUrl=new URL('./vendor/plotly/plotly.min.js',import.meta.url).href;

export function renderPlotly(content,text,doc) {
  const frame=doc.createElement('iframe');
  frame.title=text || 'Plotly chart';frame.className='display-plotly';
  frame.setAttribute('sandbox','allow-scripts');frame.referrerPolicy='no-referrer';
  frame.style.cssText='width:100%;height:440px;border:0;display:block;resize:vertical;min-height:200px;max-height:900px;';
  let port,disposed=false,failed=false,sequence=0,latest,settle,timer;
  Object.defineProperty(frame,'failed',{get:()=>failed});
  const finish=()=>{clearTimeout(timer);settle?.();settle=null;};
  frame.update=(next,title)=>{
    const figure=plotlyFigure(next);if(!figure || disposed || failed)return false;
    finish();frame.title=title || 'Plotly chart';latest={type:'figure',figure,id:++sequence};
    frame.rendered=new Promise(resolve=>{settle=resolve;});
    timer=setTimeout(()=>{failed=true;finish();},20000);
    port?.postMessage(latest);return true;
  };
  frame.dispose=()=>{disposed=true;frame.onload=null;port?.close();finish();};
  frame.onload=()=>{
    if(disposed)return;
    port?.close();const channel=new MessageChannel();port=channel.port1;
    port.onmessage=({data})=>{
      if(disposed)return;
      if(data.type==='ready')port.postMessage(latest);
      if(data.type==='failed'){failed=true;finish();}
      if(data.type==='drawn' && data.id===sequence)finish();
    };
    port.start();frame.contentWindow.postMessage({type:'roclet-plotly-connect'},'*',[channel.port2]);
  };
  const json=JSON.stringify(plotlyFigure(content)).replace(/</g,'\\u003c').replace(/>/g,'\\u003e').replace(/&/g,'\\u0026');
  const policy=`default-src 'none'; script-src 'unsafe-inline' ${plotlyUrl}; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'`;
  frame.srcdoc=`<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${policy}"><meta name="referrer" content="no-referrer"><style>html,body{margin:0;height:100%;font:14px system-ui}#chart{width:100%;height:100%}#status{padding:12px}</style></head><body><div id="status" role="status">Loading chart…</div><div id="chart"></div><script type="application/json" id="figure">${json}</script><script>
    const status=document.getElementById('status'),chart=document.getElementById('chart');
    let port,pending,running=false,loaded=false,failed=false;
    const fail=()=>{failed=true;status.hidden=false;status.textContent='Chart preview unavailable. See the plain-text result below.';chart.hidden=true;port?.postMessage({type:'failed'});};
    async function draw(){
      if(running || !loaded || failed)return;
      running=true;
      try{while(pending){const {figure,id}=pending;pending=null;status.hidden=true;
        await Plotly.react(chart,figure.data,{...figure.layout,uirevision:figure.layout.uirevision??'roclet',width:undefined,height:undefined,autosize:true},{responsive:true,displaylogo:false,showLink:false});
        chart.dataset.ready='true';port?.postMessage({type:'drawn',id});
      }}catch{fail();}finally{running=false;}
    }
    addEventListener('message',event=>{
      if(event.source!==parent || event.data?.type!=='roclet-plotly-connect' || !event.ports[0] || port)return;
      port=event.ports[0];port.onmessage=({data})=>{if(data?.type==='figure'){pending=data;void draw();}};
      port.start();port.postMessage({type:failed?'failed':'ready'});
    });
    const script=document.createElement('script');script.src=${JSON.stringify(plotlyUrl)};
    script.onerror=fail;script.onload=()=>{loaded=true;pending??={figure:JSON.parse(document.getElementById('figure').textContent),id:0};void draw();};
    document.head.append(script);
  </script></body></html>`;
  frame.update(content,text);
  return frame;
}
