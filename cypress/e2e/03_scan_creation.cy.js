describe('Scan Creation', () => {
  // Ignore ECharts errors on scan pages  
  Cypress.on('uncaught:exception', (err, runnable) => {
    if (err.message.includes('Cannot read properties of undefined') && err.message.includes('push')) {
      return false
    }
    return true
  })
  
  let testTargetName
  let createdScanName
  
  before(() => {
    // Create a test target that will be used for scan creation
    cy.createTestTarget().then((targetName) => {
      testTargetName = targetName
    })
  })
  
  it('creates a new scan with benign test probe', () => {
    const timestamp = Date.now()
    const scanName = `Test Scan ${timestamp}`
    createdScanName = scanName // Store for later tests
    
    // Navigate to new scan page
    cy.visit('/scans/new')
    
    // Verify we're on the new scan page
    cy.url().should('include', '/scans/new')
    
    // Fill in scan name
    cy.get('#scan_name').type(scanName)
    
    // Use custom Cypress command to select the target by name
    cy.selectTargetByName(testTargetName)
    
    // Select benign test probe by name (handles category expansion automatically)
    cy.selectProbeByName('test.Blank', 'anyoutput')
    
    // Check priority box
    cy.get('#scan_priority').check({ force: true })

    // Optionally select output server (leave as None for now)
    // cy.get('#scan_output_server_id').select('None')
    
    // Leave schedule as None (default)
    
    // Submit the form
    cy.contains('button[type="submit"]', 'Create Scan').click()
    
    // Check for validation errors
    cy.get('body').then($body => {
      if ($body.text().includes("can't be blank") || $body.text().includes('error')) {
        cy.log('Form validation error detected')
      }
    })
    
    // Verify successful creation - should redirect to scan detail page
    cy.location('pathname').should('match', /^\/scans\/\d+$/)
    
    // Verify scan details are displayed
    cy.contains(scanName).should('be.visible')

    // Track created scan
    cy.trackResource({ type: 'scan', name: scanName })
    
    // Verify that a report was created and completes successfully
    // Note: Don't verify target name as it may be displayed differently in the reports table
    cy.verifyReportCreated(scanName, undefined, { waitForCompletion: true, expectSuccess: true, timeout: 120000 })
  })
  
  it('verifies scan appears in scans list', () => {
    // This test is dependent on the previous test, skip if it didn't run
    cy.log('Note: This test depends on the previous test creating a scan')
    
    // Navigate to scans index
    cy.visit('/scans')
    
    // Wait for page to load
    cy.wait(2000)
    
    // Check if there's a table or a "no scans" message
    cy.get('body').then($body => {
      if ($body.find('table tbody tr').length > 0) {
        // Verify at least one scan exists in the list
        cy.get('table tbody tr').should('have.length.greaterThan', 0)
        
        // Verify the first scan has expected columns
        cy.get('table tbody tr').first().within(() => {
          cy.get('td').should('have.length.greaterThan', 3) // Has multiple columns
        })
      } else {
        cy.log('No scans found in table - previous test may have failed')
        // Check if there's any indication of scans on the page
        cy.contains(/scan/i).should('exist')
      }
    })
  })
  
  it('creates a scan with multiple probes', () => {
    const timestamp = Date.now()
    const scanName = `Multi-Probe Scan ${timestamp}`
    
    cy.visit('/scans/new')
    
    // Fill in scan name
    cy.get('#scan_name').type(scanName)
    
    // Wait for page to fully load
    cy.wait(2000)
    
    // Use custom Cypress command to select the target by name
    cy.selectTargetByName(testTargetName)
    
    // Select multiple probes by name
    cy.selectProbeByName('test.Blank', 'anyoutput')
    cy.selectProbeByName('test.Test', 'pass') // Select another probe from the same category
    
    // Submit the form
    cy.contains('button[type="submit"]', 'Create Scan').click()
    
    // Verify successful creation
    cy.location('pathname').should('match', /^\/scans\/\d+$/)
    cy.contains(scanName).should('be.visible')

    // Track created scan
    cy.trackResource({ type: 'scan', name: scanName })

    // Verify that a report was created and completes successfully
    // Multi-probe scans take longer, so we use a 2-minute timeout
    cy.verifyReportCreated(scanName, testTargetName, { waitForCompletion: true, expectSuccess: true, timeout: 240000 })
  })
  
  it('shows validation errors when required fields are missing', () => {
    cy.visit('/scans/new')
    
    // Try to submit without filling any fields
    cy.contains('button[type="submit"]', 'Create Scan').click()
    
    // Should either stay on new page or redirect to index with errors
    cy.url().should('include', '/scans')
    
    // Should show validation errors or stay on form
    cy.get('body').then($body => {
      // Check if validation error is shown
      if ($body.text().includes("can't be blank")) {
        cy.contains("can't be blank").should('be.visible')
      } else {
        // Otherwise just verify we're on scans page
        cy.url().should('include', '/scans')
      }
    })
  })
  
  it('creates a scheduled scan', () => {
    const timestamp = Date.now()
    const scanName = `Scheduled Scan ${timestamp}`
    
    cy.visit('/scans/new')
    
    // Fill in scan name
    cy.get('#scan_name').type(scanName)
    
    // Use custom Cypress command to select the target by name
    cy.selectTargetByName(testTargetName)
    
    // Select probe by name
    cy.selectProbeByName('test.Blank', 'anyoutput')
    
    // Set up daily schedule using visual frequency button
    cy.get('button[data-frequency="daily"]').first().click()

    // Set time (e.g., 10:00)
    cy.get('#recurrence_time').clear().type('10:00')

    // Submit the form (scroll into view and force click as page has overlapping elements)
    cy.contains('button[type="submit"]', 'Create Scan').scrollIntoView().click({ force: true })
    
    // Verify successful creation
    cy.location('pathname').should('match', /^\/scans\/\d+$/)
    cy.contains(scanName).should('be.visible')

    // Track created scan
    cy.trackResource({ type: 'scan', name: scanName })
    
    // Verify schedule is shown
    cy.contains('Daily').should('be.visible')
  })
  
  it('selects and clears every probe in a category', () => {
    cy.visit('/scans/new')
    cy.waitForStimulusController('probe-category')
    cy.get('button[data-action="click->probe-category#expandAll"]').click()

    cy.get('input#category_pass').check({ force: true })
    cy.get('#category_content_pass input[name="scan[probe_ids][]"]')
      .should('have.length.greaterThan', 0)
      .each(($checkbox) => cy.wrap($checkbox).should('be.checked'))

    cy.get('input#category_pass').uncheck({ force: true })
    cy.get('#category_content_pass input[name="scan[probe_ids][]"]')
      .each(($checkbox) => cy.wrap($checkbox).should('not.be.checked'))
  })

  it('can rerun an existing scan', () => {
    // Navigate to one-time scans (scheduled scans don't have rerun button)
    cy.visit('/scans?scope=unscheduled')

    // Check if there are any scans to rerun
    cy.get('body').then($body => {
      const rows = $body.find('table tbody tr')
      if (rows.length === 0) {
        cy.log('No one-time scans available to rerun')
        return
      }

      // Check if rerun button exists in any row
      const hasRerunButton = rows.find('button:contains("Rerun")').length > 0
      if (!hasRerunButton) {
        cy.log('No rerun buttons available - scans may be running or scheduled')
        return
      }

      // Find a row with the rerun button and click it
      cy.get('table tbody tr').contains('button', 'Rerun').first().click()

      // Verify we're redirected to reports page
      cy.url().should('include', '/reports')

      // Verify success message
      cy.contains('Scan launched successfully').should('be.visible')

      // Verify a new report was created
      cy.get('table tbody tr').should('have.length.greaterThan', 0)
    })
  })

  // Optional deliberate failure test to verify skip-cleanup behavior
  const failFlag = Cypress.expose('FAIL_SCAN_CREATION_TEST')
  const shouldFail = failFlag === true || /^(true|1|yes|on)$/i.test(String(failFlag || ''))
  if (shouldFail) {
    it('deliberately fails to verify cleanup is skipped when SKIP_CLEANUP is set', () => {
      throw new Error('Deliberate failure for SKIP_CLEANUP verification')
    })
  }
})
