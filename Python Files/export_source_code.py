"""
export_source_code.py

What this script does:
1. Prints the folder tree of the given source directory in the terminal.
2. Lists every .c and .h file found recursively.
3. Exports all .c and .h file contents into one text file.

Example:
    python export_source_code.py
    python export_source_code.py source output.txt
"""

from __future__ import annotations

import argparse
from pathlib import Path


def print_tree(root: Path) -> None:
    """
    Print a readable directory tree of the root folder, including files.
    """
    print(f"\n=== Folder tree for: {root.name} ===")
    print(root.name)

    def walk(current: Path, prefix: str = "") -> None:
        entries = sorted(
            list(current.iterdir()),
            key=lambda p: (p.is_file(), p.name.lower())
        )

        for i, entry in enumerate(entries):
            is_last = i == len(entries) - 1
            branch = "└── " if is_last else "├── "
            print(prefix + branch + entry.name)

            if entry.is_dir():
                extension = "    " if is_last else "│   "
                walk(entry, prefix + extension)

    walk(root)
    print()


def find_code_files(source_dir: Path) -> list[Path]:
    """
    Return all .c and .h files under source_dir, sorted by relative path.
    """
    code_files: list[Path] = []

    for path in source_dir.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".c", ".h"}:
            code_files.append(path)

    code_files.sort(
        key=lambda p: str(p.relative_to(source_dir)).replace("\\", "/").lower()
    )
    return code_files


def read_file_text(file_path: Path) -> str:
    """
    Read a text file safely.
    Try UTF-8 first, then fall back to latin-1.
    """
    try:
        return file_path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return file_path.read_text(encoding="latin-1", errors="replace")


def write_output(source_dir: Path, output_file: Path) -> list[Path]:
    """
    Create the output text file containing all .c and .h file contents.
    Returns the list of files exported.
    """
    code_files = find_code_files(source_dir)

    with output_file.open("w", encoding="utf-8", newline="\n") as f:
        f.write("===Codes inside Source===\n\n")

        if not code_files:
            f.write("No .c or .h files found.\n")
            return code_files

        for file_path in code_files:
            relative_path = file_path.relative_to(source_dir).as_posix()
            contents = read_file_text(file_path)

            f.write(f"{relative_path}:\n")
            f.write(contents)

            if not contents.endswith("\n"):
                f.write("\n")

            f.write("\n")

    return code_files


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Print the source tree and export all .c and .h files into one text file."
    )
    parser.add_argument(
        "source",
        nargs="?",
        default="source",
        help="Path to the source folder. Default is './source'.",
    )
    parser.add_argument(
        "output",
        nargs="?",
        default="source_code_dump.txt",
        help="Output text file name. Default is 'source_code_dump.txt'.",
    )
    args = parser.parse_args()

    source_dir = Path(args.source).resolve()
    output_file = Path(args.output).resolve()

    if not source_dir.exists():
        raise FileNotFoundError(f"Source folder does not exist: {source_dir}")

    if not source_dir.is_dir():
        raise NotADirectoryError(f"Source path is not a folder: {source_dir}")

    print_tree(source_dir)

    exported_files = write_output(source_dir, output_file)

    print("=== .c and .h files exported ===")
    if exported_files:
        for file_path in exported_files:
            print(file_path.relative_to(source_dir).as_posix())
    else:
        print("No .c or .h files found.")

    print(f"\nDone. Output written to: {output_file}")


if __name__ == "__main__":
    main()