import { createServer } from 'node:http';

export async function startNativeNetworkCanary(host = '127.0.0.1') {
  let requests = 0;
  const server = createServer({ maxHeaderSize: 8192, requestTimeout: 10_000, headersTimeout: 5000, keepAliveTimeout: 1000 }, (request, response) => {
    request.resume();
    response.setHeader('Cache-Control', 'no-store');
    if (request.method === 'GET' && request.url === '/observations') {
      response.setHeader('Content-Type', 'application/json');
      response.end(JSON.stringify({ requests }));
    } else if (request.method === 'POST' && request.url === '/reset') {
      requests = 0;
      response.writeHead(204).end();
    } else {
      requests++;
      response.setHeader('Content-Type', 'image/svg+xml');
      response.setHeader('Access-Control-Allow-Origin', '*');
      response.end('<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>');
    }
  });
  server.maxConnections = 4;
  server.maxRequestsPerSocket = 4;
  await new Promise<void>((accept, reject) => {
    server.once('error', reject);
    server.listen(55460, host, accept);
  });
  return {
    close: () =>
      new Promise<void>((accept, reject) => {
        server.close((error) => (error ? reject(error) : accept()));
        server.closeAllConnections();
      }),
  };
}
