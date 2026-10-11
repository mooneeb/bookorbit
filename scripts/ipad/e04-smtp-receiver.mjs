import { createServer as createHTTPServer } from "node:http";
import { createServer as createTCPServer } from "node:net";

export async function startEmailReceiver({ smtpPort = 0, httpPort = 0 } = {}) {
  const messages = [];
  const sockets = new Set();
  let mode = "accept";
  const smtp = createTCPServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.setEncoding("utf8");
    socket.write("220 BookOrbit controlled SMTP receiver\r\n");
    let buffer = "";
    let inData = false;
    let data = "";
    let recipients = [];
    socket.on("data", (chunk) => {
      buffer += chunk;
      if (buffer.length + data.length > 32 * 1024 * 1024) return socket.destroy();
      let end;
      while ((end = buffer.indexOf("\r\n")) >= 0) {
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 2);
        if (inData) {
          if (line !== ".") {
            data += `${line.startsWith("..") ? line.slice(1) : line}\r\n`;
            continue;
          }
          inData = false;
          if (mode === "reject") socket.write("550 controlled delivery rejection\r\n");
          else if (mode === "timeout") continue;
          else {
            messages.push({ id: messages.length + 1, recipients, raw: data, receivedAt: new Date().toISOString() });
            if (messages.length > 100) messages.shift();
            socket.write("250 queued by controlled receiver\r\n");
          }
          data = "";
          recipients = [];
        } else if (/^(EHLO|HELO)/i.test(line)) socket.write("250 receiver\r\n");
        else if (/^MAIL FROM:/i.test(line)) socket.write("250 sender accepted\r\n");
        else if (/^RCPT TO:/i.test(line)) {
          recipients.push(line.slice(8).trim());
          socket.write("250 recipient accepted\r\n");
        } else if (/^DATA$/i.test(line)) {
          inData = true;
          socket.write("354 send message\r\n");
        } else if (/^QUIT$/i.test(line)) socket.end("221 goodbye\r\n");
        else if (/^AUTH/i.test(line)) socket.write("535 controlled authentication rejection\r\n");
        else if (/^(RSET|NOOP)/i.test(line)) socket.write("250 OK\r\n");
        else socket.write("502 unsupported command\r\n");
      }
    });
    socket.on("error", () => {});
  });
  const http = createHTTPServer(async (request, response) => {
    response.setHeader("Content-Type", "application/json");
    if (request.url === "/messages" && request.method === "GET") return response.end(JSON.stringify(messages));
    if (request.url === "/messages" && request.method === "DELETE") {
      messages.length = 0;
      response.statusCode = 204;
      return response.end();
    }
    if (request.url === "/mode" && request.method === "POST") {
      let body = "";
      for await (const chunk of request) {
        body += chunk;
        if (body.length > 1024) {
          response.statusCode = 413;
          return response.end();
        }
      }
      try {
        const value = JSON.parse(body).mode;
        if (!["accept", "reject", "timeout"].includes(value)) throw new Error("mode");
        mode = value;
        response.statusCode = 204;
        return response.end();
      } catch {
        response.statusCode = 400;
        return response.end(JSON.stringify({ error: "Invalid mode" }));
      }
    }
    response.statusCode = 404;
    response.end();
  });
  await new Promise((resolve, reject) => {
    smtp.once("error", reject);
    smtp.listen(smtpPort, "127.0.0.1", resolve);
  });
  await new Promise((resolve, reject) => {
    http.once("error", reject);
    http.listen(httpPort, "127.0.0.1", resolve);
  });
  return {
    smtpPort: smtp.address().port,
    httpURL: `http://127.0.0.1:${http.address().port}`,
    close: async () => {
      for (const socket of sockets) socket.destroy();
      await Promise.all([new Promise((resolve) => smtp.close(resolve)), new Promise((resolve) => http.close(resolve))]);
    },
  };
}
