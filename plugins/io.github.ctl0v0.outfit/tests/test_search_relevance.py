"""Fictional, local-only search evidence and quick-setup contract regressions."""
import json
from pathlib import Path
import statistics
import tempfile
import time
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app, ROOT


class SearchRelevanceTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.store = app.Store(Path(directory.name) / "cache")
        self.preferences = app.Store(Path(directory.name) / "config")
        self.addCleanup(self.store.close)
        self.addCleanup(self.preferences.close)
        self.fixture = json.loads((ROOT / "demo/fixtures/example.json").read_text())["catalog"]["plugins"][0]
        for name in ("fetch_bytes", "fetch_catalog", "fetch_readme", "fetch_search_readme",
                     "run_command", "scan_profile", "scan_inventory"):
            patch = mock.patch.object(app, name, side_effect=AssertionError("Live operation forbidden: " + name))
            patch.start()
            self.addCleanup(patch.stop)

    def catalog(self, *entries):
        raw = [{**self.fixture, "id": "example." + entry["slug"], "name": "Neutral utility",
                "description": "Fictional utility", "category": "Productivity", "tags": [], "stars": 0,
                "repo": f"https://github.com/fictional/plugin-{index}",
                "listingValidatedCommit": f"{index + 1:040x}", **entry}
               for index, entry in enumerate(entries)]
        self.items, generated = app.normalize_catalog({"plugins": raw})
        app.save_catalog(self.store, self.items, generated, 100)
        with app.ReadmeIndex(self.store, create=True) as index:
            for item, entry in zip(self.items, entries):
                if "body" in entry:
                    index.put(app.readme_key(item), {"ok": True, "searchText": entry["body"]}, 100)

    def query(self, text="", **values):
        result = app.run({"action": "quick-setup", "localOnly": True, "setupQuery": text,
                          "setupSort": "relevance", **values}, self.store, now=200,
                         preferences_store=self.preferences)
        self.assertFalse(result["error"])
        self.assertFalse(result["readmeIndex"]["error"])
        return json.loads(json.dumps(result))["setup"]

    def ids(self, result):
        return [row["id"].removeprefix("example.") for row in result["rows"]]

    def test_exact_name_and_id_beat_popular_incidental_readme(self):
        self.catalog({"slug": "readme", "name": "Popular tool", "stars": 999999,
                      "body": "Nebula " * 100},
                     {"slug": "prefix", "name": "Nebula companion", "stars": 900},
                     {"slug": "name", "name": "Ｎｅｂｕｌａ"},
                     {"slug": "id", "body": "example.name"})
        result = self.query("NEBULA")
        self.assertEqual(self.ids(result), ["name", "prefix", "readme"])
        self.assertEqual(result["search"], {"active": True, "mode": "complete", "suggestion": None})
        self.assertEqual(self.ids(self.query("example.name"))[0], "name")
        self.assertEqual(result["rows"][0]["searchSnippet"], "")

    def test_midi_controller_requires_all_words_before_sorting(self):
        self.catalog({"slug": "one", "name": "MIDI monitor", "stars": 9999},
                     {"slug": "both", "name": "MIDI Controller"},
                     {"slug": "readme", "name": "Synth", "body": "MIDI controller support"},
                     {"slug": "other", "description": "Controller", "stars": 999})
        result = self.query("MIDI controller")
        self.assertEqual(self.ids(result), ["both", "readme"])
        self.assertEqual(result["search"]["mode"], "complete")
        legacy = app.ranked_rows(self.items, [], set(), "MIDI controller", "")
        self.assertEqual([row["id"] for row in legacy], ["example.both"])

    def test_partial_fallback_is_explicit_and_never_claims_completion(self):
        self.catalog({"slug": "one", "name": "MIDI monitor"},
                     {"slug": "other", "description": "Controller utility"})
        result = self.query("MIDI controller")
        self.assertEqual(set(self.ids(result)), {"one", "other"})
        self.assertEqual(result["search"]["mode"], "partial")
        self.assertIsNone(result["search"]["suggestion"])
        self.assertTrue(all(row["searchReason"].startswith("Partial match (1/2 words)") for row in result["rows"]))

    def test_boundary_aware_readme_and_metadata(self):
        self.catalog({"slug": "chair", "description": "Armchair tools", "body": "chair repair airpods"},
                     {"slug": "atmosphere", "body": "clean air quality"},
                     {"slug": "name", "name": "AirPods controller"})
        self.assertEqual(self.ids(self.query("air")), ["name", "atmosphere"])
        self.assertEqual(self.query("repairing")["total"], 0)

    def test_only_final_name_word_gets_prefix_matching(self):
        self.catalog({"slug": "name", "name": "MIDI Controller"},
                     {"slug": "description", "description": "MIDI Controller"},
                     {"slug": "readme", "body": "MIDI Controller"})
        self.assertEqual(self.ids(self.query("midi contr")), ["name"])
        early = self.query("mid controller")
        self.assertEqual(early["search"]["mode"], "partial")
        self.assertTrue(all(not app.search_evidence(item, "mid controller")["complete"] for item in self.items))
        self.assertEqual(self.ids(self.query("mid")), ["name"])

    def test_crossfield_completion_beats_partial(self):
        self.catalog({"slug": "split", "name": "MIDI helper", "body": "USB controller integration"},
                     {"slug": "metadata", "name": "MIDI tools", "tags": ["controller"]},
                     {"slug": "one", "name": "Controller", "stars": 99999})
        result = self.query("midi controller")
        self.assertEqual(self.ids(result), ["metadata", "split"])
        self.assertEqual(result["rows"][0]["searchSnippet"], "")
        self.assertIn("controller", result["rows"][1]["searchSnippet"])
        self.assertIn("Listing and README", result["rows"][1]["searchReason"])

    def test_title_plus_short_readme_term_is_not_lost_by_fts_nomination(self):
        self.catalog({"slug": "mixed", "name": "Controller", "body": "An AI integration"},
                     {"slug": "incidental", "body": "controller chair"})
        self.assertEqual(self.ids(self.query("controller ai")), ["mixed"])
        self.assertEqual(self.ids(self.query("controller AI")), ["mixed"])

    def test_unicode_short_words_and_normalization(self):
        self.catalog({"slug": "jp", "name": "Controller", "body": "音 楽 controls"},
                     {"slug": "accent", "name": "Café"},
                     {"slug": "german", "body": "Straße controls"})
        for query, expected in (("音", "jp"), ("controller 音", "jp"), ("Ｃａｆｅ́", "accent"),
                                ("STRASSE", "german"), ("音 楽", "jp")):
            with self.subTest(query=query):
                self.assertEqual(self.ids(self.query(query)), [expected])
                self.assertEqual(self.query(query)["search"]["mode"], "complete")

    def test_stopwords_empty_and_punctuation_have_sensible_modes(self):
        self.catalog({"slug": "match", "name": "MIDI Controller", "description": "The utility"},
                     {"slug": "unrelated"})
        self.assertEqual(self.ids(self.query("for the MIDI and controller")), ["match"])
        self.assertEqual(self.ids(self.query("the")), ["match"])
        self.assertEqual(self.query("   ")["search"], {"active": False, "mode": "none", "suggestion": None})
        self.assertEqual(self.query("!!!")["search"], {"active": True, "mode": "none", "suggestion": None})
        self.assertEqual(self.query("!!!")["total"], 0)

    def test_phrase_and_proximity_boost_within_tier_without_popularity_override(self):
        self.catalog({"slug": "far", "name": "A tool", "body": "rare " + "filler " * 40 + "orbital phrase", "stars": 999999},
                     {"slug": "near", "name": "B tool", "body": "rare and orbital phrase"},
                     {"slug": "phrase", "name": "Z tool", "body": "rare orbital phrase"})
        result = self.query("rare orbital phrase")
        self.assertEqual(self.ids(result), ["phrase", "near", "far"])
        self.assertIn("rare orbital phrase", result["rows"][0]["searchSnippet"])

    def test_popularity_only_breaks_equal_strong_relevance(self):
        self.catalog({"slug": "low", "name": "Z tool", "description": "Orbital", "stars": 0},
                     {"slug": "high", "name": "A tool", "description": "Orbital", "stars": 50},
                     {"slug": "readme-low", "name": "A readme", "body": "Orbital"},
                     {"slug": "readme-high", "name": "Z readme", "body": "Orbital", "stars": 99999})
        self.assertEqual(self.ids(self.query("orbital")), ["high", "low", "readme-low", "readme-high"])

    def test_explicit_stars_sort_is_global_before_pagination(self):
        self.catalog(*[{"slug": f"item-{i}", "name": "MIDI Controller" if i == 0 else f"MIDI Controller {i}",
                       "stars": i} for i in range(30)])
        pages = [self.query("midi controller", setupSort="stars", setupPage=page, setupPageSize=12)
                 for page in (1, 2, 3)]
        self.assertEqual([row["stars"] for page in pages for row in page["rows"]], list(reversed(range(30))))
        self.assertEqual(self.ids(self.query("midi controller"))[0], "item-0")

    def test_hard_filters_determine_completion_and_preserve_status_category(self):
        self.catalog({"slug": "complete", "name": "MIDI controller", "category": "Hardware"},
                     {"slug": "partial", "name": "MIDI helper", "category": "Productivity"})
        result = self.query("midi controller", setupCategory="Productivity", setupInstallFilter="installed",
                            installed=["example.partial"])
        self.assertEqual(self.ids(result), ["partial"])
        self.assertEqual(result["search"]["mode"], "partial")
        self.assertEqual(self.query("midi controller", setupCategory="Removed category")["total"], 0)
        self.assertEqual(self.query("midi controller", setupPartyFilter="first-party")["total"], 0)
        self.assertEqual(self.query("midi controller", setupHardwareOnly=True)["total"], 0)

    def test_selected_services_are_or_and_other_filters_are_and(self):
        self.catalog({"slug": "spotify", "name": "MIDI helper", "tags": ["spotify"]},
                     {"slug": "github", "name": "MIDI helper", "tags": ["github notifications"]},
                     {"slug": "outside", "name": "MIDI controller"})
        result = self.query("midi controller", setupServices=["spotify", "github"])
        self.assertEqual(set(self.ids(result)), {"spotify", "github"})
        self.assertEqual(result["search"]["mode"], "partial")
        result = self.query("midi controller", setupServices=["spotify", "github"],
                            setupInstallFilter="installed", installed=["example.spotify", "example.outside"])
        self.assertEqual(self.ids(result), ["spotify"])

    def test_saved_interest_filter_is_not_relaxed(self):
        self.catalog({"slug": "inside", "name": "MIDI helper", "description": "astronomy"},
                     {"slug": "outside", "name": "MIDI controller"})
        key = "interest-" + "a" * 32
        result = self.query("midi controller", setupServices=[key], setupInterestCriteria=[
            {"key": key, "criterion": {"kind": "topic", "label": "Astronomy", "terms": ["astronomy"]}}])
        self.assertEqual(self.ids(result), ["inside"])
        self.assertEqual(result["search"]["mode"], "partial")
        self.assertEqual(self.query("midi controller", setupServices=[key])["total"], 0)

    def test_excerpts_are_bounded_plain_text_and_only_for_displayed_readme_evidence(self):
        self.catalog(*[{"slug": f"item-{i}", "name": f"Tool {i:02d}",
                       "body": "Introduction " * 200 + "<b>orbitalwidget</b> &lt;img src=x onerror=oops&gt; " + "details " * 200}
                      for i in range(25)],
                     {"slug": "metadata", "name": "orbitalwidget", "body": "orbitalwidget " * 100})
        with mock.patch.object(app, "_search_excerpt", wraps=app._search_excerpt) as excerpt:
            first = self.query("orbitalwidget", setupPageSize=12)
            self.assertEqual(excerpt.call_count, 11)
        self.assertEqual(first["rows"][0]["searchSnippet"], "")
        for row in first["rows"][1:]:
            self.assertIn("orbitalwidget", row["searchSnippet"])
            self.assertLessEqual(len(row["searchSnippet"]), 240)
            self.assertNotIn("<", row["searchSnippet"])
            self.assertNotIn(">", row["searchSnippet"])
            self.assertNotIn("onerror", row["searchSnippet"])
        with mock.patch.object(app, "_search_excerpt", side_effect=AssertionError("Warm excerpt rebuilt")):
            self.assertEqual(self.query("orbitalwidget", setupPageSize=12), first)
        with mock.patch.object(app, "_search_excerpt", wraps=app._search_excerpt) as excerpt:
            self.query("orbitalwidget", setupPageSize=12, setupPage=2)
            self.assertEqual(excerpt.call_count, 12)

    def test_metadata_complete_result_has_no_redundant_readme_excerpt(self):
        self.catalog({"slug": "metadata", "description": "MIDI", "tags": ["controller"],
                      "body": "MIDI controller " * 100})
        with mock.patch.object(app, "_search_excerpt", side_effect=AssertionError("Redundant excerpt")):
            result = self.query("midi controller")
        self.assertEqual(result["rows"][0]["searchSnippet"], "")
        self.assertNotIn("README", result["rows"][0]["searchReason"])

    def test_typo_suggestion_is_explicit_bounded_and_never_rewrites(self):
        self.catalog({"slug": "nebula", "name": "Nebula"},
                     {"slug": "long", "name": "Constellation"})
        result = self.query("nebla")
        self.assertEqual(result["search"], {"active": True, "mode": "none",
                         "suggestion": {"query": "Nebula", "label": "Did you mean Nebula?"}})
        self.assertEqual(result["query"], "nebla")
        self.assertEqual(result["rows"], [])
        self.assertEqual(self.query("Neblua")["search"]["suggestion"]["query"], "Nebula")
        self.assertEqual(self.query("constelation")["search"]["suggestion"]["query"], "Constellation")
        for text in ("neb", "x" * 65, "a b c d", "completelyunrelated"):
            self.assertIsNone(self.query(text)["search"]["suggestion"])

    def test_suggestion_uses_curated_service_names_and_respects_hard_filters(self):
        self.catalog({"slug": "music", "name": "Music helper", "tags": ["spotify"], "category": "Productivity"},
                     {"slug": "other", "category": "Hardware"})
        self.assertEqual(self.query("spotfy")["search"]["suggestion"]["query"], "Spotify")
        self.assertIsNone(self.query("spotfy", setupCategory="Hardware")["search"]["suggestion"])
        self.assertIsNone(self.query("spotfy", setupInstallFilter="installed")["search"]["suggestion"])
        result = self.query("spotify", setupCategory="Hardware")
        self.assertEqual(result["total"], 0)
        self.assertEqual(result["category"], "Hardware")

    def test_good_complete_or_partial_queries_do_not_get_typo_noise(self):
        self.catalog({"slug": "name", "name": "Nebula"},
                     {"slug": "exact", "description": "nebla"})
        for text in ("Nebula", "nebla", "nebula missing"):
            self.assertIsNone(self.query(text)["search"]["suggestion"])

    def test_index_and_metadata_edits_invalidate_search_and_excerpt_caches(self):
        self.catalog({"slug": "target", "body": "old orbitalwidget prose"})
        old = self.query("orbitalwidget")
        with app.ReadmeIndex(self.store, create=True) as writer:
            writer.put(app.readme_key(self.items[0]), {"ok": True, "searchText": "new orbitalwidget prose"}, 201)
        self.assertNotEqual(old["rows"][0]["searchSnippet"], self.query("orbitalwidget")["rows"][0]["searchSnippet"])
        self.items[0]["name"] = "Orbitalwidget"
        app.save_catalog(self.store, self.items, "new", 201)
        self.assertEqual(self.query("orbitalwidget")["rows"][0]["searchSnippet"], "")
        self.items[0].update(name="Unrelated", listingCommit="f" * 40)
        app.save_catalog(self.store, self.items, "newer", 202)
        self.assertEqual(self.query("orbitalwidget")["total"], 0)

    def test_readme_setting_disables_search_evidence_and_snippets(self):
        self.catalog({"slug": "target", "body": "orbitalwidget"})
        self.assertEqual(self.query("orbitalwidget")["total"], 1)
        app.save_preferences(self.preferences, {**app.DEFAULT_PREFERENCES, "readmeEnrichment": False})
        self.assertEqual(self.query("orbitalwidget")["total"], 0)

    def test_legacy_search_score_tuple_api(self):
        self.catalog({"slug": "target", "name": "MIDI Controller"})
        score, reason = app.search_score(self.items[0], "midi controller")
        self.assertGreater(score, 0)
        self.assertEqual(reason, "Exact name or ID match")
        self.assertEqual(app.search_score(self.items[0], "unrelated"), (0, ""))

    def test_exact_punctuated_name_still_has_complete_coverage(self):
        self.catalog({"slug": "target", "name": "Sound_Control"},
                     {"slug": "other", "body": "sound control"})
        result = self.query("sound_control")
        self.assertEqual(result["search"]["mode"], "complete")
        self.assertEqual(self.ids(result)[0], "target")
        self.assertEqual(result["rows"][0]["searchReason"], "Exact name or ID match")

    def test_warm_fixture_queries_are_cached_local_and_bounded(self):
        self.catalog(*[{"slug": f"item-{i}", "name": f"Controller {i}",
                       "body": "Fictional instructions. " * 100 + (" AI orbitalwidget" if i % 3 == 0 else " MIDI")}
                      for i in range(72)])
        requests = ("controller", "orbitalwidget", "controller ai")
        expected = {query: self.query(query, setupPageSize=60) for query in requests}
        samples = []
        with mock.patch.object(app, "ReadmeIndex", side_effect=AssertionError("Warm query reopened index")):
            for _ in range(3):
                for query in requests:
                    start = time.perf_counter()
                    self.assertEqual(self.query(query, setupPageSize=60), expected[query])
                    samples.append(time.perf_counter() - start)
        self.assertLess(statistics.median(samples), 1.0)  # Generous regression guard, not a hardware SLA.
        self.assertLessEqual(len(self.store.memory["indexQueries"]), 4)
        self.assertLessEqual(len(self.store.memory["searchSnippets"]), app.MAX_SETUP_PAGE_SIZE * 4)
        for item in app.load_catalog(self.store)[0]:
            self.assertLessEqual(len(item["_searchEvidenceCache"]), 4)


if __name__ == "__main__":
    unittest.main()
