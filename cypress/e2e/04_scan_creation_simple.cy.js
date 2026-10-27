describe('Simple Scan Creation', () => {
  it('creates a scan with minimal configuration', () => {
    const scanName = `Scan ${Date.now()}`

    cy.createTestTarget().then((targetName) => {
      cy.visit('/scans/new')
      cy.get('#scan_name').should('be.visible').type(scanName)
      cy.selectTargetByName(targetName)
      cy.selectProbeByName('test.Blank', 'anyoutput')
      cy.contains('button[type="submit"]', 'Create Scan').click()

      cy.location('pathname').should('match', /^\/scans\/\d+$/)
      cy.contains(scanName).should('be.visible')
      cy.trackResource({ type: 'scan', name: scanName })
      cy.verifyReportCreated(scanName, targetName)
    })
  })
})
