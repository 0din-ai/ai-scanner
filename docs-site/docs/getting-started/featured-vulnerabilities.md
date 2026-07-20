---
sidebar_position: 3
title: Featured Vulnerabilities
---

# Featured Vulnerabilities

Scanner ships with real, 0DIN-disclosed jailbreaks as ready-to-run probes. The six tactics below are drawn straight from the [0DIN Jailbreak Feed](https://0din.ai/threatfeed?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=featured_vulnerabilities) and are bundled with the scanner today - each one carries the original attack prompt plus **34 retargetable variants** so you can measure how a given tactic performs against your own targets.

These are not simulations. Every entry links to its public threat report, which includes the affected models (blast radius), taxonomy classification, reproducibility scores, and mitigation guidance.

## The six probes

| # | Tactic | Scanner probe | Technique(s) | Variants | Threat report |
|---|--------|---------------|--------------|----------|---------------|
| 1 | **Placeholder Injection** | `PlaceholderInjectionHP` | Chaff | 34 | [View report ↗](https://0din.ai/threatfeed/8ccd7f81-4e36-4084-8061-cec6e2d83ece/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=placeholder_injection) |
| 2 | **Incremental Table Completion** | `IncrementalTableCompletionCM` | Escalating | 34 | [View report ↗](https://0din.ai/threatfeed/0d1e2015-f6ce-4b79-8bde-edd26bfc6f02/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=incremental_table_completion) |
| 3 | **Technical Field Guide** | `TechnicalFieldGuideCM` | Deceptive Formatting | 34 | [View report ↗](https://0din.ai/threatfeed/a50c962f-1a46-4382-b810-9a2b4c5c6091/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=technical_field_guide) |
| 4 | **Chemical Compiler Debug** | `ChemicalCompilerDebugCM` | Stop Sequences | 34 | [View report ↗](https://0din.ai/threatfeed/4e8ed295-a772-4a29-8727-cbefada44123/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=chemical_compiler_debug) |
| 5 | **Correction** | `CorrectionCM` | Ignore Previous Instructions, Synonymous Language | 34 | [View report ↗](https://0din.ai/threatfeed/439777fa-377a-43cb-83c6-c1a012e384b1/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=correction) |
| 6 | **Hex Recipe Book** | `HexRecipeBookCM` | Base64, Escalating, Scenarios, Ask For Examples, Hex | 34 | [View report ↗](https://0din.ai/threatfeed/06b58763-8a7b-4d82-afb6-ebe738b378a4/public?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=hex_recipe_book) |

## What each tactic does

- **Placeholder Injection** - Coaxes the model into reproducing copyrighted material by asking for output with each word separated by a placeholder token, sidestepping content filters.
- **Incremental Table Completion** - Builds a partially filled table and escalates requests for the "missing" cells, walking the model past its refusal boundary one step at a time.
- **Technical Field Guide** - Wraps a harmful request in law-enforcement framing and structured technical requirements to bypass inference restrictions.
- **Chemical Compiler Debug** - Encodes instructions as a "chemical compiler" input with explicit bypass commands, pushing the model to resolve the encoded payload.
- **Correction** - Presents illicit detail under the guise of "forensic chemical investigation," then asks the model to correct it, eliciting the withheld specifics.
- **Hex Recipe Book** - Combines hex encoding with scientific framing to smuggle a harmful request past guardrails.

## Run them against your own target

Once you have a target configured (see [Your First Scan](./first-scan)), these probes run like any other. No AI red-team expertise required - configure the target, run the scan, and read the report, all from the web UI.

1. Go to **Targets** and add your model as a new target.
2. Go to **Scans**, click **New Scan**, and choose your target.
3. Under **Probes**, select the featured probe you want to run (for example, `PlaceholderInjectionHP`), or select several.
4. Click **Run Scan** and watch progress in real time.
5. When the scan completes, open **View Report** to see the results.

Each run reports an **Attack Success Rate (ASR)** per probe and per variant, so you can track how a tactic performs across models and over time.

## Learn more

- [0DIN Jailbreak Feed ↗](https://0din.ai/threatfeed?utm_source=0din.ai&utm_medium=open_source_scanner&utm_campaign=opensourcescanner&utm_content=featured_vulnerabilities) - the full stream of disclosed vulnerabilities
- [0DIN Jailbreak Taxonomy ↗](https://0din.ai/research/taxonomy) - how these techniques are classified
- [Probes](/scanner-introduction) - how probe packs plug into your scanning workflow
