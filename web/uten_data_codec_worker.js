// Same-origin local codec. No network, storage, imports, logging or persistence.
self.onmessage = (event) => {
  const { id, operation, value } = event.data;
  try {
    let result;
    switch (operation) {
      case 'json-encode':
        result = value.map(token => Array.isArray(token) ? JSON.stringify(token[1]) : token).join('');
        break;
      case 'json-decode': result = JSON.parse(value); break;
      case 'base64-encode': {
        const parts = [];
        for (let offset = 0; offset < value.length; offset += 49152) {
          parts.push(btoa(String.fromCharCode.apply(null, value.subarray(offset, offset + 49152))));
        }
        result = parts.join('');
        break;
      }
      case 'base64-decode': {
        const normalized = value.replace(/%3[dD]/g, '=')
          .replace(/-/g, '+').replace(/_/g, '/');
        if (/[^A-Za-z0-9+/=]/.test(normalized) || normalized.length % 4 !== 0) throw Error('base64');
        const pad = normalized.indexOf('=');
        if (pad >= 0 && (!/^={1,2}$/.test(normalized.slice(pad)) || normalized.length % 4 !== 0)) throw Error('base64');
        if (pad >= 0) {
          const last = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'.indexOf(normalized[pad - 1]);
          if ((last & (normalized.endsWith('==') ? 15 : 3)) !== 0) throw Error('base64');
        }
        const binary = atob(normalized);
        result = Uint8Array.from(binary, char => char.charCodeAt(0));
        break;
      }
      case 'utf8-encode': result = new TextEncoder().encode(value); break;
      case 'utf8-decode': result = new TextDecoder('utf-8', { fatal: true }).decode(value); break;
      case 'utf8-decode-lossy': result = new TextDecoder('utf-8').decode(value); break;
      default: throw Error('operation');
    }
    if (result instanceof Uint8Array) self.postMessage({ id, value: result }, [result.buffer]);
    else self.postMessage({ id, value: result });
  } catch (_) {
    self.postMessage({ id, error: true });
  }
};
