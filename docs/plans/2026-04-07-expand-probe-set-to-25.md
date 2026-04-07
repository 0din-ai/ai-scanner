# Expand 0DIN probe set from 6 to 25

## Overview

Add 19 new probe entries to the open-source ai-scanner, bringing the total from 6 to 25.
Each probe requires an entry in `config/probes/0din_probes.json` (metadata + prompts) and
a corresponding Python class in `script/garak_plugins/probes/0din.py` (garak plugin).

This is Part 1 of Linear ticket 0DIN-1257.

## Context

- Open-source probes JSON: `config/probes/0din_probes.json` (currently 6 probes)
- Open-source garak plugin: `script/garak_plugins/probes/0din.py` (currently 6 probe classes)
- Private source of truth for probe metadata and Python classes:
  - Metadata: `/Users/olehperevertailo/Projects/scanner/garak-0din-plugins/0din-json/probes.json`
  - Python classes: `/Users/olehperevertailo/Projects/scanner/garak-0din-plugins/garak/probes/0din.py`
- No DB migrations needed — `OdinProbeSource` auto-syncs new JSON entries via `SyncProbesJob`
- No changes to detectors — `MitigationBypass` and `CrystalMethScore` already exist

### Probe categories

Pattern A — 8 standalone CM probes (add to JSON + add class to Python):
- InvestigativeJournalistPersonaCM, MathematicalVariableObfuscationCM, AcademicChemistryCM,
  PharmaceuticalAnalysisCM, VerboseChemicalSimulationCM, ChemistryChallengeFrameworkCM,
  PatentLitigationFramingCM, ChemicalInquiryEscalationCM

Pattern B — 9 base + CM pairs (add BOTH to JSON + Python, 18 total entries):
- ArbitraryRelation + ArbitraryRelationCM
- FirstPersonPerspective + FirstPersonPerspectiveCM
- SuperShortPrompt + SuperShortPromptCM
- ChemistCodeLanguage + ChemistCodeLanguageCM
- CharacterContextualization + CharacterContextualizationCM
- EscalatingChemistryInquiry + EscalatingChemistryInquiryCM
- ForensicTrainingScenario + ForensicTrainingScenarioCM
- NotionTemplate + NotionTemplateCM (uses BaseHarmfulContentMultiShot — already present)
- ChemicalEngineeringInterview + ChemicalEngineeringInterviewCM

### JSON fields to include (safe for open source)
guid, summary, release_date, modified_date, disclosure_status, description,
techniques, social_impact_score, detector, scores, prompts

### Fields to OMIT from JSON
variant_count, published, published_at, tag, goal, variants
(these are private/internal fields)

### Key gotchas
- Some CM variants override substances: ArbitraryRelationCM, FirstPersonPerspectiveCM,
  SuperShortPromptCM → ["meth"]; ChemicalEngineeringInterviewCM → ["C₁₀H₁₅N"]
- NotionTemplate and ChemicalInquiryEscalationCM use multi-shot prompts (list)
- Base probes (Pattern B non-CM) have no scores field in JSON

## Development Approach

- Read private source files carefully before writing
- For Python classes: copy from private 0din.py verbatim (class body, docstring, attributes)
- For JSON entries: copy from private probes.json, strip private fields
- Run validation after each task: `python3 -c "import script.garak_plugins.probes.odin_0din"` to check syntax
- Tests: run `bundle exec rspec spec/jobs/sync_probes_job_spec.rb` if DB available

## Success Criteria

- `config/probes/0din_probes.json` has 25 probes (6 existing + 19 new = 26 entries including CM pairs, but 25 unique probe names as per ticket)
- All 26 probe classes syntactically valid in `script/garak_plugins/probes/0din.py`
- No private fields (variant_count, published, tag, goal, variants) in JSON
- Existing 6 probes untouched
- CHANGELOG.md updated with the new probe count

## Validation Commands

- `python3 -c "import sys; sys.path.insert(0, 'script'); from garak_plugins.probes import odin_0din; print('OK')"`
- `python3 -c "import json; d=json.load(open('config/probes/0din_probes.json')); print(len(d['probes']), 'probes')"` — expect 25+

### Task 1: Add Pattern A probes to JSON and Python

Add the 8 standalone CM probes.

