# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Agent fuzzing follow-up for customer agent targets
  - Optional scan flag runs discovery probes, then a dedicated AgentFuzzingRun
  - Successful attempts become seeds; failed and unmeasured attempts are not
  - Vendored Sleipnir playbooks, including poison-pill indirect prompt injection
  - Hosted source/callback artifacts (`AGENT_PUBLIC_ORIGIN`) with attack, replay and clean control arms in isolated conversations
  - Confirmed findings require an independent sink/tool observation, matched control, and replay; model echo is not a vulnerability

- Expanded 0DIN probe set from 6 to 32 probes for broader AI safety assessment coverage
  - 8 Pattern A standalone Crystal Meth probes (e.g., InvestigativeJournalistPersonaCM, AcademicChemistryCM)
  - 9 Pattern B base probes (e.g., ArbitraryRelation, NotionTemplate, ForensicTrainingScenario)
  - 9 Pattern B Crystal Meth variant probes (e.g., ArbitraryRelationCM, NotionTemplateCM)
- Industry-specific threat variant system for contextual AI safety testing
  - ThreatVariant, ThreatVariantIndustry, and ThreatVariantSubindustry models
  - ~725 unique variant probes across 12 industries (automotive, finance, healthcare, etc.)
  - VariantProbeMapper service for mapping probes to garak variant class identifiers
  - GenerateVariantReportsJob creates child variant reports after successful probe runs
  - Reports::Process resolves variant probe names from garak scan output
  - OdinProbeSource syncs variant data from 0din_probes.json
  - 0din_variants.py garak plugin with SingleShotVariant and MultiShotVariant classes
