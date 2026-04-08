# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t scanner .
# docker run -d -p 80:80 -e SECRET_KEY_BASE=<your-secret> -e POSTGRES_PASSWORD=<pw> --name scanner scanner

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.1
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

LABEL org.opencontainers.image.source="https://github.com/0din-ai/ai-scanner"

# Rails app lives here
WORKDIR /rails

# Install base packages including nodejs for runtime Playwright execution
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    curl wget python3 python3-venv libyaml-dev libjemalloc2 gosu \
    libatk-bridge2.0-0 libatk1.0-0 libcups2 libdrm2 libgbm1 libgtk-3-0 libnspr4 libnss3 libxcomposite1 \
    libxdamage1 libxfixes3 libxkbcommon0 libxrandr2 xdg-utils fonts-liberation libasound2t64 \
    openssl ca-certificates \
    gnupg lsb-release nodejs && \
    # Add PostgreSQL APT repository (for client tools and pgloader)
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y postgresql-client-18 pgloader && \
    rm -rf /tmp/* /var/tmp/*

# Create and activate a virtual environment for Python packages
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Set production environment
ENV RAILS_ENV="production" \
    RUBY_YJIT_ENABLE="1" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    RAILS_SERVE_STATIC_FILES="true" \
    RAILS_LOG_TO_STDOUT="true" \
    TMPDIR="/tmp" \
    HOME="/tmp" \
    BUNDLE_USER_HOME="/tmp"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems and Python packages
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential pkg-config python3-dev python3-pip nodejs npm rustc cargo libpq-dev

# Install Node.js tools and clean up
RUN npm install --global yarn && \
    rm -rf /tmp/* /var/tmp/* ~/.npm

# Install application gems first (better caching when only code changes)
COPY Gemfile Gemfile.lock ./
RUN --mount=type=cache,target=/usr/local/bundle/cache \
    --mount=type=cache,target=/root/.bundle \
    bundle install && \
    bundle exec bootsnap precompile --gemfile && \
    bundle clean --force && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    rm -rf /tmp/* /var/tmp/* ~/.cache /root/.gem

# Copy platform-specific garak requirements lock file
# TARGETARCH is automatically set by Docker buildx to either "amd64" or "arm64"
ARG TARGETARCH
COPY garak-requirements-lock-${TARGETARCH}.txt /tmp/garak-requirements-lock.txt
COPY playwright-requirements-lock.txt /tmp/playwright-requirements-lock.txt
COPY scanner-requirements.txt /tmp/scanner-requirements.txt

# Install garak with all its dependencies from lock file, plus Playwright and scanner deps
# No mount cache here, as Docker's cache mounts can interfere with Rust compilation subprocess execution.
# Specifically, when Python packages with Rust extensions are installed, Cargo (Rust's build system) may be invoked as a subprocess.
# Using a cache mount for pip or Cargo directories can cause permission errors or file locking issues, leading to build failures or inconsistent results.
RUN /opt/venv/bin/python -m pip install --upgrade pip wheel setuptools && \
    /opt/venv/bin/python -m pip install --no-cache-dir -r /tmp/garak-requirements-lock.txt && \
    /opt/venv/bin/python -m pip install --no-cache-dir --prefer-binary -r /tmp/playwright-requirements-lock.txt && \
    /opt/venv/bin/python -m pip install --no-cache-dir -r /tmp/scanner-requirements.txt && \
    # Selective cleanup to reduce Python venv size without breaking dependencies
    find /opt/venv -name "*.pyc" -delete && \
    find /opt/venv -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true && \
    find /opt/venv -name "*.pyo" -delete && \
    find /opt/venv -path "*/tests/*" -type f -delete 2>/dev/null || true && \
    find /opt/venv -path "*/test/*" -type f -delete 2>/dev/null || true && \
    find /opt/venv -name "examples" -type d -path "*/site-packages/*/examples" -exec rm -rf {} + 2>/dev/null || true && \
    find /opt/venv -name "*.egg-info" -type d -exec rm -rf {} + 2>/dev/null || true && \
    rm -f /tmp/garak-requirements-lock.txt /tmp/playwright-requirements-lock.txt /tmp/scanner-requirements.txt

# Copy package files and install Node dependencies (Playwright library only)
# Note: Browsers are installed separately below using shared PLAYWRIGHT_BROWSERS_PATH
COPY package.json package-lock.json* ./
RUN npm ci --production && \
    rm -rf /tmp/* /var/tmp/* ~/.npm

# Install Playwright browsers once into a shared path using Python Playwright only
# Install Chromium for PDF generation and webchat automation
RUN mkdir -p /opt/playwright-browsers && \
    chmod 755 /opt/playwright-browsers && \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers /opt/venv/bin/python -m playwright install --with-deps chromium && \
    chmod -R 755 /opt/playwright-browsers

# Configure Playwright browser path - both Python and Node.js will use these browsers
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers

# Verify venv and playwright availability (import checks)
RUN /opt/venv/bin/python - <<'PY'
import sys, importlib.util
print('python=', sys.executable)
assert importlib.util.find_spec('playwright'), 'playwright not importable'
assert importlib.util.find_spec('garak'), 'garak not importable'
PY

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile app/ lib/

# Precompiling assets for production without requiring SECRET_KEY_BASE
# CYPRESS_INSTALL_BINARY=0 prevents Cypress from downloading its binary during npm install
# (Cypress is a devDependency only needed for E2E testing, not production builds)
RUN SECRET_KEY_BASE_DUMMY=1 ASSETS_PRECOMPILE=1 CYPRESS_INSTALL_BINARY=0 ./bin/rails assets:precompile

# Clean up build dependencies and temporary files aggressively
RUN apt-get purge -y --auto-remove build-essential pkg-config nodejs npm rustc cargo && \
    apt-get autoremove -y && \
    apt-get autoclean && \
    rm -rf /tmp/* /var/tmp/* ~/.npm ~/.cache \
    "${BUNDLE_PATH}"/ruby/*/cache \
    /opt/venv/lib/python*/site-packages/pip/_vendor \
    /opt/venv/lib/python*/site-packages/setuptools \
    /rails/tmp/* /rails/log/* \
    /root/.gem /root/.local \
    /usr/share/doc/* /usr/share/man/* /usr/share/info/* \
    /usr/share/locale/* \
    /var/cache/debconf/* /var/lib/dpkg/info/* \
    /var/lib/apt/lists/* /var/cache/apt/archives/* \
    /usr/share/lintian/* /usr/share/linda/* \
    /var/cache/man/* || true

# Final stage for app image
FROM base

# Copy built artifacts: gems, application (excluding unnecessary files)
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /opt/venv /opt/venv
COPY --from=build /opt/playwright-browsers /opt/playwright-browsers
COPY --from=build /rails/node_modules /rails/node_modules
COPY --from=build /rails/package.json /rails/package.json
COPY --from=build /rails/package-lock.json /rails/package-lock.json
COPY --from=build /rails/app /rails/app
COPY --from=build /rails/bin /rails/bin
COPY --from=build /rails/config /rails/config
COPY --from=build /rails/db /rails/db
COPY --from=build /rails/lib /rails/lib
COPY --from=build /rails/public /rails/public
COPY --from=build /rails/script /rails/script
COPY --from=build /rails/Rakefile /rails/Rakefile
COPY --from=build /rails/config.ru /rails/config.ru
COPY --from=build /rails/Gemfile /rails/Gemfile
COPY --from=build /rails/Gemfile.lock /rails/Gemfile.lock

# Copy release notes if present (generated by CI, may not exist in local builds)
COPY --from=build /rails/RELEASE_NOTES.md* /rails/

# Install custom garak plugins (OpenRouter generator, 0din probes & detectors)
COPY --from=build /rails/script/garak_plugins/openrouter.py /opt/venv/lib/python3.13/site-packages/garak/generators/openrouter.py
COPY --from=build /rails/script/garak_plugins/probes/0din.py /opt/venv/lib/python3.13/site-packages/garak/probes/0din.py
COPY --from=build /rails/script/garak_plugins/probes/0din_variants.py /opt/venv/lib/python3.13/site-packages/garak/probes/0din_variants.py
COPY --from=build /rails/script/garak_plugins/detectors/0din.py /opt/venv/lib/python3.13/site-packages/garak/detectors/0din.py

# Create necessary directories with proper permissions
RUN mkdir -p /rails/storage /rails/tmp /rails/log /rails/tmp/sockets && \
    mkdir -p /tmp/.local/share/garak && \
    touch /rails/tmp/.keep /rails/log/.keep && \
    chmod 755 /rails/storage && \
    chmod 750 /rails/tmp /rails/log /rails/tmp/sockets && \
    chmod 777 /tmp/.local /tmp/.local/share /tmp/.local/share/garak

# Configure Playwright environment for runtime
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers


# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails /rails/db /rails/log /rails/storage /rails/tmp /rails/script /rails/node_modules /rails/config/probes && \
    chown -R rails:rails /opt/venv && \
    chown -R rails:rails /opt/playwright-browsers && \
    chmod -R 755 /opt/playwright-browsers

# Cache the HTTP Request: GET https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
# Run via gosu since container starts as root (no USER directive)
RUN gosu rails sh -c 'HOME=/tmp /opt/venv/bin/garak --list_probes' \
    || echo "WARNING: garak probe cache pre-warming failed (non-fatal, will retry at runtime)"

# Note: No USER directive — container starts as root so the entrypoint can
# fix bind-mount ownership before dropping to rails via gosu.
# See bin/docker-entrypoint for the privilege-drop logic.

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster (HTTP/2 proxy) + Puma
EXPOSE 80
CMD ["/rails/bin/thrust", "/rails/bin/rails", "server", "-b", "0.0.0.0"]
