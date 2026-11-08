# KumandaMac

Bluetooth kumandanın (ör. eski Xiaomi Mi TV Stick kumandası) tuşlarını Mac'te algılayıp istediğin **tuşa veya tuş kombinasyonuna** (ör. `⌘V`) çeviren küçük, tek dosyalık macOS uygulaması.

## Özellikler
- Kumandada bastığın tuşu otomatik algılar
- Yerine tek tuş veya kombinasyon (⌘ ⌥ ⌃ ⇧ + tuş) atayabilirsin
- Atamalar kalıcıdır ve listeden silinebilir
- Harici bağımlılık yok, sadece Swift ve AppKit
- Apple Silicon ve Intel Mac'lerde çalışır (evrensel derleme)

## GitHub'da derleme (kurulum gerektirmez)
Repo her `main` push'unda GitHub Actions ile otomatik derlenir.

1. Repo sayfasında **Actions** sekmesine gir, son çalışmayı aç.
2. Sayfanın altındaki **Artifacts** bölümünden `KumandaMac-macos` dosyasını indir ve zip'ten çıkar.

Kalıcı bir sürüm yayınlamak için etiket at, `.app` dosyası **Releases** sayfasına otomatik eklenir:
```bash
git tag v1.0
git push origin v1.0
```
Elle başlatmak için: Actions → Build → **Run workflow**.

## İlk açılış (Gatekeeper)
Uygulama Apple geliştirici hesabıyla imzalanmadığı için macOS ilk açılışta engelleyebilir. Şunlardan birini yap:
- Uygulamaya sağ tık → **Aç** → **Aç**, veya
- Terminal'de: `xattr -dr com.apple.quarantine KumandaMac.app`

Sonra **Sistem Ayarları → Gizlilik ve Güvenlik** altında **Erişilebilirlik** ve **Giriş İzleme** bölümlerinde *Kumanda Ayar*'ı etkinleştirip uygulamayı yeniden başlat.

## Yerelde derleme
Xcode Command Line Tools gerekir (`xcode-select --install`).
```bash
./build.sh
open build/KumandaMac.app
```

## Kullanım
1. Kumandayı Mac'e Bluetooth ile eşleştir.
2. **Yeni atama ekle** düğmesine bas.
3. Kumandada atamak istediğin tuşa bas.
4. Yerine çalışacak tuşa veya kombinasyona bas (ör. `⌘V`).
5. Silmek için listedeki **Sil** düğmesini kullan.

## Bilinen sınırlamalar
- Atamalar tüm klavyeleri etkiler, uygulama kumanda ile Mac klavyesini ayırt etmez.
- Ses, Home, Menü gibi medya tuşları ve Netflix, Assistant gibi özel tuşlar yakalanmayabilir. Bunlar için [Karabiner-Elements](https://karabiner-elements.pqrs.org/) kullanılabilir.
- Atamalar yalnızca uygulama açıkken çalışır.

## Lisans
MIT, ayrıntılar için `LICENSE` dosyasına bak.
