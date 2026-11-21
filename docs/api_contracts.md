# FamilyDoc AI — API contracts v1

Nov 21, 2026 · @Vitalii

## Огляд

Контракти описують REST API бекенду `product_eng_hack4` з гілки `back`. Біля кожного ендпоінта стоїть статус: **Є** — реалізовано, можна інтегрувати; **Частково** — є, але відрізняється від PRD чи дизайну; **Нове** — пропозиція. Джерело правди для полів — код (`src/vault/*.py`, міграції `0002` і `0004`), живий Swagger — `http://localhost:8000/docs`.

| Параметр | Значення |
| --- | --- |
| Base URL | `http://localhost:8000/v1` (Docker Compose). Android-емулятор: `10.0.2.2:8000`, iPhone на тому ж Wi-Fi: IP ноутбука, але спершу в compose.yaml замінити 127.0.0.1:8000:8000 на 8000:8000 (зараз API слухає лише loopback) |
| Формат | JSON, UTF-8. Завантаження файлу — `multipart/form-data` |
| Авторизація | `Authorization: Bearer <access_token>`. Access JWT живе 15 хв, refresh-токен — до 30 днів і змінюється при кожному `/auth/refresh` |
| Ідентифікатори | UUID |
| Час і дати | Мітки часу — ISO 8601 з поясом (`2026-11-21T13:40:00Z`). Календарні дати (дедлайни) — `YYYY-MM-DD` |
| Пагінація | Лише `GET /documents`: `?cursor=<id останнього>&limit=1..100`. Відповідь — голий масив, без обгортки `Page` |
| Rate limit | Auth-ендпоінти: 15 запитів за хвилину на IP+шлях і на email, далі `429` |

**Помилки зараз — стандартний формат FastAPI:** `{"detail": "Resource unavailable"}`, а для `422` валідації — `{"detail": [{"loc": [...], "msg": "...", "type": "..."}]}`. `BACKEND_PLAN.md` обіцяє `{code, message, request_id}`, але цього ще немає. Пропозиція (**Нове**): лишити `detail` і додати машинний `code`, щоб клієнт не парсив текст.

| Код | Коли | Що робить клієнт |
| --- | --- | --- |
| `401` | Access-токен прострочений або сесію відкликано | Один раз викликати `/auth/refresh` і повторити запит. Знову `401` — на екран входу |
| `403` | Дію над документом робить не власник (`Document owner required`) або не власник household | Сховати кнопку для viewer |
| `404` | Ресурсу немає **або** доступу немає — бекенд навмисно їх не розрізняє | «Документ недоступний» |
| `409` | Конфлікт стану: вже в черзі, вже в household, застаріла `revision`, будь-яке порушення унікальності (`Conflicting update`) | Перечитати ресурс |
| `410` | Прострочене запрошення в household | Попросити нове |
| `413` / `415` / `422` | Файл більший за ліміт / не PDF, JPG, PNG / PDF із паролем чи невалідне тіло | Помилка біля поля або на екрані завантаження |
| `429` | Перевищено ліміт auth-запитів | «Спробуйте за хвилину» |
| `503` | Сервер не налаштований (`JWT_SECRET`) або файл недоступний | Повторити пізніше |

## Авторизація й акаунт

Вхід за email і паролем із JWT працює. Email OTP з PRD (FR-01) і дизайну (`OtpInput`) свідомо вирізано з MVP: екран OTP у застосунку не потрібен. У користувача немає імені — лише email.

| Ендпоінт | Статус | Запит → відповідь | Помилки |
| --- | --- | --- | --- |
| `POST /auth/register` | Є | `{email, password, timezone?}` → `201 User`. Пароль 15–256 символів, `timezone` — IANA, за замовчуванням `UTC`. Вхід не виконує: далі потрібен `login` | `409` Email unavailable, `422` Unknown timezone, `429` |
| `POST /auth/login` | Є | `{email, password}` → `200 TokenPair`. Одразу видає токени | `401` Invalid credentials, `429` |
| `POST /auth/refresh` | Є | `{refresh_token}` → `200 TokenPair` (нова пара, старий refresh більше не діє) | `401` Invalid session. Повторне використання старого refresh відкликає всю сесію |
| `POST /auth/logout` | Є | — → `204` | — |
| `GET /users/me` | Є | — → `200 User` | — |
| `PATCH /users/me` | Нове | `{display_name?, timezone?}` → `200 User` | `422` |

