# Claude Limits для macOS

Виджет в строке меню macOS показывает, сколько осталось от лимитов подписки Claude.
Это аналог [codex-limits](https://github.com/Kolin163/codex-limits) для Claude Code.

*A macOS menu bar widget that shows your remaining Claude subscription limits
(5-hour, weekly and per-model windows) using your existing Claude Code login.
Build: `./scripts/build.sh --install`.*

В строке меню отображаются процент и кольцо. Процент — остаток по самому израсходованному
окну. Кольцо бирюзовое, если осталось больше 60%, жёлтое при остатке от 25 до 60%
и красное ниже 25%. По нажатию открывается меню. В нём для каждого окна лимита
(5 часов, неделя, недельные окна по моделям) показаны остаток, время сброса в часовом
поясе macOS и обратный отсчёт до сброса. Данные обновляются раз в 3 минуты, после выхода
из сна и при открытии меню, если они старше минуты.

## Кому подойдёт

Виджет работает, только если Claude Code вошёл через аккаунт claude.ai с подпиской
Pro или Max. Проверить вход можно в Claude Code командой `/status`.

Если Claude Code работает через API-ключ, Bedrock, Vertex или шлюз с `ANTHROPIC_BASE_URL`,
лимитов подписки нет, и виджету нечего показать.

## Установка

Нужны macOS 13 или новее и Command Line Tools. Если их нет, установите командой
`xcode-select --install`.

1. Склонируйте репозиторий, соберите, установите и запустите приложение:

   ```bash
   git clone https://github.com/leeevooon/claude-limits.git
   ./claude-limits/scripts/build.sh --install
   ```

   Сборка идёт в `~/.cache/claude-limits`. В конце появятся строки `Self-test OK`,
   `Ready: …` и `Installed: ~/Applications/Claude Limits.app`, а в строке меню — значок
   с процентом.

2. Если значка нет или вместо процента стоит «!», проверьте, получает ли виджет данные:

   ```bash
   ~/Applications/"Claude Limits.app"/Contents/MacOS/ClaudeLimits --check
   ```

   При успехе команда выведет тариф и остаток по окнам, например
   `Check OK; plan: max; five_hour=96%, seven_day=98%`. Токен в вывод не попадает.
   Ошибки разобраны в разделе «Если что-то не так».

3. Чтобы виджет запускался при входе в систему, добавьте его в «Системные настройки →
   Основные → Объекты входа».

Приложение собирается локально и подписывается ad-hoc, поэтому Gatekeeper его не блокирует.
Если передать собранный `.app` на другой компьютер, macOS может предупредить
о неизвестном разработчике.

## Откуда данные

Отдельный вход не нужен, виджет использует авторизацию Claude Code. Он читает OAuth-токен
из элемента `Claude Code-credentials` Связки ключей через `/usr/bin/security`, а если
элемента нет, то из `~/.claude/.credentials.json`. С этим токеном виджет запрашивает
`GET https://api.anthropic.com/api/oauth/usage` — тот же источник, что у команды `/usage`.
Токен отправляется только на этот адрес и нигде не сохраняется.

Эндпоинт не документирован, Anthropic может его изменить. Ключи, которые виджет не знает,
показываются как «Прочий лимит (<ключ>)», чтобы новый лимит не остался незамеченным.

Проект не связан с Anthropic.

## Если что-то не так

**Значок не появился в строке меню.** Скорее всего, его закрыл вырез экрана: macOS ставит
новые значки левее остальных. Сдвиньте значок ближе к часам и перезапустите приложение:

```bash
defaults write local.claude-limits "NSStatusItem Preferred Position Item-0" -float 330
pkill -x ClaudeLimits; open ~/Applications/"Claude Limits.app"
```

Можно также отключить лишние значки в «Системные настройки → Строка меню».

**В меню написано «Вход устарел».** Токен обновляет сам Claude Code. Запустите `claude`
в терминале: после следующего обновления данные вернутся.

**В меню написано «Войдите в Claude Code».** Токена Claude Code нет. Выполните в Claude Code
команду `/login` и войдите через аккаунт claude.ai.

**Вместо процента стоит «!».** Причина указана в меню. Если там «Нет связи с api.anthropic.com»,
проверьте сеть и нажмите «Обновить».

## Удаление

```bash
pkill -x ClaudeLimits; rm -rf ~/Applications/"Claude Limits.app" ~/.cache/claude-limits
defaults delete local.claude-limits
```

## Лицензия

MIT, см. [LICENSE](LICENSE).
