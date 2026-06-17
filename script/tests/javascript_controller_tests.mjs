import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

function loadControllerSource(filename, className) {
  const source = readFileSync(
    new URL(`../../app/javascript/controllers/${filename}`, import.meta.url),
    "utf8"
  )

  return source
    .replace(/^import .*?\n/, "")
    .replace(
      "export default class extends Controller",
      `class ${className} extends Controller`
    )
}

function loadDebugStreamLeaseController() {
  const transformed = loadControllerSource(
    "debug_stream_lease_controller.js",
    "DebugStreamLeaseController"
  )

  const context = {
    Controller: class {},
    console: { warn() {} },
    document: { querySelector() { return null } },
    fetch: async () => ({ ok: true, status: 204 }),
    window: {
      setInterval() { return null },
      clearInterval() {}
    }
  }

  const ControllerClass = vm.runInNewContext(
    `${transformed}\nDebugStreamLeaseController`,
    context
  )

  return { ControllerClass, context }
}

function loadActivityStreamController() {
  const transformed = loadControllerSource(
    "activity_stream_controller.js",
    "ActivityStreamController"
  )

  const context = {
    Controller: class {},
    requestAnimationFrame(callback) { callback() }
  }

  const ControllerClass = vm.runInNewContext(
    `${transformed}\nActivityStreamController`,
    context
  )

  return { ControllerClass, context }
}

function loadDebugTabsController() {
  const transformed = loadControllerSource(
    "debug_tabs_controller.js",
    "DebugTabsController"
  )

  const sessionStore = new Map()
  const context = {
    Controller: class {},
    sessionStorage: {
      getItem(key) { return sessionStore.has(key) ? sessionStore.get(key) : null },
      setItem(key, value) { sessionStore.set(key, String(value)) }
    }
  }

  const ControllerClass = vm.runInNewContext(
    `${transformed}\nDebugTabsController`,
    context
  )

  return { ControllerClass, context, sessionStore }
}

function loadDebugStreamFilterController() {
  const transformed = loadControllerSource(
    "debug_stream_filter_controller.js",
    "DebugStreamFilterController"
  )

  const context = { Controller: class {} }

  const ControllerClass = vm.runInNewContext(
    `${transformed}\nDebugStreamFilterController`,
    context
  )

  return { ControllerClass }
}

function loadLogViewerController() {
  const transformed = loadControllerSource(
    "log_viewer_controller.js",
    "LogViewerController"
  )

  const context = {
    Controller: class {},
    CustomEvent: class {
      constructor(type, init = {}) {
        this.type = type
        this.bubbles = !!init.bubbles
        this.detail = init.detail
      }
    }
  }

  const ControllerClass = vm.runInNewContext(
    `${transformed}\nLogViewerController`,
    context
  )

  return { ControllerClass }
}

function loadThreatVariantsController() {
  const transformed = loadControllerSource(
    "threat_variants_controller.js",
    "ThreatVariantsController"
  )

  const context = { Controller: class {}, document: {} }
  const ControllerClass = vm.runInNewContext(
    `${transformed}\nThreatVariantsController`,
    context
  )

  return { ControllerClass }
}

function loadReportRedesignedController() {
  const source = readFileSync(
    new URL("../../app/javascript/controllers/report_redesigned_controller.js", import.meta.url),
    "utf8"
  )

  const transformed = source
    .replace(/^import .*?\n/gm, "")
    .replace(
      "export default class extends Controller",
      "class ReportRedesignedController extends Controller"
    )

  const context = {
    Controller: class {},
    colors: {},
    isDark() { return true },
    disposeCharts() {},
    resizeCharts() {},
    BRAND_FONT: "Inter",
    console: { error() {} },
    document: {
      querySelector() { return null },
      createDocumentFragment() {
        return { appendChild() {} }
      }
    },
    window: {
      addEventListener() {},
      removeEventListener() {}
    },
    setTimeout(callback) { callback() }
  }

  const ControllerClass = vm.runInNewContext(
    `${transformed}\nReportRedesignedController`,
    context
  )

  return { ControllerClass }
}

function classListWith(...initialClasses) {
  const classes = new Set(initialClasses)

  return {
    contains(className) {
      return classes.has(className)
    },
    add(...names) {
      names.forEach((name) => classes.add(name))
    },
    remove(...names) {
      names.forEach((name) => classes.delete(name))
    },
    toggle(className, force) {
      if (force === true) {
        classes.add(className)
      } else if (force === false) {
        classes.delete(className)
      } else if (classes.has(className)) {
        classes.delete(className)
      } else {
        classes.add(className)
      }
    }
  }
}

function fakeElement(...initialClasses) {
  const attributes = new Map()

  return {
    classList: classListWith(...initialClasses),
    textContent: "",
    focusOptions: null,
    focusTarget: null,
    setAttribute(name, value) {
      attributes.set(name, value)
    },
    removeAttribute(name) {
      attributes.delete(name)
    },
    getAttribute(name) {
      return attributes.get(name)
    },
    querySelector(selector) {
      if (selector === "[data-activity-stream-focus-target]") return this.focusTarget

      return null
    },
    focus(options) {
      this.focusOptions = options
    }
  }
}

function fakeTab(name, ...initialClasses) {
  return {
    classList: classListWith(...initialClasses),
    dataset: { tab: name }
  }
}

function fakePanel(name, ...initialClasses) {
  return {
    classList: classListWith(...initialClasses),
    dataset: { tab: name }
  }
}

function fakeRow({ text = "", logViewerFilterMatch } = {}) {
  const dataset = {}
  if (logViewerFilterMatch !== undefined) {
    dataset.logViewerFilterMatch = logViewerFilterMatch
  }
  return {
    textContent: text,
    style: { display: "" },
    dataset
  }
}

function fakeGroup(rows, emptyState) {
  return {
    rows,
    emptyState,
    querySelector(selector) {
      if (selector.includes("emptyState")) return emptyState
      return null
    },
    querySelectorAll(selector) {
      if (selector.includes("row")) return rows
      return []
    }
  }
}

