from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app, ROOT


class ReadmeDocumentTests(unittest.TestCase):
    def setUp(self):
        self.item = {"owner": "example", "repoName": "reading", "listingCommit": "a" * 40}

    def nodes(self, value):
        if isinstance(value, dict):
            yield value
            for child in value.values():
                yield from self.nodes(child)
        elif isinstance(value, list):
            for child in value:
                yield from self.nodes(child)

    def test_common_blocks_preserve_format_and_literal_code(self):
        source = r"""# Reading **well**

Useful *words* and `some_code`, with ~~old~~ instructions.

## Setup

- First
  - Nested
1. Ordered

> A note

```sh
printf '<img src="https://tracker.invalid/pixel">'
![literal](https://tracker.invalid/image)
```

| Feature | Value |
| --- | :---: |
| **Theme** | `a|b` and a\|b |

---
"""
        blocks = app.readme_document(source, self.item)
        self.assertEqual([b["kind"] for b in blocks],
                         ["heading", "paragraph", "heading", "list", "list", "list", "quote", "code", "table", "rule"])
        self.assertEqual(blocks[4]["depth"], 1)
        self.assertEqual(blocks[5]["marker"], "1.")
        self.assertIn('<img src="https://tracker.invalid/pixel">', blocks[7]["text"])
        self.assertEqual(len(blocks[8]["rows"][1]), 2)
        self.assertTrue({"strong", "em", "code", "strike"}.issubset({n["kind"] for n in self.nodes(blocks) if "kind" in n}))

    def test_images_html_linked_badges_and_reference_images_are_removed(self):
        source = """Before ![alt [nested]](https://tracker.invalid/a_(b).png "title") after.
[![badge](https://tracker.invalid/pixel)](https://tracker.invalid/click)
![reference][image] ![image][] ![image]
<picture><source srcset="https://tracker.invalid/a"><img title=">" src="file:///etc/passwd"></picture>
<script>alert('bad')</script><iframe src="https://tracker.invalid/frame">hidden</iframe>

[image]: https://tracker.invalid/reference.png
"""
        result = json.dumps(app.readme_document(source, self.item))
        self.assertNotIn("tracker.invalid", result)
        self.assertNotIn("file:", result)
        self.assertNotIn("alert", result)
        self.assertNotIn("<img", result)
        self.assertIn("Before ", result)
        self.assertIn(" after.", result)

    def test_only_secure_explicit_links_with_pinned_relative_and_anchor_targets(self):
        source = """[Guide](docs/guide_(v2).md#install) [Here](#setup) [Root](/LICENSE)
[External](https://example.org/guide?q=one&x=two) <https://example.org/auto>
[Reference][guide]
[guide]: docs/reference.md
"""
        links = [n["url"] for n in self.nodes(app.readme_document(source, self.item)) if n.get("kind") == "link"]
        base = "https://github.com/example/reading/blob/" + "a" * 40 + "/"
        self.assertEqual(links, [base + "docs/guide_(v2).md#install", base + "README.md#setup", base + "LICENSE",
                                 "https://example.org/guide?q=one&x=two", "https://example.org/auto", base + "docs/reference.md"])
        for bad in ["http://example.org", "javascript:alert(1)", "data:text/html,bad", "file:///etc/passwd",
                    "//example.org/path", "https://user:pass@example.org", "https://example.org:99/path",
                    "https://example.org/%0aBAD", "https://example.org\\evil", "https://example.org/%5cBAD",
                    "../main/README.md", "%2e%2e/main/README.md", "https://[broken", "mailto:hello@example.org"]:
            with self.subTest(bad=bad):
                self.assertEqual(app.readme_link(bad, self.item), "")
                blocks = app.readme_document("[Safe label](" + bad + ")", self.item)
                self.assertFalse(any(n.get("kind") == "link" for n in self.nodes(blocks)))

    def test_nested_labels_escapes_and_malformed_input_remain_bounded_data(self):
        blocks = app.readme_document(r"[**Read [nested]** and `code`](docs/a\(b\).md)", self.item)
        link = next(n for n in self.nodes(blocks) if n.get("kind") == "link")
        self.assertTrue(link["url"].endswith("/docs/a(b).md"))
        for source in ["[" * 24000, "<" * 24000, "![" * 12000, "[" * 1000 + "x" + "](docs/x)" * 1000,
                       '<img src="https://bad.invalid/', "````\n```\n![x](https://bad.invalid)"]:
            blocks = app.readme_document(source, self.item)
            self.assertLess(len(json.dumps(blocks)), 300000)
            self.assertFalse(any(n.get("kind") in {"image", "html", "script"} for n in self.nodes(blocks)))
        blocks = app.readme_document("x" * 30000, self.item)
        self.assertEqual(blocks[0]["inlines"][0]["text"], "x" * app.MAX_README_TEXT)

    def test_reference_amplification_and_large_tables_have_bounded_presentation(self):
        source = "[x]: https://example.org/" + "a" * 1100 + "\n\n" + "[x] " * 5500
        blocks = app.readme_document(source, self.item)
        links = [n["url"] for n in self.nodes(blocks) if n.get("kind") == "link"]
        self.assertLessEqual(sum(map(len, links)), 64000)
        self.assertLess(len(json.dumps(blocks)), 1000000)
        source = "| Key | Value |\n| --- | --- |\n" + "| item | value |\n" * 1000
        blocks = app.readme_document(source, self.item)
        self.assertEqual(blocks[0]["kind"], "code")
        self.assertEqual(blocks[0]["text"], source.rstrip())

    def prepare_store(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        store = app.Store(Path(directory.name))
        self.addCleanup(store.close)
        raw = json.loads((ROOT / "demo/fixtures/example.json").read_text())
        items, generated = app.normalize_catalog(raw["catalog"])
        app.save_catalog(store, items, generated, 100)
        item = next(item for item in items if item.get("listingCommit"))
        return store, item

    def test_fetch_preserves_plain_search_and_pinned_limit_without_extra_requests(self):
        source = "# Heading\n\n**Strong** [Guide](docs/start.md)\n\n" + "reading " * 4000
        with mock.patch.object(app, "fetch_bytes", return_value=source.encode()) as fetch:
            result = app.fetch_readme(self.item)
        self.assertEqual(fetch.call_count, 1)
        self.assertEqual(fetch.call_args.args[0], "https://raw.githubusercontent.com/example/reading/" + "a" * 40 + "/README.md")
        self.assertEqual(result["content"], app.markdown_content(source))
        self.assertEqual(result["text"], app.markdown_text(source))
        self.assertEqual(len(result["documentSource"]), app.MAX_README_TEXT)
        self.assertEqual(result["documentVersion"], app.README_DOCUMENT_VERSION)

    def test_legacy_cache_upgrades_only_presentation_and_offline_fallback_is_retryable(self):
        store, item = self.prepare_store()
        old = {"commit": item["listingCommit"], "contentVersion": app.README_CONTENT_VERSION,
               "content": "Old cached prose", "text": "Search evidence", "fetchedAt": 100}
        app.save_readmes(store, {item["id"]: old})
        request = {"action": "readme-plugin", "pluginId": item["id"]}
        with mock.patch.object(app, "fetch_readme", return_value={"ok": False}) as fetch:
            result = app.run(request, store, now=200)
        self.assertEqual(fetch.call_count, 1)
        self.assertEqual(result["readmeContent"], old["content"])
        self.assertEqual(result["readmeBlocks"], [])
        self.assertEqual(app.load_readmes(store)[item["id"]]["documentVersion"], 0)
        with mock.patch.object(app, "fetch_bytes", return_value=b"# Rich heading\n\nStill **searchable**.") as fetch:
            result = app.run(request, store, now=201)
        self.assertEqual(fetch.call_count, 1)
        self.assertEqual(result["readmeBlocks"][0]["kind"], "heading")
        with mock.patch.object(app, "fetch_bytes", side_effect=AssertionError("Cached document must be local")):
            cached = app.run(request, store, now=202)
        self.assertEqual(cached["readmeBlocks"], result["readmeBlocks"])
        self.assertEqual(app.load_readmes(store)[item["id"]]["contentVersion"], app.README_CONTENT_VERSION)
        self.assertEqual(app.SEARCH_INDEX_VERSION, 1)

    def test_disabled_enrichment_does_not_upgrade_or_fetch(self):
        store, item = self.prepare_store()
        app.save_preferences(store, {**app.DEFAULT_PREFERENCES, "readmeEnrichment": False})
        with mock.patch.object(app, "fetch_readme", side_effect=AssertionError("Privacy forbids README requests")):
            with self.assertRaisesRegex(ValueError, "disabled"):
                app.run({"action": "readme-plugin", "pluginId": item["id"]}, store, now=200)

    def test_older_plain_cache_fallback_stays_revision_scoped(self):
        store, item = self.prepare_store()
        old = {"commit": item["listingCommit"], "text": "Legacy plain search and reading", "fetchedAt": 100}
        app.save_readmes(store, {item["id"]: old})
        request = {"action": "readme-plugin", "pluginId": item["id"]}
        with mock.patch.object(app, "fetch_readme", return_value={"ok": False}):
            result = app.run(request, store, now=200)
            self.assertEqual(result["readmeContent"], old["text"])
            self.assertEqual(result["readmeBlocks"], [])
            app.save_readmes(store, {item["id"]: {**old, "commit": "b" * 40}})
            with self.assertRaisesRegex(ValueError, "GitHub did not return"):
                app.run(request, store, now=201)


if __name__ == "__main__":
    unittest.main()
