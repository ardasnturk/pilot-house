# Privacy Policy

*Effective 24 October 2026 · applies to the Pilothouse iOS/iPadOS app and the
Pilothouse Mac app.*

**English** · [Türkçe](#gizlilik-politikası) · [Deutsch](#datenschutzerklärung)

Pilothouse does not collect, store or share any personal data on servers. There
are no accounts, no analytics, no advertising, no crash reporting and no
third-party SDKs.

* **Your devices only.** The iPhone/iPad app talks only to the Mac(s) you pair
  it with, over your local network or your own Tailscale network. All traffic is
  end-to-end encrypted. Neither the developer nor anyone else receives it.
* **No connection to Anthropic.** Pilothouse never contacts Anthropic or any
  other service, except the notification server you set up yourself (below). The Claude Code command-line tool on your Mac — which you
  install and sign in to yourself — processes your requests under Anthropic's
  own terms and privacy policy.
* **Stored on your devices.** Session transcripts are kept on your Mac
  (`~/Library/Application Support/Pilothouse`, deleted after 30 days by default)
  and cached on your phone for offline reading. Pairing keys are kept in the
  Keychain of each device. You can delete all of it at any time: clear the cache
  in the app's settings, unpair the Mac, or uninstall the apps.
* **Camera.** Used only to scan the pairing QR code; images are not stored.
* **Local network.** Used only to find and connect to your own Mac.
* **Photos you attach** to a message are sent to your Mac only.
* **Optional notifications (off by default).** If you turn on "Send to your
  iPhone with ntfy" in the Mac app, your Mac sends each notification to the ntfy
  server you choose (`ntfy.sh` unless you enter your own): the topic name, the
  event and folder name (e.g. "Task finished · my-app") and a link containing
  the session ID and Mac ID. Only if you turn on "Include a short summary" is a
  shortened last message, tool name or error text added. ntfy.sh is run by a
  third party under its own privacy policy and keeps messages for a few hours;
  anyone who knows your topic can read them on a public server. Notifications
  shown on the Mac itself stay on the Mac.

Questions: open an issue at <https://github.com/ardasnturk/pilot-house/issues>.

---

## Gizlilik Politikası

Pilothouse hiçbir kişisel veriyi sunuculara toplamaz, saklamaz veya paylaşmaz.
Hesap, analitik, reklam, çökme raporu ya da üçüncü taraf SDK yoktur.

* **Yalnızca kendi cihazlarınız.** iPhone/iPad uygulaması yalnızca eşleştirdiğiniz
  Mac(ler) ile, yerel ağınız ya da kendi Tailscale ağınız üzerinden konuşur. Tüm
  trafik uçtan uca şifrelidir; geliştirici dahil hiç kimse bu trafiği almaz.
* **Anthropic'e bağlantı yok.** Pilothouse, kendi kurduğunuz bildirim sunucusu
  (aşağıda) dışında Anthropic'e veya başka bir servise asla bağlanmaz. İsteklerinizi, kendinizin kurup giriş yaptığı Mac'inizdeki
  Claude Code komut satırı aracı, Anthropic'in kendi koşulları ve gizlilik
  politikası altında işler.
* **Cihazlarınızda saklananlar.** Oturum dökümleri Mac'inizde
  (`~/Library/Application Support/Pilothouse`, varsayılan olarak 30 gün sonra
  silinir) ve çevrimdışı okuma için telefonunuzda önbellekte tutulur. Eşleştirme
  anahtarları her cihazın Anahtar Zinciri'ndedir. Hepsini istediğiniz zaman
  silebilirsiniz: uygulama ayarlarından önbelleği temizleyin, Mac eşleşmesini
  kaldırın ya da uygulamaları silin.
* **Kamera.** Yalnızca eşleştirme QR kodunu okumak için kullanılır; görüntü
  saklanmaz.
* **Yerel ağ.** Yalnızca kendi Mac'inizi bulmak ve ona bağlanmak için kullanılır.
* **Mesaja eklediğiniz fotoğraflar** yalnızca Mac'inize gönderilir.
* **İsteğe bağlı bildirimler (varsayılan olarak kapalı).** Mac uygulamasında
  "ntfy ile iPhone'unuza gönder"i açarsanız Mac'iniz her bildirimi seçtiğiniz
  ntfy sunucusuna gönderir (kendi sunucunuzu girmediyseniz `ntfy.sh`): konu adı,
  olay ve klasör adı (örn. "Görev bitti · my-app") ve oturum kimliğiyle Mac
  kimliğini içeren bir bağlantı. Kısaltılmış son mesaj, araç adı veya hata
  metni yalnızca "Kısa bir özet ekle" açıksa eklenir. ntfy.sh üçüncü bir tarafça,
  kendi gizlilik politikası altında işletilir ve mesajları birkaç saat saklar;
  herkese açık bir sunucuda konunuzu bilen herkes mesajları okuyabilir. Mac'in
  kendisinde gösterilen bildirimler Mac'te kalır.

Sorular için: <https://github.com/ardasnturk/pilot-house/issues>

---

## Datenschutzerklärung

Pilothouse erhebt, speichert oder teilt keine personenbezogenen Daten auf
Servern. Es gibt keine Konten, keine Analyse, keine Werbung, keine
Absturzberichte und keine SDKs von Drittanbietern.

* **Nur deine Geräte.** Die iPhone/iPad-App kommuniziert ausschließlich mit den
  gekoppelten Macs – über dein lokales Netzwerk oder dein eigenes
  Tailscale-Netz. Der gesamte Verkehr ist Ende-zu-Ende-verschlüsselt; weder der
  Entwickler noch sonst jemand erhält ihn.
* **Keine Verbindung zu Anthropic.** Pilothouse kontaktiert niemals Anthropic
  oder andere Dienste – außer dem Mitteilungsserver, den du selbst einrichtest
  (unten). Deine Anfragen verarbeitet das Kommandozeilenwerkzeug
  Claude Code auf deinem Mac, das du selbst installierst und anmeldest – nach den
  Bedingungen und der Datenschutzerklärung von Anthropic.
* **Auf deinen Geräten gespeichert.** Sitzungsverläufe liegen auf deinem Mac
  (`~/Library/Application Support/Pilothouse`, standardmäßig nach 30 Tagen
  gelöscht) und zum Offline-Lesen im Cache deines iPhones. Kopplungsschlüssel
  liegen im Schlüsselbund des jeweiligen Geräts. Du kannst alles jederzeit
  löschen: Cache in den Einstellungen leeren, Mac entkoppeln oder die Apps
  entfernen.
* **Kamera.** Nur zum Scannen des Kopplungs-QR-Codes; Bilder werden nicht
  gespeichert.
* **Lokales Netzwerk.** Nur um deinen eigenen Mac zu finden und zu verbinden.
* **Angehängte Fotos** werden nur an deinen Mac gesendet.
* **Optionale Mitteilungen (standardmäßig aus).** Wenn du in der Mac-App „Mit
  ntfy an dein iPhone senden“ aktivierst, schickt dein Mac jede Mitteilung an
  den ntfy-Server deiner Wahl (`ntfy.sh`, sofern du keinen eigenen einträgst):
  den Themennamen, Ereignis und Ordnernamen (z. B. „Aufgabe fertig · my-app“)
  und einen Link mit Sitzungs- und Mac-ID. Nur mit „Kurze Zusammenfassung
  hinzufügen“ kommen eine gekürzte letzte Nachricht, der Werkzeugname oder der
  Fehlertext hinzu. ntfy.sh wird von einem Dritten nach dessen eigener
  Datenschutzerklärung betrieben und bewahrt Nachrichten einige Stunden auf;
  auf einem öffentlichen Server kann jeder, der dein Thema kennt, sie lesen.
  Auf dem Mac selbst angezeigte Mitteilungen bleiben auf dem Mac.

Fragen: <https://github.com/ardasnturk/pilot-house/issues>