async function testDebugStreamLeaseController() {
  const { ControllerClass, context } = loadDebugStreamLeaseController()

  const controller = new ControllerClass()
  assert.equal(controller.intervalMs, 30000)

  controller.hasIntervalValue = true
  controller.intervalValue = 2500
  assert.equal(controller.intervalMs, 2500)

  controller.intervalValue = 0
  assert.equal(controller.intervalMs, 30000)

  const requests = []
  context.document = {
    querySelector(selector) {
      assert.equal(selector, "meta[name='csrf-token']")
      return { content: "csrf-token" }
    }
  }
  context.fetch = async (url, options) => {
    requests.push({ url, options })
    return { ok: true, status: 204 }
  }

  controller.urlValue = "/reports/1/debug_stream/lease"
  await controller.refreshLease()

  assert.equal(requests.length, 1)
  assert.equal(requests[0].url, "/reports/1/debug_stream/lease")
  assert.equal(requests[0].options.method, "POST")
  assert.equal(requests[0].options.credentials, "same-origin")
  assert.equal(requests[0].options.headers.Accept, "text/plain")
  assert.equal(requests[0].options.headers["X-CSRF-Token"], "csrf-token")
  assert.equal(requests[0].options.headers["X-Requested-With"], "XMLHttpRequest")

  let resolveFetch
  context.fetch = async (url, options) => {
    requests.push({ url, options })
    return new Promise((resolve) => {
      resolveFetch = resolve
    })
  }

  const firstRefresh = controller.refreshLease()
  const overlappingRefresh = controller.refreshLease()
  assert.equal(requests.length, 2)

  resolveFetch({ ok: true, status: 204 })
  await firstRefresh
  await overlappingRefresh

  context.fetch = async (url, options) => {
    requests.push({ url, options })
    return { ok: true, status: 204 }
  }

  await controller.refreshLease()
  assert.equal(requests.length, 3)

  const noUrlController = new ControllerClass()
  noUrlController.hasUrlValue = false
  noUrlController.connect()
  assert.equal(requests.length, 3)

  const scheduled = []
  const cleared = []
  context.window = {
    setInterval(callback, interval) {
      scheduled.push({ callback, interval })
      return "timer-1"
    },
    clearInterval(timer) {
      cleared.push(timer)
    }
  }

  controller.hasUrlValue = true
  controller.hasIntervalValue = true
  controller.intervalValue = 5000
  controller.connect()

  assert.equal(scheduled.length, 1)
  assert.equal(scheduled[0].interval, 5000)
  assert.equal(controller.timer, "timer-1")

  controller.disconnect()

  assert.deepEqual(cleared, [ "timer-1" ])
  assert.equal(controller.timer, null)
}

function testActivityStreamController() {
  const { ControllerClass } = loadActivityStreamController()
  const controller = new ControllerClass()
  const details = fakeElement("hidden")
  const button = fakeElement()
  const buttonLabel = fakeElement()
  const focusTarget = fakeElement()

  buttonLabel.textContent = "View activity"
  details.focusTarget = focusTarget

  controller.hasDetailsTarget = true
  controller.hasButtonTarget = true
  controller.hasButtonLabelTarget = true
  controller.detailsTarget = details
  controller.buttonTarget = button
  controller.buttonLabelTarget = buttonLabel

  controller.connect()

  assert.equal(details.classList.contains("hidden"), true)
  assert.equal(button.getAttribute("aria-expanded"), "false")
  assert.equal(buttonLabel.textContent, "View activity")

  controller.toggle()

  assert.equal(details.classList.contains("hidden"), false)
  assert.equal(button.getAttribute("aria-expanded"), "true")
  assert.equal(buttonLabel.textContent, "Hide activity")
  assert.equal(focusTarget.focusOptions.preventScroll, true)

  controller.toggle()

  assert.equal(details.classList.contains("hidden"), true)
  assert.equal(button.getAttribute("aria-expanded"), "false")
  assert.equal(buttonLabel.textContent, "View activity")
}

