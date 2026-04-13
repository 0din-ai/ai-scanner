require "json"
require "base64"
require "open3"
require "tempfile"

module BrowserAutomation
  class PlaywrightService
    include Singleton

    attr_reader :browser_process, :browser_ready

    BROWSER_TIMEOUT = 30_000 # 30 seconds

    def initialize
      @mutex = Mutex.new
      @browser_process = nil
      @browser_ready = false
      @temp_script = nil
    end

    def with_page(url = nil, options = {})
      validate_url_safety!(url) if url
      script, data = build_page_script(url, options)
      execute_playwright_script(script, data: data)
    end

    def screenshot(url, output_path = nil, options = {})
      validate_url_safety!(url)
      output_path ||= generate_screenshot_path

      data = {
        url: url,
        output_path: output_path.to_s,
        wait_until: options[:wait_until] || "networkidle",
        type: options[:type] || "png"
      }

      script = <<~JS
        const { chromium } = require('playwright');
        const __data = JSON.parse(require('fs').readFileSync(process.env.PLAYWRIGHT_DATA_PATH, 'utf8'));

        (async () => {
          const browser = await chromium.launch({
            headless: true,
            args: ['--no-sandbox', '--disable-setuid-sandbox']
          });

          try {
            const context = await browser.newContext({
              viewport: { width: #{(options[:width] || 1920).to_i}, height: #{(options[:height] || 1080).to_i} }
            });
            const page = await context.newPage();

            await page.goto(__data.url, {
              waitUntil: __data.wait_until,
              timeout: #{(options[:timeout] || 30000).to_i}
            });

            await page.screenshot({
              path: __data.output_path,
              fullPage: #{options[:full_page] == true},
              type: __data.type
            });

            console.log(JSON.stringify({ success: true, path: __data.output_path }));
          } catch (error) {
            console.error(JSON.stringify({ error: error.message }));
            process.exitCode = 1;
          } finally {
            await browser.close();
          }
        })();
      JS

      result = execute_playwright_script(script, data: data)

      if result["success"]
        output_path
      else
        raise "Screenshot failed: #{result['error']}"
      end
    end

    def generate_pdf(url, output_path = nil, options = {})
      validate_url_safety!(url, allow_localhost: options[:allow_localhost])
      output_path ||= generate_pdf_path

      data = {
        url: url,
        output_path: output_path.to_s,
        wait_until: options[:wait_until] || "load",
        format: options[:format] || "A4"
      }

      script = <<~JS
        const { chromium } = require('playwright');
        const __data = JSON.parse(require('fs').readFileSync(process.env.PLAYWRIGHT_DATA_PATH, 'utf8'));

        (async () => {
          const browser = await chromium.launch({
            headless: true,
            args: [
              '--no-sandbox',
              '--disable-setuid-sandbox',
              '--disable-dev-shm-usage',
              '--disable-gpu'
            ]
          });

          try {
            const context = await browser.newContext({
              viewport: { width: #{(options[:width] || 1200).to_i}, height: #{(options[:height] || 1600).to_i} }
            });
            const page = await context.newPage();

            await page.goto(__data.url, {
              waitUntil: __data.wait_until,
              timeout: #{(options[:timeout] || 30000).to_i}
            });

            await page.pdf({
              path: __data.output_path,
              format: __data.format,
              printBackground: #{options.fetch(:print_background, true) == true},
              preferCSSPageSize: #{options.fetch(:prefer_css_page_size, true) == true}
            });

            console.log(JSON.stringify({ success: true, path: __data.output_path }));
          } catch (error) {
            console.error(JSON.stringify({ error: error.message }));
            process.exitCode = 1;
          } finally {
            await browser.close();
          }
        })();
      JS

      result = execute_playwright_script(script, data: data)

      if result["success"]
        output_path
      else
        raise "PDF generation failed: #{result['error']}"
      end
    end

    def validate_webchat_config(url, config)
      validate_url_safety!(url)
      selectors = config[:selectors] || config["selectors"]
      wait_times = config[:wait_times] || config["wait_times"] || {}

      input_selector = selectors[:input_field] || selectors["input_field"]
      send_selector = selectors[:send_button] || selectors["send_button"]
      container_selector = selectors[:response_container] || selectors["response_container"]

      test_message = "Hello"
      page_load_timeout = (wait_times[:page_load] || wait_times["page_load"] || 30000).to_i
      response_timeout = (wait_times[:response] || wait_times["response"] || 5000).to_i

      data = {
        url: url,
        input_selector: input_selector,
        container_selector: container_selector,
        send_selector: (send_selector.present? && send_selector != "null") ? send_selector : nil,
        test_message: test_message
      }

      script = <<~JS
        const { chromium } = require('playwright');
        const __data = JSON.parse(require('fs').readFileSync(process.env.PLAYWRIGHT_DATA_PATH, 'utf8'));

        (async () => {
          const browser = await chromium.launch({
            headless: true,
            args: ['--no-sandbox', '--disable-setuid-sandbox']
          });

          try {
            const context = await browser.newContext({
              viewport: { width: 1920, height: 1080 }
            });
            const page = await context.newPage();

            await page.goto(__data.url, {
              waitUntil: 'domcontentloaded',
              timeout: #{page_load_timeout}
            });

            try {
              await page.waitForLoadState('networkidle', { timeout: 15000 });
            } catch (error) {
              await page.waitForTimeout(3000);
            }

            const errors = [];

            try {
              await page.waitForSelector(__data.input_selector, {
                state: 'visible',
                timeout: 15000
              });

              await page.waitForFunction(
                (selector) => {
                  const el = document.querySelector(selector);
                  return el && !el.disabled && !el.readOnly;
                },
                __data.input_selector,
                { timeout: 5000 }
              );
            } catch (error) {
              errors.push('Input field not ready: ' + __data.input_selector + ' - ' + error.message);
            }

            const inputField = page.locator(__data.input_selector);
            const inputCount = await inputField.count();

            if (inputCount === 0) {
              errors.push('Input field not found: ' + __data.input_selector);
            } else if (!await inputField.first().isVisible()) {
              errors.push('Input field not visible: ' + __data.input_selector);
            }

            try {
              await page.waitForSelector(__data.container_selector, {
                state: 'attached',
                timeout: 15000
              });
            } catch (error) {
              errors.push('Response container not ready: ' + __data.container_selector + ' - ' + error.message);
            }

            const responseContainer = page.locator(__data.container_selector);
            const containerCount = await responseContainer.count();

            if (containerCount === 0) {
              errors.push('Response container not found: ' + __data.container_selector);
            }

            if (errors.length > 0) {
              console.log(JSON.stringify({
                success: false,
                errors: errors,
                response_detected: false
              }));
              await browser.close();
              return;
            }

            const baselineHistory = await responseContainer.first().textContent();

            let retryDelay = 1000;
            let messageSent = false;
            let lastError = null;

            for (let attempt = 0; attempt < 3; attempt++) {
              try {
                await inputField.first().fill(__data.test_message);
                await page.waitForTimeout(500);

                if (__data.send_selector) {
                  await page.click(__data.send_selector);
                } else {
                  await inputField.first().press('Enter');
                }

                messageSent = true;
                break;
              } catch (error) {
                lastError = error;
                if (attempt < 2) {
                  await page.waitForTimeout(retryDelay);
                  retryDelay *= 2;
                }
              }
            }

            if (!messageSent) {
              errors.push('Failed to send message after 3 attempts: ' + lastError.message);
              console.log(JSON.stringify({
                success: false,
                errors: errors,
                response_detected: false
              }));
              await browser.close();
              return;
            }

            await page.waitForTimeout(#{response_timeout});

            const newHistory = await responseContainer.first().textContent();
            const contentChanged = newHistory !== baselineHistory;
            const testMessagePresent = newHistory.includes(__data.test_message);

            console.log(JSON.stringify({
              success: true,
              errors: [],
              response_detected: contentChanged,
              test_message_found: testMessagePresent,
              baseline_length: baselineHistory.length,
              new_length: newHistory.length
            }));

          } catch (error) {
            console.log(JSON.stringify({
              success: false,
              errors: ['Validation error: ' + error.message],
              response_detected: false
            }));
          } finally {
            await browser.close();
          }
        })();
      JS

      result = execute_playwright_script(script, data: data)

      if result && result["success"]
        {
          success: result["success"],
          errors: result["errors"] || [],
          response_detected: result["response_detected"],
          test_message_found: result["test_message_found"],
          baseline_length: result["baseline_length"],
          new_length: result["new_length"]
        }
      else
        {
          success: false,
          errors: result["errors"] || [ "Unknown validation error" ],
          response_detected: false
        }
      end
    end

    def extract_page_structure(url, options = {})
      validate_url_safety!(url)
      data = {
        url: url,
        user_agent: options[:user_agent] || "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
      }

      script = <<~JS
        const { chromium } = require('playwright');
        const __data = JSON.parse(require('fs').readFileSync(process.env.PLAYWRIGHT_DATA_PATH, 'utf8'));

        (async () => {
          const browser = await chromium.launch({
            headless: true,
            args: ['--no-sandbox', '--disable-setuid-sandbox']
          });

          try {
            const context = await browser.newContext({
              viewport: { width: #{(options[:width] || 1920).to_i}, height: #{(options[:height] || 1080).to_i} },
              userAgent: __data.user_agent
            });
            const page = await context.newPage();

            await page.goto(__data.url, {
              waitUntil: 'domcontentloaded',
              timeout: #{(options[:timeout] || 15000).to_i}
            });

            try {
              await page.waitForLoadState('networkidle', { timeout: 15000 });
            } catch (error) {
              await page.waitForTimeout(8000);
            }

            const domElements = await page.evaluate(() => {
              const elements = {
                inputs: [],
                buttons: [],
                containers: [],
                iframes: []
              };

              function isVisible(el) {
                const rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
              }

              function isStableClass(className) {
                if (!className) return false;

                const unstablePatterns = [
                  /^ng-/,
                  /_[a-z0-9]{5,}/,
                  /^jsx-/,
                  /^css-/,
                  /^sc-/,
                  /-c\d{8,}-/,
                  /^MuiBox-root-/,
                  /^makeStyles-/
                ];

                return !unstablePatterns.some(pattern => pattern.test(className));
              }

              function getSelector(el) {
                if (el.id && isStableClass(el.id)) return '#' + el.id;

                if (el.getAttribute('role')) {
                  return '[role="' + el.getAttribute('role') + '"]';
                }
                if (el.getAttribute('data-testid')) {
                  return '[data-testid="' + el.getAttribute('data-testid') + '"]';
                }

                if (el.className && typeof el.className === 'string') {
                  const stableClasses = el.className.trim()
                    .split(/\s+/)
                    .filter(c => c && isStableClass(c))
                    .slice(0, 3);
                  if (stableClasses.length > 0) {
                    return '.' + stableClasses.join('.');
                  }
                }

                if (el.getAttribute('aria-label')) {
                  const label = el.getAttribute('aria-label').substring(0, 30);
                  return el.tagName.toLowerCase() + '[aria-label="' + label + '"]';
                }

                return el.tagName.toLowerCase();
              }

              function getSemanticAttributes(el) {
                return {
                  role: el.getAttribute('role') || '',
                  ariaLabel: el.getAttribute('aria-label') || '',
                  dataTestId: el.getAttribute('data-testid') || '',
                  dataAction: el.getAttribute('data-action') || ''
                };
              }

              const inputSelectors = 'input[type="text"], textarea, [contenteditable="true"], [role="textbox"]';
              document.querySelectorAll(inputSelectors).forEach(el => {
                if (isVisible(el)) {
                  const attrs = getSemanticAttributes(el);
                  elements.inputs.push({
                    selector: getSelector(el),
                    type: el.type || 'text',
                    placeholder: el.placeholder || '',
                    id: el.id || '',
                    classes: el.className || '',
                    role: attrs.role,
                    ariaLabel: attrs.ariaLabel,
                    dataTestId: attrs.dataTestId
                  });
                }
              });

              const buttonSelectors = 'button, input[type="submit"], [role="button"]';
              document.querySelectorAll(buttonSelectors).forEach(el => {
                if (isVisible(el)) {
                  const attrs = getSemanticAttributes(el);
                  const text = el.innerText || el.value || '';
                  elements.buttons.push({
                    selector: getSelector(el),
                    text: text,
                    id: el.id || '',
                    classes: el.className || '',
                    role: attrs.role,
                    ariaLabel: attrs.ariaLabel,
                    dataAction: attrs.dataAction
                  });
                }
              });

              const containerSelectors = 'div, main, section, [role="main"], [role="region"], [role="log"]';
              document.querySelectorAll(containerSelectors).forEach(el => {
                const rect = el.getBoundingClientRect();
                if (rect.height > 200 && isVisible(el)) {
                  const attrs = getSemanticAttributes(el);
                  elements.containers.push({
                    selector: getSelector(el),
                    id: el.id || '',
                    classes: el.className || '',
                    height: rect.height,
                    role: attrs.role,
                    ariaLabel: attrs.ariaLabel
                  });
                }
              });

              document.querySelectorAll('iframe').forEach(el => {
                elements.iframes.push({
                  selector: getSelector(el),
                  src: el.src || '',
                  title: el.title || '',
                  id: el.id || '',
                  classes: el.className || ''
                });
              });

              return {
                elements: elements,
                title: document.title,
                url: window.location.href
              };
            });

            const screenshotBuffer = await page.screenshot({
              type: 'png',
              fullPage: false
            });
            const screenshotBase64 = screenshotBuffer.toString('base64');

            const result = {
              html: domElements,
              metadata: {
                title: await page.title(),
                url: page.url()
              },
              screenshot: screenshotBase64
            };

            console.log(JSON.stringify({ success: true, data: result }));
          } catch (error) {
            console.error(JSON.stringify({ error: error.message }));
            process.exitCode = 1;
          } finally {
            await browser.close();
          }
        })();
      JS

      result = execute_playwright_script(script, data: data)

      if result && result["success"]
        result["data"]
      elsif result && result["error"]
        raise "Page structure extraction failed: #{result['error']}"
      else
        raise "Page structure extraction failed: Unexpected result format - #{result.inspect}"
      end
    end

    def stop_browser
      @mutex.synchronize do
        if @browser_process
          begin
            Process.kill("TERM", @browser_process)
          rescue Errno::ESRCH, Errno::ECHILD => e
            Rails.logger.warn "PlaywrightService: failed to kill process #{@browser_process}: #{e.message}"
          end
          begin
            Process.wait(@browser_process)
          rescue Errno::ESRCH, Errno::ECHILD => e
            Rails.logger.warn "PlaywrightService: failed to wait on process #{@browser_process}: #{e.message}"
          end
          @browser_process = nil
          @browser_ready = false
        end

        cleanup_temp_files
      end
    end

    private

    def validate_url_safety!(url, allow_localhost: nil)
      allow = allow_localhost.nil? ? UrlSafetyValidator.allow_localhost? : allow_localhost
      result = UrlSafetyValidator.safe_url?(url, allow_localhost: allow)
      raise ArgumentError, "SSRF protection: #{result.error}" unless result.safe?
    end

    def execute_playwright_script(script, data: nil)
      @mutex.synchronize do
        data_file = nil
        begin
          if data
            data_file = Tempfile.new([ "playwright_data", ".json" ], Rails.root.join("tmp"))
            data_file.write(JSON.generate(data))
            data_file.close
          end

          temp_file = Tempfile.new([ "playwright_script", ".cjs" ], Rails.root.join("tmp"))
          temp_file.write(script)
          temp_file.close

          env = {
            "NODE_PATH" => Rails.root.join("node_modules").to_s
          }
          env["PLAYWRIGHT_DATA_PATH"] = data_file.path if data_file

          output, error, status = Open3.capture3(env, "node", temp_file.path)

          extract_json = lambda do |text|
            next nil unless text && !text.empty?
            line = text.lines.reverse.find { |l| (s = l.strip).start_with?("{") && s.end_with?("}") }
            JSON.parse(line.strip) if line
          rescue JSON::ParserError
            nil
          end

          if status.success?
            result = extract_json.call(output)
            if result
              result
            else
              Rails.logger.error "No JSON found in Playwright output: #{output}"
              Rails.logger.error "Playwright stderr: #{error}" if error && !error.empty?
              { "error" => "No JSON found in output (stdout/stderr attached)", "stdout" => output.to_s[0, 4000], "stderr" => error.to_s[0, 4000] }
            end
          else
            result = extract_json.call(error)
            if result
              result
            else
              Rails.logger.error "Playwright script error: #{error}"
              Rails.logger.error "Playwright output: #{output}" if output && !output.empty?
              { "error" => (error.nil? || error.empty?) ? "Script failed with no error message" : error }
            end
          end
        ensure
          temp_file&.unlink
          data_file&.unlink
        end
      end
    end

    def build_page_script(url, options)
      data = {
        url: url,
        wait_until: options[:wait_until] || "networkidle"
      }

      script = <<~JS
        const { chromium } = require('playwright');
        const __data = JSON.parse(require('fs').readFileSync(process.env.PLAYWRIGHT_DATA_PATH, 'utf8'));

        (async () => {
          const browser = await chromium.launch({
            headless: #{options[:headless] != false}
          });

          try {
            const context = await browser.newContext({
              viewport: { width: #{(options[:width] || 1920).to_i}, height: #{(options[:height] || 1080).to_i} }
            });
            const page = await context.newPage();

            if (__data.url) {
              await page.goto(__data.url, { waitUntil: __data.wait_until });
            }

            console.log(JSON.stringify({ success: true }));
          } catch (error) {
            console.error(JSON.stringify({ error: error.message }));
            process.exitCode = 1;
          } finally {
            await browser.close();
          }
        })();
      JS

      [ script, data ]
    end

    def generate_screenshot_path
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
      Rails.root.join("storage", "screenshots", "screenshot_#{timestamp}.png").tap do |path|
        FileUtils.mkdir_p(File.dirname(path))
      end
    end

    def generate_pdf_path
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
      Rails.root.join("tmp", "pdfs", "report_#{timestamp}.pdf").tap do |path|
        FileUtils.mkdir_p(File.dirname(path))
      end
    end

    def cleanup_temp_files
      @temp_script&.unlink
    rescue Errno::ENOENT, Errno::EACCES => e
      Rails.logger.warn "PlaywrightService: failed to unlink temp script: #{e.message}"
    ensure
      @temp_script = nil
    end
  end
end
