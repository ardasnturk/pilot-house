import Foundation

/// Static content of the demo Mac: a believable home folder, three seeded
/// sessions and a scripted Claude turn. All names and data are fictional.
enum DemoContent {
    static let macName = "Demo MacBook Pro"
    static let slashCommands = ["clear", "compact", "cost", "review", "init", "model", "pr-comments", "security-review"]

    // MARK: File tree

    static let tree: [String: [String]] = [
        "/Users/demo": ["Desktop", "Developer", "Documents", "Downloads", "Music", "Pictures", ".config", ".zshrc"],
        "/Users/demo/Desktop": ["todo.txt", "Screenshot 2026-10-20.png"],
        "/Users/demo/Developer": ["weather-app", "portfolio-site", "scripts", "dotfiles"],
        "/Users/demo/Developer/weather-app": ["Sources", "Tests", "Package.swift", "README.md", ".git", ".gitignore"],
        "/Users/demo/Developer/weather-app/Sources": ["App", "Networking"],
        "/Users/demo/Developer/weather-app/Sources/App": ["AppModel.swift", "LoginView.swift", "WeatherView.swift"],
        "/Users/demo/Developer/weather-app/Sources/Networking": ["APIClient.swift", "RetryPolicy.swift"],
        "/Users/demo/Developer/weather-app/Tests": ["APIClientTests.swift", "LoginTests.swift"],
        "/Users/demo/Developer/weather-app/.git": ["HEAD", "config"],
        "/Users/demo/Developer/portfolio-site": ["src", "public", "package.json", "README.md", ".git"],
        "/Users/demo/Developer/portfolio-site/src": ["index.html", "main.js", "styles.css"],
        "/Users/demo/Developer/portfolio-site/public": ["favicon.svg"],
        "/Users/demo/Developer/portfolio-site/.git": ["HEAD", "config"],
        "/Users/demo/Developer/scripts": ["backup.sh", "rename-photos.py"],
        "/Users/demo/Developer/dotfiles": ["install.sh", "README.md", ".git"],
        "/Users/demo/Developer/dotfiles/.git": ["HEAD", "config"],
        "/Users/demo/Documents": ["Notes", "Invoices", "Resume.pdf"],
        "/Users/demo/Documents/Notes": ["2026-10-20.md", "2026-10-21.md", "2026-10-22.md"],
        "/Users/demo/Documents/Invoices": ["2026-09.pdf", "2026-10.pdf"],
        "/Users/demo/Downloads": ["installer.dmg"],
        "/Users/demo/Music": [],
        "/Users/demo/Pictures": [],
        "/Users/demo/.config": ["gh"],
        "/Users/demo/.config/gh": ["config.yml"],
    ]

    static let gitRepositories: Set<String> = [
        "/Users/demo/Developer/weather-app",
        "/Users/demo/Developer/portfolio-site",
        "/Users/demo/Developer/dotfiles",
    ]

    static func normalize(_ path: String?, home: String) -> String {
        guard var path, !path.isEmpty, path != "~" else { return home }
        if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        if !path.hasPrefix("/") { path = home + "/" + path }
        let standardized = (path as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    static func title(from message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " || character == "\n", current.count >= 6 {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func requiresPermission(_ tool: String, mode: PermissionMode) -> Bool {
        switch mode {
        case .bypassPermissions: false
        case .acceptEdits: ["Bash", "WebFetch"].contains(tool)
        case .default, .plan: ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "WebFetch"].contains(tool)
        }
    }

    // MARK: Localised strings

    private static var language: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("tr") { return "tr" }
        if preferred.hasPrefix("de") { return "de" }
        return "en"
    }

    private static func text(_ key: String) -> String {
        strings[language]?[key] ?? strings["en"]?[key] ?? key
    }

