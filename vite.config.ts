import { copyFileSync, mkdirSync, readdirSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig, type Plugin } from 'vite'
import vue from '@vitejs/plugin-vue'

const here = dirname(fileURLToPath(import.meta.url))

// One surface per build, never both at once. Two entries in a single rollup run share a
// vendor chunk, and a shared chunk is a second file the surface has to fetch at runtime --
// which is the one thing we cannot promise inside a CEF with no network and an origin we
// have not identified yet. Two builds, two self-contained pages, nothing to resolve.
/**
 * Folds every emitted chunk and stylesheet into its HTML document.
 *
 * The surface has no network: a `<script src>` or a `<link href>` is a fetch, and a fetch
 * against a `file:`-like origin is either blocked by CORS (module scripts always are) or
 * silently never resolves. An inline module script is neither -- it is already in the
 * document by the time the parser reaches it.
 */
function inlineSurface(): Plugin {
  return {
    name: 'opx-inline-surface',
    enforce: 'post',
    generateBundle(_options, bundle) {
      const js: string[] = []
      const css: string[] = []

      for (const name of Object.keys(bundle)) {
        const item = bundle[name]
        if (item.type === 'chunk') {
          js.push(item.code)
          delete bundle[name]
        } else if (name.endsWith('.css')) {
          css.push(String(item.source))
          delete bundle[name]
        }
      }

      for (const name of Object.keys(bundle)) {
        const item = bundle[name]
        if (item.type !== 'asset' || !name.endsWith('.html')) continue
        let html = String(item.source)
        html = html.replace(/[ \t]*<script\b[^>]*\bsrc=[^>]*><\/script>\r?\n?/g, '')
        html = html.replace(/[ \t]*<link\b[^>]*\brel="(?:stylesheet|modulepreload)"[^>]*>\r?\n?/g, '')
        // Replacer FUNCTIONS, never replacement strings. A string replacement treats
        // `$&`, `$'` and "$`" as substitution patterns, and minified Vue contains them
        // as ordinary identifiers -- which splices `</body>` into the middle of the
        // runtime. The page still builds and still looks right. It just does not parse.
        if (css.length) {
          const sheet = `  <style>\n${css.join('\n')}\n  </style>\n</head>`
          html = html.replace('</head>', () => sheet)
        }
        if (js.length) {
          // `</script` can only ever occur inside a string, regex or comment in valid
          // JS, and the escape is transparent in all three -- but left alone it ends
          // the element and everything after it is parsed as markup.
          const code = js.join('\n;\n').replace(/<\/script/gi, '<\\/script')
          const block = `  <script type="module">\n${code}\n  </script>\n</body>`
          html = html.replace('</body>', () => block)
        }
        item.source = html
      }
    }
  }
}

/**
 * The three augmented-ui tokens `design-system/shapes.css` draws, and nothing else.
 *
 * The library is gone (#112): shapes.css carries a hand-written copy of the polygons
 * it resolved to for `tr-clip`, `bl-clip` and `border`, which are the only tokens
 * any template ever used. A template asking for a fourth -- `tl-clip`, `br-round` --
 * would get a plain rectangle and no warning, so the build refuses it instead.
 *
 * The static attribute is read whole. The bound one is an expression
 * (`dragging ? undefined : 'tr-clip border'`), so only its quoted strings count.
 */
const AUGMENTED_TOKENS = new Set(['tr-clip', 'bl-clip', 'border'])

function guardAugmented(): Plugin {
  return {
    name: 'opx-guard-augmented',
    buildStart() {
      const unknown: string[] = []
      const walk = (dir: string): void => {
        for (const entry of readdirSync(dir, { withFileTypes: true })) {
          const path = resolve(dir, entry.name)
          if (entry.isDirectory()) walk(path)
          else if (/\.(vue|ts)$/.test(entry.name)) {
            const source = readFileSync(path, 'utf8')
            for (const match of source.matchAll(/(:?)data-augmented-ui="([^"]*)"/g)) {
              const values = match[1] ? [...match[2].matchAll(/'([^']*)'/g)].map((m) => m[1]) : [match[2]]
              for (const value of values) {
                for (const word of value.split(/\s+/).filter(Boolean)) {
                  if (!AUGMENTED_TOKENS.has(word)) unknown.push(`${entry.name}: ${word}`)
                }
              }
            }
          }
        }
      }
      walk(resolve(here, 'ui/src'))
      if (unknown.length) {
        throw new Error(`guardAugmented: shapes.css draws only tr-clip, bl-clip and border -- ${unknown.join(', ')}`)
      }
    }
  }
}

/** The probe ships as-is. Running it through the bundler would defeat its whole purpose. */
function copyProbe(): Plugin {
  return {
    name: 'opx-copy-probe',
    closeBundle() {
      const out = resolve(here, 'web/probe.html')
      mkdirSync(dirname(out), { recursive: true })
      copyFileSync(resolve(here, 'ui/probe/index.html'), out)
    }
  }
}

export default defineConfig(() => {
  return {
    root: resolve(here, 'ui'),
    // Relative, so nothing in the output can ever name an origin.
    base: './',
    plugins: [guardAugmented(), vue(), inlineSurface(), copyProbe()],
    // Every component is `<script setup>`; nothing uses `data()`, `methods` or `this`.
    // Left at its default (true) the Options API resolver ships in the runtime anyway.
    define: {
      __VUE_OPTIONS_API__: 'false',
      __VUE_PROD_DEVTOOLS__: 'false',
      __VUE_PROD_HYDRATION_MISMATCH_DETAILS__: 'false'
    },
    resolve: {
      // Array form, and `@fontsource` FIRST: aliases are matched by prefix in order, so
      // a bare `@` sitting ahead of it would rewrite `@fontsource/...` to `ui/src/fontsource/...`.
      alias: [
        { find: '@fontsource', replacement: resolve(here, 'node_modules/@fontsource') },
        { find: '@', replacement: resolve(here, 'ui/src') }
      ]
    },
    build: {
      outDir: resolve(here, 'web'),
      // Ineffective in practice: outDir sits outside root, and Vite refuses to empty a
      // directory it does not own. Every file it writes is rewritten anyway.
      emptyOutDir: true,
      // The engine baseline is unmeasured (see ui/probe). ES2019 predates optional chaining
      // and nullish coalescing, which is where an older CEF actually breaks.
      target: 'es2019',
      // Fonts and glyphs become data URIs. 4 MiB is above every asset we ship and the point
      // is that nothing is left to fetch, not that the page is small.
      assetsInlineLimit: 4 * 1024 * 1024,
      cssCodeSplit: false,
      modulePreload: { polyfill: false },
      // The Lua side names `web/index.html` literally, so no filename may carry a hash.
      rollupOptions: {
        input: resolve(here, 'ui', 'index.html'),
        output: {
          entryFileNames: 'assets/[name].js',
          chunkFileNames: 'assets/[name].js',
          assetFileNames: 'assets/[name][extname]'
        }
      },
      reportCompressedSize: false
    }
  }
})
