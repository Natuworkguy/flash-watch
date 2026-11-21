"""Run the Watch's actual mention resolver on macOS without SwiftUI."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
models = (root / "watch/FlashWatch/Model/Models.swift").read_text()
resolver = models[models.index("enum Mentions {"):]
checks = r'''
let engineer = Spark(name: "Engineer", handle: "@engineer-spark")
let manager = Spark(name: "Dev Team Manager", handle: "@dev-team-manager-spark")
let sparks = [engineer, manager]
let cases = [
    ("@Engineer Test", "@engineer-spark Test"),
    ("@ engineer Test", "@engineer-spark Test"),
    ("at Engineer Test", "@engineer-spark Test"),
    ("Hi, at Engineer Test", "Hi, @engineer-spark Test"),
    ("@engineer-spark Test", "@engineer-spark Test"),
    ("@dev-team-manager-spark Test", "@dev-team-manager-spark Test"),
    ("at Dev Team Manager Test", "@dev-team-manager-spark Test"),
    ("look at Engineer", "look at Engineer"),
    ("person@Engineer.com", "person@Engineer.com"),
]
for (input, expected) in cases {
    let actual = Mentions.resolve(input, sparks: sparks)
    precondition(actual == expected, "\(input): \(actual) != \(expected)")
    precondition(Mentions.resolve(actual, sparks: sparks) == actual, "not idempotent")
}
precondition(Mentions.prefixed("Test", with: engineer) == "@engineer-spark Test")
precondition(Mentions.prefixed("@engineer-spark Test", with: engineer) == "@engineer-spark Test")
precondition(Mentions.prefixed("@engineer Test", with: engineer) == "@engineer Test")
precondition(Mentions.prefixed("Test", with: nil) == "Test")
// Flash sends handles with the @ on; the Watch keeps them without it.
let bare = Spark(name: "Engineer", handle: "engineer-spark")
precondition(Mentions.bare("@engineer-spark") == "engineer-spark")
precondition(Mentions.bare("engineer-spark") == "engineer-spark")
precondition(Mentions.resolve("@Engineer Test", sparks: [bare]) == "@engineer-spark Test")
precondition(Mentions.prefixed("Test", with: bare) == "@engineer-spark Test")
precondition(!Mentions.prefixed("Test", with: engineer).contains("@@"))
precondition(!Mentions.resolve("@Engineer Test", sparks: sparks).contains("@@"))
precondition(Mentions.prefixed(Mentions.resolve("@Engineer Test", sparks: sparks), with: engineer)
    == "@engineer-spark Test")
print("Mention checks passed")
'''
source = 'import Foundation\nstruct Spark { let name: String; let handle: String }\n'
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "mentions.swift"
    path.write_text(source + resolver + "\n" + checks)
    subprocess.run(["swift", str(path)], check=True)
