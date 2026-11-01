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
  // This frame has an opaque origin and only loads the fixed, bundled renderer.
  // Figure text cannot close the JSON script element or add HTML/scripts.
  const json=JSON.stringify(plotlyFigure(content)).replace(/</g,'\\u003c').replace(/>/g,'\\u003e').replace(/&/g,'\\u0026');
  const policy=`default-src 'none'; script-src 'unsafe-inline' ${plotlyUrl}; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'`;
  frame.srcdoc=`<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${policy}"><meta name="referrer" content="no-referrer"><style>html,body{margin:0;height:100%;font:14px system-ui}#chart{width:100%;height:100%}#status{padding:12px}</style></head><body><div id="status" role="status">Loading chart…</div><div id="chart"></div><script type="application/json" id="figure">${json}</script><script>
    const status=document.getElementById('status'),chart=document.getElementById('chart');
    const fail=()=>{status.hidden=false;status.textContent='Chart preview unavailable. See the plain-text result below.';chart.hidden=true;};
    const script=document.createElement('script');script.src=${JSON.stringify(plotlyUrl)};
    script.onerror=fail;script.onload=async()=>{
      try {
        const figure=JSON.parse(document.getElementById('figure').textContent);
        status.hidden=true;
        await Plotly.newPlot(chart,figure.data,{...figure.layout,width:undefined,height:undefined,autosize:true},{responsive:true,displaylogo:false,showLink:false});
        chart.dataset.ready='true';
      } catch {fail();}
    };
    document.head.append(script);
  </script></body></html>`;
  return frame;
}
