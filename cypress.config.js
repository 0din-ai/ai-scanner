import { defineConfig } from 'cypress'
import fs from 'fs'
import path from 'path'

// Allow overriding baseUrl via environment variables.
// Priority: BASE_URL -> CYPRESS_BASE_URL -> default to https://localhost
const envBaseUrl = process.env.BASE_URL || process.env.CYPRESS_BASE_URL

function getRegistryDir(projectRoot) {
  return path.join(projectRoot, 'cypress', '.e2e')
}

function getRegistryFile(projectRoot) {
  const runId = process.env.E2E_RUN_ID || process.env.GITHUB_RUN_ID || `${Date.now()}`
  const dir = getRegistryDir(projectRoot)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, `created-${runId}.json`)
  if (!fs.existsSync(file)) fs.writeFileSync(file, '[]')
  return file
}

function getFailureFlagFile(projectRoot) {
  const dir = getRegistryDir(projectRoot)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, '.had-failures')
}

function pruneE2eFiles(projectRoot, options = {}) {
  const dir = getRegistryDir(projectRoot)
  const {
    pattern = /^created-.*\.json$/,
    olderThanMs = 0,
    removeDir = false,
  } = options
  if (!fs.existsSync(dir)) return { removed: 0, dirRemoved: false }

  const now = Date.now()
  let removed = 0
  for (const name of fs.readdirSync(dir)) {
    const shouldMatch = (typeof pattern === 'string') ? new RegExp(pattern) : (pattern instanceof RegExp ? pattern : /^created-.*\\.json$/);
    if (!shouldMatch.test(name)) continue
    const full = path.join(dir, name)
    try {
      const stat = fs.statSync(full)
      if (olderThanMs > 0 && (now - stat.mtimeMs) < olderThanMs) continue
      fs.rmSync(full, { force: true })
      removed += 1
    } catch (_) {}
  }

  let dirRemoved = false
  if (removeDir) {
    try {
      fs.rmSync(dir, { recursive: true, force: true })
      dirRemoved = true
    } catch (_) {}
  }
  return { removed, dirRemoved }
}

export default defineConfig({
  expose: {},
  e2e: {
    baseUrl: envBaseUrl || 'https://localhost',
    viewportWidth: 1280,
    viewportHeight: 720,
    video: false,
    screenshotOnRunFailure: true,
    defaultCommandTimeout: 10000,
    requestTimeout: 10000,
    supportFile: 'cypress/support/e2e.js',
    specPattern: 'cypress/e2e/**/*.cy.{js,jsx,ts,tsx}',
    // Enable Chrome Web Security to be disabled for cross-origin OAuth flows
    chromeWebSecurity: false,
    setupNodeEvents(on, config) {
      // Keep existing --env/CYPRESS_* flags working while exposing only public settings.
      const publicKeys = [
        'OAUTH_PROVIDER_URL', 'OAUTH_PROVIDER', 'MOCK_LLM_PORT', 'MOCK_LLM_HOST',
        'SKIP_CLEANUP', 'NO_CLEANUP', 'FAIL_SCAN_CREATION_TEST', 'PDF_REQUEST_TIMEOUT_MS'
      ]
      for (const key of publicKeys) {
        if (config.env[key] !== undefined && config.expose[key] === undefined) {
          config.expose[key] = config.env[key]
        }
      }

      // Simple JSON file-backed registry to track resources created during a run
      const registryFile = getRegistryFile(config.projectRoot)
      const failureFlagFile = getFailureFlagFile(config.projectRoot)

      const readAll = () => {
        try {
          return JSON.parse(fs.readFileSync(registryFile, 'utf8') || '[]')
        } catch (_) {
          return []
        }
      }
      const writeAll = (arr) => fs.writeFileSync(registryFile, JSON.stringify(arr, null, 2))

      // Tasks available to tests and support files
      on('task', {
        // Registry helpers
        'registry:add'(item) {
          const all = readAll()
          all.push({ ...item, at: new Date().toISOString() })
          writeAll(all)
          return null
        },
        'registry:get'() {
          return readAll()
        },
        'registry:clear'() {
          writeAll([])
          return null
        },
        'registry:pruneFiles'(opts = {}) {
          // Remove created-*.json files now
          return pruneE2eFiles(config.projectRoot, opts)
        },
        // Failure marker
        'failures:mark'() {
          try { fs.writeFileSync(failureFlagFile, '1') } catch (_) {}
          return true
        },
        'failures:has'() {
          try { return fs.existsSync(failureFlagFile) } catch (_) { return false }
        },
        // Console passthrough for ad-hoc debugging from the browser context
        'console:log'(msg) {
          try { console.log(msg) } catch (_) {}
          return null
        },
        'console:warn'(msg) {
          try { console.warn(msg) } catch (_) {}
          return null
        },
        'console:error'(msg) {
          try { console.error(msg) } catch (_) {}
          return null
        }
      })

      // Clean stale failure flag
      on('before:run', () => {
        try { fs.rmSync(failureFlagFile, { force: true }) } catch (_) {}
      })

      // Print failing test errors to terminal after each spec for easier CI debugging
      on('after:spec', (_spec, results) => {
        try {
          if (!results || !Array.isArray(results.tests)) return
          for (const t of results.tests) {
            const title = Array.isArray(t.title) ? t.title.join(' > ') : String(t.title || '')
            if (t.displayError) {
              console.error(`[failed] ${title}\n${t.displayError}`)
            }
            if (Array.isArray(t.attempts)) {
              for (let i = 0; i < t.attempts.length; i++) {
                const a = t.attempts[i]
                if (a && a.state === 'failed' && a.error) {
                  const msg = a.error.message || ''
                  const stack = a.error.stack || ''
                  console.error(`[attempt ${i + 1}] ${title}\n${msg}\n${stack}`)
                }
              }
            }
          }
        } catch (_) {}
      })

      // Auto-clean .e2e after the run unless explicitly kept
      on('after:run', (results) => {
        if (process.env.KEEP_E2E_FILES) return
        // Keep artifacts if there were failures to aid debugging
        if (results && results.totalFailed > 0) return
        try { fs.rmSync(failureFlagFile, { force: true }) } catch (_) {}
        pruneE2eFiles(config.projectRoot, { pattern: /^created-.*\.json$/, removeDir: true })
      })

      return config
    }
  }
})
