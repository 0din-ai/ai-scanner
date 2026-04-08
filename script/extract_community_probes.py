#!/usr/bin/env python3
"""Extract community probe metadata from installed garak package.

Introspects garak's built-in probe modules and outputs a JSON file
compatible with GarakCommunityProbeSource.

Usage:
    python3 script/extract_community_probes.py [output_path]

Default output: config/probes/community_probes.json
"""

import sys
import os
import json
import uuid
import inspect
import pkgutil
import importlib
from datetime import date
from pathlib import Path

# Deterministic UUID namespace for community probes
GARAK_UUID_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_DNS, "garak.nvidia.com")

# Modules to skip (custom plugins, test modules, base classes)
SKIP_MODULES = {'base', '0din', '0din_variants', 'test'}

# Individual probes to skip (format: "module.ClassName")
# atkgen.Tox: multi-turn red-teaming probe, very slow (~12min per scan)
BLOCKED_PROBES = {'atkgen.Tox'}

# Map Garak tags to taxonomy technique names
TAG_TO_TECHNIQUE = {
    'owasp:llm01': 'Prompt Injection',
    'owasp:llm02': 'Insecure Output Handling',
    'owasp:llm05': 'Supply Chain Vulnerabilities',
    'owasp:llm06': 'Sensitive Information Disclosure',
    'owasp:llm09': 'Misinformation',
    'owasp:llm10': 'Model Denial of Service',
    'avid-effect:security:S0403': 'Goal Hijacking',
    'avid-effect:security:S0301': 'Sensitive Information Disclosure',
    'avid-effect:security:S0201': 'Model Evasion',
    'avid-effect:ethics:E0301': 'Toxic Content Generation',
    'avid-effect:ethics:E0302': 'Toxic Content Generation',
    'avid-effect:ethics:E0101': 'Bias and Discrimination',
    'avid-effect:performance:P0204': 'Goal Hijacking',
    'avid-effect:performance:P0201': 'Model Evasion',
    'avid-effect:performance:P0401': 'Output Integrity',
    'avid-effect:performance:P0403': 'Model Denial of Service',
    'payload:jailbreak': 'DAN - Do Anything Now',
    'payload:generic': 'Prompt Injection',
    'payload:malicious:badcode': 'Malicious Code Generation',
    'quality:Security:PromptStability': 'Prompt Injection',
    'quality:Behavioral:ContentSafety:Toxicity': 'Toxic Content Generation',
    'quality:Behavioral:ContentSafety:Violence': 'Toxic Content Generation',
    'quality:Behavioral:ContentSafety:LegalGoodsServices': 'Sensitive Information Disclosure',
    'risk-cards:lmrc:anthropomorphisation': 'Personas',
    'risk-cards:lmrc:bullying': 'Toxic Content Generation',
    'risk-cards:lmrc:deadnaming': 'Toxic Content Generation',
    'risk-cards:lmrc:quack_medicine': 'Misinformation',
    'risk-cards:lmrc:sexualised_content': 'Toxic Content Generation',
    'risk-cards:lmrc:profanity': 'Toxic Content Generation',
    'risk-cards:lmrc:slur_usage': 'Toxic Content Generation',
    'risk-cards:lmrc:providing_illegal_info': 'Sensitive Information Disclosure',
}

# Map Garak tier enum to social impact score (1-5)
TIER_TO_SCORE = {
    'UNLISTED': 2,
    'INFORMATIONAL': 1,
    'COMPETE_WITH_SOTA': 3,
    'OF_CONCERN': 4,
}


def get_tier_name(tier):
    """Extract tier name from enum or string."""
    if tier is None:
        return 'UNLISTED'
    if hasattr(tier, 'name'):
        return tier.name
    return str(tier).split('.')[-1] if '.' in str(tier) else str(tier)


def extract_techniques(tags):
    """Map Garak tags to taxonomy technique names."""
    techniques = set()
    for tag in (tags or []):
        if tag in TAG_TO_TECHNIQUE:
            techniques.add(TAG_TO_TECHNIQUE[tag])
    return sorted(techniques) if techniques else ['Prompt Injection']


def get_probe_docstring(probe_class):
    """Extract and clean the first line of a probe class docstring."""
    doc = probe_class.__doc__
    if not doc:
        return ''
    lines = [line.strip() for line in doc.strip().split('\n') if line.strip()]
    return lines[0][:255] if lines else ''