```json
// User (зараз)
{ "id": "6f1c…", "email": "laura@example.com", "timezone": "America/Chicago" }

// TokenPair (зараз) — поля expires_in немає, access живе 15 хв
{ "access_token": "eyJhbGciOi…", "refresh_token": "q8Zk…", "token_type": "bearer" }
```

```json
// User (пропозиція) — додати display_name
{ "id": "6f1c…", "email": "laura@example.com", "display_name": "Laura Reynolds", "timezone": "America/Chicago" }
```

Доки `display_name` немає, клієнт показує частину email до `@` і будує з неї ініціали. Клієнт зберігає refresh-токен у Keychain / Keystore (`flutter_secure_storage`), access — лише в пам'яті.

## Документи

Завантаження, перегляд, виправлення даних і підтвердження документа (`REVIEW_REQUIRED` → `READY`) працюють. Пошук за назвою та заміна файлу лишаються пропозиціями.

| Ендпоінт | Статус | Запит → відповідь | Помилки та нюанси |
| --- | --- | --- | --- |
| `POST /documents` | Є | multipart: `file`, `title?`, `category?` → `202 Document` | `413` понад 20 MB (PRD: 10 MB), `415` не PDF/JPG/PNG або розширення не збігається з MIME, `422` PDF із паролем. Ліміту в 20 сторінок немає |
| `GET /documents` | Частково | `scope=owned\|shared\|all`, `category`, `status`, `cursor`, `limit` → `200 Document[]` | `status` фільтрує за `processing_stage`, а не за `review_status`. Сортування за `id` (випадковий порядок). Пошуку за назвою немає |
| `GET /documents/{id}` | Є | → `200 Document` | `404`. Клієнт опитує цей ендпоінт після завантаження |
| `PATCH /documents/{id}` | Є | `{title?, category?, subtype?}` → `200 Document` | `403` viewer |
| `DELETE /documents/{id}` | Є | → `204` | `403` viewer |
| `GET /documents/{id}/file` | Є | → `200` файл (`Content-Disposition: attachment`) | `404` у заблокованого документа файлу немає, `503` |
| `POST /documents/{id}/reprocess` | Є | → `202 Document` | `409` вже в черзі або файл не збережено |
| `GET /documents/{id}/summary` | Є | → `200 {document_id, summary, card, revision}` | `409` немає опублікованого результату, `404` |
| `GET /documents/{id}/extraction` | Є | → `200 Extraction` | `409` доки обробка не завершена або документ заблоковано |
| `PATCH /documents/{id}/extraction` | Є | `{expected_revision, fields}` → `200 Extraction` | `409` застаріла `revision`. `fields` дописуються в `overrides` |
| `POST /documents/{id}/confirm` | Є | `{expected_result_revision, expected_extraction_revision}` → `200 Document` (`READY`, `confirmed_at`) | Лише власник. Версії беруться з `Document.result_revision` і `Extraction.revision`. Повтор з тими самими версіями ідемпотентний. `409` застаріла версія або документ ще не готовий до підтвердження |
| `PUT /documents/{id}/file` | Нове | multipart `file` → `202 Document` | `409` йде обробка. Обгортка над готовим `replace_document_file` (FR-11) |
| `GET /documents?q=&review_status=&order=-created_at` | Нове | Додати пошук за назвою, фільтр за `review_status` і сортування за датою | — |

### Модель Document

Відповідь — це рядок `documents` разом із станом задачі обробки, метаданими файлу й карткою-резюме. Поля `status` і `processing_stage` однакові — клієнт читає `processing_stage`.

```json
{
  "id": "0b6e…", "owner_id": "6f1c…",
  "title": "Renters insurance - Laura Reynolds", "category": "HOME_INSURANCE", "subtype": null,
  "classification_confidence": 0.94,
  "review_status": "REVIEW_REQUIRED", "confirmed_at": null, "replaced_at": null,
  "policy_outcome": "ALLOWED", "policy_reason": null, "result_revision": 1,
  "processing_stage": "COMPLETED", "status": "COMPLETED", "error_code": null,
  "started_at": "2026-11-21T13:40:02Z", "finished_at": "2026-11-21T13:40:11Z",
  "display_filename": "renters-policy-2027.pdf", "media_type": "application/pdf", "size_bytes": 184233,
  "summary": "Renters insurance - Laura Reynolds\nAnnual premium 1,240.00 USD\n…",
  "summary_card": {
    "title": "Renters insurance - Laura Reynolds", "holder": "Laura Reynolds", "issuer": "Lemonade Insurance Co.",
    "key_facts": ["Policy period Feb 1, 2026 to Jan 31, 2027", "Auto-renews unless cancelled 30 days before end"],
    "topics": ["renters insurance", "auto-renewal", "premium"]
  },
  "created_at": "2026-11-21T13:40:00Z", "updated_at": "2026-11-21T13:40:11Z"
}
```

