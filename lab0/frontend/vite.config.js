
import { defineConfig, loadEnv } from 'vite'
import http from 'node:http'
import https from 'node:https'
import fs from 'node:fs'

function apiProxyPlugin(target) {
  const t = new URL(target)
  const client = t.protocol === 'https:' ? https : http
  const port = t.port || (t.protocol === 'https:' ? 443 : 80)

  const handler = (req, res, next) => {
    if (!req.url?.startsWith('/api')) return next()

    const headers = {}

    for (const [key, value] of Object.entries(req.headers)) {
      if (!key.startsWith(':')) {
        headers[key] = value
      }
    }

    headers.host = t.host

    const proxyReq = client.request(
      {
        protocol: t.protocol,
        hostname: t.hostname,
        port,
        path: req.url,
        method: req.method,
        headers,
      },
      (proxyRes) => {
        res.writeHead(proxyRes.statusCode || 502, proxyRes.headers)
        proxyRes.pipe(res)
      },
    )

    proxyReq.on('error', (err) => {
      res.statusCode = 502
      res.end(`proxy error: ${err.message}`)
    })

    req.pipe(proxyReq)
  }

  return {
    name: 'api-proxy',
    configureServer(server) {
      server.middlewares.use(handler)
    },
    configurePreviewServer(server) {
      server.middlewares.use(handler)
    },
  }
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
   const target = env.BACKEND_PROXY_TARGET || 'http://localhost:5040'

  const hasCerts = fs.existsSync('./localhost-key.pem') && fs.existsSync('./localhost.pem')

  return {
    plugins: [apiProxyPlugin(target)],
    server: {
      port: 5173,
      host: true,
      https: hasCerts
        ? {
            key: fs.readFileSync('./localhost-key.pem'),
            cert: fs.readFileSync('./localhost.pem'),
          }
        : undefined,
    },
  }
})