function testDebugTabsController() {
  const { ControllerClass, context, sessionStore } = loadDebugTabsController()

  const tabs = [
    fakeTab("timeline", "text-zinc-400", "hover:text-zinc-200"),
    fakeTab("raw", "text-zinc-400", "hover:text-zinc-200"),
    fakeTab("logs", "text-zinc-400", "hover:text-zinc-200")
  ]
  const panels = [
    fakePanel("timeline"),
    fakePanel("raw", "hidden"),
    fakePanel("logs", "hidden")
  ]

  const controller = new ControllerClass()
  controller.tabTargets = tabs
  controller.panelTargets = panels
  controller.hasStorageKeyValue = true
  controller.storageKeyValue = "report-debug-tab-42"

  controller.panelTargetConnected()
  // default tab = timeline
  assert.equal(tabs[0].classList.contains("bg-zinc-800"), true)
  assert.equal(tabs[0].classList.contains("text-white"), true)
  assert.equal(panels[0].classList.contains("hidden"), false)
  assert.equal(panels[1].classList.contains("hidden"), true)
  assert.equal(panels[2].classList.contains("hidden"), true)

  // switch to raw
  controller.switch({ currentTarget: tabs[1] })
  assert.equal(tabs[1].classList.contains("bg-zinc-800"), true)
  assert.equal(tabs[0].classList.contains("bg-zinc-800"), false)
  assert.equal(panels[0].classList.contains("hidden"), true)
  assert.equal(panels[1].classList.contains("hidden"), false)
  assert.equal(panels[2].classList.contains("hidden"), true)
  assert.equal(sessionStore.get("report-debug-tab-42"), "raw")

  // reconnect — restores raw
  const tabs2 = [fakeTab("timeline"), fakeTab("raw"), fakeTab("logs")]
  const panels2 = [fakePanel("timeline"), fakePanel("raw"), fakePanel("logs")]
  const controller2 = new ControllerClass()
  controller2.tabTargets = tabs2
  controller2.panelTargets = panels2
  controller2.hasStorageKeyValue = true
  controller2.storageKeyValue = "report-debug-tab-42"
  controller2.panelTargetConnected()
  assert.equal(panels2[0].classList.contains("hidden"), true)
  assert.equal(panels2[1].classList.contains("hidden"), false)
  assert.equal(panels2[2].classList.contains("hidden"), true)

  // explicit "logs" works
  controller.switch({ currentTarget: tabs[2] })
  assert.equal(panels[2].classList.contains("hidden"), false)
  assert.equal(sessionStore.get("report-debug-tab-42"), "logs")

  // stored tab id that doesn't exist falls back to "timeline"
  sessionStore.set("report-debug-tab-99", "old_renamed_tab")
  const tabs3 = [fakeTab("timeline"), fakeTab("raw"), fakeTab("logs")]
  const panels3 = [fakePanel("timeline"), fakePanel("raw"), fakePanel("logs")]
  const controller3 = new ControllerClass()
  controller3.tabTargets = tabs3
  controller3.panelTargets = panels3
  controller3.hasStorageKeyValue = true
  controller3.storageKeyValue = "report-debug-tab-99"
  controller3.panelTargetConnected()
  assert.equal(panels3[0].classList.contains("hidden"), false,
    "stale stored id should fall back to timeline")
  assert.equal(panels3[1].classList.contains("hidden"), true)
  assert.equal(panels3[2].classList.contains("hidden"), true)
  assert.equal(tabs3[0].classList.contains("bg-zinc-800"), true,
    "timeline tab button should show active styling after fallback")

  // missing storage value — no read/write
  const noStorageController = new ControllerClass()
  noStorageController.tabTargets = [fakeTab("timeline"), fakeTab("raw")]
  noStorageController.panelTargets = [fakePanel("timeline"), fakePanel("raw")]
  noStorageController.hasStorageKeyValue = false
  noStorageController.panelTargetConnected()
  assert.equal(noStorageController.tabTargets[0].classList.contains("bg-zinc-800"), true)

  // throwing sessionStorage does not break the controller
  const throwingStorage = {
    getItem() { throw new Error("SecurityError") },
    setItem() { throw new Error("SecurityError") }
  }
  const tabs4 = [fakeTab("timeline"), fakeTab("raw"), fakeTab("logs")]
  const panels4 = [fakePanel("timeline"), fakePanel("raw"), fakePanel("logs")]
  const controller4 = new ControllerClass()
  controller4.tabTargets = tabs4
  controller4.panelTargets = panels4
  controller4.hasStorageKeyValue = true
  controller4.storageKeyValue = "report-debug-tab-77"
  // Override the controller's sessionStorage reference for this test
  const originalSessionStorage = context.sessionStorage
  context.sessionStorage = throwingStorage

  let connectError = null
  try {
    controller4.panelTargetConnected()
  } catch (err) {
    connectError = err
  }
  assert.equal(connectError, null, "connect() should not throw when sessionStorage throws")
  assert.equal(panels4[0].classList.contains("hidden"), false,
    "controller should still default to timeline when storage is unavailable")

  let switchError = null
  try {
    controller4.switch({ currentTarget: tabs4[1] })
  } catch (err) {
    switchError = err
  }
  assert.equal(switchError, null, "switch() should not throw when sessionStorage throws")
  assert.equal(panels4[1].classList.contains("hidden"), false,
    "switch should still apply tab even when persistence fails")

  context.sessionStorage = originalSessionStorage
}

function testDebugStreamFilterController() {
  const { ControllerClass } = loadDebugStreamFilterController()

  const rows = [
    fakeRow({ text: "ATTEMPT prompt_injection probe" }),
    fakeRow({ text: "EVAL detector misleading" }),
    fakeRow({ text: "INIT 12:00:00" })
  ]
  const emptyState = { hidden: true }
  const group = fakeGroup(rows, emptyState)

  const controller = new ControllerClass()
  controller.rowTargets = rows
  controller.groupTargets = [group]
  controller.hasQueryTarget = true
  controller.queryTarget = { value: "" }

  // empty filter — all visible, empty state hidden
  controller.filter()
  assert.equal(rows[0].style.display, "")
  assert.equal(rows[1].style.display, "")
  assert.equal(rows[2].style.display, "")
  assert.equal(emptyState.hidden, true)

  // filter "probe" — only row 0 matches
  controller.queryTarget.value = "probe"
  controller.filter()
  assert.equal(rows[0].style.display, "")
  assert.equal(rows[1].style.display, "none")
  assert.equal(rows[2].style.display, "none")
  assert.equal(emptyState.hidden, true)

  // filter no matches — empty state shown
  controller.queryTarget.value = "zzz_nomatch_zzz"
  controller.filter()
  assert.equal(rows[0].style.display, "none")
  assert.equal(rows[1].style.display, "none")
  assert.equal(rows[2].style.display, "none")
  assert.equal(emptyState.hidden, false)

  // composition: row with logViewerFilterMatch=false stays hidden even if text matches
  const composedRow = fakeRow({ text: "ATTEMPT", logViewerFilterMatch: "false" })
  const composedGroup = fakeGroup([composedRow], { hidden: true })
  const controller2 = new ControllerClass()
  controller2.rowTargets = [composedRow]
  controller2.groupTargets = [composedGroup]
  controller2.hasQueryTarget = true
  controller2.queryTarget = { value: "" }
  controller2.filter()
  assert.equal(composedRow.style.display, "none")
  // empty state shown because there's an active filter (logViewer side) and no visible rows
  assert.equal(composedGroup.emptyState.hidden, false)

  // missing query target — query returns ""
  const noQueryController = new ControllerClass()
  noQueryController.hasQueryTarget = false
  assert.equal(noQueryController.query, "")

  // clearQuery clears the input value and re-runs filter
  const queryInput = { value: "probe" }
  const filterRows = [fakeRow({ text: "ATTEMPT probe foo" }), fakeRow({ text: "EVAL detector bar" })]
  const filterGroup = fakeGroup(filterRows, { hidden: true })
  const ctrl3 = new ControllerClass()
  ctrl3.rowTargets = filterRows
  ctrl3.groupTargets = [filterGroup]
  ctrl3.hasQueryTarget = true
  ctrl3.queryTarget = queryInput
  ctrl3.filter()
  assert.equal(filterRows[0].style.display, "")
  assert.equal(filterRows[1].style.display, "none")

  ctrl3.clearQuery()
  assert.equal(queryInput.value, "", "clearQuery should empty the query input")
  assert.equal(filterRows[0].style.display, "")
  assert.equal(filterRows[1].style.display, "", "rows hidden by query should be visible after clearQuery")
}

