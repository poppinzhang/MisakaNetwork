"""Read Android's binary XML attributes without an Android SDK dependency."""
from __future__ import annotations

import struct
from xml.etree import ElementTree

ANDROID = "http://schemas.android.com/apk/res/android"


def _length(data: bytes, offset: int, utf8: bool) -> tuple[int, int]:
    if utf8:
        value = data[offset]
        return (((value & 0x7f) << 8) | data[offset + 1], offset + 2) if value & 0x80 else (value, offset + 1)
    value = struct.unpack_from("<H", data, offset)[0]
    return (((value & 0x7fff) << 16) | struct.unpack_from("<H", data, offset + 2)[0], offset + 4) if value & 0x8000 else (value, offset + 2)


def attributes(data: bytes) -> dict[str, dict[str, object]]:
    if data.lstrip().startswith(b"<"):
        root = ElementTree.fromstring(data)
        return {element.tag: {key.rsplit("}", 1)[-1]: value for key, value in element.attrib.items()}
                for element in root.iter() if element.tag in {"manifest", "uses-sdk"}}
    try:
        kind, header, size = struct.unpack_from("<HHI", data)
        if kind != 3 or header < 8 or size != len(data):
            raise ValueError("Invalid Android binary XML header")
        strings: list[str] = []
        result: dict[str, dict[str, object]] = {}
        offset = header
        while offset < size:
            kind, chunk_header, chunk_size = struct.unpack_from("<HHI", data, offset)
            if chunk_header < 8 or chunk_size < chunk_header or offset + chunk_size > size:
                raise ValueError("Invalid Android binary XML chunk")
            if kind == 1:  # RES_STRING_POOL_TYPE
                count, _, flags, start, _ = struct.unpack_from("<IIIII", data, offset + 8)
                strings = []
                for index in range(count):
                    relative = struct.unpack_from("<I", data, offset + chunk_header + index * 4)[0]
                    position = offset + start + relative
                    _, position = _length(data, position, bool(flags & 0x100))
                    if flags & 0x100:
                        length, position = _length(data, position, True)
                        strings.append(data[position:position + length].decode("utf-8"))
                    else:
                        # First UTF-16 length is measured in code units.
                        length, _ = _length(data, offset + start + relative, False)
                        strings.append(data[position:position + length * 2].decode("utf-16-le"))
            elif kind == 0x102:  # RES_XML_START_ELEMENT_TYPE
                extension = offset + chunk_header
                _, name, start, stride, count = struct.unpack_from("<IIHHH", data, extension)
                element = strings[name]
                if stride < 20:
                    raise ValueError("Invalid Android XML attribute size")
                values = {}
                for index in range(count):
                    position = extension + start + index * stride
                    if position + 20 > offset + chunk_size:
                        raise ValueError("Android XML attribute exceeds chunk")
                    _, attribute, raw, _, _, data_type, value = struct.unpack_from("<IIIHBBI", data, position)
                    values[strings[attribute]] = (strings[raw] if raw != 0xffffffff else
                        strings[value] if data_type == 3 else value)
                if element in {"manifest", "uses-sdk"}:
                    if element in result:
                        raise ValueError("Duplicate Android manifest element")
                    result[element] = values
            offset += chunk_size
        return result
    except (IndexError, struct.error, UnicodeError) as error:
        raise ValueError("Malformed Android binary XML") from error
