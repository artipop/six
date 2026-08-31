# Тестовые MCP-серверы

`mcp_apps_server.py` — один файл, только стандартная библиотека Python, никакого `pip` и никакого `npx`. Он
говорит на протоколе напрямую, а не через SDK: сервер, написанный по тексту спеки, ловит в хосте ровно те
ошибки, которые SDK по обе стороны согласованно прячет.

Юнит-тесты рядом ([../SixCoreTests](../SixCoreTests)) закрывают чистые функции — разбор `_meta`, построение CSP,
разбор `WWW-Authenticate`, отображение записи реестра на определение сервера. Всё, что делает приложение
приложением, чистой функцией не является: окно в полосе, два источника, мост через `postMessage`, полоса
разрешений, teardown, которого хост обязан дождаться. Эта половина проверяется руками, и вот чем.

## Запуск

```sh
python3 Tests/Servers/mcp_apps_server.py --persona basic                # stdio, по умолчанию
python3 Tests/Servers/mcp_apps_server.py --persona basic --http 8931    # Streamable HTTP
python3 Tests/Servers/mcp_apps_server.py --persona oauth --http 8931    # он же за OAuth 2.1
```

Дальше либо `six://apps` → **Add a server**, либо из терминала (см. [docs/mcp-apps.md](../../docs/mcp-apps.md)):

```sh
six=/path/to/six.app/Contents/MacOS/six
$six --mcp-probe "python3 $PWD/Tests/Servers/mcp_apps_server.py --persona basic"
$six --mcp-probe http://127.0.0.1:8931/mcp
SIX_MCP_APP_SELFTEST='http://127.0.0.1:8931/mcp#show_greeting' six
```

Флаги: `--http PORT` — вместо stdio слушать `127.0.0.1:PORT` (по умолчанию 8931, путь всегда `/mcp`),
`--sse` — отвечать `text/event-stream` вместо одного JSON-объекта, `--trace` — зеркалить сообщения в stderr.

## Персоны, и что каждая доказывает

| персона | транспорт | что проверяет |
|---|---|---|
| `basic` | оба | весь протокол вида: `ui/initialize`, `tool-input`, `tool-result`, `tools/call` обратно через хост, `ui/open-link`, `ui/message`, `ui/update-model-context`, `size-changed`, `resources/read`. С неё начинать |
| `readonly` | оба | `annotations.readOnlyHint: true`. Закрыть six, запустить снова — окно возвращается и **само** повторяет вызов |
| `stateful` | оба | тот же инструмент без пометки, со счётчиком вызовов. Восстановленное окно показывает карточку и ждёт «Run Again»; счётчик, выросший сам, — это баг |
| `goodbye` | оба | вид отвечает на `ui/resource-teardown` только после круга обратно через six. Закрытие окна доказывает, что хост держит страницу живой |
| `hostile` | оба | сервер, просящий больше, чем ему положено (ниже) |
| `slow` | оба | 90 секунд на `tools/call` — что видно в окне, пока оно ждёт |
| `forgetful` | только HTTP | забывает сессию после первого вызова и отвечает 404 на следующий запрос со старым `Mcp-Session-Id`. Клиент обязан переинициализироваться без него |
| `oauth` | только HTTP | 401 с `WWW-Authenticate`, RFC 9728 → RFC 8414 → RFC 7591 → PKCE S256 → `resource` (RFC 8707) → токен. Сервер авторизации встроен и одобряет всё сразу, но **проверяет** verifier, `redirect_uri` и `resource` |

### `hostile` — что должно не долететь

Она объявляет в `ui.csp` то, чего там объявить нельзя, и пытается этим воспользоваться:

- `"https://evil.example.com; script-src * 'unsafe-eval'"` в `connectDomains` — это вторая директива внутри
  значения. Должна быть отброшена целиком (`MCPUIResource.CSP.isPlausibleSource`).
- `'unsafe-eval'` в `resourceDomains` — попало бы в `script-src`, потому что туда идут ресурсные домены.
- Все четыре разрешения сразу — они проходят не через CSP, а через `SitePermissions`, как у обычной страницы.
- Скрипт вида пробует `eval`, `new Function`, `Worker(blob:)`, `fetch` наружу и `tools/call` инструмента,
  помеченного `visibility: ["model"]`. Каждая строчка в окне, где написано `ALLOWED`, — это дефект.

## Что стоит пройти после правок в MCP-слое

1. `--persona basic` по stdio: окно рисуется, все пять кнопок делают что обещают, размер колонки приезжает в
   `hostContext.containerDimensions` и меняется при перетаскивании границы.
2. Он же по `--http` и по `--http --sse`: разбор `text/event-stream` — отдельная ветка в транспорте.
3. `--persona hostile`: в логе окна нет ни одного `ALLOWED`.
4. `--persona goodbye`: закрыть окно — в stderr сервера видно `resources/read`, пришедший **после** закрытия.
5. `--persona readonly` и `--persona stateful`: закрыть six, запустить снова, посмотреть на обе колонки.
6. `--persona forgetful --http`: вызвать инструмент дважды; второй раз six переинициализируется молча.
7. `--persona oauth --http`: вход целиком, потом перезапуск six — токен должен подхватиться из Keychain без
   второго входа.