function testReportRedesignedController() {
  const { ControllerClass } = loadReportRedesignedController()
  const events = []
  const callbacks = {}
  const turboFrame = {
    dataset: { probeAttemptsUrl: "/reports/1/probe_attempts?probe_result_id=2" },
    src: "",
    innerHTML: "",
    addEventListener(type, callback, options) {
      events.push({ type, options })
      callbacks[type] = callback
    },
    removeAttribute(name) {
      if (name === "src") this.src = ""
    }
  }
  const attemptsContent = {
    classList: classListWith("hidden"),
    querySelector(selector) {
      return selector === "turbo-frame" ? turboFrame : null
    }
  }
  const attemptsChevron = { style: {} }
  const controller = new ControllerClass()

  controller.element = {
    querySelector(selector) {
      if (selector.includes("attemptsContent")) return attemptsContent
      if (selector.includes("attemptsChevron")) return attemptsChevron
      return null
    }
  }

  controller.toggleProbeAttempts({
    stopPropagation() {},
    currentTarget: { dataset: { probeResultId: "2" } }
  })

  assert.equal(attemptsContent.classList.contains("hidden"), false)
  assert.equal(attemptsChevron.style.transform, "rotate(180deg)")
  assert.equal(turboFrame.src, "/reports/1/probe_attempts?probe_result_id=2")
  assert.deepEqual(events.map((event) => event.type), [
    "turbo:frame-missing",
    "turbo:fetch-request-error"
  ])

  let prevented = false
  callbacks["turbo:fetch-request-error"]({
    preventDefault() { prevented = true }
  })

  assert.equal(prevented, true)
  assert.equal(turboFrame.src, "")
  assert.equal(turboFrame.innerHTML.includes("Failed to load attempts"), true)

  controller.toggleProbeAttempts({
    stopPropagation() {},
    currentTarget: { dataset: { probeResultId: "2" } }
  })

  assert.equal(attemptsContent.classList.contains("hidden"), true)
  assert.equal(attemptsChevron.style.transform, "rotate(0deg)")

  controller.toggleProbeAttempts({
    stopPropagation() {},
    currentTarget: { dataset: { probeResultId: "2" } }
  })

  assert.equal(attemptsContent.classList.contains("hidden"), false)
  assert.equal(turboFrame.src, "/reports/1/probe_attempts?probe_result_id=2")
}

function testReportRedesignedControllerListenerCleanup() {
  const { ControllerClass } = loadReportRedesignedController()
  const addCalls = []
  const removeCalls = []
  const turboFrame = {
    dataset: { probeAttemptsUrl: "/reports/1/probe_attempts?probe_result_id=2" },
    src: "",
    innerHTML: "",
    addEventListener(type, callback, options) {
      addCalls.push({ type, callback, options })
    },
    removeEventListener(type, callback) {
      removeCalls.push({ type, callback })
    },
    removeAttribute(name) {
      if (name === "src") this.src = ""
    }
  }
  const attemptsContent = {
    classList: classListWith("hidden"),
    querySelector(selector) {
      return selector === "turbo-frame" ? turboFrame : null
    }
  }
  const attemptsChevron = { style: {} }
  const controller = new ControllerClass()

  controller.element = {
    addEventListener() {},
    querySelector(selector) {
      if (selector.includes("attemptsContent")) return attemptsContent
      if (selector.includes("attemptsChevron")) return attemptsChevron
      return null
    }
  }
  controller.hasAsrHistoryChartTarget = false
  controller.hasTopProbesChartTarget = false

  if (typeof controller.connect === "function") {
    controller.connect()
  }

  controller.toggleProbeAttempts({
    stopPropagation() {},
    currentTarget: { dataset: { probeResultId: "2" } }
  })

  assert.equal(addCalls.length, 2, "expected two error listeners attached")
  const addedTypes = addCalls.map((call) => call.type).sort()
  assert.deepEqual(addedTypes, [
    "turbo:fetch-request-error",
    "turbo:frame-missing"
  ])

  // listeners never fire (happy path); disconnect must clean them up
  controller.disconnect()

  const removedTypes = removeCalls.map((call) => call.type).sort()
  assert.deepEqual(
    removedTypes,
    ["turbo:fetch-request-error", "turbo:frame-missing"],
    "disconnect should remove both turbo-frame error listeners"
  )

  // each removed handler should match the originally attached handler
  for (const removeCall of removeCalls) {
    const matchingAdd = addCalls.find(
      (a) => a.type === removeCall.type && a.callback === removeCall.callback
    )
    assert.ok(
      matchingAdd,
      `removeEventListener for ${removeCall.type} should match the originally registered handler`
    )
  }
}

