#!/usr/bin/env python3
"""Fail only when the head introduces failed RSpec examples vs. the base."""

import sys
import xml.etree.ElementTree as ET


def failed_examples(path):
    root = ET.parse(path).getroot()
    examples = root.findall(".//testcase")
    if not examples:
        raise ValueError(f"JUnit report contains no examples: {path}")

    reported_failures = int(root.get("failures", "0")) + int(root.get("errors", "0"))
    failures = set()
    for example in examples:
        if example.find("failure") is not None or example.find("error") is not None:
            failures.add(f"{example.get('classname', '')}::{example.get('name', '')}")
    return len(examples), reported_failures, failures


def main():
    if len(sys.argv) != 3:
        print("Usage: compare-rspec-results.py BASE.xml HEAD.xml", file=sys.stderr)
        return 2

    base_total, base_failure_count, base_failures = failed_examples(sys.argv[1])
    head_total, head_failure_count, head_failures = failed_examples(sys.argv[2])
    introduced = sorted(head_failures - base_failures)
    resolved = sorted(base_failures - head_failures)

    print(f"Base: {base_total} examples, {base_failure_count} failures ({len(base_failures)} unique examples)")
    print(f"Head: {head_total} examples, {head_failure_count} failures ({len(head_failures)} unique examples)")
    print(f"Resolved examples: {len(resolved)}")
    print(f"New failing examples: {len(introduced)}")

    if introduced:
        for example in introduced:
            print(f"::error::New failing RSpec example: {example}")
        return 1

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ET.ParseError, OSError, ValueError) as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(2)
