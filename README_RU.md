# Thrustmaster T300RS — драйвер для macOS

Userspace-драйвер + GUI-приложение для руля **Thrustmaster T300RS / T300RS GT Edition** на **macOS** (Apple Silicon и Intel). Из коробки macOS определяет руль как обычный геймпад с 12-битным рулением, без force feedback, с залипшим углом поворота по умолчанию, без педали сцепления и с курсором, который дрейфует от педали тормоза. Драйвер исправляет всё это и добавляет **живой force feedback на основе игровой телеметрии** для Euro Truck Simulator 2.

## Что внутри

| Компонент | Что делает |
|-----------|------------|
| `ThrustmasterWheel` CLI | Root-демон. Переключает руль в полный режим T300RS, захватывает его у macOS HID, создаёт чистый виртуальный джойстик для игр, управляет мотором FF. |
| `ETS2FFControl.app` | SwiftUI GUI (не-root). Живые слайдеры для всех параметров FF, именованные пресеты, реал-тайм индикатор скорости / RPM / передачи. Говорит с демоном через Unix-сокет. |
| `ff_telemetry.so` | SCS telemetry-плагин для ETS2. Пишет живое состояние игры в shared memory — оттуда демон читает и конвертит в FF-эффекты. |

## Возможности

- **Полный режим T300RS** — 16-битное руление, 10-битные педали, педаль сцепления, все 13 кнопок, хат-переключатель
- **Настраиваемый угол поворота** — 40°…1080°, меняется на лету
- **Базовый force feedback** — пружина возврата + демпфер, работает всегда
- **Живой FF из телеметрии ETS2** — самоцентрирование от скорости, вибрация двигателя, текстура дороги, удары подвески, столкновения, ABS, переключение передач, коррекция раскачивания прицепа, вертикальные удары, усилие парковки с прицепом
- **Нет дрейфа курсора** — прямой USB-захват обходит слой macOS HID
- **Поддержка CrossOver / Wine** — отдельный режим, настраивает руль и отдаёт его Wine

## Три режима

| Режим | Для кого | Нужно отключать SIP/AMFI? | Виртуальное устройство? |
|-------|----------|---------------------------|-------------------------|
| **ETS2 native (по умолчанию с `--ets2`)** | Euro Truck Simulator 2 на нативном macOS | Да | Да |
| **Native (без телеметрии)** | Любая другая нативная macOS-игра | Да | Да |
| **CrossOver (`--crossover`)** | Игры под Wine/CrossOver (ETS2 через CrossOver, Assetto и т.д.) | Нет | Нет |

---

## Требования

- Mac с Apple Silicon или Intel, macOS 13+
- **Swift 5.9** (`xcode-select --install`)
- SIP и AMFI **отключены** для native / ETS2 режимов (одноразовая настройка, см. ниже). Для CrossOver-режима не требуется.

## Настройка безопасности macOS (для native + ETS2)

macOS не даёт userspace-процессу создавать виртуальное HID-устройство без ограниченного entitlement'а. Мы обходим это, отключая две функции безопасности.

### 1. Отключить SIP (System Integrity Protection)

Загрузись в **Recovery Mode**: выключи Mac, затем держи кнопку Power до появления логотипа Apple и надписи "Loading startup options". Options → Terminal. Затем:

```bash
csrutil disable
```

Перезагрузись.

### 2. Отключить AMFI (Apple Mobile File Integrity)

Из обычного Terminal:

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1"
```

Перезагрузись.

### Последствия отключения SIP + AMFI

- Системные файлы в `/System` становятся изменяемыми под root. Будь осторожен — не делай `rm` наобум.
- В System Settings → Privacy & Security появится предупреждение.
- Неподписанные kext'ы и ограниченные entitlement'ы становятся рабочими.
- macOS Software Update продолжает работать нормально.
- **В любой момент можно включить обратно:** загрузка в Recovery → `csrutil enable`, затем `sudo nvram -d boot-args` → перезагрузка. Native-режим драйвера перестанет работать, но CrossOver-режим продолжит.

Если это слишком радикально — используй **`--crossover` режим**, для него ни SIP, ни AMFI отключать не нужно.

---

## Сборка

```bash
git clone <этот-репозиторий>
cd ThrustmasterWheel

# Собрать демон + GUI-приложение
./build_app.sh