function testLogViewerController() {
  const { ControllerClass } = loadLogViewerController()

  const passLine = {
    classList: classListWith("log-line", "pass-line"),
    textContent: "ok on 5/10 PASS",
    style: { display: "" },
    dataset: {}
  }
  const failLine = {
    classList: classListWith("log-line", "fail-line"),
    textContent: "FAIL probe failed",
    style: { display: "" },
    dataset: {}
  }
  const events = []
  const element = {
    dispatchEvent(evt) { events.push(evt) }
  }

  const controller = new ControllerClass()
  controller.element = element
  controller.contentTarget = {
    contains() { return false },
    querySelectorAll(selector) {
      assert.equal(selector, ".log-line")
      return [passLine, failLine]
    }
  }
  controller.hasSearchTarget = true
  controller.searchTarget = { value: "" }

  // PASS filter — pass line stays visible, fail line hides, info line stays visible
  const infoLine = {
    classList: classListWith("log-line"),
    textContent: "INFO module loaded",
    style: { display: "" },
    dataset: {}
  }
  controller.contentTarget = {
    contains() { return false },
    querySelectorAll(selector) {
      assert.equal(selector, ".log-line")
      return [passLine, failLine, infoLine]
    }
  }

  controller.filter({ currentTarget: { dataset: { filterType: "pass" } } })
  assert.equal(passLine.dataset.logViewerStatusMatch, "true")
  assert.equal(failLine.dataset.logViewerStatusMatch, "false")
  assert.equal(infoLine.dataset.logViewerStatusMatch, "true",
    "info lines should remain visible under PASS filter (only opposite-type lines hide)")
  assert.equal(passLine.style.display, "")
  assert.equal(failLine.style.display, "none")
  assert.equal(infoLine.style.display, "")
  assert.equal(events.at(-1).type, "log-viewer:filter-change")
  assert.equal(events.at(-1).bubbles, true)

  // FAIL filter — fail line stays visible, pass line hides, info line stays visible
  controller.filter({ currentTarget: { dataset: { filterType: "fail" } } })
  assert.equal(failLine.dataset.logViewerStatusMatch, "true")
  assert.equal(passLine.dataset.logViewerStatusMatch, "false")
  assert.equal(infoLine.dataset.logViewerStatusMatch, "true")

  // re-apply PASS filter so downstream search/composition assertions match the original setup
  controller.filter({ currentTarget: { dataset: { filterType: "pass" } } })

  // search "FAIL" — only fail line matches; combined with pass-only status, fail line still hidden
  controller.searchTarget.value = "FAIL"
  controller.search()
  assert.equal(passLine.dataset.logViewerSearchMatch, "false")
  assert.equal(failLine.dataset.logViewerSearchMatch, "true")
  // pass: status=true, search=false -> filterMatch=false -> hidden
  assert.equal(passLine.style.display, "none")
  // fail: status=false, search=true -> filterMatch=false -> hidden
  assert.equal(failLine.style.display, "none")

  // resetFilter — both lines back to visible, search cleared
  controller.resetFilter()
  assert.equal(controller.searchTarget.value, "")
  assert.equal(passLine.dataset.logViewerStatusMatch, "true")
  assert.equal(failLine.dataset.logViewerStatusMatch, "true")
  assert.equal(passLine.dataset.logViewerSearchMatch, "true")
  assert.equal(failLine.dataset.logViewerSearchMatch, "true")
  assert.equal(passLine.style.display, "")
  assert.equal(failLine.style.display, "")

  // resetFilter dispatches log-viewer:reset event for the cross-panel filter
  const resetEvents = events.filter(e => e.type === "log-viewer:reset")
  assert.equal(resetEvents.length, 1, "resetFilter should dispatch exactly one log-viewer:reset event")
  assert.equal(resetEvents[0].bubbles, true)

  // composition with debug-stream filter — line hidden if either side false
  passLine.dataset.debugStreamFilterMatch = "false"
  controller.search()
  assert.equal(passLine.style.display, "none")

  // notifyFilterChange always dispatches an event
  const eventCountBefore = events.length
  controller.notifyFilterChange()
  assert.equal(events.length, eventCountBefore + 1)

  // appended rows are included on later filter runs
  const dynamicPassLine = {
    classList: classListWith("log-line", "pass-line"),
    textContent: "early PASS line",
    style: { display: "" },
    dataset: {}
  }
  const dynamicFailLine = {
    classList: classListWith("log-line", "fail-line"),
    textContent: "late FAIL line",
    style: { display: "" },
    dataset: {}
  }
  const dynamicEvents = []
  const dynamicController = new ControllerClass()
  let dynamicLines = [dynamicPassLine]
  dynamicController.element = {
    dispatchEvent(evt) { dynamicEvents.push(evt) }
  }
  dynamicController.contentTarget = {
    contains(node) { return dynamicLines.includes(node) },
    querySelectorAll(selector) {
      assert.equal(selector, ".log-line")
      return dynamicLines
    }
  }

  dynamicController.filter({ currentTarget: { dataset: { filterType: "pass" } } })
  dynamicLines = [dynamicPassLine, dynamicFailLine]
  dynamicController.filter({ currentTarget: { dataset: { filterType: "pass" } } })

  assert.equal(dynamicFailLine.dataset.logViewerStatusMatch, "false")
  assert.equal(dynamicFailLine.style.display, "none")
}