    private static let strings: [String: [String: String]] = [
        "en": [
            "login.title": "Fix the flaky login test",
            "login.user": "LoginTests fails about once in five runs on CI. Can you find out why and fix it?",
            "login.answer": "The test was racing the retry timer: `RetryPolicy` used the real clock, so a slow CI machine sometimes retried before the mock server answered. I injected a clock, used an immediate clock in the test, and the suite now passes 50 runs in a row.",
            "site.title": "Add a dark mode toggle",
            "site.user": "Add a dark mode toggle to the portfolio site and remember the choice.",
            "site.answer": "Done. The toggle lives in the header, follows the system setting by default and stores an explicit choice in `localStorage`.",
            "notes.title": "Summarize this week's notes",
            "notes.user": "Summarize my notes from this week into five bullet points.",
            "notes.answer": "Here is your week in five points:\n\n- **Weather app**: login flakiness traced to the retry timer.\n- **Portfolio**: dark mode shipped.\n- **Planning**: Q4 roadmap draft due Friday.\n- **Reading**: two chapters of *The Pragmatic Programmer*.\n- **Personal**: book the dentist appointment.",
            "script.think": "The user wants a change in this project. I should look at the structure, find the relevant code, make a focused edit and verify it with the tests.",
            "script.intro": "I'll start by looking at how the project is organised.",
            "script.found": "`RetryPolicy` schedules retries with `Task.sleep` on the real clock. I'll make the clock injectable so tests can control time.",
            "script.summary": "All set! Here's what I changed:\n\n1. **`RetryPolicy`** now takes a `Clock` — production uses `ContinuousClock`, tests use an immediate clock.\n2. **`LoginTests`** no longer depends on timing.\n\n```swift\nlet policy = RetryPolicy(maxAttempts: 3, clock: .immediate)\n```\n\nThe whole suite passes (42 tests, 0 failures).",
            "todo.1": "Make RetryPolicy's clock injectable",
            "todo.2": "Use an immediate clock in LoginTests",
            "todo.3": "Run the full test suite",
        ],
        "tr": [
            "login.title": "Kararsız giriş testini düzelt",
            "login.user": "LoginTests CI'da yaklaşık her beş çalıştırmada bir başarısız oluyor. Nedenini bulup düzeltebilir misin?",
            "login.answer": "Test, yeniden deneme zamanlayıcısıyla yarışıyordu: `RetryPolicy` gerçek saati kullanıyordu, yavaş bir CI makinesinde sahte sunucu yanıt vermeden yeniden deneme yapılıyordu. Saati enjekte edilebilir yaptım, testte anında ilerleyen bir saat kullandım; test paketi artık art arda 50 kez geçiyor.",
            "site.title": "Karanlık mod anahtarı ekle",
            "site.user": "Portfolyo sitesine karanlık mod anahtarı ekle ve seçimi hatırla.",
            "site.answer": "Tamamlandı. Anahtar başlıkta; varsayılan olarak sistem ayarını izliyor ve açık bir seçimi `localStorage` içinde saklıyor.",
            "notes.title": "Bu haftanın notlarını özetle",
            "notes.user": "Bu haftaki notlarımı beş maddede özetle.",
            "notes.answer": "Haftan beş maddede:\n\n- **Hava durumu uygulaması**: giriş sorunu yeniden deneme zamanlayıcısına bağlandı.\n- **Portfolyo**: karanlık mod yayında.\n- **Planlama**: 4. çeyrek yol haritası taslağı cuma günü.\n- **Okuma**: *The Pragmatic Programmer*'dan iki bölüm.\n- **Kişisel**: dişçi randevusunu al.",
            "script.think": "Kullanıcı bu projede bir değişiklik istiyor. Yapıya bakmalı, ilgili kodu bulmalı, odaklı bir düzenleme yapmalı ve testlerle doğrulamalıyım.",
            "script.intro": "Önce projenin nasıl düzenlendiğine bakacağım.",
            "script.found": "`RetryPolicy`, yeniden denemeleri gerçek saatte `Task.sleep` ile planlıyor. Testlerin zamanı kontrol edebilmesi için saati enjekte edilebilir yapacağım.",
            "script.summary": "Hazır! Yaptığım değişiklikler:\n\n1. **`RetryPolicy`** artık bir `Clock` alıyor — üretimde `ContinuousClock`, testlerde anında ilerleyen saat.\n2. **`LoginTests`** artık zamanlamaya bağlı değil.\n\n```swift\nlet policy = RetryPolicy(maxAttempts: 3, clock: .immediate)\n```\n\nTüm paket geçiyor (42 test, 0 hata).",
            "todo.1": "RetryPolicy saatini enjekte edilebilir yap",
            "todo.2": "LoginTests'te anında saat kullan",
            "todo.3": "Tüm test paketini çalıştır",
        ],
        "de": [
            "login.title": "Wackeligen Login-Test reparieren",
            "login.user": "LoginTests schlägt auf CI etwa bei jedem fünften Lauf fehl. Kannst du die Ursache finden und beheben?",
            "login.answer": "Der Test lieferte sich ein Rennen mit dem Retry-Timer: `RetryPolicy` nutzte die echte Uhr, daher wiederholte eine langsame CI-Maschine manchmal, bevor der Mock-Server antwortete. Ich habe die Uhr injizierbar gemacht und im Test eine sofortige Uhr verwendet – die Suite besteht jetzt 50 Läufe am Stück.",
            "site.title": "Dark-Mode-Schalter hinzufügen",
            "site.user": "Füge der Portfolio-Seite einen Dark-Mode-Schalter hinzu und merke dir die Auswahl.",
            "site.answer": "Erledigt. Der Schalter sitzt im Header, folgt standardmäßig der Systemeinstellung und speichert eine explizite Wahl in `localStorage`.",
            "notes.title": "Notizen dieser Woche zusammenfassen",
            "notes.user": "Fasse meine Notizen dieser Woche in fünf Stichpunkten zusammen.",
            "notes.answer": "Deine Woche in fünf Punkten:\n\n- **Wetter-App**: Login-Problem auf den Retry-Timer zurückgeführt.\n- **Portfolio**: Dark Mode ist live.\n- **Planung**: Q4-Roadmap-Entwurf bis Freitag.\n- **Lesen**: zwei Kapitel *The Pragmatic Programmer*.\n- **Privat**: Zahnarzttermin vereinbaren.",
            "script.think": "Der Nutzer möchte eine Änderung in diesem Projekt. Ich sollte die Struktur ansehen, den relevanten Code finden, gezielt ändern und mit den Tests prüfen.",
            "script.intro": "Ich sehe mir zuerst an, wie das Projekt aufgebaut ist.",
            "script.found": "`RetryPolicy` plant Wiederholungen mit `Task.sleep` auf der echten Uhr. Ich mache die Uhr injizierbar, damit Tests die Zeit steuern können.",
            "script.summary": "Fertig! Das habe ich geändert:\n\n1. **`RetryPolicy`** nimmt jetzt eine `Clock` – produktiv `ContinuousClock`, in Tests eine sofortige Uhr.\n2. **`LoginTests`** hängt nicht mehr vom Timing ab.\n\n```swift\nlet policy = RetryPolicy(maxAttempts: 3, clock: .immediate)\n```\n\nDie ganze Suite besteht (42 Tests, 0 Fehler).",
            "todo.1": "Uhr von RetryPolicy injizierbar machen",
            "todo.2": "Sofortige Uhr in LoginTests verwenden",
            "todo.3": "Gesamte Test-Suite ausführen",
        ],
    ]

