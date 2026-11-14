"""Small host-independent PE checks for packaged Windows native components."""


def verify_windows_executable(data: bytes, name: str) -> None:
    message = "Windows bundle executable must be an x64 PE executable: " + name
    if len(data) < 64 or data[:2] != b"MZ":
        raise ValueError(message)
    offset = int.from_bytes(data[60:64], "little")
    if offset < 64 or offset + 26 > len(data):
        raise ValueError(message)
    flags = int.from_bytes(data[offset + 22:offset + 24], "little")
    if (data[offset:offset + 4] != b"PE\0\0" or
            int.from_bytes(data[offset + 4:offset + 6], "little") != 0x8664 or
            not flags & 0x0002 or flags & 0x2000 or
            int.from_bytes(data[offset + 24:offset + 26], "little") != 0x20B):
        raise ValueError(message)
