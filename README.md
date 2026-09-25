# Apple Music wrapper: установка в Docker

Установщик для нового сервера Ubuntu 22.04/24.04 x86_64. Он скачивает [WorldObservationLog/wrapper, ветка `lite`](https://github.com/WorldObservationLog/wrapper/tree/lite) с GitHub, собирает Docker-образ, запрашивает Apple ID и пароль, открывает порт через UFW и проверяет `/status` и `/m3u8`. Контейнер называется `wrapper`.

## Быстрый старт

На **новом** сервере с доступом `sudo`:

```bash
git clone https://github.com/dev-x64/apple-music-wrapper-deploy.git
cd apple-music-wrapper-deploy
sudo bash install.sh
```

Если Git ещё не установлен:

```bash
sudo apt-get update && sudo apt-get install -y git
```

Установщик сам поставит Docker Engine и Compose из [официального репозитория Docker](https://docs.docker.com/engine/install/ubuntu/), если Docker отсутствует. Для первого образа скачивается Android NDK, поэтому первая сборка может занять несколько минут и требует свободного места на диске. При последующих обновлениях этот слой Docker используется повторно.

При входе пароль вводится без отображения. Если Apple запросит двухфакторный код, введите его в интерактивном терминале. После установки команда `wrapper` доступна из любого каталога.

## Команды

```bash
wrapper status                 # Проверить /status и доступные регионы
sudo wrapper logs              # Последние 100 строк журнала
sudo wrapper logs --follow     # Следить за журналом
sudo wrapper login             # Запросить Apple ID и пароль скрытым вводом
sudo wrapper login USER        # Запросить только пароль
sudo wrapper login USER PASS   # Передать оба параметра
sudo wrapper update            # Скачать новую lite, пересобрать, запустить, проверить
wrapper test                   # /status + /m3u8 тестового трека
wrapper test 1608815075        # Тест с конкретным Apple Music track ID
```

Для `wrapper login USER PASS` пароль остаётся в истории команд оболочки и кратковременно виден в списке процессов. Используйте `sudo wrapper login` или `sudo wrapper login USER`, если это нежелательно. Пароль не записывается в Compose, Dockerfile, репозиторий или конфигурационный файл; сохраняется только состояние входа, созданное upstream wrapper.

`wrapper update` обновляет исходный код upstream-ветки `lite`, а не этот установщик. Если новая сборка или проверка не пройдёт, команда вернёт прежний образ и исходную версию. Данные аккаунта в `/opt/apple-music-wrapper/data` сохраняются.

## Настройки

Переменные задаются перед запуском `install.sh`:

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `WRAPPER_PORT` | `12340` | Порт HTTP API и правило UFW |
| `WRAPPER_INSTALL_DIR` | `/opt/apple-music-wrapper` | Каталог установки |
| `WRAPPER_TEST_ADAM_ID` | `1608815075` | ID трека для проверки `/m3u8`; `0` пропускает её |

Пример:

```bash
sudo WRAPPER_PORT=12341 WRAPPER_TEST_ADAM_ID=1608815075 bash install.sh
```

Для подключения клиента укажите `http://IP_СЕРВЕРА:12340` как адрес wrapper-lite. Например, в `amdl` это параметр `lite-server`.

## Как устроено

- `/opt/apple-music-wrapper/upstream` — отдельный shallow clone upstream `lite`.
- `/opt/apple-music-wrapper/Dockerfile` и `compose.yaml` — создаются из шаблонов этого репозитория.
- `/opt/apple-music-wrapper/data` — постоянные данные аккаунта; права `0700`.
- `/etc/apple-music-wrapper.conf` — путь, порт и ID тестового трека; секретов нет.
- `/usr/local/bin/wrapper` — CLI для управления.

Контейнер использует `network_mode: host` и `privileged: true`: upstream rootless launcher создаёт namespace и монтирует `/proc`. При обычной публикации порта Docker может [обойти правила UFW](https://docs.docker.com/engine/install/ubuntu/#firewall-limitations); с host networking входящий трафик идёт через правила хоста. Установщик разрешает обнаруженные SSH-порты до включения UFW, затем разрешает порт wrapper. API wrapper не имеет собственного пароля: открытый порт доступен извне. Такой контейнер запускайте только на доверенном сервере; при необходимости ограничьте правило UFW конкретными IP клиентов.

Проверка установки требует успешного `/status` с хотя бы одним регионом и успешного `/m3u8` для тестового трека. Если этот трек недоступен в регионе аккаунта, задайте другой `WRAPPER_TEST_ADAM_ID` или `0` для проверки только статуса. `wrapper test TRACK_ID` можно запустить позже.

## Если установка прервалась

Повторите `sudo bash install.sh`: установщик продолжит собственную незавершённую установку. Он не перезаписывает чужой каталог `/opt/apple-music-wrapper` без своего маркера.

```bash
wrapper status
sudo wrapper logs
sudo docker ps --filter name=wrapper
```

Если `/status` отвечает, а `/m3u8` нет, проверьте подписку, регион аккаунта и ID трека. Если вход не прошёл, запустите `sudo wrapper login` ещё раз. Код и бинарные зависимости wrapper принадлежат [upstream-проекту](https://github.com/WorldObservationLog/wrapper/tree/lite); этот репозиторий содержит только сценарии установки и управления.

## Проверки разработчика

```bash
bash -n install.sh wrapper
bash tests/run.sh
```

## Лицензия

Сценарии этого репозитория: MIT. Исходный wrapper: [MIT](https://github.com/WorldObservationLog/wrapper/blob/lite/LICENSE). Репозиторий не содержит Apple ID, пароль или данные входа.
