import { Controller } from "@hotwired/stimulus"

// Drives the wizard's Authentication section. Reads repeatable cookie + header
// rows and a storageState textarea, serializing them into the `auth` key of the
// hidden web_config textarea. Pure transforms (buildAuthPayload / mergeAuthIntoConfig)
// are unit-tested; the DOM glue is thin.
export default class extends Controller {
  static targets = ["cookieRows", "headerRows", "storageState", "cookieTemplate", "headerTemplate"]

  connect() {
    this.webConfigField = document.querySelector('textarea[name="target[web_config]"]')
    this.populateFromAuth()
  }

  // Hydrate the section from an already-saved web_config.auth so editing a target
  // does not silently drop its credentials. Does NOT re-serialize (the textarea
  // already holds the auth); it only mirrors it into the visible rows.
  populateFromAuth() {
    if (!this.webConfigField) return
    let auth
    try {
      auth = (JSON.parse(this.webConfigField.value || "{}") || {}).auth
    } catch (_) {
      return
    }
    if (!auth || typeof auth !== "object") return

    if (this.hasCookieTemplateTarget && this.hasCookieRowsTarget) {
      for (const cookie of auth.cookies || []) {
        const row = this.cookieTemplateTarget.content.firstElementChild.cloneNode(true)
        this.setRowField(row, "name", cookie.name)
        this.setRowField(row, "value", cookie.value)
        this.setRowField(row, "domain", cookie.domain)
        // The row UI only edits name/value/domain. Stash any other Playwright cookie
        // fields (url, path, secure, httpOnly, sameSite, expires) so a later edit
        // re-serializes them instead of dropping them.
        const { name, value, domain, ...extra } = cookie
        if (Object.keys(extra).length) row.dataset.cookieExtra = JSON.stringify(extra)
        this.cookieRowsTarget.appendChild(row)
      }
    }

    if (this.hasHeaderTemplateTarget && this.hasHeaderRowsTarget) {
      for (const [key, value] of Object.entries(auth.headers || {})) {
        const row = this.headerTemplateTarget.content.firstElementChild.cloneNode(true)
        this.setRowField(row, "key", key)
        this.setRowField(row, "value", value)
        this.headerRowsTarget.appendChild(row)
      }
    }

    if (auth.storage_state && this.hasStorageStateTarget) {
      this.storageStateTarget.value = JSON.stringify(auth.storage_state, null, 2)
    }
  }

  setRowField(row, field, value) {
    const input = row.querySelector(`[data-field="${field}"]`)
    if (input && value != null) input.value = value
  }

  // --- Pure helpers (unit-tested) ---

  buildAuthPayload(cookies, headers, storageStateText) {
    const auth = {}

    // Keep cookies with an empty-string value (valid flag/presence cookies); the
    // server validator only requires `value` to be a string.
    const cleanCookies = (cookies || []).filter((c) => c && c.name && typeof c.value === "string")
    if (cleanCookies.length) auth.cookies = cleanCookies

    const headerObj = {}
    for (const h of headers || []) {
      if (h && h.key && h.key.toLowerCase() !== "host") headerObj[h.key] = h.value || ""
    }
    if (Object.keys(headerObj).length) auth.headers = headerObj

    const text = (storageStateText || "").trim()
    if (text) {
      try {
        const parsed = JSON.parse(text)
        // Keep the raw text for non-object/invalid JSON so server-side validation
        // rejects it instead of silently scanning without the intended login state.
        auth.storage_state = parsed && typeof parsed === "object" ? parsed : text
      } catch (_) {
        auth.storage_state = text
      }
    }

    return Object.keys(auth).length ? auth : null
  }

  mergeAuthIntoConfig(configText, auth) {
    let config
    try {
      config = JSON.parse(configText || "{}")
    } catch (_) {
      config = {}
    }
    if (auth) {
      config.auth = auth
    } else {
      delete config.auth
    }
    return JSON.stringify(config, null, 2)
  }

  // --- DOM glue ---

  serialize() {
    if (!this.webConfigField) return
    const auth = this.buildAuthPayload(this.readCookieRows(), this.readHeaderRows(), this.readStorageState())
    this.webConfigField.value = this.mergeAuthIntoConfig(this.webConfigField.value, auth)
    this.webConfigField.dispatchEvent(new Event("input", { bubbles: true }))
  }

  readCookieRows() {
    if (!this.hasCookieRowsTarget) return []
    return Array.from(this.cookieRowsTarget.querySelectorAll("[data-auth-row]")).map((row) => {
      let extra = {}
      try {
        if (row.dataset && row.dataset.cookieExtra) extra = JSON.parse(row.dataset.cookieExtra)
      } catch (_) {
        extra = {}
      }
      const name = row.querySelector('[data-field="name"]')?.value?.trim()
      const value = row.querySelector('[data-field="value"]')?.value ?? ""
      const domain = row.querySelector('[data-field="domain"]')?.value?.trim()
      const cookie = { ...extra, name, value }
      if (domain) {
        // A provided domain takes precedence; drop a stashed url to avoid the
        // url+domain conflict Playwright's addCookies rejects.
        cookie.domain = domain
        delete cookie.url
      } else {
        cookie.domain = undefined
      }
      return cookie
    })
  }

  readHeaderRows() {
    if (!this.hasHeaderRowsTarget) return []
    return Array.from(this.headerRowsTarget.querySelectorAll("[data-auth-row]")).map((row) => ({
      key: row.querySelector('[data-field="key"]')?.value?.trim(),
      value: row.querySelector('[data-field="value"]')?.value ?? "",
    }))
  }

  readStorageState() {
    return this.hasStorageStateTarget ? this.storageStateTarget.value : ""
  }

  addCookieRow() {
    this.appendFromTemplate(this.cookieTemplateTarget, this.cookieRowsTarget)
  }

  addHeaderRow() {
    this.appendFromTemplate(this.headerTemplateTarget, this.headerRowsTarget)
  }

  appendFromTemplate(template, container) {
    const node = template.content.firstElementChild.cloneNode(true)
    container.appendChild(node)
    this.serialize()
  }

  removeRow(event) {
    const row = event.target.closest("[data-auth-row]")
    if (row) row.remove()
    this.serialize()
  }

  toggleVisibility(event) {
    const input = event.target.closest("[data-auth-row]")?.querySelector('[data-field="value"]')
    if (input) input.type = input.type === "password" ? "text" : "password"
  }
}
