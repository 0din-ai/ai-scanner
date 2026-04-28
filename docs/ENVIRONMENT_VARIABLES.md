# Environment Variables Configuration Guide

## Overview

Environment variables allow you to securely configure API keys and system settings for AI security scans. The Scanner platform uses these variables to authenticate with different AI providers and control scan behavior.

## How to Configure Environment Variables

### Step 1: Access the Admin Panel
1. Log into the Scanner platform with your admin credentials
2. Navigate to **Configuration** → **Environment Variables** in the admin menu

### Step 2: Create a New Environment Variable
1. Click the **New Environment Variable** button
2. Fill in the required fields:
   - **Target**: Leave empty for global variables, or select a specific target
   - **Environment Name**: The name of the variable (see supported variables below)
   - **Environment Value**: The value for this variable (e.g., your API key)
3. Click **Create Environment Variable** to save

### Step 3: Edit or Delete Variables
- To edit: Click on any existing variable to modify its value
- To delete: Select the variable and choose the delete action

## Supported API Environment Variables

### OpenAI
- **OPENAI_API_KEY**: Your OpenAI API key for GPT models
  - Format: `sk-...` 
  - Get your key at: https://platform.openai.com/account/api-keys

### OpenRouter
- **OPENROUTER_API_KEY**: Your OpenRouter API key for accessing multiple AI models
  - Format: API key from OpenRouter dashboard
  - Get your key at: https://openrouter.ai/keys

### Azure OpenAI
- **AZURE_API_KEY**: Your Azure OpenAI service key
- **AZURE_ENDPOINT**: Your Azure OpenAI endpoint URL
- **AZURE_MODEL_NAME**: The deployment name of your Azure model

### Anthropic
- **ANTHROPIC_API_KEY**: Your Anthropic API key for Claude models
  - Get your key at: https://console.anthropic.com/account/keys

### Groq
- **GROQ_API_KEY**: Your Groq API key for fast inference
  - Get your key at: https://console.groq.com/keys

### Replicate
- **REPLICATE_API_TOKEN**: Your Replicate API token
  - Format: `r8-...`
  - Get your token at: https://replicate.com/account/api-tokens

### Hugging Face
- **HF_TOKEN**: Your Hugging Face access token
  - Get your token at: https://huggingface.co/settings/tokens

### Cohere
- **COHERE_API_KEY**: Your Cohere API key
  - Get your key at: https://dashboard.cohere.ai/api-keys

## System Configuration Variables

These variables are process-level settings from the root `.env` file or container environment. They are not managed through **Configuration** → **Environment Variables**, and changing them requires restarting Scanner.

### SESSION_COOKIE_DOMAIN
- **Purpose**: Enables session cookie sharing across subdomains for WebSocket authentication
- **When to use**: Required when `ACTION_CABLE_URL` uses a different subdomain than the main application
- **Format**: Domain with leading dot (e.g., `.example.com`, `.scanner-preview`)
- **Examples**:
  - Production: `SESSION_COOKIE_DOMAIN=".scanner.example.com"` (allows `scanner.example.com` and `ws.scanner.example.com`)
  - Kubernetes: `SESSION_COOKIE_DOMAIN=".scanner-preview"` (allows `scanner-preview` and `ws.scanner-preview`)

### ACTION_CABLE_URL
- **Purpose**: WebSocket server URL for real-time updates
- **Format**: WebSocket URL (e.g., `wss://ws.scanner.example.com/cable`)
- **When to set**: When WebSockets are hosted on a different subdomain or server
- **Note**: If the WebSocket host differs from the application host, you must also set `SESSION_COOKIE_DOMAIN`

### EVALUATION_THRESHOLD
- **Purpose**: Controls how strict the vulnerability detection is
- **Default Value**: `0.2`
- **Impact**: Lower values (e.g., 0.1) are more strict and will flag more potential issues
- **Recommendation**: Start with default and adjust based on your security requirements

