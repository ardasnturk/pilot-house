#!/usr/bin/env python3
"""Builds the String Catalogs (Localizable.xcstrings) for the iOS and Mac apps.

1. Extracts localizable literals from the app's Swift sources (the same
   literals Xcode's SWIFT_EMIT_LOC_STRINGS would find), converting string
   interpolations to the format specifiers Swift uses (%lld, %@, %lf).
2. Merges translations from scripts/l10n/<app>.json ({key: {"tr": ..., "de": ...}}).
3. Writes <App>/Resources/Localizable.xcstrings and reports missing translations.

Run from the repository root:  python3 scripts/l10n/build_catalogs.py [--check]
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LANGUAGES = ["tr", "de", "es", "fr", "it", "pt-BR", "ja", "ko", "zh-Hans"]
# tr and de live in scripts/l10n/<app>.json (generated from <app>_translations.py);
# the other languages in scripts/l10n/<app>.<language>.json ({key: value}).
EXTRA_LANGUAGE_FILES = ["es", "fr", "it", "pt-BR", "ja", "ko", "zh-Hans"]
STRING = r'"'
PATTERNS = [
    r'(?<![A-Za-z])Text\(\s*' + STRING,
    r'(?<![A-Za-z])Button\(\s*' + STRING,
    r'(?<![A-Za-z])Label\(\s*' + STRING,
    r'(?<![A-Za-z])Toggle\(\s*' + STRING,
    r'(?<![A-Za-z])Picker\(\s*' + STRING,
    r'(?<![A-Za-z])LabeledContent\(\s*' + STRING,
    r'(?<![A-Za-z])SecureField\(\s*' + STRING,
    r'(?<![A-Za-z])TextField\(\s*' + STRING,
    r'(?<![A-Za-z])Link\(\s*' + STRING,
    r'(?<![A-Za-z])Section\(\s*' + STRING,
    r'(?<![A-Za-z])SectionTitle\(\s*' + STRING,
    r'String\(localized:\s*' + STRING,
    r'LocalizedStringKey\(\s*' + STRING,
    r'\b(?:title|detail|text):\s*' + STRING,
]
FORMATTING_PATTERN = r'case \.\w+:\s*' + STRING

# Interpolated expressions that are integers (→ %lld) or doubles (→ %lf).
INTEGER_EXPRESSIONS = {
    "remaining / 60", "remaining", "minutes / 1_440", "minutes / 60", "skills.count", "plainCommands.count", "Int((window?.usedPercent ?? 0).rounded())", "number", "devices", "sessions", "settings.retentionDays",
    "lines.count", "attachments", "payloads.count", "item.number ?? index + 1", "DiffBuilder.stats(of: diff).added", "status",
    "DiffBuilder.stats(of: diff).removed", "count",
}
DOUBLE_EXPRESSIONS = set()

# Keys that are not literals in Text(...) but are looked up at runtime.
EXTRA_KEYS = {
    "ios": [
        # ToolSummary titles (PilothouseKit) shown via LocalizedStringKey.
        "Read", "Edit", "Write", "Edit notebook", "Run", "Search", "Find files", "Fetch", "Web search", "Tasks", "Sub-agent",
        # Notices produced by the Mac (shown via LocalizedStringKey).
        "Interrupted.", "Interrupted by user.", "Session closed.", "Session continued.", "Session resumed.",
        "The conversation was compacted to free up context.",
        "Claude Code is not signed in on this Mac. Open Terminal, run `claude` and sign in, then try again.",
        "Remote Code was restarted while Claude was working; the last turn may be incomplete.",
        "Claude Code could not find the earlier conversation. Your next message starts a fresh one in this session.",
        "Every action in this chat is now allowed without asking.", "The permission mode of this chat was changed.",
    ],
    "mac": [
        # TailscaleSetup.manualSteps (PilothouseHost) shown via LocalizedStringKey.
        "Install Tailscale",
        "Download Tailscale for macOS from tailscale.com, or install it with Homebrew.",
        "Open Tailscale and sign in",
        "Start Tailscale from Applications, allow its VPN configuration when macOS asks, then log in from its menu bar icon.",
        "Turn on MagicDNS (recommended)",
        "In the Tailscale admin console under DNS, enable MagicDNS so your Mac gets a stable name.",
        "Check the connection",
        "Remote Code detects Tailscale automatically. You can also check it in Terminal.",
        "Install Tailscale on your iPhone or iPad",
        "Get Tailscale from the App Store and sign in with the same account. iOS does not allow apps to do this for you.",
    ],
}


def swift_format_key(literal):
    """Turns a Swift literal with \\(...) interpolations into a catalog key."""
    result = []
    index = 0
    while index < len(literal):
        if literal.startswith("\\(", index):
            depth = 1
            cursor = index + 2
            while cursor < len(literal) and depth > 0:
                if literal[cursor] == "(":
                    depth += 1
                elif literal[cursor] == ")":
                    depth -= 1
                cursor += 1
            expression = literal[index + 2:cursor - 1].strip()
            if expression in INTEGER_EXPRESSIONS:
                result.append("%lld")
            elif expression in DOUBLE_EXPRESSIONS:
                result.append("%lf")
            else:
                result.append("%@")
            index = cursor
        elif literal.startswith("\\n", index):
            result.append("\n")
            index += 2
        elif literal.startswith('\\"', index):
            result.append('"')
            index += 2
        elif literal.startswith("\\\\", index):
            result.append("\\")
            index += 2
        else:
            result.append(literal[index])
            index += 1
    return "".join(result)


def read_literal(source, start):
    """Returns the body of the Swift string literal whose opening quote is at
    `start - 1`, honouring escapes and nested strings inside \\( ... )."""
    index = start
    while index < len(source):
        char = source[index]
        if char == "\\" and source.startswith("\\(", index):
            depth = 1
            index += 2
            while index < len(source) and depth > 0:
                if source[index] == '"':
                    index = start_of_end(source, index + 1)
                    continue
                if source[index] == "(":
                    depth += 1
                elif source[index] == ")":
                    depth -= 1
                index += 1
            continue
        if char == "\\":
            index += 2
            continue
        if char == '"':
            return source[start:index]
        if char == "\n":
            return None
        index += 1
    return None


def start_of_end(source, index):
    """Skips a nested simple string literal starting after its opening quote."""
    while index < len(source):
        if source[index] == "\\":
            index += 2
            continue
        if source[index] == '"':
            return index + 1
        index += 1
    return index


def extract(app_dir):
    keys = set()
    for folder, _, files in os.walk(app_dir):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            source = open(path, encoding="utf-8").read()
            patterns = PATTERNS + ([FORMATTING_PATTERN] if name == "Formatting.swift" else [])
            for pattern in patterns:
                for match in re.finditer(pattern, source):
                    if source.startswith('""', match.end() - 1) and source.startswith('"""', match.end() - 1):
                        continue
                    literal = read_literal(source, match.end())
                    if literal is None or not literal.strip() or literal.startswith("sk-"):
                        continue
                    if re.fullmatch(r"[a-z0-9]+(\.[a-z0-9]+)+", literal):
                        continue  # SF Symbol name
                    keys.add(swift_format_key(literal))
    return keys


