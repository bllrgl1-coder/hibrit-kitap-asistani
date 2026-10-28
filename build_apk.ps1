# Kişisel Hibrit E-Kitap Okuyucu ve Akıllı Sesli Kitap Asistanı - Otomatik APK Derleme Betiği
$ErrorActionPreference = "Stop"

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Hibrit E-Kitap & Sesli Kitap Asistani APK Builder" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

if (-not (Get-Command "flutter" -ErrorAction SilentlyContinue)) {
    Write-Host "[UYARI] 'flutter' komutu PATH uzerinde bulunamadi." -ForegroundColor Yellow
    Write-Host "Lutfen Flutter SDK dizinini PATH'e ekleyin veya Android Studio uzerinden acin." -ForegroundColor Yellow
    exit 1
}

Write-Host "1/4 Paketler indiriliyor (flutter pub get)..." -ForegroundColor Green
flutter pub get

Write-Host "2/4 Eksik platform dosyalari tamamlanip dogrulaniyor..." -ForegroundColor Green
flutter create . --platforms=android

Write-Host "3/4 Statik kod analizi yapiliyor (flutter analyze)..." -ForegroundColor Green
flutter analyze

Write-Host "4/4 Telefona kurulabilir Final Release APK derleniyor..." -ForegroundColor Green
flutter build apk --release --split-per-abi

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "BASARILI! APK dosyalari su dizinde olusturuldu:" -ForegroundColor Green
Write-Host "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk" -ForegroundColor Yellow
Write-Host "=====================================================" -ForegroundColor Cyan