    // MARK: Seeds

    struct Seed {
        var summary: SessionSummary
        var events: [SessionEvent]
    }

    static func seedSessions(now: Date) -> [Seed] {
        let weather = "/Users/demo/Developer/weather-app"
        let site = "/Users/demo/Developer/portfolio-site"
        let notes = "/Users/demo/Documents/Notes"
        return [
            Seed(
                summary: SessionSummary(
                    id: "demo-session-login", cwd: weather, title: text("login.title"),
                    lastMessagePreview: text("login.answer"), createdAt: now.addingTimeInterval(-3_600),
                    updatedAt: now.addingTimeInterval(-720), model: "sonnet", permissionMode: .default, state: .idle,
                    slashCommands: slashCommands
                ),
                events: [
                    .userMessage(.init(text: text("login.user"))),
                    .toolUse(.init(toolUseId: "toolu_seed_1", name: "Read", input: ["file_path": .string("\(weather)/Tests/LoginTests.swift")])),
                    .toolResult(.init(toolUseId: "toolu_seed_1", output: loginTestsSource, isError: false)),
                    .toolUse(.init(toolUseId: "toolu_seed_2", name: "Edit", input: [
                        "file_path": .string("\(weather)/Sources/Networking/RetryPolicy.swift"),
                        "old_string": "    let delay: Duration",
                        "new_string": "    let delay: Duration\n    let clock: any Clock<Duration>",
                    ])),
                    .permissionDecision(.init(requestId: "seed-permission-1", toolName: "Edit", summary: "\(weather)/Sources/Networking/RetryPolicy.swift", outcome: .allowed)),
                    .toolResult(.init(toolUseId: "toolu_seed_2", output: "The file \(weather)/Sources/Networking/RetryPolicy.swift has been updated successfully.", isError: false)),
                    .fileEdit(.init(toolUseId: "toolu_seed_2", path: "\(weather)/Sources/Networking/RetryPolicy.swift", kind: .modified, diff: retryDiff)),
                    .toolUse(.init(toolUseId: "toolu_seed_3", name: "Bash", input: ["command": "swift test --filter LoginTests", "description": "Run the login tests"])),
                    .permissionDecision(.init(requestId: "seed-permission-2", toolName: "Bash", summary: "swift test --filter LoginTests", outcome: .allowed)),
                    .toolResult(.init(toolUseId: "toolu_seed_3", output: testOutput, isError: false)),
                    .assistantMessage(.init(blockId: "seed-login:0", text: text("login.answer"))),
                    .result(.init(isError: false, subtype: "success", durationMs: 48_210, numTurns: 7, costUSD: 0.0841)),
                ]
            ),
            Seed(
                summary: SessionSummary(
                    id: "demo-session-site", cwd: site, title: text("site.title"),
                    lastMessagePreview: text("site.answer"), createdAt: now.addingTimeInterval(-7_200),
                    updatedAt: now.addingTimeInterval(-5_400), model: "sonnet", permissionMode: .acceptEdits, state: .idle,
                    slashCommands: slashCommands
                ),
                events: [
                    .userMessage(.init(text: text("site.user"))),
                    .toolUse(.init(toolUseId: "toolu_seed_4", name: "Write", input: ["file_path": .string("\(site)/src/theme.js"), "content": .string(themeSource)])),
                    .toolResult(.init(toolUseId: "toolu_seed_4", output: "File created successfully at: \(site)/src/theme.js", isError: false)),
                    .fileEdit(.init(toolUseId: "toolu_seed_4", path: "\(site)/src/theme.js", kind: .created, diff: themeSource.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" }.joined(separator: "\n"))),
                    .assistantMessage(.init(blockId: "seed-site:0", text: text("site.answer"))),
                    .result(.init(isError: false, subtype: "success", durationMs: 21_904, numTurns: 4, costUSD: 0.0312)),
                ]
            ),
            Seed(
                summary: SessionSummary(
                    id: "demo-session-notes", cwd: notes, title: text("notes.title"),
                    lastMessagePreview: text("notes.answer"), createdAt: now.addingTimeInterval(-90_000),
                    updatedAt: now.addingTimeInterval(-86_400), model: "haiku", permissionMode: .plan, state: .closed,
                    slashCommands: slashCommands
                ),
                events: [
                    .userMessage(.init(text: text("notes.user"))),
                    .toolUse(.init(toolUseId: "toolu_seed_5", name: "Glob", input: ["pattern": "*.md"])),
                    .toolResult(.init(toolUseId: "toolu_seed_5", output: "\(notes)/2026-10-20.md\n\(notes)/2026-10-21.md\n\(notes)/2026-10-22.md", isError: false)),
                    .assistantMessage(.init(blockId: "seed-notes:0", text: text("notes.answer"))),
                    .result(.init(isError: false, subtype: "success", durationMs: 9_120, numTurns: 3, costUSD: 0.0041)),
                ]
            ),
        ]
    }

    // MARK: Script

    enum Step {
        case think(String)
        case say(String, index: Int)
        case tool(name: String, input: JSONValue, output: String, isError: Bool, edit: SessionEvent.FileEdit?)
        /// Claude hands a task to another agent; its steps stream into a thread.
        case delegate(agent: AgentKind, prompt: String, command: String, output: String, answer: String)
    }

    static func script(for prompt: String, cwd: String, turn: Int) -> [Step] {
        let retryPath = "\(cwd)/Sources/Networking/RetryPolicy.swift"
        if prompt.localizedCaseInsensitiveContains("codex") {
            return [
                .say("I'll ask Codex for a second opinion on the retry logic.", index: 0),
                .delegate(
                    agent: .codex,
                    prompt: "Review Sources/Networking/RetryPolicy.swift for timing bugs and suggest a fix.",
                    command: "rg -n \"sleep\" Sources/Networking",
                    output: "Sources/Networking/RetryPolicy.swift:18:            try await Task.sleep(for: delay)",
                    answer: "RetryPolicy sleeps on the real clock, so tests race the timer. Inject a Clock and use it in retry(after:)."
                ),
                .say("Codex agrees: inject a clock into RetryPolicy so the tests control time. Want me to make that change?", index: 1),
            ]
        }
        return [
            .think(text("script.think")),
            .say(text("script.intro"), index: 0),
            .tool(name: "Glob", input: ["pattern": "**/*.swift"], output: [
                "\(cwd)/Sources/App/AppModel.swift",
                "\(cwd)/Sources/App/LoginView.swift",
                "\(cwd)/Sources/Networking/APIClient.swift",
                "\(cwd)/Sources/Networking/RetryPolicy.swift",
                "\(cwd)/Tests/LoginTests.swift",
            ].joined(separator: "\n"), isError: false, edit: nil),
            .tool(name: "Grep", input: ["pattern": "Task.sleep", "path": .string(cwd), "output_mode": "content"],
                  output: "\(retryPath):18:            try await Task.sleep(for: delay)", isError: false, edit: nil),
            .say(text("script.found"), index: 1),
            .tool(name: "TodoWrite", input: ["todos": [
                ["content": .string(text("todo.1")), "status": "in_progress", "activeForm": .string(text("todo.1"))],
                ["content": .string(text("todo.2")), "status": "pending", "activeForm": .string(text("todo.2"))],
                ["content": .string(text("todo.3")), "status": "pending", "activeForm": .string(text("todo.3"))],
            ]], output: "Todos have been modified successfully.", isError: false, edit: nil),
            .tool(name: "Edit", input: [
                "file_path": .string(retryPath),
                "old_string": "            try await Task.sleep(for: delay)",
                "new_string": "            try await clock.sleep(for: delay)",
            ], output: "The file \(retryPath) has been updated successfully.", isError: false,
                  edit: .init(toolUseId: "", path: retryPath, kind: .modified, diff: sleepDiff)),
            .tool(name: "Bash", input: ["command": "swift test", "description": "Run the full test suite"],
                  output: testOutput, isError: false, edit: nil),
            .say(text("script.summary"), index: 2),
        ]
    }

    // MARK: Sample sources

    static let loginTestsSource = """
          1\timport Testing
          2\t@testable import WeatherApp
          3\t
          4\t@Suite struct LoginTests {
          5\t    @Test func retriesAfterTimeout() async throws {
          6\t        let server = MockServer(failures: 1)
          7\t        let client = APIClient(server: server, retry: .default)
          8\t        let session = try await client.login(user: "demo", password: "••••••")
          9\t        #expect(session.isValid)
         10\t    }
         11\t}
        """

    static let retryDiff = """
        @@ -4,6 +4,7 @@
         struct RetryPolicy: Sendable {
             let maxAttempts: Int
             let delay: Duration
        +    let clock: any Clock<Duration>

             func run<T>(_ operation: () async throws -> T) async throws -> T {
                 var attempt = 0
        """

    static let sleepDiff = """
        @@ -15,7 +15,7 @@
                     } catch where attempt < maxAttempts {
                         attempt += 1
        -            try await Task.sleep(for: delay)
        +            try await clock.sleep(for: delay)
                     }
                 }
             }
        """

    static let testOutput = """
        Building for debugging...
        [4/4] Linking WeatherAppPackageTests
        Build complete! (3.12s)
        ◇ Test run started.
        ✔ Suite APIClientTests passed after 0.214 seconds.
        ✔ Suite LoginTests passed after 0.031 seconds.
        ✔ Test run with 42 tests in 6 suites passed after 0.402 seconds.
        """

    static let themeSource = """
        const storageKey = "theme";
        const root = document.documentElement;

        export function applyTheme(theme) {
          root.dataset.theme = theme ?? (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
        }

        export function toggleTheme() {
          const next = root.dataset.theme === "dark" ? "light" : "dark";
          localStorage.setItem(storageKey, next);
          applyTheme(next);
        }

        applyTheme(localStorage.getItem(storageKey));
        """
}
