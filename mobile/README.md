# FamilyDoc — мобільний застосунок (Flutter)

Клієнт для бекенду з цього репозиторію (`src/vault`). UI англійською (ринок США), документація українською.
Дизайн — прототип v2 «Clear index» (IBM Plex Sans, токени з `familydoc-theme.css`).

## Запуск

1. Підняти бекенд з кореня репозиторію (`docker compose up -d --build`, див. `README.MD`).
   Для обробки документів потрібен `LLM_PROVIDER=gemini` і `GEMINI_API_KEY` у `.env`: fake-клієнт без відповідей валить кожен документ.
2. Запустити застосунок:

```bash
cd mobile
flutter pub get
flutter emulators --launch Pixel_10   # або open -a Simulator
flutter run
```

Base URL за замовчуванням: Android-емулятор — `http://10.0.2.2:8000`, iOS-симулятор — `http://localhost:8000`.
Для телефона в тій самій мережі: `flutter run --dart-define=API_BASE_URL=http://<IP ноутбука>:8000` і в `compose.yaml` відкрити порт API не лише на loopback.

Демо-дані: `demo/renters-policy-2027.pdf` (договір страхування з номером поліса, премією й умовою «за 30 днів»).
Тестовий акаунт створюється реєстрацією в застосунку; паролі в репозиторій не кладемо.
HTTP без TLS дозволений лише в debug/profile-збірках Android (`src/debug`, `src/profile`), release — тільки HTTPS.

Тести: `flutter test`. Лінтер: `flutter analyze`.

## Структура

```
lib/
  core/        config (API URL), router (go_router + редирект за сесією), format, icons (SVG з дизайну), theme (токени)
  data/        api_client (JWT + refresh), repository (усі ендпоінти), models, categories (тип → плитка), providers (Riverpod), local_prefs
  ui/          fd.dart — єдиний імпорт; widgets/ — компоненти з bundle.css; shell/ — плаваюча нижня навігація
  features/
    auth/        Sign in, Create account
    home/        порожній / attention / ok стани
    vault/       пошук + фільтр за групою
    deadlines/   Overdue / Next 30 days / Later / Done
    ask/         чат; документ для питання вибирається на клієнті
    add/         Add sheet, Scan (camera → PDF), Processing
    document/    Review, Types, Confirm deadline, Document (вкладки), Failed, Blocked, Share
    household/   створення, учасники, запрошення, вступ за кодом
    settings/
```

## Що робиться на клієнті, бо бекенд ще не вміє

- *Mark as done* — локально (shared_preferences) + dismiss нагадувань; стану `DONE` у бекенді немає.
- Ім'я користувача — локально; у `User` лише email.
- Ask по всьому сховищу — бекенд має чат лише для одного документа, тож клієнт вибирає найрелевантніший документ.
- Похідний дедлайн «за N днів до кінця» рахує клієнт з `notice_period` і створює `CANCELLATION`.
- Шерінг: працює лише *Household*; *A person*, *Link that expires*, *Hide sensitive details* показані вимкненими.
- Household: без рівнів Full/Partial і запитів на вступ; запрошення за email + одноразовий код.
- Пароль від 15 символів (вимога бекенду), HEIC не приймається.
