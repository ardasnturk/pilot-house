<p align="center"><img src="docs/icon.png" width="128" height="128" alt="Pilothouse simgesi"></p>

<h1 align="center">Pilothouse</h1>

<p align="center">Mac'inizdeki <b>Claude Code</b> CLI'ını iPhone veya iPad'inizden yönetin.</p>

<p align="center"><a href="README.md">English</a> · <b>Türkçe</b></p>

> **Pilothouse, Claude Code ile çalışır.** Bağımsız, açık kaynaklı bir projedir;
> **Anthropic ile bağlantılı değildir, Anthropic tarafından onaylanmamış veya
> desteklenmemiştir.** Claude Code'u
> [Anthropic'in koşullarına](https://www.anthropic.com/legal) uygun kullanmak
> sizin sorumluluğunuzdadır.

Pilothouse iki uygulama ve ortak bir Swift paketinden oluşur:

* **Mac için Pilothouse** — Mac'inizde resmi `claude` komut satırı aracını
  başlatan ve denetleyen, Mac'i uyanık tutan ve her şeyi eşleştirilmiş
  cihazlarınıza ileten küçük bir menü çubuğu uygulaması.
* **iPhone ve iPad için Pilothouse** — herhangi bir proje klasöründe oturum
  başlatın; yanıtları, düşünmeyi, araç çağrılarını, farkları (diff) ve terminal
  çıktısını canlı izleyin, her işlemi onaylayın ya da reddedin.

Pilothouse **Anthropic'e hiçbir zaman bağlanmaz** ve Claude kimlik bilgilerinize
asla dokunmaz: tüm yapay zeka işini kendi hesabınızla giriş yaptığınız `claude`
CLI'ı yapar. Sunucu, hesap ya da telemetri yoktur — yalnızca uçtan uca
şifrelenmiş şekilde konuşan kendi cihazlarınız vardır.

## İçindekiler

* [Gereksinimler](#gereksinimler)
* [Kurulum](#kurulum)
* [Telefonu eşleştirme](#telefonu-eşleştirme)
* [Kullanım](#kullanım)
* [Evden uzakta: Tailscale](#evden-uzakta-tailscale)
* [Mac'i uyanık tutma](#maci-uyanık-tutma)
* [Güvenlik modeli](#güvenlik-modeli)
* [SSS](#sss)
* [Kaynaktan derleme](#kaynaktan-derleme)
* [Katkıda bulunma](#katkıda-bulunma)
* [Lisans](#lisans)

## Gereksinimler

| | |
|---|---|
| Mac | macOS 15 Sequoia veya üstü, Apple silicon ya da Intel |
| iPhone / iPad | iOS / iPadOS 18 veya üstü |
| Claude Code | Mac'te kurulu resmi CLI ([kurulum rehberi](https://docs.claude.com/en/docs/claude-code/setup)), **kendi Claude hesabınızla** giriş yapılmış — ya da kendi Anthropic API anahtarınız |
| Ağ | İki cihaz aynı ağda ya da ikisi de [Tailscale](https://tailscale.com) ağınızda |

## Kurulum

**Mac uygulaması** — noter onaylı (notarized) `Pilothouse-<sürüm>.dmg`
dosyasını [GitHub Releases](https://github.com/ardasnturk/pilot-house/releases)
sayfasından indirin ya da Homebrew kullanın:

```sh
brew tap ardasnturk/pilothouse https://github.com/ardasnturk/pilot-house
brew install --cask pilothouse
```

Pilothouse'u açın; simgesi menü çubuğunda görünür. Claude Code kurulu değilse ya
da giriş yapılmamışsa uygulama kısa bir kurulum rehberi gösterir
(`curl -fsSL https://claude.ai/install.sh | bash`, ardından giriş yapmak için
Terminal'de bir kez `claude`).

**iPhone / iPad uygulaması** — App Store'dan (beta süresince TestFlight).
Her şeyi önce **Demoyu Dene** ile deneyebilirsiniz: uygulamanın içinde
simüle edilmiş bir Mac; Mac ya da hesap gerekmez.

## Telefonu eşleştirme

1. Mac'te: menü çubuğu simgesi → **Yeni Cihaz Eşleştir…**. Bir QR kod belirir;
   5 dakika geçerlidir ve yalnızca bir kez kullanılabilir.
2. Telefonda: **Mac'inizle Eşleştirin** → kodu okutun. iOS sorduğunda *Yerel Ağ*
   iznini verin.
3. İki ekranda da aynı **doğrulama kodu** görünür. Bu kadar — Mac ve telefon
   artık birbirinin anahtarına güvenir.

Bir cihazı mı kaybettiniz? Mac menüsü → **Eşleşmiş cihazlar** → **İptal Et**.
O cihazın bağlantıları anında kesilir.

## Kullanım

* **Yeni Sohbet** → Mac'inizin ev klasöründeki klasörlere göz atın (favoriler,
  son kullanılanlar; Git depoları işaretlidir) → **… içinde başlat**. Modeli ve
  izin modunu seçin:
  * *Her seferinde sor* (varsayılan) — onay gerektiren her işlem telefonunuza
    gelir,
  * *Düzenlemeleri kabul et* — dosya düzenlemeleri uygulanır, komutlar yine
    sorulur,
  * *Plan* — Claude yalnızca plan yapar,
  * *İzinleri atla* — yalnızca Mac ayarlarında izin verdiyseniz; kırmızıyla
    gösterilir.
* **İzin istekleri**, Claude'un ne yapmak istediğini gösteren bir sayfa olarak
  açılır: bir düzenlemenin farkı, çalıştırmak istediği komut. *İzin Ver*,
  *Reddet* ya da *Bu oturumda … için hep izin ver*. Kimsenin yanıtlamadığı
  istekler **10 dakika sonra reddedilir**.
* **Durdur**, çalışan turu anında bitirir (Ctrl-C gibi). Bir sonraki mesajınız
  aynı sohbeti sürdürür.
* **Oturumlar**, Pilothouse'un Mac'te çalıştırdığı tüm oturumları listeler
  (30 gün saklanır). Birini açıp okuyabilir — çevrimdışı da — ya da tüm
  bağlamıyla sürdürebilirsiniz.
* Mac'te menü çubuğu, çalışan oturumları ve bekleyen onayları gösterir; onları
  orada da yanıtlayabilirsiniz.

## Evden uzakta: Tailscale

Evde ya da ofiste telefon Mac'i Bonjour ile bulur (`_pilothouse._tcp`, port
47823 ya da bir sonraki boş port). Başka yerlerde Pilothouse, cihazlarınız
arasında ücretsiz bir özel ağ olan [Tailscale](https://tailscale.com)'i kullanır:

* Mac menüsü → **Tailscale** → **Claude ile otomatik kur**: Pilothouse, Tailscale'i adım
  adım kuran ve yapılandıran bir Claude Code oturumu açar; parolanız ya da
  tarayıcıda giriş gerektiğinde durur — her komut, Mac'te ya da telefonda
  onayınızı bekler. Kendiniz yapmayı mı tercih edersiniz? **Elle Kur** adımları
  gösterir.
* Telefonda: App Store'dan Tailscale uygulamasını kurun ve aynı hesapla giriş
  yapın. Pilothouse ardından sırasıyla son çalışan yolu, Bonjour'u, yerel IP
  adreslerini ve en son Tailscale adresini otomatik olarak dener.

## Mac'i uyanık tutma

Pilothouse çalışırken *boşta sistem uykusunu engelleme* kilidi tutar: ekran
kapanabilir, Mac erişilebilir kalır. İsteğe bağlı **Kapak kapalıyken de açık
kal** (Mac ayarları → Genel), tek yeteneği `pmset -a disablesleep 0/1` olan
küçük bir ayrıcalıklı yardımcı kullanır. Pilde otomatik olarak kapanır
(ayarlanabilir) ve Pilothouse kapanınca geri alınır. Kapağı kapalı ama uyanık
bir MacBook ısınabilir — çantada değil, masada kullanın.

## Güvenlik modeli

* **Eşleştirme:** QR kod, Mac'in açık anahtarını ve tek kullanımlık bir belirteci
  içerir. Ağdaki bir saldırgan Mac'i taklit edemez: el sıkışmayı yalnızca
  eşleşen özel anahtarın sahibi tamamlayabilir.
* **Her bağlantı:** `Noise_IK_25519_ChaChaPoly_SHA256` — sabitlenmiş X25519
  anahtarlarıyla karşılıklı kimlik doğrulama, her bağlantıda yeni oturum
  anahtarları, ChaCha20-Poly1305, kesin artan nonce'lar, zaman damgaları
  (tekrar oynatma reddedilir).
* **Dosyalar:** telefon yalnızca ev klasörünüzün içine göz atabilir ve orada
  oturum başlatabilir; yollar kontrol öncesi normalleştirilir, sembolik
  bağlantılar çözülür.
* **Onaylar:** Claude Code'un kendi izin sistemi yetkili kalır; Pilothouse
  onun isteklerini, oturum başına bir belirteçle korunan ve yalnızca localhost'ta
  dinleyen bir MCP uç noktası üzerinden iletir.
* **Kimlik bilgileri:** Pilothouse Claude girişinizi asla okumaz, saklamaz ya da
  iletmez. İsteğe bağlı API anahtarı (Mac ayarları → Claude Code) Anahtar
  Zinciri'nde tutulur ve yalnızca `claude`'a `ANTHROPIC_API_KEY` olarak verilir.
* **Veri:** Mac'te oturum kayıtları (mod 0600, 30 gün sonra silinir), telefonda
  bir önbellek, Anahtar Zinciri'nde anahtarlar. Başka hiçbir şey, başka hiçbir
  yerde.

Ayrıntılar: [docs/SECURITY.md](docs/SECURITY.md) · protokol:
[docs/PROTOCOL.md](docs/PROTOCOL.md) · gizlilik: [PRIVACY.md](PRIVACY.md).
Güvenlik açıklarını lütfen *Security → Report a vulnerability* üzerinden gizli
olarak bildirin.

## SSS

**Pilothouse Claude aboneliği gerektirir mi?**
Claude Code CLI'ınız neye ihtiyaç duyuyorsa onu — Claude Code erişimi olan bir
Claude hesabı ya da bir Anthropic API anahtarı. Pilothouse'un kendisi ücretsizdir.

**Kodum Mac'imden çıkar mı?**
Yalnızca Claude Code ile zaten çıktığı şekilde: CLI her zamanki gibi
Anthropic ile konuşur. Pilothouse yalnızca *sizin* telefonunuza şifreli bir
bağlantı ekler.

**Mac uygulaması neden Mac App Store'da değil?**
Uygulama kendi `claude` programınızı kabuk ortamınızla çalıştırmalı ve tüm
klasörlerinizde çalışabilmelidir; App Store korumalı alanı (sandbox) buna izin
vermez (D-080). Uygulama Developer ID ile imzalı ve Apple tarafından noter
onaylıdır.

**Telefonu mobil veriyle kullanabilir miyim?**
Evet, Tailscale ile (yukarıya bakın). Tailscale olmadan telefon Mac ile aynı
ağda olmalıdır.

**Tur sürerken telefonun bağlantısı koparsa ne olur?**
Hiçbir şey kaybolmaz. Claude Mac'te çalışmaya devam eder; telefon yeniden
bağlandığında oturum kaydından eksikleri tamamlar. İzin istekleri sizi bekler
(10 dakikaya kadar).

**Bildirimler?**
1.1'den beri Mac'te Ayarlar → Bildirimler altında (varsayılan olarak kapalı):
telefondan başlattığınız bir görev bittiğinde, Claude onay beklediğinde ya da
bir oturum hata verdiğinde yerel macOS bildirimleri ve [ntfy](https://ntfy.sh)
üzerinden iPhone bildirimleri. Oluşturulan konuya ücretsiz ntfy uygulamasında
abone olun; bildirime dokununca oturum Pilothouse'da açılır. Varsayılan olarak
yalnızca "Görev bitti · <klasör>" gönderilir (D-095).

**Kayıtlar nerede?**
`~/Library/Application Support/Pilothouse/sessions/<oturum-kimliği>.jsonl`.

**Nasıl kaldırırım?**
Pilothouse'tan çıkın ve silin (ya da `brew uninstall --zap --cask pilothouse`).
Tamamen temiz bir kurulum için `~/Library/Application Support/Pilothouse`
klasörünü ve Anahtar Zinciri Erişimi'ndeki "Pilothouse identity key" öğelerini
silin.

## Kaynaktan derleme

```sh
git clone https://github.com/ardasnturk/pilot-house.git && cd pilot-house
open Pilothouse.xcodeproj          # Xcode 16 veya üstü; şemalar PilothouseMac / PilothouseiOS
scripts/test.sh                    # bu makinenin çalıştırabildiği tüm testler
```

* `PilothouseKit/` — protokol, kriptografi, istemci, demo Mac (`PilothouseKit`)
  ve Mac sunucu çekirdeği (`PilothouseHost`); Linux'ta da derlenir ve test
  edilir (`swift test`).
* `PilothouseMac/`, `PilothouseHelper/`, `PilothouseiOS/` — uygulamalar.
* `project.yml` — XcodeGen tanımı; değiştirdikten sonra `scripts/bootstrap.sh`
  çalıştırın.
* Sürüm çıkarma: [docs/RELEASE.md](docs/RELEASE.md). Testler:
  [docs/TESTING.md](docs/TESTING.md). Tasarım kararları:
  [docs/DECISIONS.md](docs/DECISIONS.md) (İngilizce).

Apple platformlarında üçüncü taraf bağımlılık yoktur.

## Katkıda bulunma

Hata bildirimleri ve pull request'ler memnuniyetle karşılanır — lütfen önce
[CONTRIBUTING.md](CONTRIBUTING.md) dosyasını okuyun. Çeviriler
`scripts/l10n/` içindedir; yeni bir dil eklemek harika bir ilk katkıdır.

## Lisans

[MIT](LICENSE) © 2026 Arda Şentürk.

"Claude" ve "Claude Code", Anthropic, PBC'nin ticari markalarıdır ve burada
yalnızca uyumluluğu belirtmek için kullanılmıştır. "Tailscale", Tailscale Inc.'in
ticari markasıdır.
