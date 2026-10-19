# «Через Mac»: свой сервер связи

Если прямой путь к Mac недоступен (Mac не дома, серый IP, сеть без проброса — см.
`docs/via-mac-direct.md`), iPhone и Mac связываются через сервер связи (relay iroh). По
умолчанию это публичные серверы n0 за рубежом; в некоторых сетях соединения с ними
замирают после первых килобайт. Свой сервер на VPS — запасной путь, который зависит
только от вас. Сервер видит лишь зашифрованный трафик между вашими устройствами
(QUIC/TLS iroh), расшифровать его он не может.

Ниже — iroh-relay **1.0.2** (как iroh 1.0.2 в приложениях) на VPS с Linux, на одном сервере
с вашим сайтом. Все ключи конфига и порты сверены с исходным кодом iroh-relay 1.0.2
(`src/main.rs`, `src/defaults.rs`) и проверены запуском официального образа.

Файлы: `docs/via-mac-relay/iroh-relay.toml` (конфиг), `docker-compose.yml`,
`iroh-relay.service` (systemd, вариант без Docker), `nginx.conf` (сайт и сервер связи на 443).

## Выбор VPS

- **Хостинг в России.** Замедление, из-за которого всё затеяно, в наблюдаемых случаях
  касалось TLS-соединений с зарубежными адресами; с российским дата-центром его быть не
  должно. Это ожидание, а не гарантия — проверьте (раздел «Проверка»).
- **Ресурсы:** хватит минимального тарифа — 1 vCPU, 512 МБ–1 ГБ RAM (с сайтом рядом — 1 ГБ).
  Замеры ниже.
- **Трафик:** через сервер идёт только то, что не прошло напрямую. Каждый байт он
  принимает и отправляет, то есть у хостера считается дважды. Если тариф с лимитом
  трафика, оценивайте его как 2× объём страниц, открытых «Через Mac» вне дома без прямого
  пути. Скорость канала VPS (обычно 100 Мбит/с и выше) ограничивает скорость страниц.
- Нужны публичный IPv4, доменное имя (поддомен вашего сайта, например
  `relay.example.ru`, A-запись на IP VPS) и открытые порты (ниже).

## Порты

| Порт | Кто слушает | Зачем | Снаружи |
|---|---|---|---|
| 443/TCP | nginx → iroh-relay `127.0.0.1:8443` | сам сервер связи (HTTPS + WebSocket `/relay`), проверки `/ping` | открыть |
| 80/TCP | nginx | сайт, проверки certbot, `/generate_204` сервера связи → `127.0.0.1:3340` | открыть |
| 7842/UDP | iroh-relay `[::]:7842` | QUIC address discovery: устройства узнают свой внешний адрес, это помогает прямому пути | открыть |
| 3340/TCP | iroh-relay `127.0.0.1:3340` | простой HTTP сервера (captive portal) | только локально |
| 9090/TCP | iroh-relay `127.0.0.1:9090` | метрики Prometheus | только локально |

Порт 7842 — тот, который клиенты iroh ждут по умолчанию (`DEFAULT_RELAY_QUIC_PORT`);
менять его нельзя, иначе клиенты не найдут QUIC-сервер. Без 7842/UDP связь через сервер
всё равно работает, только хуже находится прямой путь.

Файрвол (ufw):

```sh
ufw allow 22/tcp      # SSH — до включения ufw!
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 7842/udp
ufw enable
```

Если у хостера есть свой файрвол в панели — откройте там то же.

## Сайт и сервер связи на одном 443

Сервер связи сам принимает TLS (ему нужен свой сертификат на `relay.example.ru`), поэтому
nginx не проксирует его как веб-сайт, а пропускает TLS насквозь: модуль `stream` с
`ssl_preread` читает имя (SNI) из начала соединения и отдаёт соединения для
`relay.example.ru` серверу связи на `127.0.0.1:8443`, а все остальные — HTTPS-серверу
сайта, который nginx слушает локально на `127.0.0.1:4443`. Готовый файл —
`docs/via-mac-relay/nginx.conf`: замените имена и путь к сайту.

- На Debian/Ubuntu модуль stream ставится пакетом `libnginx-mod-stream`.
- Сайт в этой схеме видит адрес клиента как `127.0.0.1` (в журналах и в приложении).
  Настоящий адрес передаёт PROXY protocol, но включать его в `stream` можно только для
  сайта: iroh-relay его не понимает.
- `proxy_timeout 1h` в `stream` обязателен: устройства держат соединение с сервером
  связи часами, а по умолчанию nginx рвёт его после 10 минут тишины.

Проще, но без 443: сервер связи на отдельном порту, без nginx stream. В конфиге
`https_bind_addr = "[::]:8443"`, адрес в UniBrowser — `https://relay.example.ru:8443`,
сертификат только от certbot (`cert_mode = "Reloading"`, см. ниже), в файрволе открыть
8443/TCP. Минус: некоторые сети пропускают наружу только 80 и 443.

## Сертификат Let's Encrypt

Два варианта, оба поддерживаются iroh-relay 1.0.2:

