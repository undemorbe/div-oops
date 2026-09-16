import { defineConfig, loadEnv } from 'vite'
import http from 'node:http'
import https from 'node:https'

// Прокси на бэкенд: фронт зовёт свой же /api, Vite форвардит на бэкенд.
// Браузер видит один origin → CORS на бэкенде не нужен (нет preflight OPTIONS).
// Цель форварда — BACKEND_PROXY_TARGET (origin бэкенда, без /api).
//
// Свой forward через нативный http/https, а не встроенный proxy Vite:
// встроенный http-proxy рвёт TLS с туннелем (не тот SNI). Node сам ставит
// SNI из hostname, поэтому работает и с HTTPS-туннелем, и с локальным HTTP.
function apiProxyPlugin(target) {
  const t = new URL(target)
  const client = t.protocol === 'https:' ? https : http
  const port = t.port || (t.protocol === 'https:' ? 443 : 80)

  const handler = (req, res, next) => {
    if (!req.url.startsWith('/api')) return next()

    const proxyReq = client.request(
      {
        protocol: t.protocol,
        hostname: t.hostname,
        port,
        path: req.url,
        method: req.method,
        headers: { ...req.headers, host: t.host },
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

  return {
    plugins: [apiProxyPlugin(target)],
    server: { port: 5173, host: true },
    preview: { port: 4173, host: true },
  }
})
