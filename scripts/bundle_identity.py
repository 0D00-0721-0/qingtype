"""Verify that every bundle in a QingType package came from the same build."""
import json
import re
from pathlib import Path


def check_bundle_identity(bundles, *, require_clean=False, expected_commit=None):
    records = [json.loads((Path(bundle) / 'Contents/Resources/BuildInfo.json').read_text())
               for bundle in bundles]
    if not records or any(record != records[0] for record in records[1:]):
        raise ValueError('Settings, input service and nested settings must have identical build provenance')
    record = records[0]
    if not re.fullmatch(r'[0-9a-f]{40}', record.get('sourceCommit', '')):
        raise ValueError('Invalid source commit in build provenance')
    if require_clean and record.get('workingTreeClean') is not True:
        raise ValueError('Published packages must come from a clean source tree')
    if expected_commit is not None and record['sourceCommit'] != expected_commit:
        raise ValueError('Published package does not match the checked-out release commit')
    return record