# (Опционально) собрать ETS2-плагин если нужен FF от телеметрии
cd ets2_plugin
make
make install   # копирует ff_telemetry.so в bundle игры
cd ..
```

Ad-hoc подпись с entitlement (нужна для native/ETS2 режимов):

```bash
codesign --force --sign - --entitlements entitlements.plist .build/release/ThrustmasterWheel
```

Для **CrossOver-режима** — без entitlement:

```bash
codesign --force --sign - .build/release/ThrustmasterWheel
```

---

## Запуск

### ETS2 с живым FF от телеметрии

```bash
# Terminal 1 — демон
sudo .build/release/ThrustmasterWheel --range 1080 --ets2

# GUI (Finder или терминал)
open ETS2FFControl.app
```

Запусти ETS2. В GUI загорится зелёная точка у "ETS2 live" когда плагин подключится. Двигай слайдеры, жми **Accept** — руль реагирует мгновенно. Настройки сохраняются в `~/Library/Application Support/ThrustmasterWheel/settings.json`.

### Любая другая нативная macOS-игра

```bash
sudo .build/release/ThrustmasterWheel --range 900 --spring 70 --damper 25
```

### CrossOver / Wine

```bash
# Terminal 1 — держать открытым пока играешь
sudo .build/release/ThrustmasterWheel --crossover --range 900