function testThreatVariantsController() {
  const { ControllerClass } = loadThreatVariantsController()

  const enabledController = new ControllerClass()
  const enabledContent = fakeElement()
  const enabledNotice = fakeElement("hidden")
  const enabledIndustryCheckbox = fakeElement()
  const enabledSubindustryCheckbox = fakeElement()

  enabledController.contentTarget = enabledContent
  enabledController.hasContentTarget = true
  enabledController.disabledNoticeTarget = enabledNotice
  enabledController.hasDisabledNoticeTarget = true
  enabledController.industryCheckboxTargets = [enabledIndustryCheckbox]
  enabledController.subindustryCheckboxTargets = [enabledSubindustryCheckbox]

  enabledController.applyEligibility(true)

  assert.equal(enabledContent.classList.contains("opacity-50"), false)
  assert.equal(enabledContent.classList.contains("pointer-events-none"), false)
  assert.equal(enabledContent.getAttribute("aria-disabled"), undefined)
  assert.equal(enabledNotice.classList.contains("hidden"), true)
  assert.equal(enabledIndustryCheckbox.disabled, false)
  assert.equal(enabledSubindustryCheckbox.disabled, false)

  const disabledController = new ControllerClass()
  const disabledContent = fakeElement()
  const disabledNotice = fakeElement("hidden")
  const disabledIndustryCheckbox = fakeElement()
  const disabledSubindustryCheckbox = fakeElement()

  disabledController.contentTarget = disabledContent
  disabledController.hasContentTarget = true
  disabledController.disabledNoticeTarget = disabledNotice
  disabledController.hasDisabledNoticeTarget = true
  disabledController.industryCheckboxTargets = [disabledIndustryCheckbox]
  disabledController.subindustryCheckboxTargets = [disabledSubindustryCheckbox]

  disabledController.applyEligibility(false)

  assert.equal(disabledContent.classList.contains("opacity-50"), true)
  assert.equal(disabledContent.classList.contains("pointer-events-none"), true)
  assert.equal(disabledContent.getAttribute("aria-disabled"), "true")
  assert.equal(disabledNotice.classList.contains("hidden"), false)
  assert.equal(disabledIndustryCheckbox.disabled, true)
  assert.equal(disabledSubindustryCheckbox.disabled, true)

  const clearController = new ControllerClass()
  const cb1 = fakeElement()
  cb1.checked = true
  const cb2 = fakeElement()
  cb2.checked = true
  clearController.subindustryCheckboxTargets = [cb1, cb2]
  clearController.industryItemTargets = []
  clearController.summaryTarget = fakeElement()
  clearController.hasSummaryTarget = true

  clearController.clearSelections()

  assert.equal(cb1.checked, false)
  assert.equal(cb2.checked, false)
}

function loadWebchatAuthController() {
  const transformed = loadControllerSource(
    "webchat_auth_controller.js",
    "WebchatAuthController"
  )

  const context = {
    Controller: class {},
    Event: class {
      constructor(type, init = {}) {
        this.type = type
        this.bubbles = !!init.bubbles
      }
    },
    document: {
      querySelector() { return null }
    }
  }

  const ControllerClass = vm.runInNewContext(
    `${transformed}\nWebchatAuthController`,
    context
  )

  return { ControllerClass }
}

