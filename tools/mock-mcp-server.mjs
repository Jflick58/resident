// A small MCP server with OAuth, for trying the app's connector sign-in without
// a real account. No dependencies:  node tools/mock-mcp-server.mjs [port]
// Approves every sign-in at once. Tokens last 60 seconds so renewal is exercised.
import http from 'node:http';
import crypto from 'node:crypto';

const port = Number(process.argv[2] || 8765);
const base = `http://localhost:${port}`;
const codes = new Map();
const access = new Map();
const refresh = new Set();
const notes = ['Buy oat milk', 'Call the plumber about the kitchen tap', 'Book flights to Lisbon'];
const tools = [
  { name: 'search_notes', description: 'Search the user\'s notes. Returns every note containing the query words.',
    inputSchema: { type: 'object', properties: { query: { type: 'string', description: 'Words to look for' } }, required: ['query'] } },
  { name: 'add_note', description: 'Save a new note.',
    inputSchema: { type: 'object', properties: { text: { type: 'string', description: 'The note' } }, required: ['text'] } },
];

const send = (res, status, body, headers = {}) => {
  res.writeHead(status, { 'Content-Type': 'application/json', ...headers });
  res.end(body === undefined ? '' : JSON.stringify(body));
};
const issue = () => {
  const token = crypto.randomUUID(), renew = crypto.randomUUID();
  access.set(token, Date.now() + 60_000);
  refresh.add(renew);
  return { access_token: token, refresh_token: renew, expires_in: 60, token_type: 'Bearer' };
};

http.createServer(async (req, res) => {
  const url = new URL(req.url, base);
  let body = '';
  for await (const chunk of req) body += chunk;
  console.log(req.method, url.pathname, body.slice(0, 120));

  if (url.pathname === '/.well-known/oauth-protected-resource/mcp')
    return send(res, 200, { resource: `${base}/mcp`, authorization_servers: [base] });
  if (url.pathname === '/.well-known/oauth-authorization-server')
    return send(res, 200, { issuer: base, authorization_endpoint: `${base}/authorize`, token_endpoint: `${base}/token`,
      registration_endpoint: `${base}/register`, code_challenge_methods_supported: ['S256'] });
  if (url.pathname === '/register') return send(res, 201, { client_id: crypto.randomUUID() });
  if (url.pathname === '/authorize') {
    const code = crypto.randomUUID();
    codes.set(code, url.searchParams.get('code_challenge'));
    const back = `${url.searchParams.get('redirect_uri')}?code=${code}&state=${encodeURIComponent(url.searchParams.get('state'))}`;
    res.writeHead(302, { Location: back });
    return res.end();
  }
  if (url.pathname === '/token') {
    const form = new URLSearchParams(body);
    if (form.get('grant_type') === 'authorization_code') {
      const challenge = codes.get(form.get('code'));
      const made = crypto.createHash('sha256').update(form.get('code_verifier') || '').digest('base64url');
      if (!challenge || challenge !== made) return send(res, 400, { error: 'invalid_grant' });
      codes.delete(form.get('code'));
      return send(res, 200, issue());
    }
    if (!refresh.delete(form.get('refresh_token'))) return send(res, 400, { error: 'invalid_grant' });
    return send(res, 200, issue());
  }
  if (url.pathname === '/mcp') {
    const token = (req.headers.authorization || '').replace('Bearer ', '');
    if (!(access.get(token) > Date.now()))
      return send(res, 401, undefined, { 'WWW-Authenticate': `Bearer resource_metadata="${base}/.well-known/oauth-protected-resource/mcp"` });
    const message = JSON.parse(body);
    const result = (value, headers) => send(res, 200, { jsonrpc: '2.0', id: message.id, result: value }, headers);
    switch (message.method) {
      case 'initialize':
        return result({ protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'mock-notes', title: 'Mock Notes' } },
          { 'Mcp-Session-Id': crypto.randomUUID() });
      case 'notifications/initialized': res.writeHead(202); return res.end();
      case 'tools/list': return result({ tools });
      case 'tools/call': {
        const args = message.params.arguments || {};
        let text;
        if (message.params.name === 'add_note') { notes.push(args.text); text = `Saved. There are now ${notes.length} notes.`; }
        else {
          const words = String(args.query || '').toLowerCase().split(/\s+/).filter(Boolean);
          const found = notes.filter(n => words.some(w => n.toLowerCase().includes(w)));
          text = found.length ? found.map(n => `- ${n}`).join('\n') : 'No notes match.';
        }
        // Answered as an event stream, as many real servers do.
        res.writeHead(200, { 'Content-Type': 'text/event-stream' });
        res.end(`event: message\ndata: ${JSON.stringify({ jsonrpc: '2.0', id: message.id, result: { content: [{ type: 'text', text }] } })}\n\n`);
        return;
      }
      default: return send(res, 200, { jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Method not found' } });
    }
  }
  send(res, 404, { error: 'not found' });
}).listen(port, () => console.log(`mock MCP server at ${base}/mcp`));
