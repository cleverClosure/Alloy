#!/usr/bin/env python3
"""Unsigned synthetic input for the unchanged launch compiler. Author: Timur Isaev."""
import base64
import hashlib
import json
from proof_support import PACKAGE


def canonical(value):
    # This fixture uses ASCII object keys, integers and strings only. It has no
    # float/UTF-16 ordering edge cases; the real compiler still validates bytes.
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def digest(value):
    return "sha256:" + hashlib.sha256(canonical(value)).hexdigest()


def launch_input(fixture, layer_digest, layer_size, lifetime=120, discovered=None):
    source = PACKAGE.parent / "profile-compiler/Tests/Fixtures/Launch"
    profile = json.loads((source / "profile.json").read_text())
    profile["game"]["canonicalId"] = "fixture"
    profile["runtime"]["generation"] = "rtg_service_fixture_001"
    profile["certification"]["level"] = "experimental"
    profile["runtime"]["layers"][0]["digest"] = layer_digest
    manifest = json.loads((source / "minimal-manifest.json").read_text())
    manifest["generationId"] = "rtg_service_fixture_001"
    manifest["components"][0]["digest"] = layer_digest
    manifest["components"][0]["size"] = layer_size
    manifest["activation"] = {"releaseRing": "development"}
    build = {"id": "service-fixture-build", "version": "1.0.0", "files": []}
    if discovered is not None:
        fingerprint = discovered["fingerprint"]
        profile["game"]["canonicalId"] = "steam-" + fingerprint["appid"]
        profile["game"]["storefronts"] = [{"kind": "steam", "appId": fingerprint["appid"]}]
        profile["selectors"]["gameBuild"] = {"manifestId": fingerprint["buildid"]}
        build = {"id": "steam:" + fingerprint["appid"] + ":" + fingerprint["buildid"] + ":"
                 + fingerprint["aggregate_sha256"], "manifestId": fingerprint["buildid"],
                 "files": fingerprint["files"]}
    metadata = {"profileDigest": digest(profile), "releaseRing": "development", "approvedCertification": "experimental",
                "gameAliases": [], "launcherAliases": [], "deniedMacOSBuilds": [], "requiredFeatures": []}
    host = fixture.request("host.info")
    for key in ("gpuFamilies", "features", "entitlements"):
        host[key] = sorted(set(host[key]))
    process_digest = "a" * 64
    processes = [{"path": "Game/Binaries/Win64/Game.exe", "sha256": process_digest,
                  "commandLine": "", "moduleFingerprints": []}]
    evidence = {
        "profileDigest": digest(profile), "manifestDigest": digest(manifest), "metadataDigest": digest(metadata),
        "gameBuildDigest": digest(build), "hostClassId": "local-unregistered:" + digest(host).split(":")[1],
        "matrixDigest": profile["certification"]["matrixDigest"], "lifecycle": "draft",
        "certificationExpiresAt": "2030-01-01T00:00:00Z", "fixtureCeilingsOnly": True,
        "ceilings": [{"provider": "metal12", "features": ["fixture.capability"], "limits": {"fixture.slots": 4}}],
        "masks": [{"id": "fixture-mask", "provider": "metal12", "features": ["fixture.capability"],
                   "limits": {"fixture.slots": 2}, "workaroundIds": ["wa_game"]}],
        "workarounds": [{"id": "wa_game", "owner": "Timur Isaev", "reason": "Synthetic service fixture",
                         "gameBuild": build["id"], "processPolicy": "game", "introducedInProfileRevision": 1,
                         "testEvidence": [profile["certification"]["matrixDigest"]],
                         "expiresAt": "2030-01-01T00:00:00Z", "removalCondition": "Remove the fixture",
                         "userVisibleRisk": False, "performanceRisk": "Fixture only"}],
        "providers": {item["name"]: {"component": item["name"], "directory": "R:\\providers\\" + item["name"]}
                      for item in manifest["components"]},
        "processDigests": {"game": process_digest}, "approvedDependencyDigests": [],
    }
    return {"profile": base64.b64encode(canonical(profile)).decode(),
            "manifest": base64.b64encode(canonical(manifest)).decode(),
            "metadata": base64.b64encode(canonical(metadata)).decode(),
            "evidence": base64.b64encode(canonical(evidence)).decode(),
            "build": build, "processes": processes,
            "volumes": {key: "fixture-volume-" + key for key in ("runtime", "game", "saves", "settings", "cache", "temp")},
            "validForSeconds": lifetime}

