import struct
import sys
from pathlib import Path


def binary_to_hex(bin_path: str, hex_path: str) -> None:
    data = Path(bin_path).read_bytes()

    if len(data) % 4 != 0:
        data += b"\x00" * (4 - len(data) % 4)

    with open(hex_path, "w", encoding="ascii") as f:
        for i in range(0, len(data), 4):
            word = struct.unpack_from("<I", data, i)[0]
            f.write(f"{word:08x}\n")


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} input.bin output.hex")
        return 1

    binary_to_hex(sys.argv[1], sys.argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())