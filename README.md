# Soundboard

macOS menü çubuğunda çalışan uygulama bazlı ses mikseri.

## Gereksinimler

- macOS 15 veya üzeri
- Swift 6 ve macOS SDK 15 veya üzerini içeren Xcode ya da Command Line Tools
- Uygulama ilk kez ses kontrolü yaptığında **Sistem Ayarları → Gizlilik ve Güvenlik → Ekran ve Sistem Ses Kaydı** izni

## Derleme

```sh
chmod +x Packaging/build-app.sh
./Packaging/build-app.sh
open build/Soundboard.app
```

macOS'un ses süreci olarak gördüğü açık uygulamalar ayrı ayrı kısılır veya susturulur.

Uygulama başına ses kontrolü Apple'ın Core Audio process tap API'sini kullanır. Ayar ilk kez değiştiğinde sistem izin ister; izin verilmezse hedef uygulama sessiz kalabilir.

Core Audio yönlendirme çekirdeği MIT lisanslı [SoundRouter](https://github.com/dws741119/SoundRouter) projesinden alınmıştır; lisans metni `LICENSE` dosyasındadır.
