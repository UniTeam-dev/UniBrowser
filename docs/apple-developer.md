# Как подключить UniBrowser к «Паролям» через Apple (только сборка с сайта)

## 1. Завести аккаунт Apple Developer

1. Зайди на https://developer.apple.com/programs/enroll/ под своим Apple ID
   (на нём должна быть включена двухфакторная аутентификация).
2. Выбери **Individual** (на себя). Для организации нужен номер D-U-N-S, это дольше.
3. Оплати $99 в год. Проверка обычно занимает от нескольких часов до пары дней.
4. Когда аккаунт активируют, открой https://developer.apple.com/account. В разделе
   **Membership details** будет **Team ID** из 10 символов. Пришли его мне.

## 2. Что сделаю я

1. Пропишу Team ID в проект и включу подпись **Developer ID** и нотаризацию:
   помощник «Паролей» запускается только из нотаризованного браузера.
2. Закреплю идентификатор сборки с сайта (сейчас `app.unibrowser.UniBrowser.direct`; у App Store-сборки `app.unibrowser.UniBrowser`, её «Пароли» не касаются).
   После заявки менять его нельзя.
3. Подготовлю заявку (pull request) в
   https://github.com/apple/password-manager-resources: новую запись в
   `quirks/web-browser-extension-distribution-information.json` с полями
   `bundle_identifier`, `code_signing_identifier` и `code_signing_team_identifier`.
   Отправить её нужно с твоего аккаунта GitHub.

## 3. Что понадобится для заявки

- Публичная страница браузера, откуда его можно скачать (хватит страницы релизов на GitHub).
  По правилам репозитория браузер должен открывать http/https-ссылки и иметь
  адресную строку. У UniBrowser это есть.
- Apple сама решает, принимать ли заявку. Принятые изменения попадают к пользователям
  только с одним из следующих обновлений macOS.

## 4. Как проверить, что UniBrowser уже в списке

```sh
codesign -d -vvvv /System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper
```

Смотри раздел Launch Constraints: там должен быть наш Team ID. После этого в
UniBrowser выбери меню **Вкладки → Подключить «Пароли»…** и введи код из окна
«Пароли».

## Риск

В списке Apple сейчас браузеры, которые поддерживают магазины расширений
(Chrome Web Store и подобные). UniBrowser расширения пока не поддерживает, и
Apple может отклонить заявку по этой причине. Тогда придётся добавить поддержку
расширений Chrome. WebKit это позволяет, но это отдельная большая работа.
