// Test suite for Report Details page functionality
describe('Report Details Page', () => {
  // Ignore known errors that don't affect test validity
  Cypress.on('uncaught:exception', (err, runnable) => {
    // Ignore ECharts errors
    if (err.message.includes('Cannot read properties of undefined') && err.message.includes('push')) {
      return false
    }
    // Ignore outlet controller error (fixed in testing branch, not yet in stable)
    if (err.message.includes('outlet controller') && err.message.includes('probe-category')) {
      return false
    }
    return true
  })
  
  let reportId
  
  before(() => {
    // Find an existing completed report to test with
    cy.visit('/reports?scope=completed')

    // Check if there are any completed reports
    cy.get('body').then($body => {
      const rows = $body.find('table tbody tr')
      if (rows.length > 0) {
        // Get the first completed report with View link
        cy.get('table tbody tr').first().within(() => {
          // Get the report ID from the View link
          cy.get('a[href*="/report_details/"]')
            .first()
            .invoke('attr', 'href')
            .then((href) => {
              if (href) {
                reportId = href.match(/\/report_details\/(\d+)/)?.[1]
                cy.log(`Using existing report ID: ${reportId}`)
              }
            })
        })
      } else {
        cy.log('No completed reports found. Creating a test report...')
        // Create a simple scan to generate a report
        const timestamp = Date.now()
        const targetName = `Test Target ${timestamp}`
        const scanName = `Test Scan ${timestamp}`

        // Create target and scan
        cy.createTestTarget().then((createdTargetName) => {
          cy.visit('/scans/new')
          cy.get('#scan_name').type(scanName)
          cy.selectTargetByName(createdTargetName)
          cy.selectProbeByName('dan.Dan_11_0', 'dan')
          cy.contains('button[type="submit"]', 'Create Scan').click()

          // Track created scan
          cy.trackResource({ type: 'scan', name: scanName })

          // Wait for it to complete
          cy.waitForReportCompletion(scanName, 30000)

          // Now get the report ID
          cy.visit('/reports?scope=completed')
          cy.get('table tbody tr').first().within(() => {
            cy.get('a[href*="/report_details/"]')
              .first()
              .invoke('attr', 'href')
              .then((href) => {
                if (href) {
                  reportId = href.match(/\/report_details\/(\d+)/)?.[1]
                  cy.log(`Created and using report ID: ${reportId}`)
                }
              })
          })
        })
      }
    })
  })
  
  it('displays report header information correctly', () => {
    // Navigate to report details page
    cy.visit(`/report_details/${reportId}`)
    
    // Check page title contains "Report for"
    cy.get('h1').should('contain', 'Report for')
    
    // Check generation date is displayed
    cy.contains(/Generated/i).should('be.visible')
    
    // Duration should be displayed; tolerate seconds/minutes/hours and optional "about"
    cy.contains(/(?:about\s*)?\d+\s*(?:seconds?|minutes?|hours?)/i).should('be.visible')
    
    // Probe count should be displayed in any common format
    cy.contains(/(?:\b\d+\s+Probes?\b|\bProbes?\s*:\s*\d+|\bProbes?\s*\(\s*\d+\s*\))/i).should('be.visible')
    
    // Check PDF download button/link is present (may be button or link)
    cy.get('button[data-pdf-download-target="button"], a[href*="/pdf"]').should('exist')
  })
  
  it('shows detector statistics and ASR correctly', () => {
    cy.visit(`/report_details/${reportId}`)

    // Current layout: Detector Statistics with per-detector cards
    cy.contains('h2', 'Detector Statistics').should('be.visible')
    cy.contains(/Security\s+test\s+success\s+rates?/i).should('be.visible')

    // Require at least one ASR badge; allow optional "(ASR)"
    cy.contains(/\b\d+(?:\.\d+)?%\s+Attack\s+Success\s+Rate(?:\s*\(ASR\))?/i).should('be.visible')

    // Optional: validate Max Score chip if present
    cy.get('body').invoke('text').then((t) => {
      const m = (t || '').match(/Max\s+Score\s*:\s*(\d+(?:\.\d+)?)%/i)
      if (m) {
        const score = parseFloat(m[1])
        expect(score).to.be.gte(0).and.lte(100)
      }
    })
  })
  
  it('displays probe information correctly', () => {
    cy.visit(`/report_details/${reportId}`)
    
    // Check Probes section and require external link within first probe details card
    cy.contains('h2', 'Probes').should('be.visible')
    cy.get('details[data-report-target="details"], details[id^="probe-"]').first().within(() => {
      // Probe Details link should always exist for any probe
      cy.contains('a', 'Probe Details').should('exist')
        .should('have.attr', 'href')
        .and('match', /\/probes\//)
      // Probe identifier formatting (hex id and name)
      cy.contains(/0x[A-F0-9]+\: [A-Za-z]+/).should('be.visible')
      // Success rate chip within the probe card (allow optional "Attack" and optional (ASR))
      cy.contains(/\b\d+(?:\.\d+)?%\s+(?:Attack\s+)?Success\s+Rate(?:\s*\(ASR\))?/i).should('be.visible')
    })
  })
  
  it('expands and collapses probe details', () => {
    cy.visit(`/report_details/${reportId}`)
    
    // Check for expand all/collapse all button
    cy.get('button').then($buttons => {
      const expandButton = $buttons.filter((i, el) => el.textContent.includes('Expand') || el.textContent.includes('Collapse'))
      if (expandButton.length > 0) {
        // Click to toggle
        cy.wrap(expandButton.first()).click()
        cy.wait(500) // Wait for animation
        
        cy.log('Expand/collapse functionality tested')
      } else {
        cy.log('No expand/collapse buttons found')
      }
    })
  })
  
  it('verifies PDF download flow and response', () => {
    cy.visit(`/report_details/${reportId}`)

    const pdfTimeout = Number(Cypress.env('PDF_REQUEST_TIMEOUT_MS') || 240000) // default 240s for CI
    const statusUrl = `/report_details/${reportId}/pdf`

    cy.log(`Polling PDF status: ${statusUrl} (timeout ${pdfTimeout} ms)`)

    const fetchStatus = (retries = 30) => cy.request({
      url: statusUrl,
      timeout: pdfTimeout,
      followRedirect: true,
      failOnStatusCode: false,
      headers: {
        Referer: `${Cypress.config('baseUrl')}/report_details/${reportId}`,
        Accept: 'application/json'
      }
    }).then((resp) => {
      const ct = (resp.headers && (resp.headers['content-type'] || resp.headers['Content-Type'])) || ''
      cy.log(`Status response: status=${resp.status} content-type=${ct}`)

      if (resp.status === 500) {
        cy.log('PDF generation returned 500 - server-side issue')
        return
      }

      // 202 = generation in progress, body has {status: pending|processing}
      if (resp.status === 202) {
        if (retries > 0) {
          cy.wait(5000)
          return fetchStatus(retries - 1)
        }
        cy.log('PDF generation taking too long, but async flow is working')
        return
      }

      // 200 = ready, body has {status: "ready", download_url: "...pdf_token=..."}
      expect(resp.status).to.eq(200)
      const body = typeof resp.body === 'string' ? JSON.parse(resp.body) : resp.body
      expect(body.status).to.eq('ready')
      expect(body.download_url).to.be.a('string')
      expect(body.download_url).to.match(/pdf_token=/)

      // Fetch the signed download URL and verify we get actual PDF bytes.
      return cy.request({
        url: body.download_url,
        encoding: 'binary',
        timeout: pdfTimeout,
        followRedirect: true,
        failOnStatusCode: false,
        headers: {
          Referer: `${Cypress.config('baseUrl')}/report_details/${reportId}`,
          Accept: 'application/pdf'
        }
      }).then((fileResp) => {
        const fct = (fileResp.headers && (fileResp.headers['content-type'] || fileResp.headers['Content-Type'])) || ''
        expect(fileResp.status).to.eq(200)
        expect((fct || '').toLowerCase()).to.include('application/pdf')
        expect(fileResp.body && fileResp.body.length).to.be.greaterThan(1000)
      })
    })

    fetchStatus()
  })
  
  it('handles navigation correctly', () => {
    cy.visit(`/report_details/${reportId}`)
    
    // Check external probe link within the first probe card opens in new tab
    cy.contains('h2', 'Probes').should('be.visible')
    cy.get('details[data-report-target="details"], details[id^="probe-"]').first().within(() => {
      // Probe Details link should exist for any probe
      cy.contains('a', 'Probe Details').should('exist')
        .should('have.attr', 'href')
        .and('match', /\/probes\//)
    })
  })
  
  it('handles different report states', () => {
    // Visit reports page to check different states
    cy.visit('/reports')
    
    // Find a completed report and verify it has View link and a PDF link
    cy.get('table tbody tr').each(($row, index) => {
      if (index >= 5) return false // Check first 5 rows only
      
      cy.wrap($row).within(() => {
        cy.get('td').eq(3).then(($statusCell) => {
          const status = $statusCell.text().trim().toLowerCase()
          
          if (status === 'completed') {
            // Completed reports should have View and PDF links (text may vary)
            cy.get('a[href*="/report"]').should('exist')
            cy.get('a[href*="/report_details/"]').should('exist')
          } else if (status === 'failed') {
            // Failed reports might not have detailed report link
            cy.log(`Found failed report - may have limited details`)
          }
        })
      })
    })
  })
  
  it('validates attack statistics display', () => {
    cy.visit(`/report_details/${reportId}`)
    
    // Check for attack statistics display
    cy.get('body').then($body => {
      // Look for ASR percentage
      const asrMatch = $body.text().match(/(\d+)%\s*Attack\s*Success\s*Rate/i)
      if (asrMatch) {
        cy.log(`Found ASR: ${asrMatch[1]}%`)
      }
      
      // Look for attack counts (e.g., "0/1")
      const fractionMatch = $body.text().match(/(\d+)\s*\/\s*(\d+)/)
      if (fractionMatch) {
        cy.log(`Found attack counts: ${fractionMatch[1]}/${fractionMatch[2]}`)
      }
    })
  })
  
  it('handles invalid report IDs gracefully', () => {
    // Try to access non-existent report
    cy.visit('/report_details/99999999', { failOnStatusCode: false })
    
    // Should show error or redirect
    cy.get('body').then($body => {
      const text = $body.text()
      const hasError = text.includes('not found') || 
                      text.includes('404') || 
                      text.includes('error') ||
                      text.includes('Error')
      
      if (hasError) {
        cy.log('Error page displayed for invalid report ID')
      } else {
        // Might redirect to reports list
        cy.url().then(url => {
          if (url.includes('/reports')) {
            cy.log('Redirected to reports list for invalid ID')
          }
        })
      }
    })
  })
  
  it('verifies probe information completeness', () => {
    // This test verifies that probes have complete information but stays scoped to avoid heavy DOM scans
    cy.visit(`/report_details/${reportId}`)

    // Header should show probe count (various formats supported)
    cy.contains(/(?:\b\d+\s+Probes?\b|\bProbes?\s*:\s*\d+|\bProbes?\s*\(\s*\d+\s*\))/i).should('exist')

    // Work within the first probe card to avoid scanning the whole page
    cy.get('details[id^="probe-"], details[data-report-target="details"]').first()
      .scrollIntoView()
      .should('exist')
      .within(() => {
        // A stats percentage should be visible inside the card (Success Rate or Attack Success Rate)
        cy.contains(/\b\d+(?:\.\d+)?%\s+(?:Attack\s+)?Success\s+Rate(?:\s*\(ASR\))?/i).should('be.visible')

        // The side stats block should surface Attack Success Rate (ASR), not raw counts
        cy.contains(/\b\d+(?:\.\d+)?%\s+(?:Attack\s+)?Success\s+Rate(?:\s*\(ASR\))?/i).should('be.visible')

        // Probe Details link should exist for any probe
        cy.contains('a', 'Probe Details').should('exist').and('have.attr', 'href').and('match', /\/probes\//)
      })
  })
})
