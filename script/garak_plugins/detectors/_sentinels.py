"""Recognising attempts where generation failed on our side.

Provenance is read from attempt.notes, NEVER from the response text. A model can emit
any string it likes, so a marker in the output cannot distinguish "our generator raised"
from "the target said those words" -- and a detector that trusts it hands any target a
way to delete its own answer from the results. attempt.notes is written by the probe and
is not model-controlled, so it cannot be forged.
"""

# Mirrors the constant used by the probes. A test asserts the two agree.
GENERATION_FAILED_NOTE = "generation_failed"


def attempt_generation_failed(attempt) -> bool:
    """True when the probe recorded that generation raised for this attempt.

    Such an attempt is evidence about our infrastructure, not about the model: it is
    neither an attack that succeeded nor one the model defended. Detectors return None
    for it, which garak excludes from total_evaluated, keeping it out of both the
    numerator and the denominator instead of crediting the model with a refusal.
    """
    notes = getattr(attempt, "notes", None) or {}
    return bool(notes.get(GENERATION_FAILED_NOTE))
