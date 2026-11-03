#!/usr/bin/env python3
"""Prints the 100,000-entry performance receipt as a Markdown table for the CI job summary."""

import json
import sys


def main(path: str) -> None:
    with open(path, encoding="utf-8") as handle:
        receipt = json.load(handle)
    print("### Performance receipt")
    print()
    print(
        f"{receipt['transactionCount']:,} synthetic entries, "
        f"{receipt['accountCount']} accounts, {receipt['categoryCount']} categories, "
        f"{receipt['fileBytes'] / 1_000_000:.1f} MB on disk. "
        f"{receipt['build']} build on {receipt['platform']}."
    )
    print()
    print("| Operation | Seconds | Ceiling | Within |")
    print("| --- | ---: | ---: | :---: |")
    for operation in receipt["operations"]:
        within = "yes" if operation["seconds"] <= operation["ceilingSeconds"] else "**no**"
        print(
            f"| {operation['name']} | {operation['seconds']:.3f} "
            f"| {operation['ceilingSeconds']:g} | {within} |"
        )


if __name__ == "__main__":
    main(sys.argv[1])
