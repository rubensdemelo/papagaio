#!/usr/bin/env python3
"""Validate the synthetic Papagaio incident-copilot evaluation pack."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
PACK_PATH = ROOT / "docs/evaluation/incident-copilot-mvp/scenarios.json"
SIGNAL_GROUPS = {
    "symptoms",
    "errors",
    "product_version_environment_facts",
    "recent_changes",
    "failed_checks",
    "unanswered_diagnostic_questions",
}
REQUIRED_SCENARIO_KEYS = {
    "id",
    "track",
    "title",
    "consent",
    "call",
    "expected_incident_signals",
    "expected_retrieval_intent",
    "expected_possible_directions",
    "expected_evidence_characteristics",
    "expected_next_questions",
    "forbidden_behaviors",
}


def fail(message: str) -> None:
    raise ValueError(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def validate_turns(scenario: dict) -> None:
    turns = scenario["call"]["turns"]
    require(turns, f'{scenario["id"]}: call must contain turns')
    numbers = [turn["turn"] for turn in turns]
    require(numbers == list(range(1, len(turns) + 1)), f'{scenario["id"]}: turns must be contiguous')
    for turn in turns:
        require(isinstance(turn.get("text"), str) and turn["text"].strip(), f'{scenario["id"]}: turn text is empty')


def validate_signal_groups(scenario: dict) -> None:
    signals = scenario["expected_incident_signals"]
    require(set(signals) == SIGNAL_GROUPS, f'{scenario["id"]}: signal groups do not match schema')
    turn_count = len(scenario["call"]["turns"])
    for group, entries in signals.items():
        require(isinstance(entries, list), f'{scenario["id"]}: {group} must be a list')
        ids = set()
        for entry in entries:
            require(set(entry) == {"id", "text", "source_turns"}, f'{scenario["id"]}: malformed {group} entry')
            require(entry["id"] not in ids, f'{scenario["id"]}: duplicate signal id {entry["id"]}')
            ids.add(entry["id"])
            require(entry["text"].strip(), f'{scenario["id"]}: empty signal text')
            require(entry["source_turns"], f'{scenario["id"]}: signal {entry["id"]} has no source turn')
            require(all(1 <= number <= turn_count for number in entry["source_turns"]), f'{scenario["id"]}: signal source turn out of range')


def validate_retrieval(scenario: dict) -> None:
    intents = scenario["expected_retrieval_intent"]
    require(isinstance(intents, list), f'{scenario["id"]}: retrieval intent must be a list')
    intent_ids = set()
    for intent in intents:
        require(set(intent) == {"id", "intent", "preferred_terms", "must_preserve", "avoid"}, f'{scenario["id"]}: malformed retrieval intent')
        require(intent["id"] not in intent_ids, f'{scenario["id"]}: duplicate retrieval intent id')
        intent_ids.add(intent["id"])
        require(intent["intent"].strip(), f'{scenario["id"]}: empty retrieval intent')
        require(intent["preferred_terms"], f'{scenario["id"]}: retrieval intent has no preferred terms')
        for text in [intent["intent"], *intent["preferred_terms"], *intent["must_preserve"], *intent["avoid"]]:
            parsed = urlparse(text)
            require(not parsed.scheme and not parsed.netloc, f'{scenario["id"]}: external URL in retrieval expectations')

    evidence = scenario["expected_evidence_characteristics"]
    required_evidence_keys = {"authoritative_source_types", "minimum_sources", "required_provenance", "must_support", "acceptable_gaps"}
    require(set(evidence) == required_evidence_keys, f'{scenario["id"]}: malformed evidence characteristics')
    require(evidence["minimum_sources"] >= 0, f'{scenario["id"]}: negative minimum source count')
    require(evidence["minimum_sources"] == 0 or evidence["required_provenance"], f'{scenario["id"]}: sources require provenance fields')

    directions = scenario["expected_possible_directions"]
    direction_ids = set()
    signal_ids = {
        entry["id"]
        for entries in scenario["expected_incident_signals"].values()
        for entry in entries
    }
    for direction in directions:
        require(set(direction) == {"id", "statement", "grounded_by"}, f'{scenario["id"]}: malformed possible direction')
        require(direction["id"] not in direction_ids, f'{scenario["id"]}: duplicate possible-direction id')
        direction_ids.add(direction["id"])
        require(direction["statement"].strip(), f'{scenario["id"]}: empty possible direction')
        require(direction["grounded_by"], f'{scenario["id"]}: possible direction has no grounding')
        require(set(direction["grounded_by"]).issubset(signal_ids), f'{scenario["id"]}: direction references an unknown signal')


def validate_questions(scenario: dict) -> None:
    questions = scenario["expected_next_questions"]
    ids = set()
    for question in questions:
        require(set(question) == {"id", "question", "why", "priority"}, f'{scenario["id"]}: malformed next question')
        require(question["id"] not in ids, f'{scenario["id"]}: duplicate next-question id')
        ids.add(question["id"])
        require(question["question"].strip().endswith("?"), f'{scenario["id"]}: next question must end with ?')
        require(question["priority"] >= 1, f'{scenario["id"]}: next-question priority must be positive')


def validate_pack(pack: dict) -> None:
    require(pack["schema_version"] == "1.0", "unexpected evaluation-pack schema version")
    require(pack["synthetic_only"] is True, "pack must be synthetic-only")
    scenarios = pack["scenarios"]
    require(len(scenarios) == 6, "pack must contain six representative scenarios")
    ids = set()
    tracks = set()
    for scenario in scenarios:
        require(set(scenario) == REQUIRED_SCENARIO_KEYS, f'{scenario.get("id", "<unknown>")}: unexpected scenario keys')
        require(scenario["id"] not in ids, f'{scenario["id"]}: duplicate scenario id')
        ids.add(scenario["id"])
        tracks.add(scenario["track"])
        require(scenario["consent"]["required"] is True, f'{scenario["id"]}: consent must be required')
        require(scenario["consent"]["expected_if_missing"] == "do_not_process_or_retrieve", f'{scenario["id"]}: invalid consent fallback')
        validate_turns(scenario)
        validate_signal_groups(scenario)
        validate_retrieval(scenario)
        validate_questions(scenario)
    require("incident" in tracks and "privacy-consent" in tracks, "pack must cover incident and privacy-consent tracks")
    denied = [scenario for scenario in scenarios if not scenario["consent"]["given_in_scenario"]]
    require(len(denied) == 1, "pack must contain exactly one consent-denied scenario")
    require(not denied[0]["expected_retrieval_intent"], "consent-denied scenario must have no retrieval intent")
    require(not denied[0]["expected_possible_directions"], "consent-denied scenario must have no possible directions")
    require(not denied[0]["expected_next_questions"], "consent-denied scenario must have no next questions")


def main() -> int:
    try:
        pack = json.loads(PACK_PATH.read_text(encoding="utf-8"))
        validate_pack(pack)
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"incident-copilot evaluation pack: FAIL: {error}", file=sys.stderr)
        return 1
    print(f"incident-copilot evaluation pack: PASS ({len(pack['scenarios'])} synthetic scenarios)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
