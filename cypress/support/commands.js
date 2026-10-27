// Constants for timeouts
const TIMEOUTS = {
  TABLE_LOAD: 10000,
  REPORT_FIND: 15000,
  BODY_CHECK: 5000
};

// Helper: Extract CSRF token from HTML
function extractCsrfToken(html) {
  const patterns = [
    /name=["']authenticity_token["']\s+value=["']([^"']+)["']/i,
    /value=["']([^"']+)["']\s+[^>]*name=["']authenticity_token["']/i,
    /<meta\s+name=["']csrf-token["']\s+content=["']([^"']+)["']/i
  ];
  for (const pattern of patterns) {
    const match = html.match(pattern);
    if (match?.[1]) return match[1];
  }
  return null;
}

// Helper: Get OAuth credentials with fallbacks
function getOAuthCredentials(email, password) {
  return cy.env(['OAUTH_EMAIL', 'OAUTH_PASSWORD', 'ADMIN_EMAIL', 'ADMIN_PASSWORD']).then((env) => ({
    email: email || env.OAUTH_EMAIL || env.ADMIN_EMAIL,
    password: password || env.OAUTH_PASSWORD || env.ADMIN_PASSWORD
  }));
}

// Resolve credentials inside the command queue before running a login command.
function withOAuthCredentials(callback) {
  return (email, password, ...args) => getOAuthCredentials(email, password)
    .then((credentials) => callback(credentials, ...args));
}

/**
 * Polls a function until a predicate returns true or timeout is reached.
 * @param {function} fn - Function returning a Cypress chainable that resolves to a value.
 * @param {function} predicate - Function that receives the value and returns true if done.
 * @param {object} options - { interval, timeout, description }
 * @returns {Cypress.Chainable<any>} The value for which predicate returned true.
 */
Cypress.Commands.add('pollUntil', (fn, predicate, options = {}) => {
  const {
    interval = 2000,
    timeout = 30000,
    description = 'polling',
    heartbeatEvery = 5, // log every N attempts to prevent CI idle timeouts
  } = options;
  const maxAttempts = Math.ceil(Math.max(1, timeout) / Math.max(1, interval));

  function attempt(attempts = 0) {
    if (attempts >= maxAttempts) {
      throw new Error(`${description} did not complete within ${timeout}ms`);
    }
    return fn().then((result) => {
      if (predicate(result)) {
        return cy.wrap(result);
      } else {
        // Emit a heartbeat log periodically so GitHub Actions doesn't cancel for inactivity
        if (heartbeatEvery > 0 && (attempts % heartbeatEvery) === 0) {
          const remaining = Math.max(0, maxAttempts - attempts - 1);
          cy.log(`${description}: attempt ${attempts + 1}/${maxAttempts} (${remaining} remaining)`);
        }
        // Keep individual waits quiet; the heartbeat above provides periodic output
        cy.wait(interval, { log: false });
        return attempt(attempts + 1);
      }
    });
  }
  return attempt();
});

/**
 * Waits for target validation to complete
 * @param {number} maxAttempts - Maximum number of polling attempts (default: 10)
 * @returns {Cypress.Chainable<string>} The validation status
 */
Cypress.Commands.add('waitForTargetValidation', (maxAttempts = 30) => {
  // Try to wait for validation to complete, but don't block on it
  // Some test environments may not have async job processing enabled
  //
  // The target show page renders status as static server-side HTML — there are
  // no live updates. We must reload on each attempt to get a fresh status.

  const attemptValidation = (attempt = 0) => {
    if (attempt >= maxAttempts) {
      cy.log(`Target validation still pending after ${maxAttempts} attempts, continuing anyway`);
      return cy.wrap(true);
    }

    // Reload to fetch current server-rendered status
    cy.reload({ log: false });

    return cy.get('body').then($body => {
      const statusTag = $body.find('.status_tag');
      if (statusTag.length === 0) {
        cy.log('No validation status tag found, continuing with tests');
        return cy.wrap(true);
      }

      const status = statusTag.first().text().toLowerCase();

      if (status.includes('good') || status.includes('bad')) {
        cy.log(`Target validation complete - status: ${status}`);
        return cy.wrap(true);
      }

      if (status.includes('validating')) {
        cy.log(`Validation in progress (attempt ${attempt + 1}/${maxAttempts})...`);
        return cy.wait(2000).then(() => attemptValidation(attempt + 1));
      }

      cy.log(`Unknown validation status: ${status}, continuing`);
      return cy.wrap(true);
    });
  };

  return attemptValidation(0);
});

/**
 * Login via OAuth provider using API requests (recommended approach).
 * Bypasses the OAuth UI and uses direct API calls to get authentication.
 * @param {string} email - OAuth provider email
 * @param {string} password - OAuth provider password
 * @returns {Cypress.Chainable}
 */
Cypress.Commands.add('oauthLogin', withOAuthCredentials(({ email: oauthEmail, password: oauthPassword }) => {
  const oauthProviderUrl = Cypress.expose('OAUTH_PROVIDER_URL');

  if (!oauthEmail || !oauthPassword) {
    throw new Error('oauthLogin: missing credentials');
  }

  if (!oauthProviderUrl) {
    throw new Error('oauthLogin: missing OAUTH_PROVIDER_URL');
  }

  cy.log('Starting OAuth login - API approach');

  // Get the CSRF token from the login page first
  cy.request({
    method: 'GET',
    url: '/login',
    failOnStatusCode: false
  }).then((loginPage) => {
    const csrfToken = extractCsrfToken(loginPage.body);

    if (!csrfToken) {
      throw new Error('Could not find CSRF token on Scanner login page');
    }

    cy.log('Found Scanner CSRF token, initiating OAuth flow');

    // POST to the OAuth provider endpoint with CSRF token
    const oauthProvider = Cypress.expose('OAUTH_PROVIDER') || 'oauth';
    cy.request({
      method: 'POST',
      url: `/auth/${oauthProvider}`,
      headers: {
        'X-CSRF-Token': csrfToken
      },
      followRedirect: true,  // Let it follow to get to the OAuth authorize endpoint
      failOnStatusCode: false
    }).then((resp) => {
      cy.log(`Response status: ${resp.status}`);
      cy.log(`Final URL after redirects: ${resp.url || 'unknown'}`);
      cy.log(`Response body type: ${typeof resp.body}`);

      // Check if we got an error response
      if (resp.status >= 400) {
        cy.writeFile('cypress/oauth-error-response.html', resp.body);
        throw new Error(`OAuth request failed with status ${resp.status}`);
      }

      // The response should now be the OAuth provider's login page
      const html = typeof resp.body === 'string' ? resp.body : JSON.stringify(resp.body);

      // Write HTML to file for debugging
      cy.writeFile('cypress/oauth-response.html', html);
      cy.log('Wrote response HTML to cypress/oauth-response.html');

      // Extract CSRF token from OAuth provider page
      const token = extractCsrfToken(html);

      if (!token) {
        cy.task('console:log', '=== FULL HTML ===');
        cy.task('console:log', html);
        throw new Error('Could not find CSRF token on OAuth login page');
      }

      cy.log('Found CSRF token: ' + token.substring(0, 20) + '...');

      cy.log('Submitting credentials to OAuth provider');

      // Submit credentials to OAuth provider
      cy.request({
        method: 'POST',
        url: `${oauthProviderUrl}/users/sign_in`,
        form: true,
        body: {
          'authenticity_token': token,
          'user[email]': oauthEmail,
          'user[password]': oauthPassword,
          'user[remember_me]': '0',
          'g-recaptcha-response-data[registration]': '',  // Empty reCAPTCHA token (should bypass for whitelisted email)
          'commit': 'Sign in'
        },
        followRedirect: true,  // Follow all the way back to scanner
        failOnStatusCode: false
      }).then((loginResp) => {
        cy.log(`After OAuth login, status: ${loginResp.status}`);
        cy.log(`Final URL: ${loginResp.url || 'unknown'}`);

        // Visit the home page to establish the authenticated session
        cy.visit('/');
      });
    });
  });

  // Verify we're logged in
  cy.location('pathname', { timeout: 15000 }).should('not.match', /(login|sign_in)$/);
  cy.log('OAuth login via API complete');
}));

/**
 * Programmatic login via API using Rails /login flow.
 * Thin wrapper over adminApiLogin.
 * Options: { email, password }
 */
Cypress.Commands.add('apiLogin', (options = {}) => {
  return cy.env(['ADMIN_EMAIL', 'ADMIN_PASSWORD']).then((env) => {
    return cy.adminApiLogin(options.email || env.ADMIN_EMAIL, options.password || env.ADMIN_PASSWORD);
  });
});

/**
 * Programmatic login for Rails admin.
 * Detects OAuth mode and delegates to oauthLogin, otherwise does traditional login.
 */
Cypress.Commands.add('adminApiLogin', withOAuthCredentials(({ email, password }) => {
  if (!email || !password) {
    throw new Error('adminApiLogin: missing credentials');
  }

  const LOGIN_PATH = '/login';

  const doUiLogin = () => {
    cy.visit(LOGIN_PATH);
    cy.location('pathname', { timeout: 5000 }).then((pathname) => {
      if (!pathname.includes('login') && !pathname.includes('sign_in')) {
        cy.log('Already logged in');
        return;
      }

      cy.get('body').then(($body) => {
        const hasLoginForm = $body.find('input[type="email"], input[name="user[email]"]').length > 0;
        if (!hasLoginForm) {
          cy.log('No login form found, possibly already authenticated');
          return;
        }

        // Fill and submit login form
        cy.get('input[type="email"], input[name="user[email]"]').first().clear().type(email, { log: false, parseSpecialCharSequences: false });
        cy.get('input[type="password"], input[name="user[password]"]').first().clear().type(password, { log: false, parseSpecialCharSequences: false });
        cy.get('input[type="submit"], button[type="submit"]').first().click();
      });
    });
  };

  return cy.request({ method: 'GET', url: LOGIN_PATH, failOnStatusCode: false }).then((resp) => {
    // If we get redirected away from login (e.g., already authenticated), skip login
    if (resp.status === 302 || resp.status === 303) {
      const location = resp.headers.location || resp.redirectedToUrl;
      if (location && !location.includes('login') && !location.includes('sign_in')) {
        cy.log('Already authenticated, redirected from /login');
        cy.visit('/');
        return;
      }
    }

    const html = resp.body || '';

    // Check if OAuth mode is enabled (any "Sign in with ..." button)
    if (/Sign in with \w+/i.test(html)) {
      cy.log('OAuth mode detected, using OAuth API login');
      return cy.oauthLogin(email, password);
    }

    // Traditional login
    const token = extractCsrfToken(html);
    if (!token) {
      cy.log('No CSRF token found, using UI login');
      return doUiLogin();
    }

    cy.request({
      method: 'POST',
      url: LOGIN_PATH,
      form: true,
      body: {
        'authenticity_token': token,
        'user[email]': email,
        'user[password]': password,
        'user[remember_me]': '0',
        'commit': 'Sign In'
      },
      headers: { 'X-CSRF-Token': token },
      failOnStatusCode: false
    }).then((post) => {
      if (![200, 201, 204, 302, 303].includes(post.status)) {
        cy.log(`API login failed (${post.status}), using UI login`);
        return doUiLogin();
      }
      cy.visit('/');
      cy.location('pathname').should('not.match', /(login|sign_in)$/);
      cy.get('body').should('not.contain', 'Invalid Email or password');
    });
  });
}));

/**
 * Cache and restore an authenticated session using cy.session().
 * Defaults to caching across specs within a single run.
 * Automatically handles both OAuth and traditional login flows.
 * @param {string} email
 * @param {string} password
 * @param {{ cacheAcrossSpecs?: boolean, validate?: Function }} options
 */
Cypress.Commands.add('loginSession', withOAuthCredentials(({ email, password }, options = {}) => {
  if (!email || !password) {
    throw new Error('loginSession: missing credentials');
  }

  const id = ['admin', email]
  const cacheAcrossSpecs = options.cacheAcrossSpecs !== false
  const validateFn = options.validate || (() => {
    // Visit a protected page and ensure we are not redirected to login
    cy.visit('/', { failOnStatusCode: false })
    cy.location('pathname').should('not.match', /(login|sign_in)$/)
  })

  cy.session(
    id,
    () => {
      // Reuse robust API-first login with OAuth detection and UI fallback
      cy.adminApiLogin(email, password)
    },
    { validate: validateFn, cacheAcrossSpecs }
  )
}))


/**
 * Clears and types text into a form field
 * @param {string} selector - CSS selector for the input field
 * @param {string} text - Text to type into the field
 */
Cypress.Commands.add('clearAndType', (selector, text) => {
  cy.get(selector).clear().type(text)
})

/**
 * Selects a target by name from the Choices.js dropdown or regular select
 * Handles both the enhanced Choices.js dropdown and fallback to regular select
 * @param {string} targetName - Name of the target to select
 */
Cypress.Commands.add('selectTargetByName', (targetName) => {
  // Wait for the select element to exist and have options
  cy.get('[data-scan-form-target="targetsSelect"]', { timeout: 10000 }).should('exist')

  // Wait for options to load
  cy.get('[data-scan-form-target="targetsSelect"] option', { timeout: 5000 })
    .should('have.length.greaterThan', 0)

  // Check if Choices.js is wrapping the select
  cy.get('body').then(($body) => {
    const hasChoices = $body.find('.choices[data-type="select-multiple"]').length > 0

    if (hasChoices) {
      // Choices.js is present - click to open dropdown and select item
      cy.get('.choices__inner').first().click()

      // Wait for dropdown to be visible
      cy.get('.choices__list--dropdown', { timeout: 5000 }).should('be.visible')

      // Find the matching item and click it using the page's window for MouseEvent
      cy.window().then(win => {
        const items = win.document.querySelectorAll('.choices__list--dropdown .choices__item--selectable')
        let found = false
        for (const item of items) {
          if (item.textContent.trim().includes(targetName)) {
            item.dispatchEvent(new win.MouseEvent('mousedown', {
              bubbles: true,
              cancelable: true,
              view: win
            }))
            found = true
            break
          }
        }
        if (!found) {
          throw new Error(`Target "${targetName}" not found in Choices.js dropdown. Available: ${Array.from(items).map(i => i.textContent.trim()).join(', ')}`)
        }
      })

      // Wait for selection to process
      cy.wait(300)

      // Verify selection worked by checking native select has value
      cy.get('[data-scan-form-target="targetsSelect"]').then($select => {
        const selectedOptions = Array.from($select[0].selectedOptions)
        const selectedTexts = selectedOptions.map(opt => opt.text)
        expect(selectedTexts.some(t => t.includes(targetName))).to.be.true
      })
    } else {
      // Regular select - use standard select method
      cy.get('[data-scan-form-target="targetsSelect"]')
        .select(targetName, { force: true })
        .then(($select) => {
          // Verify the selection was successful
          const targetOption = $select.find(`option:contains("${targetName}")`)
          if (targetOption.length > 0) {
            const expectedValue = targetOption.val()
            const actualValue = $select.val()

            // Handle both single and multi-select cases
            if (Array.isArray(actualValue)) {
              expect(actualValue).to.include(expectedValue)
            } else {
              expect(actualValue).to.equal(expectedValue)
            }
          } else {
            cy.log(`Warning: Could not find option containing "${targetName}" to verify selection`)
          }
        })
    }
  })
})

/**
 * Waits for the page to fully load by checking for body and main content
 */
Cypress.Commands.add('waitForPageLoad', () => {
  cy.get('body').should('be.visible')
  cy.get('#main-content', { timeout: 10000 }).should('exist') // Use a stable, application-specific selector
})

/**
 * Returns a RestGenerator JSON configuration for testing
 * @param {string} name - Optional name for the service
 * @returns {object} JSON configuration object for RestGenerator targets
 */
Cypress.Commands.add('getRestGeneratorConfig', (name = 'test service') => {
  const port = Cypress.expose('MOCK_LLM_PORT') || 9292;
  const host = Cypress.expose('MOCK_LLM_HOST') || 'mock-llm';
  return {
    rest: {
      RestGenerator: {
        name: name,
        uri: `http://${host}:${port}/api/v1/mock_llm/chat`,
        method: "post",
        req_template_json_object: { text: "$INPUT" },
        response_json: true,
        response_json_field: "text"
      }
    }
  }
});

/**
 * Creates a test target for use in other tests
 * @returns {Cypress.Chainable<string>} The name of the created target
 */
Cypress.Commands.add('waitForStimulusController', (identifier) => {
  return cy.window().should((win) => {
    const element = win.document.querySelector(`[data-controller~="${identifier}"]`)
    const controller = element && win.Stimulus?.getControllerForElementAndIdentifier(element, identifier)
    expect(controller, `${identifier} controller is connected`).to.exist
  })
})

Cypress.Commands.add('selectCustomTargetProvider', () => {
  cy.waitForStimulusController('target-wizard')
  cy.get('[data-provider="custom"]').click()
  cy.get('#target_name').should('be.visible')
})

Cypress.Commands.add('createTestTarget', () => {
  const timestamp = Date.now()
  const targetName = `Test Target ${timestamp}`

  // Navigate to new target page (Step 1: Choose Provider)
  cy.visit('/targets/new')

  // Step 1: Select Custom Configuration provider
  cy.selectCustomTargetProvider()

  // Step 2: Fill in target details (now visible after provider selection)
  cy.get('#target_name').should('be.visible').type(targetName)
  cy.get('[data-target-wizard-target="modelTypeSelect"]').select('REST API (Generic)')
  cy.get('#target_model').type('test-model-v1')

  // Add JSON configuration using internal mock endpoint
  cy.getRestGeneratorConfig().then(config => {
    cy.get('#target_json_config').type(JSON.stringify(config, null, 2), { parseSpecialCharSequences: false })
  })

  // Step 2 → Step 3: Click Next: Review
  cy.contains('button', 'Next: Review').click()

  // Step 3: Submit the form
  cy.contains('button[type="submit"]', 'Create Target').click()

  // Verify successful creation and wait for validation
  cy.location('pathname').should('match', /^\/targets\/\d+$/)
  cy.contains(targetName).should('be.visible')

  // Track the created target
  cy.trackResource({ type: 'target', name: targetName })

  // Wait for validation to complete with increased timeout (30 attempts = 15 seconds)
  cy.waitForTargetValidation(30)

  // Return the target name for use in tests
  return cy.wrap(targetName)
})

/**
 * Verifies that a report was created for a specific scan
 * @param {string} scanName - Name of the scan to verify
 * @param {string} targetName - Optional target name to verify
 * @param {object} options - Optional: { waitForCompletion: boolean, expectSuccess: boolean, timeout: number }
 * @returns {Cypress.Chainable<string>} The scan name for chaining
 */
Cypress.Commands.add('verifyReportCreated', (scanName, targetName = undefined, options = {}) => {
  const { waitForCompletion = false, expectSuccess = false, timeout = 60000 } = options;
  // Navigate to reports page
  cy.visit('/reports')
  
  // Wait for reports table to load
  cy.get('table', { timeout: TIMEOUTS.TABLE_LOAD }).should('be.visible')
  
  // Find the report row by scan name
  cy.contains('td', scanName, { timeout: TIMEOUTS.REPORT_FIND }).should('exist')
  
  // Track this report by its scanName for later deletion
  cy.trackResource({ type: 'report', scanName: scanName })

  // Verify report details in the same row
  cy.contains('td', scanName)
    .parent('tr')
    .within(() => {
      // Check that target name is present (case-insensitive)
      if (targetName) {
        cy.contains(targetName, { matchCase: false }).should('exist')
      }
      
      // Check status column - should be one of the valid statuses (column index 3)
      cy.get('td').eq(3).then(($td) => {
        const status = $td.text().trim()
        if (status) {
          cy.validateReportStatus(status)
        }
      })
      
      // Store the status for logging
      cy.get('td').eq(3).then(($td) => {
        const status = $td.text().trim()
        cy.log(`Report status: ${status}`)
      })
      
      // Check for action links based on status - running reports have Stop, completed have View
      cy.get('td').eq(3).then(($statusTd) => {
        const status = $statusTd.text().trim().toLowerCase()
        // Running reports might only have Stop button, completed have View Overview
        if (status === 'completed') {
          cy.get('a').should('have.length.at.least', 1)
        } else {
          // For non-completed, just verify row exists (actions vary by status)
          cy.log(`Report status is ${status} - action links vary by status`)
        }
      })
    })
  
  // If requested, wait for report to complete and verify success
  if (waitForCompletion) {
    cy.waitForReportCompletion(scanName, timeout).then(finalStatus => {
      if (expectSuccess && finalStatus !== 'completed') {
        throw new Error(`Report for scan "${scanName}" expected to complete successfully but got status: ${finalStatus}`)
      }
      cy.log(`Report final status: ${finalStatus}`)
    })
  }
  
  // Return the scan name for chaining
  return cy.wrap(scanName)
})

/**
 * Validates report status is one of the expected values
 * @param {string} status - The status to validate
 * @param {Array<string>} validStatuses - Array of valid status values (optional)
 * @returns {boolean} True if status is valid
 */
Cypress.Commands.add('validateReportStatus', (status, validStatuses = null) => {
  const defaultStatuses = ['pending', 'starting', 'running', 'completed', 'failed', 'stopped']
  const allowedStatuses = validStatuses || defaultStatuses
  const normalizedStatus = status.trim().toLowerCase()

  if (normalizedStatus && !allowedStatuses.includes(normalizedStatus)) {
    throw new Error(`Invalid status: ${status}. Expected one of: ${allowedStatuses.join(', ')}`)
  }

  return cy.wrap(normalizedStatus)
})

/**
 * Waits for a report to reach completed or failed status
 * @param {string} scanName - Name of the scan to monitor
 * @param {number} timeout - Maximum time to wait in milliseconds (default: 30000)
 * @returns {Cypress.Chainable<string>} The final status of the report
 */
Cypress.Commands.add('waitForReportCompletion', (scanName, timeout = 30000) => {
  const checkInterval = 3000; // Increased interval to reduce server load
  return cy.pollUntil(
    () => {
      // Navigate to reports page to check status
      cy.visit('/reports', { log: false });
      return cy.get('body', { timeout: TIMEOUTS.BODY_CHECK }).then($body => {
        // Check if table exists
        const table = $body.find('table');
        if (table.length === 0) {
          cy.log('No reports table found yet');
          return { found: false, status: null };
        }

        const scanRow = $body.find(`td:contains("${scanName}")`).parent('tr');
        if (scanRow.length > 0) {
          const statusCell = scanRow.find('td').eq(3);
          const status = statusCell.text().trim().toLowerCase();
          return { found: true, status };
        } else {
          return { found: false, status: null };
        }
      });
    },
    (result) => {
      if (!result.found) {
        cy.log('Report not found, checking again...');
        return false;
      }
      const status = result.status;
      if (status === 'completed' || status === 'failed') {
        cy.log(`Report ${status}`);
        return true;
      }
      cy.log(`Report status: ${status}, checking again...`);
      return false;
    },
    { interval: checkInterval, timeout, description: `Report for scan "${scanName}"` }
  ).then(result => result.status);
})

/**
 * Selects a probe by name in the scan form
 * @param {string} probeName - The name of the probe to select (e.g., 'test.Blank')
 * @param {string} categoryId - Optional category ID to expand (e.g., 'anyoutput')
 */
Cypress.Commands.add('selectProbeByName', (probeName, categoryId = null) => {
  cy.waitForStimulusController('probe-category')
  // For community probes, expand the community section first
  if (categoryId) {
    // Expand community probes parent if it exists and is collapsed
    cy.get('body').then($body => {
      const communityHeader = $body.find('[data-probe-category-id="community_probes"]')
      if (communityHeader.length && communityHeader.attr('aria-expanded') !== 'true') {
        cy.wrap(communityHeader).click()
        cy.wait(300)
      }
    })

    // Then expand the specific sub-category
    cy.get(`[data-probe-category-id="${categoryId}"]`, { timeout: 10000 }).then($cat => {
      const isExpanded = $cat.attr('aria-expanded') === 'true'
      if (!isExpanded) {
        cy.wrap($cat).click()
        cy.get(`#category_content_${categoryId}`, { timeout: 5000 })
          .should('not.have.css', 'max-height', '0px')
      }
    })
  }

  // Find the checkbox by looking for label text and getting its 'for' attribute
  cy.contains('label', probeName, { timeout: 10000 })
    .scrollIntoView()
    .invoke('attr', 'for')
    .then((checkboxId) => {
      if (!checkboxId) {
        throw new Error(`Label for probe "${probeName}" has no 'for' attribute`)
      }
      // Use JavaScript click() which properly triggers all event handlers
      // Cypress's .check() doesn't always work with custom-styled checkboxes
      cy.get(`#${checkboxId}`, { timeout: 5000 }).then($checkbox => {
        const checkbox = $checkbox[0]
        if (!checkbox.checked) {
          checkbox.click()
        }
        // Verify the checkbox is now checked
        expect(checkbox.checked).to.be.true
      })
    })
})
