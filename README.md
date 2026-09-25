# Apple Music wrapper: установка в Docker

Установщик для нового сервера Ubuntu 22.04/24.04 x86_64. Он скачивает готовый пакет сборки [WorldObservationLog/wrapper, ветка `lite`](https://github.com/WorldObservationLog/wrapper/tree/lite), создаёт Docker-образ, запрашивает Apple ID и пароль, открывает порт через UFW и проверяет `/status` и `/m3u8`. Контейнер называется `wrapper`.

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

Установщик сам поставит Docker Engine и Compose из [официального репозитория Docker](https://docs.docker.com/engine/install/ubuntu/), если Docker отсутствует. Пакет `wrapper-lite-linux-x86_64` создаётся GitHub Actions из ветки `lite`. GitHub требует авторизацию для прямого скачивания Actions-артефактов, поэтому файл доставляется через [nightly.link](https://nightly.link/) по ссылке на конкретный запуск; установщик сравнивает SHA-256 файла с контрольной суммой GitHub API. Сборка Android NDK на сервере не требуется.

При входе пароль вводится без отображения. Если Apple запросит двухфакторный код, введите его в интерактивном терминале. После установки команда `wrapper` доступна из любого каталога.

## Команды

```bash
wrapper status                 # Проверить /status и доступные регионы
sudo wrapper logs              # Последние 100 строк журнала
sudo wrapper logs --follow     # Следить за журналом
sudo wrapper login             # Запросить Apple ID и пароль скрытым вводом
sudo wrapper login USER        # Запросить только пароль
sudo wrapper login USER PASS   # Передать оба параметра
sudo wrapper update            # Скачать готовую lite, обновить образ и проверить
wrapper test                   # /status + /m3u8 тестового трека
wrapper test 1608815075        # Тест с конкретным Apple Music track ID
```

Для `wrapper login USER PASS` пароль остаётся в истории команд оболочки и кратковременно виден в списке процессов. Используйте `sudo wrapper login` или `sudo wrapper login USER`, если это нежелательно. Пароль не записывается в Compose, Dockerfile, репозиторий или конфигурационный файл; сохраняется только состояние входа, созданное upstream wrapper.

`wrapper update` берёт последнюю **успешную сборку** upstream-ветки `lite`, а не обновляет этот установщик. При ошибке скачивания, контрольной суммы, сборки Docker-образа или проверки сервиса команда вернёт прежний образ и пакет. Данные аккаунта в `/opt/apple-music-wrapper/data` сохраняются. Если новый коммит ещё не прошёл GitHub Actions, повторите команду позже.

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

- `/opt/apple-music-wrapper/upstream` — распакованный готовый пакет `lite` и SHA коммита в `.source-commit`.
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

Для перехода с ранней версии этого установщика, которая собирала `lite` из исходников, снова запустите `sudo bash install.sh` из свежего клона репозитория. Установщик сохранит каталог `data` и заменит старый исходный код готовым пакетом. Затем используйте `sudo wrapper update`.

## Проверки разработчика

```bash
bash -n install.sh wrapper download-upstream.sh
bash tests/run.sh
```

## Лицензия

Сценарии этого репозитория: MIT. Исходный wrapper: [MIT](https://github.com/WorldObservationLog/wrapper/blob/lite/LICENSE). Репозиторий не содержит Apple ID, пароль или данные входа.