### Статуси → інтерфейс

Після `202` клієнт раз на 2 с опитує `GET /documents/{id}`, доки `review_status` не стане `REVIEW_REQUIRED`, `FAILED` або `BLOCKED` (ціль — до 15 с). Під час повторів збоїв провайдера статус повертається до `UPLOADED`, тож опитування треба продовжувати.

| `review_status` | Що показує застосунок | Дія |
| --- | --- | --- |
| `UPLOADED` | Бейдж *Uploaded* | — |
| `PROCESSING` | Бейдж *Processing* + прогрес у `ProcessingCard` | — |
| `REVIEW_REQUIRED` | *Needs review* на Home (блок *Waiting for your review*) | Відкрити Review details |
| `READY` | Без бейджа | — |
| `FAILED` | *Couldn’t read* + `error_code` | `POST /reprocess` або ручне введення |
| `BLOCKED` | Повідомлення з `policy_reason`, файлу немає. **У дизайні цього стану ще немає** | Видалити запис |

### Категорії: `category` → плитка в дизайні

`category` — це тип документа від AI (ім'я з `DocType` великими літерами), а не група з інтерфейсу. Клієнт групує типи в плитки за цією таблицею; фільтр `?category=` приймає лише один тип, тож плитку фільтруємо на клієнті або додаємо `?group=` (**Нове**).

| Плитка | Значення `category` |
| --- | --- |
| Utilities & services | `UTILITY_CONTRACT`, `UTILITY_BILL`, `SUBSCRIPTION` |
| Insurance | `AUTO_INSURANCE`, `HOME_INSURANCE` (сюди ж renters), `HEALTH_INSURANCE`, `TRAVEL_INSURANCE`, `LIFE_INSURANCE` |
| Warranties & receipts | `WARRANTY`, `RECEIPT` |
| Rental agreements | `LEASE` |
| Family IDs | `PASSPORT`, `DRIVERS_LICENSE`, `ID_CARD` (зокрема ID штату США), `GREEN_CARD`, `VISA`, `BIRTH_CERTIFICATE` |
| Vehicles | `VEHICLE_REGISTRATION`, `VEHICLE_INSPECTION` |
| Other | `OTHER` (завжди `needs_review: true`) |
| Заблоковані, не зберігаються | `MILITARY_OR_FEDERAL_ID`, `NATURALIZATION_CERTIFICATE`, `BIOMETRIC_OR_GENETIC`, `CREDENTIALS_OR_SECRETS`, `BANK_CARD_OR_CHECK` |

У бекенді немає типів для Finance, Taxes, Legal, Business і Contacts зі списку команди. Passwords **суперечить** політиці бекенду: `CREDENTIALS_OR_SECRETS` блокується.

### Модель Extraction → екран Review details

Кожен факт має `quote` — точну цитату з тексту. Факти без підтвердження в тексті бекенд відкидає і ставить `needs_review: true`. Рядок з `identifiers`, `terms` чи `financials` → поле з позначкою *Found*. Ключ у `overrides` → *Edited*. Очікуване для типу поле, якого немає, → *Not specified* (список очікуваних полів поки тримає клієнт).

```json
{
  "document_id": "0b6e…", "revision": 1, "schema_version": 1, "model_id": "gemini-3.5-flash-lite",
  "pages": [{ "page": 1, "text": "RENTERS POLICY DECLARATIONS\n…", "method": "gemini" }],
  "facts": {
    "doc_type": "home_insurance", "classification_reason": "Declarations page of a renters policy",
    "expires_on": "2027-01-31", "expires_on_quote": "Policy period: 02/01/2026 to 01/31/2027",
    "warnings": [], "needs_review": false
  },
  "identifiers": [{ "name": "policy_number", "value": "LP-4482-1190", "quote": "Policy No. LP-4482-1190" }],
  "terms": [{ "name": "notice_period", "value": "thirty (30) days", "quote": "unless you cancel at least thirty (30) days before" }],
  "financials": [{ "name": "premium", "amount": "1,240.00", "currency": "USD", "period": "annual", "quote": "Annual premium $1,240.00" }],
  "overrides": {}, "published_at": "2026-11-21T13:40:11Z"
}
```

Правка поля: `PATCH /documents/{id}/extraction` з `{"expected_revision": 1, "fields": {"policy_number": "LP-4482-1191"}}`. Ключ у `fields` = `name` факту; це конвенція, бекенд її не перевіряє. Повний текст і номери бачать і власник, і viewer, тому маску `•••• 1190` ставить клієнт.

## Дедлайни й нагадування

Для Home і вкладки Deadlines доступний загальний список підтверджених дедлайнів власника. Нагадування ставляться за 7 і 1 день о 09:00 за поясом користувача.

| Ендпоінт | Статус | Запит → відповідь | Помилки та нюанси |
| --- | --- | --- | --- |
| `GET /documents/{id}/deadlines` | Є | `?state=PROPOSED\|CONFIRMED\|REJECTED` → `200 Deadline[]`, відсортовані за датою | `409` документ ще не оброблено |
| `POST /documents/{id}/deadlines` | Є | `{type, date, label?}` → `201 Deadline` у стані `CONFIRMED` | У запиті `type`/`date`, у відповіді `kind`/`due_on` |
| `PATCH /documents/{id}/deadlines/{deadline_id}` | Є | `{date?, label?, state?}` → `200 Deadline` | Підтвердити = `state: CONFIRMED` (створює нагадування), відхилити = `REJECTED`. `422` CONFIRMED без дати |
| `GET /reminders` | Є | `?state=SCHEDULED\|DUE\|DISMISSED&through=<datetime>` → `200 Reminder[]` | Лише нагадування власника |
| `POST /reminders/{id}/dismiss` | Є | → `200 Reminder` | Ідемпотентно |
| `GET /deadlines` | Є | → `200 Deadline[]` з додатковим полем `document_title` | Підтверджені дедлайни власника, впорядковані за `due_on` та `id` |
| `PATCH …/deadlines/{id}` зі `state: DONE` | Нове | → `200 Deadline` з `completed_at` | *Mark as done* з FR-04 і дизайну. Зараз такого стану немає |
| `reminder_offsets` у `POST`/`PATCH` дедлайну | Нове | `[30, 7, 1]` за замовчуванням | Для чипів `ReminderSchedule` |

```json
// Deadline (зараз) — воркер пропонує його з дати закінчення документа
{
  "id": "9a41…", "document_id": "0b6e…",
  "kind": "INSURANCE_EXPIRATION", "label": null,
  "due_on": "2027-01-31", "raw_value": "2027-01-31",
  "state": "PROPOSED", "candidate_key": "expires_on",
  "evidence": { "quote": "Policy period: 02/01/2026 to 01/31/2027" }
}

// Reminder (зараз); status рахується під час читання
{
  "id": "e310…", "deadline_id": "9a41…", "document_id": "0b6e…", "recipient_id": "6f1c…",
  "offset_days": 7, "scheduled_at": "2027-01-24T15:00:00Z",
  "dismissed_at": null, "cancelled_at": null, "status": "SCHEDULED"
}
```

`kind`: `CONTRACT_EXPIRATION`, `CANCELLATION`, `INSURANCE_EXPIRATION`, `WARRANTY_EXPIRATION`, `PAYMENT_DUE`, `DOCUMENT_EXPIRATION`, `OTHER`. Надсилання нагадувань email чи push у бекенді немає: це лише записи, які застосунок читає з `GET /reminders?state=DUE`.

Для `UTILITY_BILL`, `BANK_STATEMENT` (кредитка) і `TAX_DOCUMENT` (податковий рахунок) воркер публікує `PAYMENT_DUE` зі станом `PROPOSED` за явно зазначеною датою оплати. В `Extraction.facts` доступні `payment_due_on` і `payment_due_on_quote`. Для інших типів воркер використовує `expires_on`. Якщо дати немає, власник може додати її вручну.

**Похідний дедлайн (Нове).** Екран Confirm deadline показує пункт договору, розрахунок і результат (*Jan 31, 2027 − 30 days = Jan 1, 2027*). `notice_period` залишається в `terms`. Пропозиція: воркер детерміновано рахує другий кандидат `candidate_key: "notice_deadline"` з `kind: CANCELLATION` і розширеним `evidence`. Якщо термін не розбирається, клієнт пропонує ввести дату вручну.

```json
// evidence для похідного дедлайну (пропозиція)
{
  "quote": "unless you cancel at least thirty (30) days before the end of the policy period",
  "base": { "kind": "INSURANCE_EXPIRATION", "date": "2027-01-31" },
  "offset_days": -30
}
```

`HomeStatus` рахує клієнт із `GET /deadlines`. Минула дата `due_on` дає *overdue*, дата в найближчі 30 днів дає *attention*. В інших випадках показуємо *ok* і найближчу дату, якщо вона є.

## Household і доступ для сім'ї

У бекенді household називається `family`; користувач може бути лише в одному. Запрошення працюють лише для вже зареєстрованих людей, а секрет запрошення передається вручну. Рівнів доступу Full / Partial з дизайну і входу за кодом household з PRD (FR-10) немає.

| Ендпоінт | Статус | Запит → відповідь | Помилки та нюанси |
| --- | --- | --- | --- |
| `POST /families` | Є | `{name}` → `201 {id, name, created_at}`. Автор стає `OWNER` | `409` уже в household |
| `GET /families/me` | Є | → `200 {id, name, role}` | `404` не в household — показати *Create* або *Join* |
| `GET /families/{id}/members` | Є | → `200 [{user_id, email, role, joined_at}]` | Імен немає, лише email |
| `POST /families/invitations` | Частково | `{email}` → `201 {id, expires_at, secret}`. Секрет повертається один раз, діє 7 днів | Тільки власник. `404` email не зареєстрований, `409` уже учасник або запрошення вже чекає |
| `GET /families/invitations` | Є | → `200 [{id, invitee_id, state, expires_at}]` | Тільки власник. `state`: `PENDING`, `ACCEPTED`, `REJECTED`, `EXPIRED` |
| `POST /families/invitations/{id}/respond` | Частково | `{secret, decision: "accept"\|"reject"}` → `200 {id, state}` | `404`, `410` прострочено, `409` вже вирішено. Запрошений не бачить своїх запрошень |
| `DELETE /families/{id}/members/{user_id}` | Є | → `204` | Тільки власник. Знімає всі шери цього учасника |
| `POST /families/{id}/leave` | Є | `{successor_user_id?}` → `204` | `409` власник має призначити наступника |
| `GET /families/invitations/incoming` | Нове | → `200 [{id, family_name, inviter_email, expires_at}]` | Щоб запрошений бачив запрошення без ручної передачі |
| `GET` / `POST /families/{id}/code` | Нове | → `{code: "RYN-482"}`; `POST` генерує новий | FR-10, тільки власник |
| `POST /families/join-requests` | Нове | `{code}` → `202 {id, state: "PENDING"}` | `404` невірний код, `429` |
| `GET /families/join-requests` | Нове | → `200 [{id, user_id, email, created_at}]` | Блок *Waiting for you* на екрані Household |
| `POST /families/join-requests/{id}/decide` | Нове | `{decision: "approve"\|"decline", access?}` → `200 FamilyMember` | Тільки власник |
| `PATCH /families/{id}/members/{user_id}` | Нове | `{access}` → `200 FamilyMember` | Зміна Full / Partial |

**Full і Partial access (Нове).** Зараз доступ вирішується лише на рівні документа: шер відкриває його всім учасникам. Пропоную поле `access` на учаснику. *Full* — бачить усе, що поширено на household. *Partial* — лише поширені документи з обраних категорій. Приватних документів інших учасників не бачить ніхто, навіть власник household (PRD FR-10).

```json
// FamilyMember (пропозиція) = нинішній рядок + display_name і access
{
  "user_id": "a7d2…", "email": "sarah@example.com", "display_name": "Sarah Reynolds",
  "role": "MEMBER", "joined_at": "2026-11-21T14:02:00Z",
  "access": { "level": "PARTIAL", "groups": ["UTILITIES", "RENTAL"] }
}
```

Доки входу за кодом немає, запрошення передаємо посиланням `familydoc://join?invitation=<id>&secret=<secret>`. Застосунок відкриває його і викликає `respond`.

## Шерінг і приховування даних

З трьох режимів `ShareSheet` у бекенді є лише *Household*. Немає *A person* (FR-08), *Link that expires* (FR-08) і приховування чутливих даних (FR-09); у PRD всі три позначені як Must have.

| Ендпоінт | Статус | Запит → відповідь | Помилки та нюанси |
| --- | --- | --- | --- |
| `POST /documents/{id}/shares` | Є | `{family_id}` → `200 [{user_id, granted_at}]` | Дає доступ усім, хто зараз у household. Тих, хто приєднається пізніше, не охоплює. `409` немає отримувачів або документ не оброблено |
| `GET /documents/{id}/shares` | Є | → `200 [{user_id, granted_at}]` | Тільки власник |
| `DELETE /documents/{id}/shares` | Є | → `204` | Знімає всі household-шери документа (*Stop sharing*) |
| `GET /documents?scope=shared` | Є | → `200 Document[]` | Вхідні документи для viewer |
| `POST /documents/{id}/shares/people` | Нове | `{email, hide?: string[]}` → `201 {user_id, email, granted_at}` | `404` email без акаунта |
| `DELETE /documents/{id}/shares/people/{user_id}` | Нове | → `204` | — |
| `POST /documents/{id}/links` | Нове | `{expires_in: "1h"\|"24h"\|"7d", hide?: string[]}` → `201 ShareLink`. За замовчуванням `24h` | Недійсне після заміни чи видалення документа |
| `GET /documents/{id}/links` / `DELETE …/links/{link_id}` | Нове | Список і відкликання | — |
| `GET /s/{token}` | Нове | Без авторизації → файл (або замаскована копія) | `410` прострочено або відкликано |
| `GET /documents/{id}/redaction/candidates` | Нове | → `200 RedactionCandidate[]` | Для перемикача *Hide sensitive details* |
| `POST /documents/{id}/redaction/preview` | Нове | `{hide: string[]}` → `200 {pages: [{page, text}]}` (приховане = `████`) | — |
| `GET /documents/{id}/access` | Нове | → `200 {household, people[], links[]}` | Один запит для вкладки Sharing |

```json
// ShareLink (пропозиція)
{ "id": "5d0f…", "url": "https://familydoc.app/s/K7m2Qx…", "expires_at": "2026-11-22T13:40:00Z", "hidden": ["holder_name", "address", "policy_number"] }

// RedactionCandidate (пропозиція)
{ "id": "policy_number", "kind": "POLICY_NUMBER", "text": "LP-4482-1190", "occurrences": 2, "default_hidden": true }
```

`kind` у `RedactionCandidate` беремо з FR-09: `NAME`, `ADDRESS`, `ACCOUNT_NUMBER`, `POLICY_NUMBER`, `AMOUNT`. Номери й суми вже є в `identifiers` і `financials`, ім'я — у `summary_card.holder`. Адреси зараз ніде не витягуються. Прихований текст має зникати з копії, зокрема з текстового шару PDF, а не лише закриватися прямокутником; текст у `ShareSheet` це вже обіцяє.

## Чат Ask

Сесія буває двох видів: по одному документу (`POST /documents/{id}/chat`) і по всьому сховищу (`POST /chat`, `document_id: null`; роутер обирає до 3 документів за картками). Запитання надсилаються через `POST /chat/{id}/messages`. Уточнення («а коли він закінчується?») враховують 3 останні репліки. У тексті відповіді стоять маркери `[n]`, що відповідають `citations[].n`.

| Ендпоінт | Статус | Запит → відповідь | Помилки та нюанси |
| --- | --- | --- | --- |
| `POST /documents/{id}/chat` | Є | `{title?}` → `201 ChatSession` для одного документа | `409` документ ще не оброблено |
| `GET /documents/{id}/chat` | Є | → `200 ChatSession[]` | Лише власні сесії |
| `GET /chat/{id}` | Є | → `200 ChatSession + turns[]` | `404` якщо доступ до документа відкликано |
| `DELETE /chat/{id}` | Є | → `204` | — |
| `POST /chat` | Є | `{title?}` → `201 ChatSession` з `document_id: null` | Сесія по всіх доступних документах |
| `GET /chat` | Є | → `200 ChatSession[]` | Історія для Ask |
| `POST /chat/{id}/messages` | Є | `{message}` → `201 ChatTurn`. Один запит на одне запитання, до 4000 символів | `404` сесія або документ недоступні, `409` змінився документ чи версія чату, `409` немає оброблених документів, `503` модель недоступна. У відповіді також `standalone_question` і `usage` (не зберігаються) |

```json
// ChatSession: document_id = null для сесії по всьому сховищу (POST /chat)
{ "id": "c71e…", "owner_id": "6f1c…", "document_id": "88b3…", "title": null, "turn_version": 2,
  "created_at": "2026-11-21T14:10:00Z", "updated_at": "2026-11-21T14:11:30Z" }

// ChatTurn
{
  "id": "t09a…", "session_id": "c71e…", "turn_number": 1,
  "question": "When does my car insurance expire?",
  "answer_status": "ANSWERED",
  "answer": "Your Geico auto policy ends on Jan 18, 2027 [1].",
  "citations": [{ "n": 1, "document_id": "88b3…", "document_title": "Geico auto policy", "category": "auto_insurance",
                  "quote": "Policy period: 07/18/2026 to 01/18/2027" }],
  "routed_document_ids": ["88b3…"], "source_revision": 1, "created_at": "2026-11-21T14:10:04Z"
}
```

| `answer_status` | Що показує `ChatAnswer` |
| --- | --- |
| `ANSWERED` | Текст відповіді + чипи джерел із `citations` (тап відкриває документ) |
| `INSUFFICIENT_INFORMATION` | Нейтральний notice: *I couldn’t find this in your documents* + підказка, що додати |

**Джерела.** Кожна цитата перевірена бекендом: `quote` дослівно (без урахування регістру й пробілів) є в тексті документа `document_id`. Неперевірені цитати відкидаються, їхні маркери прибираються з тексту, решта перенумеровується `1..N` без пропусків. Однакові цитати зливаються в одне джерело. Якщо після перевірки не лишилось жодної цитати, хід стає `INSUFFICIENT_INFORMATION` з порожнім `citations`.

- `n` — номер джерела; у `answer` йому відповідає маркер `[n]` (може бути кілька поспіль: `[1][2]`).
- `document_title` — назва з картки документа, `category` — AI-тип у нижньому регістрі (`auto_insurance`, `passport`…). Чип: `document_title`, тап відкриває `GET /documents/{document_id}`.
- `page` немає: весь текст лежить як одна сторінка.
- Ходи, збережені до 21.11 ~16:30, мають у `citations` лише `document_id` і `quote`: клієнт нумерує їх за порядком і бере назву з `GET /documents/{id}`.

**Як рендерити.** Замінити `[n]` в `answer` на маленький superscript-чип, що підсвічує або відкриває джерело `n`; під відповіддю — список джерел з `document_title` і цитатою. `standalone_question` показувати не треба: це переписане роутером запитання («а коли він закінчується?» → «When does my auto policy expire?»), корисне для дебагу. Запит синхронний, 2–8 с: на час очікування — індикатор набору, кнопка надсилання вимкнена (паралельний хід у тій самій сесії отримає `409`).

## Перевірка паспорта для авіаквитка (stretch)

У бекенді цього ще немає, але паспорти вже дозволені (`PASSPORT`), і воркер витягує з них `expires_on` та власника. Пропозиція: квиток — це звичайний документ нового типу `FLIGHT_TICKET`, а перевірка — окремий детермінований ендпоінт поверх уже витягнутих даних, без додаткового виклику моделі.

1. Клієнт завантажує квиток через `POST /documents` і чекає на `REVIEW_REQUIRED`, як для будь-якого документа.
2. Воркер для `FLIGHT_TICKET` витягує пасажирів, рейси та дати вильоту й повернення (**Нове**).
3. `POST /documents/{ticket_id}/travel-check` → `200 TravelCheck` (**Нове**). Бекенд зіставляє кожного пасажира з паспортами, доступними власнику квитка, і порівнює `expires_on` з датою повернення.
4. *Remind me to renew* → `POST /documents/{passport_id}/deadlines` з `type: DOCUMENT_EXPIRATION`.

```json
// TravelCheck (пропозиція)
{
  "ticket_document_id": "f402…",
  "trip": { "carrier": "TAP Air Portugal", "flight": "TP 202", "from": "JFK", "to": "LIS",
            "departs_on": "2027-01-14", "returns_on": "2027-01-24" },
  "passengers": [
    { "name_on_ticket": "REYNOLDS/LAURA", "passport_document_id": "aa31…",
      "checks": [
        { "kind": "NAME_MATCH", "result": "PASS" },
        { "kind": "VALID_THROUGH_RETURN", "result": "FAIL", "passport_expires_on": "2027-01-20", "days_short": 4 }
      ] },
    { "name_on_ticket": "REYNOLDS/DAVID", "passport_document_id": null,
      "checks": [{ "kind": "PASSPORT_MISSING", "result": "UNKNOWN" }] }
  ],
  "disclaimer": "Checks passport dates only, not visas or entry rules."
}
```

`result`: `PASS`, `FAIL`, `UNKNOWN` — застосунок показує їх іконками check / x / alert з текстом. Доступ до паспорта іншого члена сім'ї йде тільки через звичайний шер. Якщо паспорта не поширено, результат — `PASSPORT_MISSING`, і жодних даних з нього у відповіді немає.

## Екрани → ендпоінти

Демо з даними з бекенду покриває вхід, завантаження, перевірку документа, підтвердження дедлайну та чат — по документу і по всьому сховищу.

| Екран | Виклики | Готовність |
| --- | --- | --- |
| Sign up / Log in | `POST /auth/register`, `POST /auth/login`, `GET /users/me` (без OTP) | Є |
| Home | `GET /families/me`; `GET /deadlines` для статусу й hero; `GET /documents?scope=all` — *Waiting for your review* (фільтр `REVIEW_REQUIRED` на клієнті) і лічильники на плитках; *Mark as done* — `PATCH …/deadlines/{id}` зі `state: DONE` (Нове) | Частково |
| Add (Scan, Upload) | `POST /documents` (камера дає JPG або PDF), далі опитування `GET /documents/{id}` | Є |
| Review details | `GET /documents/{id}`, `GET /documents/{id}/extraction`, `PATCH /documents/{id}/extraction`, *Change* категорії — `PATCH /documents/{id}`; *Confirm details* — `POST /documents/{id}/confirm` | Є |
| Confirm deadline | `GET /documents/{id}/deadlines?state=PROPOSED`, `PATCH …/deadlines/{id}` зі `state: CONFIRMED` або новою `date`; розрахунок і `reminder_offsets` (Нове) | Частково |
| Document | `GET /documents/{id}`, `/extraction`, `/deadlines`, `/file`; `DELETE`; *Retry* — `POST /reprocess`; *Replace* — `PUT /documents/{id}/file` (Нове) | Є |
| Share | *Household* — `POST`/`GET`/`DELETE /documents/{id}/shares`; *A person*, *Link that expires*, *Hide sensitive details* (Нове) | Частково |
| Ask | Сесія для всього сховища — `POST /chat`, для документа — `POST /documents/{id}/chat`; `POST /chat/{id}/messages`, `GET /chat/{id}`, історія — `GET /chat` | Є |
| Flight added | `POST /documents` + `POST /documents/{id}/travel-check` (Нове) | Не працює |
| Household | `GET /families/me`, `GET /families/{id}/members`, `POST /families/invitations`; код, запити на вступ і рівні доступу (Нове) | Частково |
| Vault (у прототипі немає) | `GET /documents?scope=all`, групування в плитки на клієнті; пошук `q` (Нове) | Частково |

## Що доробити на бекенді

Підтвердження документа, список дедлайнів власника й чат (по документу і по всьому сховищу) вже доступні. Вхід — за email і паролем, email OTP вирізано з MVP.

### P1 — те, що показує прототип

- [ ] Стан `DONE` для *Mark as done*, якщо він потрібен в інтерфейсі
- [ ] Нагадування за 30, 7 і 1 день і `reminder_offsets` на дедлайні (зараз 7 і 1, FR-05)
- [ ] Похідний дедлайн `CANCELLATION` із `notice_period` і `evidence.base`/`offset_days` (екран Confirm deadline)
- [ ] Посилання з терміном дії 1h / 24h / 7d і приховування даних (FR-08, FR-09)
- [ ] `display_name` у `User` і списку учасників
- [ ] `GET /documents`: `q`, `review_status`, сортування за `created_at` (FR-06)
- [ ] Машинний `code` у тілі помилки

### P2 — після демо або за наявності часу

- [ ] Шер одній людині за email (FR-08)
- [ ] Код household, запити на вступ зі схваленням, вхідні запрошення (FR-10)
- [ ] Рівні доступу Full / Partial для учасників
- [ ] `PUT /documents/{id}/file` поверх готового `replace_document_file` (FR-11)
- [ ] Тип `FLIGHT_TICKET` і `POST /documents/{id}/travel-check` (stretch)
- [ ] Надсилання нагадувань email чи push (FR-05)

### Розбіжності, які треба вирішити

| Що | Бекенд | PRD або дизайн | Пропозиція |
| --- | --- | --- | --- |
| Ліміт файлу | 20 MB, без ліміту сторінок | 10 MB, до 20 сторінок PDF | `MAX_UPLOAD_MB=10`; в дизайні лишити *up to 10 MB* |
| Поля дедлайну | Запит: `type`, `date`; відповідь: `kind`, `due_on` | — | Приймати `kind` і `due_on` також |
| Фільтр `status` | Стадія воркера | Клієнту потрібен `review_status` | Новий параметр `review_status` |
| Категорії | 20 AI-типів | 4 групи MVP + 9 категорій команди | Таблиця групування в розділі «Документи» |
| Passwords | `CREDENTIALS_OR_SECRETS` блокується | Категорія в списку команди | Прибрати з продукту або зберігати доступи окремо, не документами |
| Стан `BLOCKED` | Є | У дизайні немає | Додати в дизайн-систему notice з `policy_reason` |
| Нативний застосунок | CORS налаштований лише на веб | PRD: веб; команда: Flutter | Flutter на CORS не залежить; для телефона виставити API в локальній мережі (зараз лише loopback) |