function testWebchatAuthController() {
  const { ControllerClass } = loadWebchatAuthController()

  // 1. builds auth payload from rows
  {
    const controller = new ControllerClass()
    const auth = controller.buildAuthPayload(
      [{ name: "session", value: "v", domain: "example.com" }],
      [{ key: "Authorization", value: "Bearer x" }],
      '{"cookies":[],"origins":[]}'
    )
    // JSON round-trip to avoid vm-realm prototype mismatch in deepEqual
    assert.deepEqual(JSON.parse(JSON.stringify(auth.cookies)), [{ name: "session", value: "v", domain: "example.com" }])
    assert.deepEqual(JSON.parse(JSON.stringify(auth.headers)), { Authorization: "Bearer x" })
    assert.deepEqual(JSON.parse(JSON.stringify(auth.storage_state)), { cookies: [], origins: [] })
  }

  // 2. returns null for empty section
  {
    const controller = new ControllerClass()
    assert.equal(controller.buildAuthPayload([], [], ""), null)
  }

  // 3. merges auth into existing web_config JSON
  {
    const controller = new ControllerClass()
    const merged = controller.mergeAuthIntoConfig(
      JSON.stringify({ url: "https://x", selectors: {} }),
      { headers: { Authorization: "Bearer x" } }
    )
    const parsed = JSON.parse(merged)
    assert.equal(parsed.url, "https://x")
    assert.deepEqual(parsed.auth, { headers: { Authorization: "Bearer x" } })
  }

  // 4. drops the auth key when payload is null
  {
    const controller = new ControllerClass()
    const merged = controller.mergeAuthIntoConfig(
      JSON.stringify({ url: "https://x", auth: { headers: {} } }),
      null
    )
    assert.equal("auth" in JSON.parse(merged), false)
  }

  // 5. serializes DOM rows into the web_config auth block
  {
    const controller = new ControllerClass()
    controller.hasCookieRowsTarget = true
    controller.cookieRowsTarget = {
      querySelectorAll: () => [
        {
          querySelector: (sel) => ({
            value: sel.includes("name") ? "session" : sel.includes("domain") ? "example.com" : "v"
          })
        }
      ]
    }
    controller.hasHeaderRowsTarget = false
    controller.hasStorageStateTarget = false

    let dispatched = false
    controller.webConfigField = {
      value: JSON.stringify({ url: "https://x", selectors: {} }),
      dispatchEvent() { dispatched = true }
    }

    controller.serialize()

    const parsed = JSON.parse(controller.webConfigField.value)
    assert.equal(parsed.url, "https://x")
    assert.deepEqual(parsed.auth.cookies[0], { name: "session", value: "v", domain: "example.com" })
    assert.equal(dispatched, true)
  }

  // 6. appends a cookie row and re-serializes
  {
    const controller = new ControllerClass()
    const rows = []
    const fakeRow = { querySelector: () => ({ value: "" }) }
    controller.cookieTemplateTarget = { content: { firstElementChild: { cloneNode: () => fakeRow } } }
    controller.cookieRowsTarget = { appendChild: (n) => rows.push(n), querySelectorAll: () => rows }
    controller.hasCookieRowsTarget = true
    controller.hasHeaderRowsTarget = false
    controller.hasStorageStateTarget = false
    controller.webConfigField = { value: "{}", dispatchEvent() {} }

    controller.addCookieRow()

    assert.equal(rows.length, 1)
  }

  // 7. removes a row and re-serializes
  {
    const controller = new ControllerClass()
    let removed = false
    const row = { remove: () => { removed = true } }
    controller.hasCookieRowsTarget = false
    controller.hasHeaderRowsTarget = false
    controller.hasStorageStateTarget = false
    controller.webConfigField = { value: "{}", dispatchEvent() {} }

    controller.removeRow({ target: { closest: () => row } })

    assert.equal(removed, true)
  }

  // 8. toggles a value field between password and text
  {
    const controller = new ControllerClass()
    const input = { type: "password" }
    const row = { querySelector: () => input }

    controller.toggleVisibility({ target: { closest: () => row } })

    assert.equal(input.type, "text")
  }

  // 9. hydrates rows from existing web_config auth
  {
    const controller = new ControllerClass()
    const cookieRows = []
    const headerRows = []
    const mkRow = () => {
      const fields = {}
      return {
        dataset: {},
        querySelector: (sel) => {
          const m = sel.match(/data-field="(\w+)"/)
          const f = m[1]
          return (fields[f] || (fields[f] = { value: "" }))
        },
        _fields: fields
      }
    }
    controller.hasCookieTemplateTarget = true
    controller.cookieTemplateTarget = { content: { firstElementChild: { cloneNode: () => mkRow() } } }
    controller.hasCookieRowsTarget = true
    controller.cookieRowsTarget = { appendChild: (r) => cookieRows.push(r) }
    controller.hasHeaderTemplateTarget = true
    controller.headerTemplateTarget = { content: { firstElementChild: { cloneNode: () => mkRow() } } }
    controller.hasHeaderRowsTarget = true
    controller.headerRowsTarget = { appendChild: (r) => headerRows.push(r) }
    controller.hasStorageStateTarget = true
    controller.storageStateTarget = { value: "" }
    controller.webConfigField = {
      value: JSON.stringify({
        url: "https://x",
        auth: {
          cookies: [{ name: "session", value: "v", domain: "example.com" }],
          headers: { Authorization: "Bearer x" },
          storage_state: { cookies: [] }
        }
      })
    }

    controller.populateFromAuth()

    assert.equal(cookieRows.length, 1)
    assert.equal(cookieRows[0]._fields.name.value, "session")
    assert.equal(cookieRows[0]._fields.value.value, "v")
    assert.equal(cookieRows[0]._fields.domain.value, "example.com")
    assert.equal(headerRows.length, 1)
    assert.equal(headerRows[0]._fields.key.value, "Authorization")
    assert.equal(headerRows[0]._fields.value.value, "Bearer x")
    assert.ok(controller.storageStateTarget.value.includes("cookies"))
  }

  // 10. hydrates nothing when there is no auth
  {
    const controller = new ControllerClass()
    const cookieRows = []
    controller.hasCookieTemplateTarget = true
    controller.cookieTemplateTarget = { content: { firstElementChild: { cloneNode: () => ({ dataset: {}, querySelector: () => ({ value: "" }) }) } } }
    controller.hasCookieRowsTarget = true
    controller.cookieRowsTarget = { appendChild: (r) => cookieRows.push(r) }
    controller.hasHeaderRowsTarget = false
    controller.hasStorageStateTarget = false
    controller.webConfigField = { value: JSON.stringify({ url: "https://x" }) }

    controller.populateFromAuth()

    assert.equal(cookieRows.length, 0)
  }

  // 11. round-trips advanced cookie fields through edit
  {
    const controller = new ControllerClass()
    const fields = { name: { value: "session" }, value: { value: "v" }, domain: { value: "" } }
    const row = {
      dataset: { cookieExtra: JSON.stringify({ url: "https://x/app", secure: true, sameSite: "Lax", path: "/app" }) },
      querySelector: (sel) => fields[sel.match(/data-field="(\w+)"/)[1]]
    }
    controller.hasCookieRowsTarget = true
    controller.cookieRowsTarget = { querySelectorAll: () => [row] }

    const cookie = controller.readCookieRows()[0]
    assert.equal(cookie.url, "https://x/app")
    assert.equal(cookie.secure, true)
    assert.equal(cookie.sameSite, "Lax")
    assert.equal(cookie.path, "/app")
    assert.equal(cookie.name, "session")
    assert.equal(cookie.value, "v")
    assert.equal(cookie.domain, undefined)
  }

  // 12. prefers a typed domain over a stashed url
  {
    const controller = new ControllerClass()
    const fields = { name: { value: "s" }, value: { value: "v" }, domain: { value: "example.com" } }
    const row = {
      dataset: { cookieExtra: JSON.stringify({ url: "https://x/" }) },
      querySelector: (sel) => fields[sel.match(/data-field="(\w+)"/)[1]]
    }
    controller.hasCookieRowsTarget = true
    controller.cookieRowsTarget = { querySelectorAll: () => [row] }

    const c = controller.readCookieRows()[0]
    assert.equal(c.domain, "example.com")
    assert.equal("url" in c, false)
  }

  // 13. stashes advanced cookie fields on hydrate
  {
    const controller = new ControllerClass()
    const rows = []
    const mkRow = () => {
      const fields = {}
      return {
        dataset: {},
        querySelector: (sel) => {
          const f = sel.match(/data-field="(\w+)"/)[1]
          return (fields[f] || (fields[f] = { value: "" }))
        }
      }
    }
    controller.hasCookieTemplateTarget = true
    controller.cookieTemplateTarget = { content: { firstElementChild: { cloneNode: () => mkRow() } } }
    controller.hasCookieRowsTarget = true
    controller.cookieRowsTarget = { appendChild: (r) => rows.push(r) }
    controller.hasHeaderTemplateTarget = false
    controller.hasHeaderRowsTarget = false
    controller.hasStorageStateTarget = false
    controller.webConfigField = {
      value: JSON.stringify({ auth: { cookies: [{ name: "s", value: "v", domain: "e.com", secure: true, sameSite: "Lax" }] } })
    }

    controller.populateFromAuth()

    assert.equal(rows.length, 1)
    const extra = JSON.parse(rows[0].dataset.cookieExtra)
    assert.equal(extra.secure, true)
    assert.equal(extra.sameSite, "Lax")
    assert.equal("name" in extra, false)
  }

  // 14. keeps invalid storageState so the server can reject it
  {
    const controller = new ControllerClass()
    assert.equal(controller.buildAuthPayload([], [], "{ not valid json").storage_state, "{ not valid json")
    assert.equal(controller.buildAuthPayload([], [], "42").storage_state, "42")
  }

  // 15. keeps a cookie with an empty-string value
  {
    const controller = new ControllerClass()
    const auth = controller.buildAuthPayload([{ name: "flag", value: "", domain: "e.com" }], [], "")
    assert.equal(auth.cookies.length, 1)
    assert.equal(auth.cookies[0].name, "flag")
    assert.equal(auth.cookies[0].value, "")
  }
}

