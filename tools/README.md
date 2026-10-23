# Сборка патча

Инструмент для тех, кто хочет обновить перевод или пересобрать файлы после правок JSON. Для установки он не нужен: `patcher/Apply-RU.bat` работает без Python.

## Что нужно

- Python 3.10+.
- UnityPy 1.25.2:

```powershell
pip install -r tools/requirements.txt
```

- Чистая или уже пропатченная установка Big Dig v1.0. Скрипт читает игру, но ничего в ней не меняет.

## Запуск

```powershell
python tools/rebuild.py --game "C:\Program Files (x86)\Steam\steamapps\common\Big Dig"
```

Можно передать `--game` как папку игры, как `BigDig_Data` или как `StreamingAssets\aa`.

Результат появится в `build\BigDig_Data`:

```
build/
└─ BigDig_Data/
   ├─ level0 … level12
   └─ StreamingAssets/
      └─ aa/
         ├─ catalog.bin
         └─ StandaloneWindows64/
            ├─ localization-locales_assets_all.bundle
            └─ localization-string-tables-russian(ru)_assets_all.bundle
```

## После сборки

1. Проверьте, что игра запускается и русский текст на месте.
2. Скопируйте `build\BigDig_Data` в `files\BigDig_Data` с заменой.
3. Пересчитайте `SHA256SUMS.txt`:

```powershell
Get-ChildItem files -Recurse -File | ForEach-Object {
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
    $rel = $_.FullName.Substring((Resolve-Path files).Path.Length + 1).Replace('\', '/')
    "$hash  files/$rel"
} | Set-Content SHA256SUMS.txt -Encoding ASCII
```

4. Закоммитьте изменения.

## Ограничения

- Offsets каталога и структура `disabledLocales` привязаны к Big Dig v1.0. Скрипт проверяет старые размеры и отказывается патчить незнакомую версию, чтобы не сломать игру.
- Скрипт не трогает `catalog.hash` — для текущей версии игры это нормально.
- Скрипт не обновляет сохранение. Это делает `patcher/apply.ps1`.
