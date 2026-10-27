// Import order matters: registry commands first, then the rest
import './resourceRegistry'
import './commands'

// Establish and cache login session before specs
before(() => {
  return cy.env(['ADMIN_EMAIL', 'ADMIN_PASSWORD']).then(({ ADMIN_EMAIL: email, ADMIN_PASSWORD: password }) => {
    if (!email || !password) return
    return cy.loginSession(email, password, { cacheAcrossSpecs: true })
  })
})

// Restore cached session before each test (fast, no re-login)
beforeEach(() => {
  return cy.env(['ADMIN_EMAIL', 'ADMIN_PASSWORD']).then(({ ADMIN_EMAIL: email, ADMIN_PASSWORD: password }) => {
    if (!email || !password) return
    return cy.loginSession(email, password, { cacheAcrossSpecs: true })
  })
})

// Mark failures so we can conditionally skip cleanup when any test fails
afterEach(function () {
  // Use function() to access Mocha context
  if (this.currentTest && this.currentTest.state === 'failed') {
    cy.task('failures:mark')
  }
})

// Alternatively you can use CommonJS syntax:
// require('./commands')