function loadTargetWizardController() {
  const transformed = loadControllerSource(
    "target_wizard_controller.js",
    "TargetWizardController"
  )

  const context = {
    Controller: class {},
    console: { warn() {} },
    document: { querySelector() { return null } },
    window: { scrollTo() {} },
  }

  const ControllerClass = vm.runInNewContext(
    `${transformed}\nTargetWizardController`,
    context
  )

  return { ControllerClass, context }
}

function testTargetWizardRedactAuth() {
  const { ControllerClass } = loadTargetWizardController()
  const c = new ControllerClass()

  // passthrough when no auth key
  assert.deepEqual(JSON.parse(JSON.stringify(c.redactAuthForReview({ url: "x" }))), { url: "x" })

  // redacts cookies/headers/storage_state to non-secret summaries
  const out = JSON.parse(JSON.stringify(c.redactAuthForReview({
    url: "https://x",
    selectors: {},
    auth: {
      cookies: [{ name: "s", value: "secret-cookie" }],
      headers: { Authorization: "Bearer secret-token" },
      storage_state: { cookies: [] },
    },
  })))
  assert.equal(out.url, "https://x")
  assert.equal(JSON.stringify(out).includes("secret-cookie"), false)
  assert.equal(JSON.stringify(out).includes("secret-token"), false)
  assert.equal(out.auth.cookies, "1 cookie(s) [hidden]")
  assert.equal(out.auth.headers, "1 header(s) [hidden]")
  assert.equal(out.auth.storage_state, "[hidden]")

  // empty cookies array — passthrough (no redaction when length === 0)
  const outEmpty = JSON.parse(JSON.stringify(c.redactAuthForReview({
    url: "x",
    auth: { cookies: [], headers: {}, storage_state: null },
  })))
  assert.deepEqual(outEmpty.auth, {})

  // missing auth key — passthrough unchanged
  const cfg = { url: "https://x", selectors: { input_field: "#i" } }
  assert.deepEqual(JSON.parse(JSON.stringify(c.redactAuthForReview(cfg))), cfg)
}

function testTargetWizardSyncModel() {
  const { ControllerClass } = loadTargetWizardController()

  // edited model is synced into the embedded json config (replaces all occurrences,
  // covering the model in a request body and/or a URI)
  const c = new ControllerClass()
  c.embeddedModel = "claude-sonnet-4-5"
  c.hasModelFieldTarget = true
  c.modelFieldTarget = { value: "claude-opus-4-1" }
  c.hasJsonConfigFieldTarget = true
  c.jsonConfigFieldTarget = {
    value: '{"rest":{"RestGenerator":{"uri":"https://api.anthropic.com/v1/messages","req_template_json_object":{"model":"claude-sonnet-4-5"}}}}',
  }
  c.syncModelIntoConfig()
  assert.equal(c.jsonConfigFieldTarget.value.includes("claude-opus-4-1"), true)
  assert.equal(c.jsonConfigFieldTarget.value.includes("claude-sonnet-4-5"), false)
  assert.equal(c.embeddedModel, "claude-opus-4-1")

  // no-op when there is no embedded config (e.g. OpenAI/OpenRouter)
  const c2 = new ControllerClass()
  c2.embeddedModel = "gpt-4o"
  c2.hasModelFieldTarget = true
  c2.modelFieldTarget = { value: "gpt-4o-mini" }
  c2.hasJsonConfigFieldTarget = true
  c2.jsonConfigFieldTarget = { value: "" }
  c2.syncModelIntoConfig()
  assert.equal(c2.jsonConfigFieldTarget.value, "")
  assert.equal(c2.embeddedModel, "gpt-4o-mini")
}

function loadWebchatAutoDetectController() {
  const raw = readFileSync(
    new URL("../../app/javascript/controllers/webchat_auto_detect_controller.js", import.meta.url),
    "utf8"
  )
  const transformed = raw
    .replace(/^import .*\n/gm, "")
    .replace("export default class extends Controller", "class WebchatAutoDetectController extends Controller")
  const context = {
    Controller: class {},
    consumer: {},
    document: { querySelector() { return null } },
    console: { log() {}, warn() {} },
  }
  const ControllerClass = vm.runInNewContext(`${transformed}\nWebchatAutoDetectController`, context)
  return { ControllerClass, context }
}

function testWebchatAutoDetectCurrentAuth() {
  const { ControllerClass } = loadWebchatAutoDetectController()

  const withAuth = new ControllerClass()
  withAuth.configTextarea = {
    value: JSON.stringify({ url: "https://x", auth: { headers: { Authorization: "Bearer x" } } }),
  }
  assert.deepEqual(
    JSON.parse(JSON.stringify(withAuth.currentAuth())),
    { headers: { Authorization: "Bearer x" } }
  )

  const withoutAuth = new ControllerClass()
  withoutAuth.configTextarea = { value: JSON.stringify({ url: "https://x" }) }
  assert.equal(withoutAuth.currentAuth(), null)

  const malformed = new ControllerClass()
  malformed.configTextarea = { value: "{not json" }
  assert.equal(malformed.currentAuth(), null)
}

await testDebugStreamLeaseController()
testActivityStreamController()
testDebugTabsController()
testDebugStreamFilterController()
testReportRedesignedController()
testReportRedesignedControllerListenerCleanup()
testLogViewerController()
testThreatVariantsController()
testWebchatAuthController()
testTargetWizardRedactAuth()
testTargetWizardSyncModel()
testWebchatAutoDetectCurrentAuth()
console.log("JavaScript controller tests passed")