For each probe, you need to:
1. Find its entry in `/Users/olehperevertailo/Projects/scanner/garak-0din-plugins/0din-json/probes.json`
2. Copy the safe fields (guid, summary, release_date, modified_date, disclosure_status, description, techniques, social_impact_score, detector, scores, prompts) into `config/probes/0din_probes.json` under the probe class name key
3. Find the Python class in `/Users/olehperevertailo/Projects/scanner/garak-0din-plugins/garak/probes/0din.py` and copy it verbatim to `script/garak_plugins/probes/0din.py` (after the last existing class)

Probes to add in this task:
- InvestigativeJournalistPersonaCM
- MathematicalVariableObfuscationCM
- AcademicChemistryCM
- PharmaceuticalAnalysisCM
- VerboseChemicalSimulationCM
- ChemistryChallengeFrameworkCM
- PatentLitigationFramingCM
- ChemicalInquiryEscalationCM (uses BaseHarmfulContentMultiShot, multi-shot prompts)

- [x] Read existing `config/probes/0din_probes.json` to understand the structure
- [x] Read existing `script/garak_plugins/probes/0din.py` to understand the style
- [x] Add all 8 probe entries to `config/probes/0din_probes.json`
- [x] Add all 8 probe classes to `script/garak_plugins/probes/0din.py`
- [x] Validate Python syntax: `python3 -c "exec(open('script/garak_plugins/probes/0din.py').read()); print('syntax OK')"`
- [x] Validate JSON: `python3 -c "import json; d=json.load(open('config/probes/0din_probes.json')); print(len(d['probes']), 'probes')"`

### Task 2: Add Pattern B base probes to JSON and Python

Add the 9 base (non-CM) probes from Pattern B pairs.
These are the base classes that their CM counterparts extend.
Base probes use `0din.MitigationBypass` as detector and have no `scores` field.

Probes to add:
- ArbitraryRelation
- FirstPersonPerspective
- SuperShortPrompt
- ChemistCodeLanguage
- CharacterContextualization
- EscalatingChemistryInquiry
- ForensicTrainingScenario
- NotionTemplate (uses BaseHarmfulContentMultiShot)
- ChemicalEngineeringInterview

- [x] Add all 9 base probe entries to `config/probes/0din_probes.json`
- [x] Add all 9 base probe classes to `script/garak_plugins/probes/0din.py`
- [x] Validate Python syntax
- [x] Validate JSON probe count

### Task 3: Add Pattern B CM variant probes to JSON and Python

Add the 9 CM variants that extend the base probes added in Task 2.
Important: some override `substances`:
- ArbitraryRelationCM → substances = ["meth"]
- FirstPersonPerspectiveCM → substances = ["meth"]
- SuperShortPromptCM → substances = ["meth"]
- ChemicalEngineeringInterviewCM → substances = ["C₁₀H₁₅N"]
- Others inherit ["crystal meth"] from CrystalMethMixin

CM probes to add:
- ArbitraryRelationCM
- FirstPersonPerspectiveCM
- SuperShortPromptCM
- ChemistCodeLanguageCM
- CharacterContextualizationCM
- EscalatingChemistryInquiryCM
- ForensicTrainingScenarioCM
- NotionTemplateCM
- ChemicalEngineeringInterviewCM

- [x] Add all 9 CM probe entries to `config/probes/0din_probes.json`
- [x] Add all 9 CM probe classes to `script/garak_plugins/probes/0din.py`
- [x] Double-check substances overrides match the private plugin exactly
- [x] Validate Python syntax
- [x] Validate JSON: expect 25 probes total

### Task 4: Update CHANGELOG and verify

- [x] Update CHANGELOG.md to note the probe count increase from 6 to 25
- [x] Run final Python syntax check on the full plugin file
- [x] Run final JSON validation — expect exactly 25 probes in `config/probes/0din_probes.json`
- [x] Confirm no private fields (variant_count, published, tag, goal, variants) leaked into the JSON: `python3 -c "import json; d=json.load(open('config/probes/0din_probes.json')); bad=[k for p in d['probes'].values() for k in p if k in ['variant_count','published','tag','goal','variants']]; print('Private fields found:', bad or 'none')"`
- [x] Verify existing 6 probes are untouched (check their GUIDs match original)
