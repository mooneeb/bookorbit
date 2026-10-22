import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { fileURLToPath, URL } from 'node:url'
import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'
import { defineConfig, type Plugin } from 'vite'

const client = fileURLToPath(new URL('.', import.meta.url))
const fixture = fileURLToPath(new URL('../docs/wayfinder/bookorbit-ipad-reader/prototypes/context-preservation/', import.meta.url))
const sample = `${fixture}/evidence/physical-review-build-4/examples`
const privateInput = process.env.BOOKORBIT_READER_PROOF_INPUT
const sha = (bytes: Buffer) => createHash('sha256').update(bytes).digest('hex')
const epub = readFileSync(`${fixture}/Fixtures/Reflow/reflow.epub`)
const pdf = readFileSync(`${sample}/pdf/background.pdf`)
const pdfInk = readFileSync(`${sample}/pdf/ink-preview.png`)
const publicInk = readFileSync(`${sample}/scroll/ink-preview.png`)
const local = privateInput ? JSON.parse(readFileSync(`${privateInput}/epub-note.json`, 'utf8')) : null
const epubInk = privateInput ? readFileSync(`${privateInput}/epub-note.png`) : publicInk
const manifest = {
  epub: local ?? {
    quote: 'most useful observation keeps',
    cfi: 'epubcfi(/6/2!/4/4,/1:4,/1:33)',
    sourceSha256: sha(epub),
    originalSha256: sha(readFileSync(`${sample}/scroll/ink.drawing`)),
    renderer: 'Previously published physical iPad ink preview',
    association: 'Supplied example text link; not a native CFI round trip',
    nativeWalkthrough: 'Check a saved EPUB page',
  },
  pdf: {
    sourceSha256: sha(pdf),
    originalSha256: sha(readFileSync(`${sample}/pdf/ink.drawing`)),
    previewSha256: sha(pdfInk),
    width: 624,
    height: 468,
    nativeCanvas: { width: 640, height: 480 },
    canvasToPage: [0, -1.3, 1.3, 0, 0, 650],
    nativeWalkthrough: 'Check a saved PDF page',
  },
  transfer: 'Local fixture delivery only. No BookOrbit sync or account is connected.',
}
if (manifest.epub.sourceSha256 !== sha(epub)) throw new Error('The native note belongs to a different EPUB fixture.')
manifest.epub.previewSha256 = sha(epubInk)
const inputs = new Map<string, { bytes: Buffer; type: string }>([
  ['/proof-input/manifest.json', { bytes: Buffer.from(JSON.stringify(manifest)), type: 'application/json' }],
  ['/proof-input/book.epub', { bytes: epub, type: 'application/epub+zip' }],
  ['/proof-input/epub-note.png', { bytes: epubInk, type: 'image/png' }],
  ['/proof-input/book.pdf', { bytes: pdf, type: 'application/pdf' }],
  ['/proof-input/pdf-ink.png', { bytes: pdfInk, type: 'image/png' }],
  ['/proof-input/pdf-reference.png', { bytes: readFileSync(`${sample}/pdf/background.png`), type: 'image/png' }],
])
const scratchInputs: Plugin = {
  name: 'bookorbit-reader-prototype-inputs',
  configureServer(server) {
    server.middlewares.use((request, response, next) => {
      const path = request.url?.split('?')[0] ?? ''
      if (!path.startsWith('/proof-input/')) return next()
      const input = inputs.get(path)
      if (!input) {
        response.statusCode = 404
        response.end('Unknown prototype fixture')
        return
      }
      response.setHeader('Content-Type', input.type)
      response.setHeader('Cache-Control', 'no-store')
      response.end(input.bytes)
    })
  },
  generateBundle() {
    for (const [path, input] of inputs) this.emitFile({ type: 'asset', fileName: path.slice(1), source: input.bytes })
  },
}

export default defineConfig({
  root: `${client}/src/features/reader/prototypes/browser-notes`,
  publicDir: `${client}/public`,
  cacheDir: `${client}/node_modules/.vite-reader-prototype`,
  plugins: [vue({ template: { transformAssetUrls: false } }), tailwindcss(), scratchInputs],
  resolve: { alias: { '@': `${client}/src` } },
  server: { host: '127.0.0.1', port: 8767, strictPort: true, fs: { allow: [client] } },
  build: { outDir: `${client}/../docs/wayfinder/bookorbit-ipad-reader/prototypes/browser-compatibility/build`, emptyOutDir: true },
})
