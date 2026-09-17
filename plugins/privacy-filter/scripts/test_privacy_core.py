import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

from privacy_core import MappingStore, PrivacyError, Sanitizer, Span


class FakeClassifier:
    def classify(self, text):
        needle = "alice@example.com"
        if needle not in text:
            return []
        start = text.index(needle)
        return [Span(start, start + len(needle), "private_email")]


class PrivacyCoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "state" / "mappings.json"
        self.store = MappingStore(self.path)
        self.sanitizer = Sanitizer(self.store, FakeClassifier())

    def tearDown(self):
        self.tmp.cleanup()

    def test_stable_mapping_and_restore(self):
        first = self.sanitizer.sanitize_text("Email alice@example.com")
        second = self.sanitizer.sanitize_text("Again alice@example.com")
        token = first.removeprefix("Email ")
        self.assertIn(token, second)
        self.assertNotIn("alice@example.com", first)
        restored = self.store.restore_json_bytes(json.dumps({"text": token}).encode())
        self.assertEqual(json.loads(restored)["text"], "alice@example.com")

    def test_known_mapping_does_not_depend_on_classifier(self):
        first = self.sanitizer.sanitize_text("alice@example.com")
        self.sanitizer.classifier = FakeClassifier()
        second = self.sanitizer.sanitize_text("alice@example.com")
        self.assertEqual(first, second)

    def test_mapping_file_is_private(self):
        self.sanitizer.sanitize_text("alice@example.com")
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.path.parent.stat().st_mode), 0o700)

    def test_rejects_insecure_existing_mapping_file(self):
        self.path.parent.mkdir(parents=True)
        self.path.write_text('{"version":1,"salt":"00","mappings":{}}')
        os.chmod(self.path, 0o644)
        with self.assertRaises(PrivacyError):
            MappingStore(self.path)

    def test_opaque_data_url_requires_addon_bypass(self):
        with self.assertRaisesRegex(PrivacyError, "opaque base64"):
            self.sanitizer.sanitize_text("data:image/png;base64,AAAA")

    def test_classifier_spans_inside_tokens_are_ignored(self):
        first = self.sanitizer.sanitize_text("alice@example.com")
        self.assertEqual(self.store._data["mappings"].keys(), {"alice@example.com"})

        class FragmentClassifier:
            def classify(self, text):
                needle = "example"
                if needle not in text:
                    return []
                start = text.index(needle)
                return [Span(start, start + len(needle), "private_url")]

        self.sanitizer.classifier = FragmentClassifier()
        again = self.sanitizer.sanitize_text(f"Message about {first}")
        self.assertIn(first, again)
        self.assertEqual(self.store._data["mappings"].keys(), {"alice@example.com"})

    def test_json_tree(self):
        sanitized = self.sanitizer.sanitize_json(
            {"messages": [{"content": "alice@example.com"}], "stream": True}
        )
        self.assertNotEqual(sanitized["messages"][0]["content"], "alice@example.com")
        self.assertIs(sanitized["stream"], True)


if __name__ == "__main__":
    unittest.main()