### DEBUG_LOG_TAIL_BYTES
- **Purpose**: Controls how many bytes of the garak execution log are synced into the live report debug log tail
- **Default Value**: `131072`
- **Location**: Root `.env` file or container environment; read by the Python runner process at startup
- **Disable live tails**: Set to `0` to skip live-tail reads and database updates
- **Invalid values**: Blank, non-integer, or negative values fall back to the default
- **Impact**: Higher values show more live execution-log context while a scan is running; lower values reduce database write size
- **Restart required**: Restart Scanner after changing this value

### PARALLEL_ATTEMPTS
> **Note**: This setting has been moved to the Settings page (`/settings`). It is no longer managed as an Environment Variable.

- **Purpose**: Number of simultaneous requests sent to the AI model during scanning
- **Default Value**: `16`
- **Configurable Range**: 1-100
- **Location**: Settings page at `/settings`
- **Impact**:
  - Higher values: Faster scans but may hit API rate limits
  - Lower values: Slower scans but more reliable with rate-limited APIs
- **Recommendation**: OpenAI (5-10), Anthropic (3-5), Local models (20-50)

## Global vs Target-Specific Variables

### When to Use Global Variables
Global variables apply to all scans across all targets. Use them for:
- Default API keys that work with all your models
- System-wide settings like default thresholds
- General configuration that rarely changes

**How to create**: Leave the "Target" field empty when creating the variable

### When to Use Target-Specific Variables
Target-specific variables apply only to scans of a particular AI model/target. Use them for:
- Different API keys for different models
- Custom endpoints for specific deployments
- Override default settings for particular targets

**How to create**: Select a specific target from the dropdown when creating the variable

### Priority Rules
- Target-specific variables always override global variables with the same name
- This allows you to set defaults globally and customize per target as needed

## Best Practices

### Security
1. **Keep API Keys Secure**
   - Never share your API keys
   - Rotate keys regularly
   - Use different keys for production and testing

2. **Use Target-Specific Keys When Possible**
   - Isolate different environments
   - Limit potential exposure if a key is compromised

### Organization
1. **Naming Convention**
   - Always use UPPERCASE with underscores (e.g., OPENAI_API_KEY)
   - Be consistent with the exact names listed above

2. **Documentation**
   - Keep a secure record of which keys are used where
   - Document any custom variables your organization uses

### Performance Optimization
1. **PARALLEL_ATTEMPTS Settings**
   - OpenAI: 5-10 (respects rate limits well)
   - Anthropic: 3-5 (more conservative rate limits)
   - Local models: 20-50 (no external rate limits)

2. **EVALUATION_THRESHOLD Tuning**
   - Production systems: 0.1-0.15 (strict)
   - Development/Testing: 0.2-0.3 (balanced)
   - Initial exploration: 0.3-0.5 (permissive)

## Common Scenarios

### Scenario 1: Setting Up OpenAI Scanning
1. Go to Configuration → Environment Variables
2. Create new global variable:
   - Name: `OPENAI_API_KEY`
   - Value: Your OpenAI API key
3. Your OpenAI targets will now authenticate automatically

### Scenario 2: Different Keys for Production vs Development
1. Create a global variable for development:
   - Name: `OPENAI_API_KEY`
   - Value: Your development API key
2. For production target, create target-specific variable:
   - Target: Select "Production GPT-4"
   - Name: `OPENAI_API_KEY`
   - Value: Your production API key

### Scenario 3: Adjusting Scan Speed for Rate-Limited API
1. Select the specific target experiencing rate limit errors
2. Create target-specific variable:
   - Name: `PARALLEL_ATTEMPTS`
   - Value: `3` (reduced from default 16)
3. Scans will now run slower but more reliably

## Troubleshooting

### API Key Not Working
- Verify the variable name matches exactly (case-sensitive)
- Check that the key is active in your provider's dashboard
- Ensure no extra spaces before or after the key value

### Scans Failing with Rate Limit Errors
- Reduce PARALLEL_ATTEMPTS for that target
- Consider upgrading your API plan
- Add delays between scans if running multiple

### Variables Not Being Applied
- Check if a target-specific variable is overriding your global setting
- Verify the target association is correct
- Ensure the variable is saved and enabled
