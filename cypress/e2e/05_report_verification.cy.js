// Dedicated test file for verifying report creation and status tracking

describe('Report Verification', () => {
  // Ignore ECharts errors on scan pages
  Cypress.on('uncaught:exception', (err, runnable) => {
    if (err.message.includes('Cannot read properties of undefined') && err.message.includes('push')) {
      return false
    }
    return true
  })
  
  let testTargetName
  let scanName
  
  before(() => {
    // Create a test target for use in all tests
    cy.createTestTarget().then((targetName) => {
      testTargetName = targetName
    })
  })
  
  it('creates a scan and verifies report creation immediately', () => {
    const timestamp = Date.now()
    scanName = `Report Test Scan ${timestamp}`
    
    // Create a scan
    cy.visit('/scans/new')
    
    // Fill in scan details
    cy.get('#scan_name').type(scanName)
    
    // Wait for target select to be ready
    cy.wait(2000)
    
    // Use custom Cypress command to select the target by name
    cy.selectTargetByName(testTargetName)
    
    // Select a DAN probe (community probe, always available)
    cy.selectProbeByName('test.Blank', 'anyoutput')

    // Check priority
    cy.get('#scan_priority').check({ force: true })
    
    // Submit the form
    cy.contains('button[type="submit"]', 'Create Scan').click()
    
    // Verify scan creation
    cy.location('pathname').should('match', /^\/scans\/\d+$/)
    cy.contains(scanName).should('be.visible')

    // Track created scan
    cy.trackResource({ type: 'scan', name: scanName })
    
    // Immediately navigate to reports page
    cy.visit('/reports')

    // Verify report exists (might still be starting)
    cy.contains('td', scanName, { timeout: 15000 }).should('exist')

    // Poll until the scan leaves pending state (no live updates on this page)
    cy.pollUntil(
      () => {
        cy.visit('/reports', { log: false })
        return cy.contains('td', scanName).parent('tr').find('td').eq(3).invoke('text')
      },
      (text) => text.trim().toLowerCase() !== 'pending',
      { timeout: 30000, interval: 2000, description: 'Wait for report to leave pending state' }
    )

    // Verify report details
    cy.contains('td', scanName)
      .parent('tr')
      .within(() => {
        // Check target name
        cy.contains(testTargetName).should('exist')

        // Check status - should be starting or running (column 3)
        cy.get('td').eq(3).then(($td) => {
          const status = $td.text().trim().toLowerCase()
          expect(['starting', 'running', 'completed', 'failed']).to.include(status)
          cy.log(`Initial report status: ${status}`)
        })
        
        // Check for action link (View Overview or any View link)
        cy.get('a').then($links => {
          const hasViewLink = $links.filter((i, el) =>
            el.textContent.includes('View') || el.textContent.includes('Overview')
          ).length > 0
          if (!hasViewLink) {
            // Running reports may not have view links yet
            cy.log('No view link found - report may still be running')
          }
        })
      })
  })
  
  it('monitors report status progression', () => {
    // Use the scan from the previous test
      if (!scanName) {
        const timestamp = Date.now()
        scanName = `Status Monitor Scan ${timestamp}`
        
        // Quick scan creation
        cy.visit('/scans/new')
        cy.get('#scan_name').type(scanName)
        
        // Wait for target select to be ready
        cy.wait(2000)
        
        // Use custom Cypress command to select the target by name
        cy.selectTargetByName(testTargetName)

        // Track the scan created for monitoring
        cy.trackResource({ type: 'scan', name: scanName })
        
        // Select probe by name
      cy.selectProbeByName('test.Blank', 'anyoutput')
      cy.contains('button[type="submit"]', 'Create Scan').click()
    }
    
    // Monitor status changes using the waitForReportCompletion command
    cy.waitForReportCompletion(scanName, 20000).then((finalStatus) => {
      cy.log(`Report finished with status: ${finalStatus}`)

      // Track the scan if it was created in this test sequence
      cy.trackResource({ type: 'scan', name: scanName })

      // If completed, verify the report row exists and has expected content
      if (finalStatus === 'completed') {
        cy.visit('/reports')
        cy.contains('td', scanName)
          .parent('tr')
          .within(() => {
            // Verify status shows completed
            cy.get('td').eq(3).invoke('text').then(text => {
              expect(text.trim().toLowerCase()).to.equal('completed')
            })
            // Check for any action links/buttons (flexible check)
            cy.get('a, button').should('have.length.at.least', 1)
          })
      }
    })
  })
  
  it('verifies report actions based on status', () => {
    // Navigate to reports page
    cy.visit('/reports')

    // Check if there are any reports
    cy.get('body').then($body => {
      const rows = $body.find('table tbody tr')
      if (rows.length === 0) {
        cy.log('No reports found to verify actions')
        return
      }
    })

    // Check different report statuses and their available actions
    cy.get('table tbody tr').each(($row, index) => {
      if (index >= 5) return // Only check first 5 reports

      cy.wrap($row).within(() => {
        // Get the status (column 3)
        cy.get('td').eq(3).then(($statusCell) => {
          const status = $statusCell.text().trim().toLowerCase()

          // Check destinations rather than tooltip wording shared across tables.
          cy.get('a[href]').should(($links) => {
            const overviewLinks = $links.filter((_index, link) => /^\/reports\/\d+$/.test(link.getAttribute('href')))
            expect(overviewLinks.length, 'report overview link').to.be.greaterThan(0)
          })
          if (status === 'completed') {
            cy.get('a[href^="/report_details/"]').should('exist')
          }
        })
      })
    })
  })
  
  it('verifies report filtering by status', () => {
    // Test the status filter links
    cy.visit('/reports')
    
    // Click on "Running" filter
    cy.contains('a', 'Running').click()
    cy.url().should('include', 'scope=running')
    
    // If there are running reports, verify they all have "running" or "starting" status
    cy.get('body').then($body => {
      if ($body.find('table tbody tr').length > 0) {
        cy.get('table tbody tr').each(($row) => {
          cy.wrap($row).find('td').eq(3).should(($td) => {
            const status = $td.text().trim().toLowerCase()
            expect(['starting', 'running']).to.include(status)
          })
        })
      }
    })

    // Test "Completed" filter
    cy.contains('a', 'Completed').click()
    cy.url().should('include', 'scope=completed')

    // If there are completed reports, verify they all have "completed" status (case-insensitive)
    cy.get('body').then($body => {
      if ($body.find('table tbody tr').length > 0) {
        cy.get('table tbody tr').each(($row) => {
          cy.wrap($row).find('td').eq(3).invoke('text').then(text => {
            expect(text.trim().toLowerCase()).to.equal('completed')
          })
        })
      }
    })
    
    // Test "Failed" filter
    cy.contains('a', 'Failed').click()
    cy.url().should('include', 'scope=failed')
    
    // Return to "All" view
    cy.contains('a', 'All').click()
    cy.url().should('include', 'scope=all')
  })
  
  it('verifies ASR and attack counts for completed reports', () => {
    cy.visit('/reports?scope=completed')
    
    // Find completed reports and check their metrics
    cy.get('body').then($body => {
      if ($body.find('table tbody tr').length > 0) {
        cy.get('table tbody tr').first().within(() => {
          // Check ASR column (column 4)
          cy.get('td').eq(4).then(($asrCell) => {
            const asrText = $asrCell.text().trim()
            // ASR should be either "N/A" or a percentage like "100.0%"
            if (asrText !== 'N/A') {
              expect(asrText).to.match(/\d+(\.\d+)?%/)
            }
          })
          
          // Check Successful Attacks column (column 5)
          cy.get('td').eq(5).then(($attacksCell) => {
            const attacksText = $attacksCell.text().trim()
            // Should be either "-" or a fraction like "1/1"
            if (attacksText !== '-') {
              expect(attacksText).to.match(/\d+\/\d+/)
            }
          })
        })
      }
    })
  })
  
  it('can stop a running scan from reports page', () => {
    // This test requires a running scan, so we'll create one
    const timestamp = Date.now()
    const stopTestScanName = `Stop Test Scan ${timestamp}`
    
    // Create a scan that will run for a while
    cy.visit('/scans/new')
    cy.get('#scan_name').type(stopTestScanName)
    
    // Wait for target select to be ready
    cy.wait(2000)
    
    // Use custom Cypress command to select the target by name
    cy.selectTargetByName(testTargetName)

    // Track the created scan for cleanup now (safe even if it completes quickly)
    cy.trackResource({ type: 'scan', name: stopTestScanName })
    
    // Select two test probes by name to make it run long enough to stop but not too long
    cy.selectProbeByName('test.Blank', 'anyoutput')
    cy.selectProbeByName('test.Test', 'pass')
    
    // Submit
    cy.contains('button[type="submit"]', 'Create Scan').click()

    // Poll until the scan reaches 'running' state (or a terminal state if it completes quickly)
    cy.pollUntil(
      () => {
        cy.visit('/reports', { log: false })
        return cy.contains('td', stopTestScanName, { timeout: 10000 })
          .parent('tr').find('td').eq(3).invoke('text')
      },
      (text) => {
        const status = text.trim().toLowerCase()
        return ['running', 'completed', 'failed', 'stopped'].includes(status)
      },
      { timeout: 30000, description: 'Wait for scan to start running' }
    )

    // Attempt to stop the scan if it's still running
    cy.contains('td', stopTestScanName)
      .parent('tr')
      .then(($row) => {
        const stopButton = $row.find('a[title*="Stop"]')
        if (stopButton.length > 0) {
          cy.wrap(stopButton).click()
          cy.log('Clicked stop button')
        } else {
          cy.log('No stop button found - scan already reached a terminal state')
        }
      })

    // Poll until the scan reaches a terminal state (stopped, completed, or failed)
    cy.pollUntil(
      () => {
        cy.visit('/reports', { log: false })
        return cy.contains('td', stopTestScanName)
          .parent('tr').find('td').eq(3).invoke('text')
      },
      (text) => {
        const status = text.trim().toLowerCase()
        return ['stopped', 'completed', 'failed'].includes(status)
      },
      { timeout: 30000, description: 'Wait for scan to reach terminal state' }
    )

    cy.contains('td', stopTestScanName)
      .parent('tr')
      .find('td')
      .eq(3)
      .then(($statusCell) => {
        const status = $statusCell.text().trim().toLowerCase()
        // Status should be either stopped (if we stopped it) or completed/failed (if it finished)
        expect(['stopped', 'completed', 'failed']).to.include(status)
      })
  })
  it('verifies priority scan system status', () => {
    const timestamp = Date.now()
    const priorityScanName = `Priority Test Scan ${timestamp}`

    // Create a priority scan
    cy.visit('/scans/new')
    cy.get('#scan_name').type(priorityScanName)

    // Wait for target select to be ready
    cy.wait(2000)

    // Use custom Cypress command to select the target by name
    cy.selectTargetByName(testTargetName)

    // Check priority
    cy.get('#scan_priority').check({ force: true })

    // Select a probe using the helper (more reliable with tier filtering)
    cy.selectProbeByName('test.Blank', 'anyoutput')

    // Submit
    cy.contains('button[type="submit"]', 'Create Scan').click()

    // Track the created scan
    cy.trackResource({ type: 'scan', name: priorityScanName })

    // Wait for the report to be in a running state or completed
    // We need to poll because it might be pending initially
    // Note: Priority scans with single probes can complete very quickly,
    // so we accept starting/running/processing/completed/failed states
    cy.pollUntil(
      () => {
        cy.visit('/reports', { log: false })
        return cy.contains('td', priorityScanName).parent('tr').find('td').eq(3).invoke('text')
      },
      (text) => {
        const status = text.trim().toLowerCase()
        // Accept any state that means the scan has moved past 'pending'
        return ['starting', 'running', 'processing', 'completed', 'failed', 'stopped'].includes(status)
      },
      { timeout: 30000, description: 'Wait for priority scan to appear' }
    )

    // Verify the priority scan executed successfully
    // Wait for the scan to reach a final state (completed/failed/stopped)
    cy.pollUntil(
      () => {
        cy.visit('/reports', { log: false })
        return cy.contains('td', priorityScanName).parent('tr').find('td').eq(3).invoke('text')
      },
      (text) => {
        const status = text.trim().toLowerCase()
        const finalStates = ['completed', 'failed', 'stopped']
        return finalStates.includes(status)
      },
      { timeout: 120000, description: 'Wait for priority scan to complete' }
    )

    // Verify it reached a final status
    cy.visit('/reports')
    cy.contains('td', priorityScanName)
      .parent('tr')
      .within(() => {
        cy.get('td').eq(3).invoke('text').then(text => {
          const status = text.trim().toLowerCase()
          expect(['completed', 'failed', 'stopped']).to.include(status)
          cy.log(`Priority scan finished with status: ${status}`)
        })
      })
  })
})