def build(app, app_dir, check):
    translations_path = os.path.join(ROOT, "scripts/l10n", f"{app}.json")
    translations = json.load(open(translations_path, encoding="utf-8")) if os.path.exists(translations_path) else {}
    for language in EXTRA_LANGUAGE_FILES:
        path = os.path.join(ROOT, "scripts/l10n", f"{app}.{language}.json")
        if not os.path.exists(path):
            continue
        for key, value in json.load(open(path, encoding="utf-8")).items():
            translations.setdefault(key, {})[language] = value
    keys = sorted(extract(app_dir) | set(EXTRA_KEYS[app]))
    missing = []
    strings = {}
    for key in keys:
        entry = {}
        localized = translations.get(key, {})
        localizations = {}
        for language in LANGUAGES:
            value = localized.get(language)
            if value is None:
                missing.append((language, key))
                continue
            localizations[language] = {"stringUnit": {"state": "translated", "value": value}}
        if localizations:
            entry["localizations"] = localizations
        strings[key] = entry
    unused = sorted(set(translations) - set(keys))
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    output = os.path.join(app_dir, "Resources/Localizable.xcstrings")
    if not check:
        with open(output, "w", encoding="utf-8") as handle:
            json.dump(catalog, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
    print(f"{app}: {len(keys)} keys, {len(missing)} missing translations, {len(unused)} unused translations")
    for language, key in missing:
        print(f"  MISSING [{language}] {json.dumps(key, ensure_ascii=False)}")
    for key in unused:
        print(f"  UNUSED {json.dumps(key, ensure_ascii=False)}")
    return not missing


if __name__ == "__main__":
    if "--list" in sys.argv:
        for app, folder in (("ios", "PilothouseiOS"), ("mac", "PilothouseMac")):
            keys = sorted(extract(os.path.join(ROOT, folder)) | set(EXTRA_KEYS[app]))
            print(json.dumps({app: keys}, ensure_ascii=False, indent=1))
        sys.exit(0)
    check = "--check" in sys.argv
    ok = build("ios", os.path.join(ROOT, "PilothouseiOS"), check)
    ok = build("mac", os.path.join(ROOT, "PilothouseMac"), check) and ok
    sys.exit(0 if ok or not check else 1)