1. **certbot (рекомендуется рядом с сайтом).** nginx на порту 80 уже отдаёт
   `/.well-known/acme-challenge/` из `/var/www/letsencrypt` для обоих имён:

   ```sh
   mkdir -p /var/www/letsencrypt
   certbot certonly --webroot -w /var/www/letsencrypt -d relay.example.ru
   ```

   В конфиге — `cert_mode = "Reloading"` и пути `/etc/letsencrypt/live/relay.example.ru/…`.
   Режим `Reloading` перечитывает файлы раз в сутки, так что продление certbot
   подхватывается без перезапуска.

2. **Сервер связи получает сертификат сам** (`cert_mode = "LetsEncrypt"`, `hostname`,
   `contact`, `cert_dir`). Он проходит проверку TLS-ALPN-01 на порту 443; через nginx
   `ssl_preread` это работает, потому что TLS доходит до сервера связи нетронутым. На
   отдельном порту (8443) этот режим не работает — Let's Encrypt проверяет только 443.

Ключ сертификата должен быть RSA, ECDSA (P-256/P-384, именованная кривая) или Ed25519 в
PEM — certbot выдаёт подходящие по умолчанию.

## Запуск в Docker (рекомендуется)

```sh
mkdir -p /opt/iroh-relay && cd /opt/iroh-relay
# скопируйте сюда docker-compose.yml и iroh-relay.toml из docs/via-mac-relay/, поменяйте имя
docker compose up -d
docker compose logs -f
```

В журнале должно быть:

```
[HTTPS/WSS] relay: serving on 127.0.0.1:8443
QUIC server listening on bind_addr=[::]:7842
```

Образ `n0computer/iroh-relay:v1.0.2` — официальный образ n0 для этой версии (amd64 и arm64).

## Без Docker

```sh
apt install build-essential pkg-config      # и Rust: https://rustup.rs
cargo install iroh-relay --version 1.0.2 --features server --locked
install -m 0755 ~/.cargo/bin/iroh-relay /usr/local/bin/
useradd --system --home /nonexistent --shell /usr/sbin/nologin iroh-relay
mkdir -p /etc/iroh-relay/tls
cp docs/via-mac-relay/iroh-relay.toml /etc/iroh-relay/
cp docs/via-mac-relay/iroh-relay.service /etc/systemd/system/
```

Ключи certbot читает только root, поэтому их копия для сервера связи кладётся при каждом
продлении — `/etc/letsencrypt/renewal-hooks/deploy/iroh-relay.sh`:

```sh
#!/bin/sh
install -o iroh-relay -g iroh-relay -m 0640 /etc/letsencrypt/live/relay.example.ru/fullchain.pem /etc/iroh-relay/tls/
install -o iroh-relay -g iroh-relay -m 0600 /etc/letsencrypt/live/relay.example.ru/privkey.pem /etc/iroh-relay/tls/
```

(`chmod +x`, запустить один раз вручную.) В `/etc/iroh-relay/iroh-relay.toml` пути
`manual_cert_path`/`manual_key_path` — на `/etc/iroh-relay/tls/fullchain.pem` и `privkey.pem`.

```sh
systemctl daemon-reload
systemctl enable --now iroh-relay
journalctl -u iroh-relay -f
```

## Настройка UniBrowser

1. На Mac: Настройки → iPhone (или окно «iPhone…»), поле «Свой сервер связи» —
   `https://relay.example.ru` (или `https://relay.example.ru:8443`), Return. Связь
   перезапустится через ваш сервер; серверы n0 больше не используются.
2. iPhone узнаёт новый адрес при следующем подключении к Mac (в QR-коде и в каждом ответе
   Mac). Если телефон сейчас не может достучаться до Mac, на iPhone в настройках
   «Через Mac» → «Подключение» укажите тот же адрес в поле «Сервер связи».
3. Пустое поле на Mac — снова серверы n0.

## Проверка

1. С любого устройства: `https://relay.example.ru` — страница «Iroh Relay»;
   `https://relay.example.ru/ping` — ответ 200.
2. iPhone в мобильном интернете (Wi-Fi выключен), Mac не напрямую (например, проброс
   выключен): в настройках «Через Mac» «Связь» показывает «Через сервер связи», страницы
   открываются. Сравните время открытия страниц с серверами n0 (поле на Mac пустое).
3. Метрики на VPS: `curl -s 127.0.0.1:9090/metrics | grep relayserver_bytes` — растут,
   когда трафик идёт через сервер.

## Замеры (локальный стенд, Docker на Mac)

`n0computer/iroh-relay:v1.0.2 --dev` в Docker Desktop (arm64), iPhone-симулятор и Mac,
прямой путь между ними выключен:

- Подключение iPhone к Mac через сервер (до ответа Mac): 0,05 с.
- Память контейнера: 3,8–12,5 МБ в покое, 4,1–4,8 МБ под нагрузкой.
- CPU: 0 % в покое; около 3–3,5 % одного ядра, пока открываются страницы
  (Википедия 122 КБ, apple.com 327 КБ — по 0,27–0,36 с); файл 10 МБ прошёл за 1,1 с
  (≈77 Мбит/с, упёрлось не в сервер).
- Счётчики сервера после 15 страниц и файла 10 МБ: по 23 МБ принято и отправлено — каждый
  байт проходит через сервер дважды (внутрь и наружу).

Это локальная сеть без задержек; на VPS потребление CPU и памяти на мегабайт будет того же
порядка (оценка), а скорость определит канал VPS и мобильная сеть.
