"""Frozen engineering baselines and observed comparisons. Author: Timur Isaev."""

import statistics
from pathlib import Path
from datetime import datetime, timezone

from .common import canonical, file_digest, hashed, require
from .evidence import validate


def algorithm():
    return file_digest(Path(__file__))['sha256']


def key(record):
    provenance = record['provenance']
    return hashed({'scenario': provenance['scenario_sha256'], 'host': provenance['host_class_sha256'],
                   'runtime': provenance['runtime']['expected']})


def binding(record):
    provenance = record['provenance']
    return {name: provenance[name] for name in ('runner', 'scheduler', 'host_class_sha256', 'scenario_sha256',
                                              'runtime', 'subject', 'inputs')}


def statistics_for(records):
    require(records and len(records) <= 100, 'baseline:sample_count')
    for record in records:
        validate(record)
        require(record['state'] == 'COMPLETED' and record['control'] == 'clean', 'baseline:unclean_sample')
        require(binding(record) == binding(records[0]), 'baseline:identity_mismatch')
    require(len({record['run_id'] for record in records}) == len(records), 'baseline:duplicate_run')
    rules = records[0]['scenario']['observables']
    require(any(item['comparison']['class'] != 'informational' for item in rules), 'baseline:no_gates')
    limits = {}
    for item in rules:
        values = [record['observed'][item['id']] for record in records]
        kind = item['comparison']['class']
        if kind in ('exact', 'behavioral'):
            require(all(canonical(value) == canonical(values[0]) for value in values), 'baseline:flaky_exact')
            limits[item['id']] = {'reference': values[0], 'count': len(values)}
        elif kind in ('numeric', 'performance'):
            if kind == 'performance':
                require(len(records) >= 8, 'baseline:eight_calibration_runs_required')
            mean = statistics.mean(values)
            spread = max(values) - min(values)
            slack = max(item['comparison']['absolute'], abs(mean) * item['comparison']['relative'])
            if kind == 'performance':
                # LAB-001's observed-range envelope, with a seconds-only floor.
                slack = max(slack, 4 * spread, 0.05 if item['unit'] == 'seconds' else 0)
            limits[item['id']] = {'mean': mean, 'range': spread, 'slack': slack, 'count': len(values)}
        else:
            limits[item['id']] = {'count': len(values)}
    return limits


def freeze(records, record_ids):
    require(bool(records) and len(records) == len(record_ids) and len(set(record_ids)) == len(record_ids), 'baseline:sample_ids')
    result = {'version': 1, 'scope': 'provisional-engineering-only', 'key': key(records[0]),
              'created_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
              'records': record_ids, 'binding': binding(records[0]), 'limits': statistics_for(records),
              'algorithm_sha256': algorithm()}
    result['integrity_sha256'] = hashed(result)
    return result


def validate_baseline(baseline, records):
    require(set(baseline) == {'version', 'scope', 'key', 'created_at', 'records', 'binding', 'limits',
                              'algorithm_sha256', 'integrity_sha256'}, 'baseline:fields')
    require(type(baseline['version']) is int and baseline['version'] == 1 and
            baseline['scope'] == 'provisional-engineering-only', 'baseline:version_scope')
    require(baseline['integrity_sha256'] == hashed({key: value for key, value in baseline.items() if key != 'integrity_sha256'}),
            'baseline:integrity')
    require(baseline['algorithm_sha256'] == algorithm(), 'baseline:algorithm_changed')
    require(len(baseline['records']) == len(records) and len(set(baseline['records'])) == len(records), 'baseline:sample_ids')
    require(baseline['binding'] == binding(records[0]) and baseline['key'] == key(records[0]), 'baseline:binding')
    require(baseline['limits'] == statistics_for(records), 'baseline:recomputed_limits_mismatch')
    return baseline


def compare(candidate, baseline, records):
    validate(candidate)
    validate_baseline(baseline, records)
    if candidate['state'] != 'COMPLETED':
        return {'verdict': candidate['state'], 'reasons': [item['code'] for item in candidate['failures']]}
    if binding(candidate) != baseline['binding']:
        return {'verdict': 'INCOMPARABLE', 'reasons': ['execution_identity_mismatch']}
    if candidate['run_id'] in {record['run_id'] for record in records}:
        return {'verdict': 'INCOMPARABLE', 'reasons': ['calibration_sample_reused']}
    start = datetime.fromisoformat(candidate['created_at'].replace('Z', '+00:00'))
    frozen = datetime.fromisoformat(baseline['created_at'].replace('Z', '+00:00'))
    if start < frozen:
        return {'verdict': 'INCOMPARABLE', 'reasons': ['candidate_predates_frozen_baseline']}
    reasons, unsupported = [], []
    for item in candidate['scenario']['observables']:
        value = candidate['observed'][item['id']]
        rule = item['comparison']
        limit = baseline['limits'][item['id']]
        kind = rule['class']
        if kind in ('exact', 'behavioral'):
            if canonical(value) != canonical(limit['reference']):
                reasons.append(item['id'])
        elif kind in ('numeric', 'performance'):
            delta = value - limit['mean']
            change = abs(delta) if rule['direction'] == 'any' else delta if rule['direction'] == 'higher' else -delta
            if change > limit['slack']:
                reasons.append(item['id'])
        elif kind == 'visual':
            unsupported.append('visual_comparator_unavailable:' + item['id'])
    return {'verdict': 'INCOMPARABLE' if unsupported else 'REGRESSION' if reasons else 'CLEAN',
            'reasons': unsupported + reasons}


def aggregate(verdicts):
    require(bool(verdicts), 'history:empty')
    order = ('CLEAN', 'UNBASELINED', 'REGRESSION', 'FAILED', 'INCOMPARABLE', 'INTERRUPTED', 'CANCELLED', 'DEADLINE')
    require(all(value in order for value in verdicts), 'history:unknown_verdict')
    flaky = len(set(verdicts)) > 1
    worst = max(verdicts, key=order.index)
    return {'classification': 'FLAKY' if flaky else worst, 'flaky': flaky, 'worst_verdict': worst,
            'regression_detected': 'REGRESSION' in verdicts, 'gating_pass': all(value == 'CLEAN' for value in verdicts),
            'attempt_count': len(verdicts), 'failure_count': sum(value != 'CLEAN' for value in verdicts),
            'failure_probability': sum(value != 'CLEAN' for value in verdicts) / len(verdicts)}