def extract_probe_metadata(probe_class, module_name):
    """Extract metadata from a Garak probe class."""
    class_name = probe_class.__name__
    full_name = f"{module_name}.{class_name}"

    goal = getattr(probe_class, 'goal', '')
    tags = getattr(probe_class, 'tags', [])
    tier = getattr(probe_class, 'tier', None)
    active = getattr(probe_class, 'active', False)
    primary_detector = getattr(probe_class, 'primary_detector', None) or 'mitigation.MitigationBypass'
    doc_uri = getattr(probe_class, 'doc_uri', '')

    docstring = get_probe_docstring(probe_class)
    description = f"Community probe from NVIDIA Garak ({full_name})."
    if docstring:
        description = f"{description} {docstring}"

    deterministic_guid = uuid.uuid5(GARAK_UUID_NAMESPACE, full_name)

    return {
        'guid': str(deterministic_guid),
        'summary': docstring or goal or f"Garak {class_name} probe",
        'description': description,
        'goal': goal,
        'techniques': extract_techniques(tags),
        'social_impact_score': TIER_TO_SCORE.get(get_tier_name(tier), 2),
        'detector': primary_detector,
        'active': active,
        'tags': tags,
        'doc_uri': doc_uri,
        'source': 'garak',
        'attribution': 'NVIDIA Garak - https://github.com/NVIDIA/garak',
    }


def extract_community_probes():
    """Extract all community probe metadata from garak."""
    try:
        import garak.probes
        import garak.probes.base
    except ImportError as e:
        print(f"Error: Failed to import garak: {e}", file=sys.stderr)
        sys.exit(1)

    probes = {}
    errors = []

    for _importer, module_name, _ispkg in pkgutil.iter_modules(garak.probes.__path__):
        if module_name.startswith('_') or module_name in SKIP_MODULES:
            continue

        try:
            module = importlib.import_module(f'garak.probes.{module_name}')

            for name, obj in inspect.getmembers(module, inspect.isclass):
                if (issubclass(obj, garak.probes.base.Probe)
                        and obj is not garak.probes.base.Probe
                        and obj.__module__ == f'garak.probes.{module_name}'):

                    full_name = f"{module_name}.{name}"
                    if full_name in BLOCKED_PROBES:
                        continue
                    try:
                        probes[full_name] = extract_probe_metadata(obj, module_name)
                    except Exception as e:
                        errors.append(f"{full_name}: {e}")

        except Exception as e:
            errors.append(f"Module {module_name}: {e}")

    return {
        'probes': probes,
        'count': len(probes),
        'errors': errors if errors else None,
    }


def load_existing(output_path):
    """Load existing probes JSON, returning {} on missing/corrupt file."""
    try:
        with open(output_path, 'r') as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get('probes'), dict):
            return data
    except (OSError, json.JSONDecodeError, ValueError):
        pass
    return {}


# Fields that carry semantic probe content (everything except dates)
_DATE_KEYS = {'release_date', 'modified_date'}


def merge_dates(new_probes, existing_probes):
    """Assign release_date and modified_date per probe based on content diff."""
    today = str(date.today())

    for name, probe in new_probes.items():
        old = existing_probes.get(name)
        if old is None:
            # New probe — both dates are today
            probe['release_date'] = today
            probe['modified_date'] = today
        else:
            # Compare semantic content (everything except date fields)
            old_content = {k: v for k, v in old.items() if k not in _DATE_KEYS}
            new_content = {k: v for k, v in probe.items() if k not in _DATE_KEYS}

            if old_content == new_content:
                # Unchanged — preserve both dates
                probe['release_date'] = old.get('release_date', today)
                probe['modified_date'] = old.get('modified_date', today)
            else:
                # Changed — preserve release_date, bump modified_date
                probe['release_date'] = old.get('release_date', today)
                probe['modified_date'] = today


def main():
    # Determine output path
    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent
    default_output = project_root / "config" / "probes" / "community_probes.json"
    output_path = Path(sys.argv[1]) if len(sys.argv) > 1 else default_output

    # Ensure output directory exists
    output_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"Extracting community probes from garak...")
    result = extract_community_probes()

    # Validate result
    if not result.get('probes') or not isinstance(result['probes'], dict):
        print("Error: No probes extracted", file=sys.stderr)
        sys.exit(1)

    if result.get('errors'):
        print(f"Warning: {len(result['errors'])} extraction errors:", file=sys.stderr)
        for err in result['errors']:
            print(f"  - {err}", file=sys.stderr)

    # Merge dates from existing file to keep output deterministic
    existing = load_existing(output_path)
    merge_dates(result['probes'], existing.get('probes', {}))

    # Serialize with sorted keys for stable ordering
    new_json = json.dumps(result, indent=2, sort_keys=True) + "\n"

    # Skip rewrite if byte-identical
    try:
        existing_bytes = output_path.read_text()
        if existing_bytes == new_json:
            print(f"No changes — {output_path} is up to date ({result['count']} probes)")
            return
    except OSError:
        pass

    output_path.write_text(new_json)
    print(f"Extracted {result['count']} community probes to {output_path}")


if __name__ == '__main__':
    main()
