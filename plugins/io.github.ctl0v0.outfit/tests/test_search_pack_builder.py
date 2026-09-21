"""Public pack provenance, data boundaries, and failure-safe publication tests."""
import base64
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("search_pack_builder", ROOT / "scripts/build_search_pack.py")
pack = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pack)
COMMIT = "a" * 40
REPO = "https://github.com/example/plugin"
ITEM = {"repo": REPO, "listingCommit": COMMIT}


def file_info(text, path):
    raw = text.encode()
    return {"type": "file", "path": path, "name": path, "encoding": "base64", "size": len(raw),
            "sha": hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest(),
            "content": base64.b64encode(raw).decode()}


class FixtureClient:
    def __init__(self, spdx="MIT", public=True, notice=True):
        self.calls = []
        self.license = {**file_info("MIT License\nCopyright 2026 Example\nFixture license text\n", "LICENSE"),
                        "license": {"spdx_id": spdx}}
        self.readme = file_info("# Useful Plugin\n<!-- hidden -->\nA **searchable** README.\n![not fetched](evil.png)", "README.md")
        self.notice = file_info("Original attribution: Example\n", "NOTICE")
        self.public = public
        self.entries = [self.license, self.readme] + ([self.notice] if notice else [])

    def api(self, route):
        self.calls.append(route)
        if route == "/repos/example/plugin":
            return {"private": not self.public, "visibility": "public" if self.public else "private",
                    "full_name": "example/plugin"}
        assert route.endswith("?ref=" + COMMIT), route
        if "/license?" in route:
            return self.license
        if "/contents/?" in route:
            return self.entries
        if "/contents/README.md?" in route:
            return self.readme
        if "/contents/NOTICE?" in route:
            return self.notice
        raise AssertionError(route)

    def file(self, route, path, commit, expected_sha, maximum):
        return self.api(route + "/contents/" + path + "?ref=" + commit)


def snapshot():
    return pack.catalog_snapshot(pack.encoded({"generatedAt": "2026-09-18T00:00:00Z", "plugins": [
        {"id": "example", "sourceType": "community", "repo": REPO, "listingValidatedCommit": COMMIT,
         "name": "Example", "description": "A public example", "privateCache": "must not survive"},
    ]}), "2026-09-18T01:00:00Z")


