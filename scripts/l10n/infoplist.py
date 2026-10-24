#!/usr/bin/env python3
"""Writes InfoPlist.xcstrings (localised permission texts) for both apps."""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

IOS = {
    "CFBundleDisplayName": ("Pilothouse", "Pilothouse", "Pilothouse"),
    "NSCameraUsageDescription": (
        "Pilothouse uses the camera to scan the pairing code shown on your Mac and, if you choose, to take photos to send to your agent.",
        "Pilothouse, kamerayı Mac'inizde gösterilen eşleştirme kodunu taramak ve isterseniz ajanınıza göndermek üzere fotoğraf çekmek için kullanır.",
        "Pilothouse verwendet die Kamera, um den auf deinem Mac angezeigten Kopplungscode zu scannen und, wenn du möchtest, Fotos aufzunehmen, die du an deinen Agenten sendest.",
    ),
    "NSLocalNetworkUsageDescription": (
        "Pilothouse connects to your Mac on the local network to control your Claude Code sessions.",
        "Pilothouse, Claude Code oturumlarınızı yönetmek için yerel ağdaki Mac'inize bağlanır.",
        "Pilothouse verbindet sich im lokalen Netzwerk mit deinem Mac, um deine Claude-Code-Sitzungen zu steuern.",
    ),
}

MAC = {
    "CFBundleDisplayName": ("Pilothouse", "Pilothouse", "Pilothouse"),
    "NSLocalNetworkUsageDescription": (
        "Pilothouse lets your paired iPhone or iPad connect to this Mac over your local network.",
        "Pilothouse, eşleşmiş iPhone veya iPad'inizin yerel ağ üzerinden bu Mac'e bağlanmasını sağlar.",
        "Pilothouse ermöglicht deinem gekoppelten iPhone oder iPad, sich über das lokale Netzwerk mit diesem Mac zu verbinden.",
    ),
    "NSDesktopFolderUsageDescription": (
        "Claude Code sessions you start from your phone may read and edit files on your Desktop.",
        "Telefonunuzdan başlattığınız Claude Code oturumları Masaüstünüzdeki dosyaları okuyup düzenleyebilir.",
        "Claude-Code-Sitzungen, die du vom Telefon startest, können Dateien auf deinem Schreibtisch lesen und bearbeiten.",
    ),
    "NSDocumentsFolderUsageDescription": (
        "Claude Code sessions you start from your phone may read and edit files in your Documents folder.",
        "Telefonunuzdan başlattığınız Claude Code oturumları Belgeler klasörünüzdeki dosyaları okuyup düzenleyebilir.",
        "Claude-Code-Sitzungen, die du vom Telefon startest, können Dateien in deinem Dokumente-Ordner lesen und bearbeiten.",
    ),
    "NSDownloadsFolderUsageDescription": (
        "Claude Code sessions you start from your phone may read and edit files in your Downloads folder.",
        "Telefonunuzdan başlattığınız Claude Code oturumları İndirilenler klasörünüzdeki dosyaları okuyup düzenleyebilir.",
        "Claude-Code-Sitzungen, die du vom Telefon startest, können Dateien in deinem Downloads-Ordner lesen und bearbeiten.",
    ),
    "NSNetworkVolumesUsageDescription": (
        "Claude Code sessions you start from your phone may access files on network volumes.",
        "Telefonunuzdan başlattığınız Claude Code oturumları ağ birimlerindeki dosyalara erişebilir.",
        "Claude-Code-Sitzungen, die du vom Telefon startest, können auf Dateien auf Netzwerkvolumes zugreifen.",
    ),
}


# Further languages: scripts/l10n/infoplist.<language>.json = {"ios": {key: value}, "mac": {key: value}}.
EXTRA_LANGUAGES = ["es", "fr", "it", "pt-BR", "ja", "ko", "zh-Hans"]


def extra(app):
    result = {}
    for language in EXTRA_LANGUAGES:
        path = os.path.join(ROOT, "scripts/l10n", f"infoplist.{language}.json")
        if os.path.exists(path):
            result[language] = json.load(open(path, encoding="utf-8")).get(app, {})
    return result


def write(entries, path, app):
    strings = {}
    others = extra(app)
    for key, (en, tr, de) in entries.items():
        values = [("en", en), ("tr", tr), ("de", de)] + [(language, table[key]) for language, table in others.items() if key in table]
        strings[key] = {
            "extractionState": "manual",
            "localizations": {
                language: {"stringUnit": {"state": "translated", "value": value}}
                for language, value in values
            },
        }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    write(IOS, os.path.join(ROOT, "PilothouseiOS/Resources/InfoPlist.xcstrings"), "ios")
    write(MAC, os.path.join(ROOT, "PilothouseMac/Resources/InfoPlist.xcstrings"), "mac")
    print("InfoPlist catalogs written.")
