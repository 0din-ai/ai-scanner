---
sidebar_position: 2
---

# Your First Scan

Run your first AI security scan using the built-in **Mock LLM** — no API keys or external services required.

The Mock LLM is a test server that ships with Scanner's Docker Compose setup. It simulates three modes of AI model behavior (safe, vulnerable, and mixed), making it ideal for validating your Scanner installation and learning the scan workflow.

## Prerequisites

Scanner must already be running. See [Quick Start](./quick-start) if you haven't set it up yet.

## Step 1: Create a Mock LLM Target

1. Log in to Scanner at `http://localhost` (or your configured port)
2. Navigate to **Targets** in the sidebar
3. Click **New Target**
4. Fill in the form:

   | Field | Value |
   |---|---|
   | **Name** | `Mock LLM - Vulnerable` |
   | **Model Type** | `rest.RestGenerator` |
   | **Model** | `http://mock-llm:9292/api/v1/mock_llm/chat` |

5. Click **Create Target**

:::tip Mock LLM modes
The mock server supports three response modes, set via the `mode` field in the JSON config:
- `safe` — always passes probes
- `vulnerable` — always fails probes (good for testing)
- `mixed` — mixed results (default if no mode is specified)

See [Mock LLM](../user-guide/mock-llm) for details on configuring modes.
:::

## Step 2: Start a Scan

1. Navigate to **Scans** in the sidebar
2. Click **New Scan**
3. Configure the scan:

   | Field | Value |
   |---|---|
   | **Name** | `My First Scan` |
   | **Target** | `Mock LLM - Vulnerable` |
   | **Probes** | Select a few families, or select all |

4. Click **Run Scan**

You'll be taken to the scan progress view. The scan runs in the background — you can watch probes execute in real time.

## Step 3: View the Report

Once the scan completes, click **View Report** to see the results.

The report shows:
- **Attack Success Rate (ASR)** — the percentage of probes that the model failed
- **Per-probe breakdown** — which probe families succeeded or failed
- **Per-attempt detail** — the exact prompt and response for every attempt

Since you used the `vulnerable` endpoint, you should see a high ASR score (many probes succeeded in eliciting problematic responses). This is expected and confirms Scanner is working correctly.

For a full explanation of what these numbers mean, see [Understanding Reports](../user-guide/reports).

## Step 4: Export a PDF Report (Optional)

From the report view, click **Export PDF** to download a formatted report suitable for sharing with stakeholders.

## Next Steps

Now that you've confirmed Scanner works:

- **Connect a real AI model** → [Targets](../user-guide/targets)
- **Configure API keys** → [Environment Variables](../user-guide/environment-variables)
- **Understand probe families** → [Probes](../user-guide/probes)
- **Schedule recurring scans** → [Scanning](../user-guide/scanning)
