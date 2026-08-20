// Final spec: delete only the resources we explicitly tracked during this run
// Runs last due to filename prefix

// Allow skipping cleanup via Cypress env flag
// Usage examples:
//   npx cypress run --env SKIP_CLEANUP=true
//   CYPRESS_SKIP_CLEANUP=1 npx cypress run
const flagTrue = (v) => v === true || v === 'true' || v === '1' || v === 1 || v === 'yes' || v === 'on'
const shouldSkipByEnv = flagTrue(Cypress.env('SKIP_CLEANUP')) || flagTrue(Cypress.env('NO_CLEANUP'))

// Always define the suite; gate execution in a before() hook so we can also
// skip when any earlier test failed.
describe('99: cleanup tracked resources', function () {
  // Ignore expected Turbo-frame and request-abort errors caused by cleanup navigation.
  Cypress.on('uncaught:exception', (err, runnable) => {
    if (err.message.includes('did not contain the expected') && err.message.includes('turbo-frame')) {
      return false
    }
    if (err.name === 'AbortError' && err.message === 'The user aborted a request.') {
      return false
    }
    return true
  })

  before(function () {
    if (shouldSkipByEnv) {
      // eslint-disable-next-line no-console
      console.info('Skipping cleanup because SKIP_CLEANUP/NO_CLEANUP is set')
      this.skip()
      return
    }
    // Skip cleanup if any test failed in this run (checked via plugin task)
    cy.task('failures:has').then((hadFailures) => {
      if (hadFailures) {
        // eslint-disable-next-line no-console
        console.info('Skipping cleanup because there were earlier test failures')
        this.skip()
      }
    })
  })

  before(() => {
    // Login without session caching for cleanup (skip if no credentials for localhost)
    const email = Cypress.env('ADMIN_EMAIL') || Cypress.env('OAUTH_EMAIL')
    const password = Cypress.env('ADMIN_PASSWORD') || Cypress.env('OAUTH_PASSWORD')
    if (email && password) {
      cy.adminApiLogin()
    }
  })

  it('cleans up reports, scans, targets, and environment variables by name', () => {
    cy.cleanupTrackedResources()
      .then(() => {
        // Remove registry JSON files now; the after:run hook also cleans as a fallback
        return cy.task('registry:pruneFiles', { pattern: /^created-.*\.json$/, removeDir: false })
      })
      .then((result) => {
        cy.log(`Pruned .e2e files: removed=${result && result.removed}`)
      })
      .then(() => {
        cy.log('Cleanup completed successfully.')
      })
  })
})
