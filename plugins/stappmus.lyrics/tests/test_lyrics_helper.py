#!/usr/bin/env python3

import importlib.machinery
import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("omasing_lyrics", str(ROOT / "omasing-lyrics"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
lyrics = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(lyrics)


STUDIO_LYRICS = """[Verse 1]
Paper moon above the quiet street
We count the windows underneath

[Chorus]
Carry the lantern, carry it home
No one should walk this road alone

[Verse 2]
Morning arrives in a silver coat
We fold our wishes in a paper boat

[Chorus]
Carry the lantern, carry it home
No one should walk this road alone"""

FORMATTED_STUDIO_LYRICS = """Paper moon above the quiet street
We count the windows underneath

Carry the lantern, carry it home
No one should walk this road alone

Morning arrives in a silver coat
We fold our wishes in a paper boat

Carry the lantern, carry it home
No one should walk this road alone"""

OTHER_LYRICS = """Copper wires hum beneath the rain
The midnight bus forgets my name

Turn every page and close the door
Nothing is waiting there anymore"""


def lrclib_candidate(track="Lantern", album="Quiet Hours", duration=240, text=STUDIO_LYRICS,
                      exact=True, synced=True):
    return {
        "provider": "LRCLIB",
        "providerKey": "lrclib",
        "providerId": "42",
        "track": track,
        "artist": "The Paper Boats",
        "album": album,
        "duration": duration,
        "instrumental": False,
        "plain": text,
        "synced": "[00:01.00]Paper moon above the quiet street" if synced else "",
        "exact": exact,
    }


def ovh_candidate(text=FORMATTED_STUDIO_LYRICS):
    return {
        "provider": "Lyrics.ovh",
        "providerKey": "lyrics-ovh",
        "providerId": "",
        "track": "Lantern (2024 Remaster)",
        "artist": "The Paper Boats",
        "album": "Quiet Hours",
        "duration": 240,
        "instrumental": False,
        "plain": text,
        "synced": "",
        "exact": True,
    }


SONG = {
    "id": "deezer:7",
    "title": "Lantern (2024 Remaster)",
    "lookupTitle": "Lantern",
    "artist": "The Paper Boats",
    "album": "Quiet Hours",
    "duration": 240,
    "lrclibId": 42,
    "instrumental": False,
}


class NormalizationTests(unittest.TestCase):
    def test_straight_and_curly_apostrophes_match_unpunctuated_queries(self):
        self.assertEqual(lyrics.normalized("It's Time"), "its time")
        self.assertEqual(lyrics.normalized("It’s Time"), "its time")

    def test_canonical_title_removes_artist_prefix_and_release_noise(self):
        self.assertEqual(
            lyrics.canonical_title(
                "The Paper Boats - Lantern (2024 Remastered)", "The Paper Boats"
            ),
            "Lantern",
        )

    def test_live_and_remaster_are_not_treated_as_the_same_kind_of_variant(self):
        self.assertEqual(lyrics.variant_tags("Lantern (2024 Remaster)"), set())
        self.assertEqual(lyrics.variant_tags("Lantern (Live in Oslo)"), {"live"})

    def test_synced_lyrics_become_readable_plain_text(self):
        synced = "[ar:Example]\n[00:01.00]First invented line\n[00:03.50]Second invented line"
        self.assertEqual(
            lyrics.plain_from_synced(synced),
            "First invented line\nSecond invented line",
        )

    def test_plain_lyrics_drop_misplaced_lrc_control_tags(self):
        plain = (
            "[offset:-47682]\n"
            "[ar:Example]\n"
            "[00:01.00]First invented line\n"
            "[00:03.50]Second invented line"
        )
        self.assertEqual(
            lyrics.clean_lyrics(plain),
            "First invented line\nSecond invented line",
        )


class MatchingTests(unittest.TestCase):
    def test_studio_selection_strongly_penalizes_live_candidate(self):
        studio = lrclib_candidate()
        live = lrclib_candidate(
            track="Lantern (Live in Oslo)", album="Northern Tour (Live)", duration=315
        )
        self.assertGreater(
            lyrics.metadata_score(SONG, studio),
            lyrics.metadata_score(SONG, live) + 0.5,
        )

    def test_live_selection_prefers_the_live_candidate(self):
        selected = dict(SONG)
        selected.update(
            title="Lantern (Live in Oslo)", album="Northern Tour (Live)", duration=315
        )
        studio = lrclib_candidate()
        live = lrclib_candidate(
            track="Lantern (Live in Oslo)", album="Northern Tour (Live)", duration=315
        )
        self.assertGreater(
            lyrics.metadata_score(selected, live),
            lyrics.metadata_score(selected, studio) + 0.5,
        )

    def test_formatting_differences_still_produce_high_text_agreement(self):
        self.assertGreater(
            lyrics.lyrics_similarity(STUDIO_LYRICS, FORMATTED_STUDIO_LYRICS), 0.90
        )
        self.assertLess(lyrics.lyrics_similarity(STUDIO_LYRICS, OTHER_LYRICS), 0.35)

    def test_two_agreeing_providers_are_reported_as_verified(self):
        result = lyrics.choose_best_candidate(
            SONG,
            [lrclib_candidate(), ovh_candidate()],
            ["LRCLIB", "Lyrics.ovh"],
        )
        self.assertEqual(result["state"], "ready")
        self.assertEqual(result["source"], "LRCLIB")
        self.assertEqual(result["verification"]["level"], "verified")
        self.assertEqual(result["plainLyrics"], STUDIO_LYRICS)

    def test_disagreement_is_exposed_instead_of_claiming_verification(self):
        result = lyrics.choose_best_candidate(
            SONG,
            [lrclib_candidate(), ovh_candidate(OTHER_LYRICS)],
            ["LRCLIB", "Lyrics.ovh"],
        )
        self.assertEqual(result["state"], "ready")
        self.assertEqual(result["verification"]["level"], "conflict")

    def test_one_provider_is_labeled_single_source(self):
        result = lyrics.choose_best_candidate(SONG, [lrclib_candidate()], ["LRCLIB"])
        self.assertEqual(result["verification"]["level"], "single")


class SearchTests(unittest.TestCase):
    def test_deezer_popularity_rank_is_preserved_for_catalog_sorting(self):
        parsed = lyrics.parse_deezer_results(
            {
                "data": [
                    {
                        "id": 1,
                        "title": "Lantern",
                        "title_short": "Lantern",
                        "artist": {"name": "The Paper Boats"},
                        "album": {"title": "Quiet Hours"},
                        "duration": 240,
                        "rank": 799104,
                    }
                ]
            }
        )
        self.assertEqual(parsed[0]["popularity"], 799104)

    def test_popularity_breaks_ambiguous_exact_title_searches(self):
        popular = {
            "id": "deezer:1", "source": "Deezer", "title": "It's Time",
            "lookupTitle": "It's Time", "artist": "Imagine Dragons",
            "album": "Night Visions", "duration": 240, "durationLabel": "4:00",
            "popularity": 799104, "coverUrl": "cover", "lrclibId": 0,
            "hasSynced": False, "instrumental": False,
        }
        less_popular = dict(popular)
        less_popular.update(
            id="deezer:2", artist="Nas", album="Illmatic",
            popularity=230440
        )
        ranked = lyrics.merge_search_results(
            "its time", [[less_popular, popular]]
        )
        self.assertEqual(ranked[0]["artist"], "Imagine Dragons")

    def test_exact_title_relevance_is_not_biased_toward_short_artist_names(self):
        long_artist = {
            "source": "Deezer", "title": "Creep", "artist": "Radiohead",
            "album": "Pablo Honey", "duration": 238, "hasSynced": False,
        }
        short_artist = dict(long_artist)
        short_artist.update(artist="TLC", album="CrazySexyCool")
        self.assertAlmostEqual(
            lyrics.search_result_score("creep", long_artist),
            lyrics.search_result_score("creep", short_artist),
        )

    def test_exact_title_does_not_reward_repeated_artist_words_or_synced_state(self):
        ordinary = {
            "source": "Deezer", "title": "It's Time", "artist": "Bobby Alu",
            "album": "Flow", "duration": 226, "hasSynced": False,
        }
        repeated_word = dict(ordinary)
        repeated_word.update(artist="Nourished by Time", hasSynced=True)
        self.assertAlmostEqual(
            lyrics.search_result_score("its time", ordinary),
            lyrics.search_result_score("its time", repeated_word),
        )

    def test_artist_qualified_query_beats_raw_popularity(self):
        popular = {
            "id": "deezer:1", "source": "Deezer", "title": "It's Time",
            "lookupTitle": "It's Time", "artist": "Imagine Dragons",
            "album": "Night Visions", "duration": 240, "durationLabel": "4:00",
            "popularity": 799104, "coverUrl": "cover", "lrclibId": 0,
            "hasSynced": False, "instrumental": False,
        }
        requested_artist = dict(popular)
        requested_artist.update(
            id="deezer:2", artist="Nas", album="Illmatic",
            popularity=230440
        )
        ranked = lyrics.merge_search_results(
            "its time nas", [[popular, requested_artist]]
        )
        self.assertEqual(ranked[0]["artist"], "Nas")

    def test_popularity_cannot_make_a_partial_title_beat_an_exact_title(self):
        exact = {
            "id": "lrclib:1", "source": "LRCLIB", "title": "Lantern",
            "lookupTitle": "Lantern", "artist": "The Paper Boats",
            "album": "Quiet Hours", "duration": 240, "durationLabel": "4:00",
            "popularity": 0, "coverUrl": "", "lrclibId": 1,
            "hasSynced": True, "instrumental": False,
        }
        popular_partial = dict(exact)
        popular_partial.update(
            id="deezer:2", source="Deezer", title="Lantern Lights",
            lookupTitle="Lantern Lights", artist="Somebody Else",
            popularity=1000000, coverUrl="cover", lrclibId=0,
            hasSynced=False,
        )
        ranked = lyrics.merge_search_results(
            "lantern", [[popular_partial, exact]]
        )
        self.assertEqual(ranked[0]["id"], "lrclib:1")

    def test_unqualified_search_places_studio_recording_before_live_recording(self):
        studio = {
            "id": "deezer:1", "source": "Deezer", "title": "Lantern",
            "lookupTitle": "Lantern", "artist": "The Paper Boats",
            "album": "Quiet Hours", "duration": 240, "durationLabel": "4:00",
            "coverUrl": "cover", "lrclibId": 0, "hasSynced": False,
            "instrumental": False,
        }
        live = dict(studio)
        live.update(
            id="deezer:2", title="Lantern (Live in Oslo)",
            album="Northern Tour (Live)", duration=315, durationLabel="5:15"
        )
        ranked = lyrics.merge_search_results("lantern paper boats", [[live, studio]])
        self.assertEqual(ranked[0]["id"], "deezer:1")

    def test_title_that_mentions_the_wanted_artist_does_not_beat_the_real_artist(self):
        correct = {
            "id": "deezer:1", "source": "Deezer", "title": "Lantern",
            "lookupTitle": "Lantern", "artist": "The Paper Boats",
            "album": "Quiet Hours", "duration": 240, "durationLabel": "4:00",
            "coverUrl": "cover", "lrclibId": 0, "hasSynced": False,
            "instrumental": False,
        }
        wrong_artist = dict(correct)
        wrong_artist.update(
            id="lrclib:9", source="LRCLIB",
            title="The Paper Boats - Lantern (Deluxe Version)", artist="Drood",
            album="The Paper Boats - Lantern", coverUrl="", lrclibId=9
        )
        ranked = lyrics.merge_search_results(
            "the paper boats lantern", [[wrong_artist, correct]]
        )
        self.assertEqual(ranked[0]["id"], "deezer:1")

    def test_catalog_duplicates_merge_cover_art_and_lrclib_id(self):
        deezer = {
            "id": "deezer:1", "source": "Deezer", "title": "Lantern",
            "lookupTitle": "Lantern", "artist": "The Paper Boats",
            "album": "Quiet Hours", "duration": 240, "durationLabel": "4:00",
            "coverUrl": "cover", "lrclibId": 0, "hasSynced": False,
            "instrumental": False,
        }
        lrclib = dict(deezer)
        lrclib.update(
            id="lrclib:42", source="LRCLIB", coverUrl="", lrclibId=42,
            hasSynced=True
        )
        merged = lyrics.merge_search_results("lantern", [[lrclib], [deezer]])
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0]["coverUrl"], "cover")
        self.assertEqual(merged[0]["lrclibId"], 42)
        self.assertTrue(merged[0]["hasSynced"])


class LyricsOvhFallbackTests(unittest.TestCase):
    class MissingClient:
        def __init__(self):
            self.urls = []

        def get_json(self, url):
            self.urls.append(url)
            raise lyrics.ProviderNotFound("no match")

    def test_explicit_live_recording_never_falls_back_to_studio_title(self):
        selected = dict(SONG)
        selected.update(title="Lantern (Live in Oslo)", lookupTitle="Lantern")
        client = self.MissingClient()
        with self.assertRaises(lyrics.ProviderNotFound):
            lyrics._lyrics_ovh(client, selected)
        self.assertEqual(len(client.urls), 1)

    def test_remaster_can_fall_back_to_lyrically_equivalent_base_title(self):
        client = self.MissingClient()
        with self.assertRaises(lyrics.ProviderNotFound):
            lyrics._lyrics_ovh(client, SONG)
        self.assertGreaterEqual(len(client.urls), 2)


if __name__ == "__main__":
    unittest.main()
