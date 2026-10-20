// Regex evaluation is isolated so a pathological pattern cannot block editing.
self.onmessage = ({data:{sources,query,caseSensitive,regex,replacement}}) => {
  try {
    if (!query) {self.postMessage({matches:[]});return;}
    const pattern = regex ? query : query.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
    const re = new RegExp(pattern,caseSensitive?'gu':'giu');
    const matches=[];
    for (const cell of sources) {
      re.lastIndex=0;
      for (const match of cell.source.matchAll(re)) {
        if(matches.length>=10000) throw new Error('Too many matches. Narrow your search (limit: 10,000).');
        // Use native replacement expansion, retaining full-source context for lookarounds.
        let insert=replacement;
        if(regex) insert=replacement.replace(/\$(\$|&|`|'|<[^>]+>|\d{1,2})/g,(token,key)=>{
          if(key==='$')return '$';if(key==='&')return match[0];
          if(key==='`')return cell.source.slice(0,match.index);if(key==="'")return cell.source.slice(match.index+match[0].length);
          if(key[0]==='<')return match.groups ? (match.groups[key.slice(1,-1)]??'') : token;
          const n=Number(key);if(n>0&&n<match.length)return match[n]??'';
          if(key.length===2&&Number(key[0])>0&&Number(key[0])<match.length)return (match[Number(key[0])]??'')+key[1];
          return token;
        });
        matches.push({key:cell.key,from:match.index,to:match.index+match[0].length,insert});
      }
    }
    self.postMessage({matches});
  } catch(error) { self.postMessage({error:error.message}); }
};
