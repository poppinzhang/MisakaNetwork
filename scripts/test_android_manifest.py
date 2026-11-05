"""Exercise binary Android XML emitted by aapt, including UTF-8 and UTF-16 pools."""
import struct
import unittest

from android_manifest import attributes


def binary_manifest(utf8=True):
    strings = ["manifest", "versionName", "0.1.5", "versionCode", "uses-sdk", "minSdkVersion"]
    encoded = b""
    offsets = []
    for value in strings:
        offsets.append(len(encoded))
        if utf8:
            data = value.encode()
            encoded += bytes((len(value), len(data))) + data + b"\0"
        else:
            encoded += struct.pack("<H", len(value)) + value.encode("utf-16-le") + b"\0\0"
    start = 28 + 4 * len(strings)
    pool = struct.pack("<HHIIIIII", 1, 28, start + len(encoded), len(strings), 0,
                       0x100 if utf8 else 0, start, 0)
    pool += b"".join(struct.pack("<I", offset) for offset in offsets) + encoded

    def element(name, entries):
        data = b"".join(struct.pack("<IIIHBBI", 0xffffffff, key, 0xffffffff, 8, 0, kind, value)
                        for key, kind, value in entries)
        return (struct.pack("<HHIII", 0x102, 16, 36 + len(data), 1, 0xffffffff)
                + struct.pack("<IIHHHHHH", 0xffffffff, name, 20, 20, len(entries), 0, 0, 0) + data)

    chunks = pool + element(0, [(1, 3, 2), (3, 16, 2005)]) + element(4, [(5, 16, 36)])
    return struct.pack("<HHI", 3, 8, 8 + len(chunks)) + chunks


class AndroidManifestTests(unittest.TestCase):
    def test_aapt_utf8_and_utf16_string_pools(self):
        for utf8 in (False, True):
            with self.subTest(utf8=utf8):
                actual = attributes(binary_manifest(utf8))
                self.assertEqual(actual["manifest"], {"versionName": "0.1.5", "versionCode": 2005})
                self.assertEqual(actual["uses-sdk"], {"minSdkVersion": 36})

    def test_malformed_and_truncated_xml_is_rejected(self):
        source = binary_manifest()
        for data in (b"", b"not XML", source[:-1], source[:15]):
            with self.subTest(data=data[:8]):
                with self.assertRaises(ValueError):
                    attributes(data)


if __name__ == "__main__":
    unittest.main()