class CollectionTests(unittest.TestCase):
    def test_shared_identity_and_normalization_with_preserved_notices(self):
        client = FixtureClient()
        row = pack.collect_record(client, ITEM)
        pack.validate_record(row)
        self.assertEqual(row["key"], hashlib.sha256((REPO.lower() + "\0" + COMMIT).encode()).hexdigest())
        self.assertEqual(row["body"], "useful plugin a searchable readme.")
        self.assertEqual(row["sourceNotices"][0]["text"], "Original attribution: Example\n")
        self.assertIn("Copyright 2026 Example", row["sourceLicenseText"])
        self.assertEqual(row["sourceSha256"], pack.digest(base64.b64decode(client.readme["content"])))
        self.assertEqual(row["license"], "MIT")

    def test_all_supported_spdx_ids_and_no_license_guessing(self):
        for spdx in pack.LICENSES:
            self.assertEqual(pack.collect_record(FixtureClient(spdx), ITEM)["state"], "indexed")
        for spdx in ("NOASSERTION", "GPL-3.0", "MPL-2.0", "CC-BY-4.0", "MIT OR GPL-3.0", "", "MIT-like"):
            with self.subTest(spdx=spdx):
                client = FixtureClient(spdx)
                row = pack.collect_record(client, ITEM)
                self.assertEqual(row["state"], "excluded")
                self.assertEqual(row["body"], "")
                self.assertEqual(len(client.calls), 2)

    def test_authenticated_private_repository_never_fetches_content(self):
        client = FixtureClient(public=False)
        row = pack.collect_record(client, ITEM)
        self.assertEqual(row["reason"], "not-public")
        self.assertEqual(len(client.calls), 1)

    def test_missing_license_excludes_without_fetching_readme(self):
        client = FixtureClient()
        original = client.api
        def api(route):
            if "/license?" in route:
                raise pack.Missing()
            return original(route)
        client.api = api
        self.assertEqual(pack.collect_record(client, ITEM)["reason"], "license-missing")

    def test_pinned_license_blob_mismatch_is_not_indexed(self):
        client = FixtureClient()
        client.entries = [{**client.license, "sha": "b" * 40}, client.readme]
        self.assertEqual(pack.collect_record(client, ITEM)["state"], "unavailable")

    def test_ambiguous_license_and_documentation_override_excluded(self):
        client = FixtureClient()
        client.entries.append(file_info("other grant", "COPYING"))
        self.assertEqual(pack.collect_record(client, ITEM)["reason"], "multiple-license-files")
        client = FixtureClient()
        client.readme = file_info("This documentation is licensed under a separate agreement.", "README.md")
        client.entries = [client.license, client.readme]
        self.assertEqual(pack.collect_record(client, ITEM)["reason"], "documentation-license-review")

    def test_failed_notice_cannot_silently_drop_attribution(self):
        client = FixtureClient()
        client.notice["sha"] = "0" * 40
        row = pack.collect_record(client, ITEM)
        self.assertEqual(row["state"], "unavailable")
        self.assertEqual(row["body"], "")

    def test_nested_readme_is_not_assumed_covered_by_root_license(self):
        client = FixtureClient()
        client.entries = [client.license]
        self.assertEqual(pack.collect_record(client, ITEM)["reason"], "root-readme-missing")

    def test_body_limit_and_truncation(self):
        client = FixtureClient()
        client.readme = file_info("Word " * 10_000, "README.md")
        client.entries = [client.license, client.readme]
        row = pack.collect_record(client, ITEM)
        self.assertLessEqual(len(row["body"]), 24_000)
        self.assertTrue(row["truncated"])
        pack.validate_record(row)

    def test_blob_binary_symlink_and_oversize_rejected(self):
        for value in (file_info("a\0b", "README.md"), {**file_info("hi", "README.md"), "type": "symlink"},
                      {**file_info("hi", "README.md"), "size": 1_000_000}):
            with self.assertRaises(pack.Unavailable):
                pack.content_file(value, 100)

    def test_minimal_catalog_round_trip_retains_raw_pin_name(self):
        value = snapshot()
        rows, _ = pack.backend().normalize_catalog(value)
        self.assertEqual(rows[0]["listingCommit"], COMMIT)
        self.assertEqual(value["plugins"][0]["listingValidatedCommit"], COMMIT)
        self.assertNotIn("privateCache", json.dumps(value))
        self.assertNotIn("_recommendationCache", json.dumps(value))

    def test_disallowed_urls_and_redirects_are_rejected_before_network(self):
        for url in ("http://api.github.com/repos/a/b", "https://evil.test/x", "https://token@api.github.com/x",
                    "https://github.com/other/repo/releases/download/v/a"):
            with self.assertRaises(pack.BuildError):
                pack.PublicClient("secret").get(url, 100, release=True)
        with self.assertRaises(pack.BuildError):
            pack.AssetRedirect().redirect_request(None, None, 302, "", {}, "https://evil.test/asset")

    def test_batched_visibility_gate_never_queries_private_tree(self):
        client = pack.PublicClient("fixture-token")
        with patch.object(client, "graphql", return_value={"r0": {
                "nameWithOwner": "example/plugin", "isPrivate": True, "visibility": "PRIVATE"}}) as query:
            client.preflight([ITEM])
        self.assertEqual(query.call_count, 1)
        self.assertNotIn("object(", query.call_args.args[0])
        self.assertEqual(pack.collect_record(client, ITEM)["reason"], "not-public")

    def test_public_metadata_batch_pins_tree_and_rejects_symlinks(self):
        client = pack.PublicClient("fixture-token")
        responses = [{"r0": {"nameWithOwner": "example/plugin", "isPrivate": False, "visibility": "PUBLIC"}},
                     {"r0": {"object": {"entries": [
                         {"name": "LICENSE", "oid": "b" * 40, "mode": 40960, "type": "blob"},
                     ]}}}]
        with patch.object(client, "graphql", side_effect=responses) as query:
            client.preflight([ITEM])
        self.assertIn(COMMIT + ":", query.call_args.args[0])
        entries = client.api("/repos/example/plugin/contents/?ref=" + COMMIT)
        self.assertEqual(entries[0]["type"], "other")

    def test_token_is_only_sent_to_github_api(self):
        from unittest.mock import MagicMock
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b"text"
        response.headers = {}
        with patch.object(pack.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = response
            client = pack.PublicClient("fixture-secret")
            client.get("https://raw.githubusercontent.com/example/plugin/" + COMMIT + "/README.md", 100)
            self.assertIsNone(opener.return_value.open.call_args.args[0].get_header("Authorization"))
            client.get("https://api.github.com/repos/example/plugin", 100)
            self.assertEqual(opener.return_value.open.call_args.args[0].get_header("Authorization"), "Bearer fixture-secret")


class BuildTests(unittest.TestCase):
    def build_fixture(self, directory, collect_side_effect=None, **overrides):
        catalog = Path(directory) / "catalog-input.json"
        catalog.write_bytes(pack.encoded(snapshot()))
        args = SimpleNamespace(output=str(Path(directory) / "pack"), state_dir=None, use_gh_auth=False,
                               catalog=str(catalog), write_catalog=None, catalog_only=False,
                               previous_public=False, max_documents=None, min_coverage=0.1, workers=1)
        for key, value in overrides.items():
            setattr(args, key, value)
        def git_metadata(argv, **_kwargs):
            # Fixture artifacts have deterministic provenance; do not depend on
            # the runner's checkout owner or process-wide Git safe-directory state.
            if argv == ["git", "rev-parse", "HEAD"]:
                return COMMIT + "\n"
            if argv == ["git", "status", "--porcelain", "--", "scripts/build_search_pack.py",
                        "scripts/outfit.py", ".github/workflows/search-pack.yml", "data/bootstrap-catalog.json"]:
                return b""
            raise AssertionError("Unexpected builder subprocess: " + repr(argv))
        with patch.object(pack, "collect_record", return_value=pack.collect_record(FixtureClient(), ITEM),
                          side_effect=collect_side_effect), \
             patch.object(pack.PublicClient, "preflight"), \
             patch.object(pack, "utc_now", return_value=datetime(2026, 9, 18, 1, 2, 3, tzinfo=timezone.utc)), \
             patch.object(pack.subprocess, "check_output", side_effect=git_metadata), \
             patch("builtins.print"):
            pack.build(args)
        return Path(args.output)

    def test_complete_pack_digest_catalog_and_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            output = self.build_fixture(directory)
            manifest, rows = pack.validate_pack(output)
            self.assertEqual(manifest["version"], "20260918T010203Z")
            self.assertTrue(manifest["complete"])
            self.assertTrue(manifest["publishable"])
            self.assertEqual(manifest["provenance"]["sourceCommit"], COMMIT)
            self.assertFalse(manifest["provenance"]["sourceDirty"])
            self.assertEqual(manifest["docCount"], len(rows))
            self.assertEqual(manifest["provenance"]["catalogSnapshotSha256"], pack.digest((output / "catalog.json").read_bytes()))
            asset = output / "search-pack-20260918T010203Z.jsonl.gz"
            asset.write_bytes(asset.read_bytes() + b"corruption")
            with self.assertRaisesRegex(pack.BuildError, "digest/length"):
                pack.validate_pack(output)

    def test_limit_is_never_publishable_even_if_it_covers_catalog(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, _ = pack.validate_pack(self.build_fixture(directory, max_documents=1))
            self.assertFalse(manifest["complete"])
            self.assertFalse(manifest["publishable"])

    def test_public_state_reuse_avoids_network(self):
        with tempfile.TemporaryDirectory() as directory:
            state = str(Path(directory) / "public-state")
            self.build_fixture(directory, state_dir=state)
            self.build_fixture(directory, state_dir=state, output=str(Path(directory) / "second"),
                               collect_side_effect=AssertionError("Unexpected source request"))

    def test_rate_limit_preserves_nonpublishable_inspection_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(pack.BuildError):
                self.build_fixture(directory, collect_side_effect=pack.RateLimited("budget exhausted"))
            manifest, rows = pack.validate_pack(Path(directory) / "pack")
            self.assertFalse(manifest["complete"])
            self.assertFalse(manifest["publishable"])
            self.assertEqual(rows, [])

    def test_coverage_gates_empty_partial_and_collapse(self):
        row = pack.collect_record(FixtureClient(), ITEM)
        with self.assertRaises(pack.BuildError):
            pack.check_coverage([], 0)
        with self.assertRaises(pack.BuildError):
            pack.check_coverage([row], 2)
        with self.assertRaises(pack.BuildError):
            pack.check_coverage([row], 1, {"docCount": 10, "stateCounts": {"indexed": 10}})
        unavailable = {**pack.initial_record(ITEM), "state": "unavailable"}
        with self.assertRaises(pack.BuildError):
            pack.check_coverage([row, unavailable], 2)

    def test_identity_and_legal_fields_mandatory(self):
        row = pack.collect_record(FixtureClient(), ITEM)
        for change in ({"key": "0" * 64}, {"sourceLicenseText": ""}, {"version": 999},
                       {"state": "excluded"}, {"body": "x" * 24_001}):
            with self.assertRaises(pack.BuildError):
                pack.validate_record({**row, **change})

    def test_import_does_not_run_desktop_or_user_store(self):
        runtime = pack.backend()
        with patch.object(runtime, "Store", side_effect=AssertionError("user store accessed")), \
             patch.object(runtime, "main", side_effect=AssertionError("runtime executed")):
            self.assertTrue(pack.backend().readme_key(ITEM))
            pack.collect_record(FixtureClient(), ITEM)


class PromotionTests(unittest.TestCase):
    def test_stage_failure_rolls_back_without_deleting_old_asset(self):
        old, staged = {"id": 10}, {"id": 20}
        with patch.object(pack, "rename_asset", side_effect=[None, pack.BuildError("failed"), None]) as rename, \
             patch.object(pack, "gh", return_value=json.dumps({"assets": []})):
            with self.assertRaises(pack.BuildError):
                pack.promote_manifest(old, staged, "20260918T010203Z")
        self.assertEqual(rename.call_args_list[-1].args, (10, "latest.json"))

    def test_lost_success_response_is_not_rolled_back(self):
        with patch.object(pack, "rename_asset", side_effect=[None, pack.BuildError("lost response")]) as rename, \
             patch.object(pack, "gh", return_value=json.dumps({"assets": [{"id": 20, "name": "latest.json"}]})):
            pack.promote_manifest({"id": 10}, {"id": 20}, "20260918T010203Z")
        self.assertEqual(rename.call_count, 2)

    def test_old_manifest_rename_failure_never_touches_candidate(self):
        with patch.object(pack, "rename_asset", side_effect=pack.BuildError("failed")) as rename, \
             patch.object(pack, "gh", return_value=json.dumps({"assets": [{"id": 10, "name": "latest.json"}]})):
            with self.assertRaises(pack.BuildError):
                pack.promote_manifest({"id": 10}, {"id": 20}, "20260918T010203Z")
        self.assertEqual(rename.call_count, 1)

    def test_lost_old_rename_response_restores_alias(self):
        with patch.object(pack, "rename_asset", side_effect=[pack.BuildError("lost response"), None]) as rename, \
             patch.object(pack, "gh", return_value=json.dumps({"assets": [{"id": 10, "name": "previous-before-v.json"}]})):
            with self.assertRaises(pack.BuildError):
                pack.promote_manifest({"id": 10}, {"id": 20}, "20260918T010203Z")
        self.assertEqual(rename.call_args_list[-1].args, (10, "latest.json"))


if __name__ == "__main__":
    unittest.main()
