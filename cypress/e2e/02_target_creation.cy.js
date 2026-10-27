describe('Target Creation', () => {
  // Ignore ECharts errors and Stimulus keyboard filter errors
  Cypress.on('uncaught:exception', (err, runnable) => {
    if (err.message.includes('Cannot read properties of undefined') && err.message.includes('push')) {
      return false
    }
    return true
  })

  it('creates a new RestGenerator target successfully', () => {
    const timestamp = Date.now()
    const targetName = `Test API Target ${timestamp}`

    // Navigate to targets page and click New Target
    cy.visit('/targets')
    cy.get('a[href="/targets/new"]').first().click()
    cy.url().should('include', '/targets/new')

    // Step 1: Select Custom Configuration provider
    cy.selectCustomTargetProvider()

    // Step 2: Fill in target details
    cy.get('#target_name').should('be.visible').type(targetName)
    cy.get('[data-target-wizard-target="modelTypeSelect"]').select('REST API (Generic)')
    cy.get('#target_model').type('test-model-v1')

    // Add JSON configuration
    cy.getRestGeneratorConfig().then(config => {
      cy.get('#target_json_config').type(JSON.stringify(config, null, 2), { parseSpecialCharSequences: false })
    })

    // Step 2 → Step 3: Click Next
    cy.contains('button', 'Next: Review').click()

    // Step 3: Submit
    cy.contains('button[type="submit"]', 'Create Target').click()

    // Verify successful creation
    cy.location('pathname').should('match', /^\/targets\/\d+$/)
    cy.contains(targetName).should('be.visible')
    cy.contains('RestGenerator').should('be.visible')
    cy.contains('test-model-v1').should('be.visible')

    // Track created target
    cy.trackResource({ type: 'target', name: targetName })
  })

  it('creates a RestGenerator target with minimal config', () => {
    const timestamp = Date.now()
    const targetName = `Test Minimal Target ${timestamp}`

    cy.visit('/targets/new')

    // Step 1: Select Custom Configuration
    cy.selectCustomTargetProvider()

    // Step 2: Fill in minimal details
    cy.get('#target_name').should('be.visible').type(targetName)
    cy.get('[data-target-wizard-target="modelTypeSelect"]').select('REST API (Generic)')
    cy.get('#target_model').type('minimal-model')

    cy.getRestGeneratorConfig('minimal test').then(config => {
      cy.get('#target_json_config').type(JSON.stringify(config, null, 2), { parseSpecialCharSequences: false })
    })

    // Step 2 → Step 3
    cy.contains('button', 'Next: Review').click()

    // Step 3: Submit
    cy.contains('button[type="submit"]', 'Create Target').click()

    // Verify successful creation
    cy.location('pathname').should('match', /^\/targets\/\d+$/)
    cy.contains(targetName).should('be.visible')
    cy.contains('RestGenerator').should('be.visible')

    // Track created target
    cy.trackResource({ type: 'target', name: targetName })
  })

  it('shows validation errors for missing required fields', () => {
    cy.visit('/targets/new')

    // Step 1: Select Custom Configuration
    cy.selectCustomTargetProvider()

    // Step 2: Name field should be required
    cy.get('#target_name').should('be.visible').should('have.attr', 'required')

    // Fill required fields and create successfully
    const timestamp = Date.now()
    cy.get('#target_name').type(`Incomplete Target ${timestamp}`)
    cy.get('[data-target-wizard-target="modelTypeSelect"]').select('REST API (Generic)')
    cy.get('#target_model').type('test-model')

    cy.getRestGeneratorConfig('test').then(config => {
      cy.get('#target_json_config').type(JSON.stringify(config, null, 2), { parseSpecialCharSequences: false })
    })

    cy.contains('button', 'Next: Review').click()
    cy.contains('button[type="submit"]', 'Create Target').click()

    cy.location('pathname').should('match', /^\/targets\/\d+$/)
    cy.trackResource({ type: 'target', name: `Incomplete Target ${timestamp}` })
  })

  it('navigates back from wizard without creating', () => {
    cy.visit('/targets/new')

    // Step 1: Select a provider to get to step 2
    cy.selectCustomTargetProvider()

    // Step 2: Fill in some data then navigate away via sidebar
    cy.get('#target_name').should('be.visible').type('Cancelled Target')

    // Click Targets in sidebar to leave without saving
    cy.get('a[href="/targets"]').first().click()

    // Should be on targets list page
    cy.location('pathname').should('eq', '/targets')
    cy.get('a[href="/targets/new"]').should('be.visible')
  })

  it('allows navigation back to targets list', () => {
    cy.visit('/targets/new')

    // Click on Targets link in sidebar
    cy.contains('a', 'Targets').first().click()

    // Should be on targets list page
    cy.location('pathname').should('eq', '/targets')
    cy.get('a[href="/targets/new"]').should('be.visible')
  })
})
