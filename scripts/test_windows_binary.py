import unittest

from windows_binary import verify_windows_executable


def pe_binary(*, machine=0x8664, dll=False, executable=True, magic=0x20B):
    data = bytearray(512)
    data[:2] = b"MZ"
    data[60:64] = (128).to_bytes(4, "little")
    data[128:132] = b"PE\0\0"
    data[132:134] = machine.to_bytes(2, "little")
    data[150:152] = ((0x2000 if dll else 0) | (2 if executable else 0)).to_bytes(2, "little")
    data[152:154] = magic.to_bytes(2, "little")
    return bytes(data)


class WindowsExecutableTests(unittest.TestCase):
    def test_accepts_x64_executable(self):
        verify_windows_executable(pe_binary(), "sisters.exe")

    def test_rejects_wrong_architecture_dll_truncation_and_missing_pe_header(self):
        for data in (pe_binary(machine=0x14C), pe_binary(machine=0xAA64), pe_binary(dll=True),
                     pe_binary(executable=False), pe_binary(magic=0x10B),
                     pe_binary()[:140], b"synthetic ELF", bytes(512)):
            with self.subTest(data=data[:8]), self.assertRaisesRegex(ValueError, "x64 PE executable"):
                verify_windows_executable(data, "misaka-runtime.exe")


if __name__ == "__main__":
    unittest.main()