# Terminal 2 — запустить CrossOver с выключенным HIDAPI
# (заставляет SDL использовать IOKit, руль появляется в DirectInput а не XInput)
SDL_JOYSTICK_HIDAPI=0 open -a CrossOver
```

В Wine "Game Controllers → Advanced" включи SDL. Руль появится как **Thrustmaster T300RS Racing wheel** во вкладке DInput.

---

## Справка по CLI

| Опция | По умолчанию | Описание |
|-------|--------------|----------|
| `--range <40-1080>` | 1080 | Угол поворота руля, градусы |
| `--gain <0-65535>` | 42000 | Мастер-гейн FF |
| `--spring <0-100>` | 70 | Базовая пружина самоцентрирования |
| `--damper <0-100>` | 25 | Базовое сопротивление демпфера |
| `--no-ff` | – | Выключить весь force feedback |
| `--ets2` | off | Читать телеметрию ETS2 через shm и управлять FF в реальном времени |
| `--ets2-hz <30-240>` | 120 | Частота опроса телеметрии (Гц) |
| `--crossover` | off | Только настройка (без захвата, без виртуального устройства) |
| `--no-modeswitch` | – | Пропустить USB-mode-switch |
| `--no-virtual` | – | Пропустить создание виртуального устройства |
| `--debug` | – | Печатать изменения байт в raw HID-репортах |
| `--axes` | – | Печатать значения осей каждые ~50 репортов |
| `TM_VERBOSE=1` *(env)* | – | Включить подробные внутренние логи (enumeration, тайминги, hex-дампы) |

---

## Слайдеры в GUI

Девять настраиваемых ручек + range и gain + пять именованных пресетов.

### Руль
- **Rotation range** — физический ход руля от упора до упора, 40°…1080°.
- **Force feedback strength** — мастер-гейн, 0…65535.

### Базовое ощущение (работает всегда)
- **Self-centering spring** — пружина возврата, 0…100%, квадратичная шкала.
- **Damper resistance** — демпфер, сопротивление пропорционально скорости вращения.

### Микс телеметрии ETS2 (только в игре)
- **Self-centering (speed-based)** — добавляет тягу к прямой, растёт пропорционально квадрату скорости.
- **Engine rumble** — периодическая вибрация, частота привязана к RPM.
- **Road surface rumble** — амплитуда зависит от покрытия: гладкое, шершавое, грунт, трава, скользкое, резонаторы.
- **Suspension bumps** — резкие импульсы от изменения прогиба передней подвески.
- **Collision impacts** — рывок от резких боковых ускорений.

### Pro tactile effects
- **ABS shiver** — стаккато ~55 Гц при блокировке колёс под торможением.
- **Gearshift thunk** — короткий импульс при переключении передачи.
- **Trailer-sway correction** — контр-усилие когда прицеп раскачивается, а водитель едет прямо.
- **Vertical impact** — всплеск при большом `accel_y` (ямы, падение с бордюра).
- **Heavy parking with trailer** — усиливает усилие руления на околонулевой скорости с прицепом.

### Пресеты

- **Realistic Truck** — 1080°, сбалансированно, вся телеметрия включена.
- **Light Arcade** — 540°, отзывчиво, лёгкое ощущение.
- **Heavy Rig** — 1080°, сильный FF, для жёсткого стенда.
- **Quiet Night** — 900°, мягко, без резких импульсов.
- **Custom** — автоматически выбирается в момент когда ты двинул любой слайдер.

---

## Структура проекта

```
ThrustmasterWheel/
├── Package.swift
├── Sources/
│   ├── CUSBModeSwitch/          # C-слой: USB I/O, FF-пакеты, виртуальный HID
│   ├── ETS2FFCore/              # Общие Swift-типы (Settings, ControlMessage)
│   ├── ThrustmasterWheel/       # Демон (CLI)
│   └── ETS2FFControl/           # SwiftUI GUI-приложение
├── ets2_plugin/                 # SCS telemetry-плагин для ETS2 (C++)
│   ├── ff_plugin.cpp
│   ├── ets2_ff_shm.h            # Формат shared memory (seqlock)
│   └── Makefile
├── build_app.sh                 # Собирает демон + оборачивает в .app
├── entitlements.plist           # Нужен для создания IOHIDUserDevice
└── ETS2FFControl.app            # Собранное GUI-приложение (после build_app.sh)
```

---

## Траблшутинг

**`zsh: killed`** — Бинарь подписан с entitlement'ом но AMFI ещё включён. Либо отключи AMFI (см. выше), либо переподпиши без entitlement для CrossOver-режима: `codesign --force --sign - .build/release/ThrustmasterWheel`.

**`[3/4] Virtual joystick · FAILED`** — `IOHIDUserDeviceCreate` вернул NULL после 6 попыток. Отключи руль, подключи обратно, запусти снова. Если не помогло — перезагрузи Mac.

**`[4/4] USB capture · FAILED`** — Руль держит другой процесс (часто предыдущий упавший демон). `sudo pkill -9 ThrustmasterWheel`, переподключи руль, повтори.

**ETS2-плагин не загружается** — Проверь что файл лежит в `Euro Truck Simulator 2.app/Contents/MacOS/plugins/ff_telemetry.so` (папка plugins *внутри* bundle игры), это Mach-O x86_64 (`file ff_telemetry.so`), и называется именно `ff_telemetry.so`.

**ETS2 показывает IDLE / 0 km/h в логе демона** — Плагин подключён, но ты не в грузовике (главное меню, экран загрузки). Загрузи сейв.

**`ETS2 plugin version mismatch`** — Ты пересобрал демон но не плагин (или наоборот). Пересобери и `make install` плагин.

**`ETS2FFControl.app` висит на "Waiting for daemon…"** — Сначала запусти демон, app переподключается каждые 1.5 с.

**Файл настроек принадлежит root** — Если демон был убит жёстко, JSON может остаться с root-овнером. `sudo chown $(whoami):staff ~/Library/Application\ Support/ThrustmasterWheel/settings.json`.

**CrossOver показывает руль как XInput-геймпад, а не DirectInput-руль** — Ты забыл `SDL_JOYSTICK_HIDAPI=0` при запуске CrossOver.

**Нужны подробные внутренние логи** — Запусти с `TM_VERBOSE=1 sudo .build/release/ThrustmasterWheel …`.

---

## Ограничения

- **Управляемый игрой FF не реализован.** Forza/F1 и т.д. на нативном macOS не могут слать собственные FF-команды на руль — для этого нужен DriverKit extension, которого у нас нет. Наша интеграция с ETS2 работает потому что мы сами читаем телеметрию. В CrossOver/Wine FF работает в рамках того, что поддерживает Wine.
- **ETS2-плагин только x86_64.** Macos-сборка ETS2 — x86_64 (работает под Rosetta на Apple Silicon); плагин собирается под ту же архитектуру. arm64 не нужен и не поддерживается.
- **Детектор столкновений — эвристика.** SCS SDK 1.14 не отдаёт чистого события столкновения; мы смотрим всплески боковых ускорений.
- **Нужен `sudo`.** Захват USB-устройства требует root.
- **Отключённые SIP + AMFI** для native-режимов. Последствия см. выше.

---

## Благодарности

USB-протокол, HID-дескриптор и форматы FF-пакетов были реверснуты по Linux-драйверу [hid-tmff2](https://github.com/Kimplul/hid-tmff2) авторства Kimplul. Интеграция телеметрии использует [SCS Software Telemetry SDK](https://modding.scssoft.com/wiki/Documentation/Engine/SDK/Telemetry) v1.14.

Полный технический дневник со всеми граблями — в [`progress.md`](./progress.md).

[English README](./README.md)
