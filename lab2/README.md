# Лаба 2 - контейнеризация всего нашего сайта

Поскольку фронтенд и бэкенд - два различных приложения, мы делаем для них отдельные Dokcerfile. Мы напишем "плохой" и "хороший" Dokcerfile для образа бэкенда и фронтенда

## Dokcerfile.backend

Для начала сделаем Dockerfile.backend.bad, содержащий несколько плохих практик при создании образа:

```
FROM golang:latest

WORKDIR /app

COPY . .

RUN go mod download

RUN go build -o server ./internal

EXPOSE 5040

CMD ["./server"]
```

Здесь можно найти несколько плохих практик:

- golang:latest - здесь берется последняя версия, и из-за этого образ может меняться в зависимости от текущей версии, поэтом могут возникнуть проблемы

- Не правильный порядок слоев - сначала идет COPY . . , который копирует файлы внутрь образа, и только после этого идет RUN go mod download, копирующий зависимости. Из-за этого при небольшом изменении файлов в проекте придется заново устанавливать непоменявшиеся зависимости

- Нет multi-stage build - из-за того, что испольуется весь образ golang, образ может весить очень много. В идеале нужно использовать его только на сборке, чтобы он не занимал много места

- Запуск от root - не указан пользователь, а значит все запускается от root. Это считается плохой практикой, ведь не нужно выдавать приложению права, которые ему не нужны 

Переделаем Dockerfile.backend по нормальному:

```
FROM golang:1.25.0 AS builder

WORKDIR /app

COPY go.mod go.sum ./

RUN go mod download

COPY . .

RUN go build -o server ./internal


FROM alpine:3.22.1

RUN adduser -D backend_user

WORKDIR /app

COPY --from=builder /app/server ./server

USER backend_user

EXPOSE 5040

FROM golang:1.25.0 AS builder

WORKDIR /app

COPY go.mod go.sum ./

RUN go mod download

COPY . .

RUN go build -o server ./internal


FROM alpine:3.22.1

RUN adduser -D backend_user

WORKDIR /app

COPY --from=builder /app/server ./server

USER backend_user

EXPOSE 5040

HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 CMD wget --spider -q http://localhost:5040/health || exit 1

CMD ["./server"]


CMD ["./server"]
```

Сначала исправляем проблему с образом go, а именно берем определенную версию (1.25.0). Также указываем, что будем использовать образ golang только для сборки (Привет, multi-stage build).

Добавляем нормальный порядок слоев: сначала копируем go.mod и go.sum (файлы с указанием зависимостей), потом устанавливаем зависимости (RUN go mod download). И только после этого мы копируем все файлы с кодом и компилируем приложение. Так мы добавляем кэширование зависимостей, и они не устанавливаются, если они не менялись. Компилируем код в файл server для следующей стадии

Переходим на вторую стадию. Сначала берем образ alpine для запуска сервера на нем. Добавляем второго пользователя (backend_user), которого потом будем использовать (строкой USER backend_user). Этим решим проблему root пользователем.

Берем результат компиляции и билдера, и кладем его в /app/server. Затем указываем порт и последней командой запускаем сервер.

Поскольку мы разделили Dockerfile на 2 стадии (build и runtime), во второй стадии мы уже не используем образ языка, так что размер нашего образа должен стать меньше.

также мы добавили Healthcheck - раз в 60 секунд мы проверяем состояние сервера. На это мы даем 5 секунд и 3 попытки. Добавляем --spider, чтобы ответ сервера не сохранялся. Это проверяет, что контейнер живой и сервер работает.


## Dockerfile.frontend

Определимся нюанс `vite build` превращает проект в статику — `index.html`, JS и CSS в папке `dist/`. После сборки Node больше не нужен, файлы остается только отдавать по HTTP, и здесь нам поможет... Nginx!
Мало весит, быстрый, умеет отдавать статику и проксировать запросы `/api` на бэкенд. `vite preview` и `vite dev` в продакшене использовать НЕ советуют — это инструменты для разработки, о чем прямо пишет документация Vite.

### 1) Плохой Dockerfile.frontend.bad

```
FROM node:latest

WORKDIR /app

COPY . .

RUN npm install

RUN npm run build

RUN npm install -g serve

EXPOSE 80

CMD ["serve", "-s", "dist", "-l", "80"]
```

Проблемы:

- `node:latest` — версия Node не зафиксирована. Сейчас `latest` это уже Node v26, завтра будет другая, и сборка может внезапно сломаться. То же самое с `npm install -g serve` без версии

- Нет multi-stage build — в финальном образе остается весь Node, `node_modules`, исходники и npm-кэш, хотя для работы нужна только папка `dist`. Как итог увидим — **1.88 ГБ**.

- Неправильный порядок слоев — `COPY . .` идет до `npm install`. Любая правка в коде меняет слой `COPY . .`, и Docker заново выполняет все после него: `npm install`, сборку и даже установку `serve`. Пересборка после изменения одной строки — **14 секунд** против 1 секунды у хорошего варианта.

- `npm install` вместо `npm ci` — `npm install` может молча обновить зависимости и переписать `package-lock.json`, поэтому сборки не воспроизводимы.

- Нет `.dockerignore` — `COPY . .` тащит в образ все подряд: локальные `node_modules` (собранные под macOS), `dist`, `docs`, а главное **секреты**. Проверили — внутри образа лежат `.env`, `localhost-key.pem` и `todo.local+3-key.pem`, то есть приватные ключи сертификатов. Любой, у кого есть образ, может их достать.

- Запуск от root - пользователь не указан, процесс работает с `uid=0`.

- Нет HEALTHCHECK — Docker не знает, отвечает ли сервер на самом деле.

- `serve` умеет только отдавать файлы. Проксировать `/api` на бекенд он не может, поэтому пришлось бы открывать бекенд наружу и настраивать CORS.

### 2) Хороший Dockerfile.frontend

Исправим все это в Dockerfile.frontend!

```
FROM node:22.23.3-alpine3.24 AS builder

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci

COPY index.html vite.config.js ./
COPY src ./src

ARG VITE_BACKEND_URL=/api

RUN npm run build


FROM nginxinc/nginx-unprivileged:1.30.5-alpine3.24

COPY <<'CONF' /etc/nginx/conf.d/default.conf
server {
    listen 8080;
    server_name _;
    server_tokens off;

    root /usr/share/nginx/html;
    index index.html;

    resolver 127.0.0.11 valid=10s ipv6=off;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;

    location /assets/ {
        add_header Cache-Control "public, max-age=31536000, immutable";
        try_files $uri =404;
    }

    location / {
        add_header Cache-Control "no-cache";
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        set $backend http://backend:5040;
        proxy_pass $backend;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 2s;
        proxy_read_timeout 15s;
    }
}
CONF

COPY --from=builder /app/dist /usr/share/nginx/html

USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:8080/ || exit 1
```

#### Стадия сборки (builder)

Фиксируем точную версию `node:22.23.3-alpine3.24` для воспроизводимости, Alpine делает базу меньше. Образ Node нужен только на этой стадии (привет, multi-stage build).

Сначала `COPY package.json package-lock.json`, а потом `RUN npm ci`. Это кэш слоев - пока зависимости не поменялись, `npm ci` берется из кэша, и при правке кода он не перезапускается.

Используем `npm ci`, а не `npm install`, `npm ci` ставит зависимости строго по `package-lock.json` и падает, если lock-файл расходится с `package.json`. `npm install` в такой ситуации молча обновит зависимости, и две сборки одного кода могут получиться разными.

Копируем только то, что реально нужно для сборки (`index.html`, `vite.config.js`, `src`), а не все подряд. В образ не попадет лишнее, и кэш не сбрасывается из-за посторонних файлов.

`ARG VITE_BACKEND_URL=/api` - Vite вшивает переменные `VITE_*` прямо в JSбандл во время сборки, в рантайме их уже не поменять. Поэтому передаем адрес бэкенда как аргумент сборки (`ARG`) - он существует только во время сборки и его можно переопределить из compose. `ENV` для этого хуже — он остается в метаданных образа. Значение `/api` относительное, то есть браузер ходит на тот же хост, где открыт сайт (в nginx), и CORS не нужен.

#### Стадия запуска

`nginxinc/nginx-unprivileged` — вариант nginx, который сразу работает от непривилегированного пользователя (`uid 101`). Обычный образ `nginx` стартует от root, потому что занимает порт 80: порты ниже 1024 без root занять нельзя. Поэтому unprivileged-версия слушает порт **8080**.

Конфиг nginx встраиваем прямо в Dockerfile через heredoc (`COPY <<'CONF' ... CONF`). Контекст сборки — `lab0/frontend`, а `COPY` не может взять файл снаружи контекста. Так Dockerfile не требует отдельного файла с конфигом.

`COPY --from=builder /app/dist` — в финальный образ попадает только собранная статика: ни Node, ни `node_modules`, ни исходников, ни секретов. Итог — **90 МБ** против **1.88 ГБ** у `.bad`.

`USER nginx` — в базовом образе уже так, но строка явно фиксирует, что запуск не от root.

`HEALTHCHECK` через `wget --spider` раз в 30 секунд проверяет, что nginx отвечает (`--spider` — не скачивать тело ответа). `CMD` не пишем: он наследуется от базового образа (`nginx -g 'daemon off;'`).

#### Что в конфиге nginx

- `try_files $uri $uri/ /index.html` — SPA fallback: любой неизвестный путь отдает `index.html`, а дальше разбирается JS.
- `location /assets/` — Vite кладет в имена файлов хеш (`index-CWG7AxkJ.js`), поэтому их можно кэшировать в браузере на год (`immutable`). При изменении кода поменяется и имя файла.
- `Cache-Control: no-cache` для `index.html` — иначе браузер не увидит новый бандл после деплоя.
- `gzip` — сжимаем JS, CSS и JSON при отдаче.
- `server_tokens off` — не показываем версию nginx в заголовках.
- `location /api/` — проксируем запросы на бэкенд. Адрес задается через переменную `set $backend` + `resolver 127.0.0.11` (встроенный DNS Docker). Если написать `proxy_pass http://backend:5040` напрямую, nginx резолвит имя при старте и падает, если бэкенда нет. С переменной имя резолвится при каждом запросе, поэтому nginx стартует и без бэкенда (на `/api` отдаст 502), а когда бэкенд появится — заработает без правок конфига. Путь передается как есть (`/api/tasks` → `/api/tasks`), это совпадает с `r.Group("/api")` в бэкенде.
- `proxy_set_header Host / X-Real-IP / X-Forwarded-*` — чтобы бэкенд видел реальный IP клиента, а не IP nginx.
- `proxy_connect_timeout` и `proxy_read_timeout` — чтобы зависший бэкенд не держал соединения бесконечно.

#### Dockerfile.frontend.dockerignore

```
node_modules
dist
docs
.vite
.git
*.log
.env
.env.*
*.pem
```

Docker сам забирает файл, если он лежит рядом с Dockerfile. Исключаем:

- `node_modules` и `dist` — тяжелые, и их все равно пересоздадут `npm ci` и `vite build`. К тому же локальные `node_modules` собраны под macOS и в Linux-контейнере могут не работать.
- `.env*` и `*.pem` — секреты и приватные ключи не должны попасть даже в контекст сборки!!!!
- `.git`, `docs`, `*.log`, `.vite` - мусор

### 3) Сравнение

Замеры на одной машине (базовые образы уже скачаны). Пересборка — после изменения одной строки в `src/main.js`:

| | Dockerfile.frontend.bad | Dockerfile.frontend |
|---|---|---|
| Размер образа | 1.88 ГБ | 90.3 МБ |
| Сборка с нуля | 10 с | 9 с |
| Пересборка после правки кода | 14 с (заново `npm install` и `npm install -g serve`) | 1 с (`npm ci` из кэша) |
| Пользователь | root (`uid=0`) | nginx (`uid=101`) |
| Секреты в образе | `.env`, `*-key.pem` | нет |
| Healthcheck | нет | есть |
| Прокси `/api` | нет | есть |

## docker-compose.yml

Фронтенд compose

```
services:
  frontend:
    build:
      context: ../lab0/frontend
      dockerfile: ../../lab2/Dockerfile.frontend
      args:
        VITE_BACKEND_URL: /api
    image: todo-frontend:good
    ports:
      - "8080:8080"
    read_only: true
    tmpfs:
      - /tmp
    restart: unless-stopped
    networks:
      - front-net

networks:
  front-net:
```

- `context: ../lab0/frontend` и `dockerfile: ../../lab2/Dockerfile.frontend` — код лежит в lab0, а Dockerfile в lab2. Путь к `dockerfile` в compose считается от `context`.
- `args: VITE_BACKEND_URL` — передает значение в `ARG` из Dockerfile.
- `image: todo-frontend:good` — понятное имя собранного образа.
- `ports: "8080:8080"` — единственная точка входа снаружи. Бэкенд потом публиковать не нужно, он будет доступен только через nginx.
- `read_only: true` + `tmpfs: /tmp` — файловая система контейнера только для чтения, даже при взломе ничего не записать. Nginx пишет только pid и временные файлы в `/tmp`, поэтому `/tmp` монтируем в память. Строка в логах `can not modify /etc/nginx/conf.d/default.conf (read-only file system?)` — это нормально: скрипт образа просто пропускает включение IPv6.
- `restart: unless-stopped` — контейнер поднимется после падения или перезапуска Docker, но не после ручного `docker stop`.
- Сеть `front-net` бекенд подключим к этой же сети, и nginx найдет его по имени `backend`.

Запуск:

```
cd lab2
docker compose up -d --build
```

Проверка:

```
docker compose ps
curl -I http://localhost:8080/
```
<img width="993" height="477" alt="image" src="https://github.com/user-attachments/assets/bf62ebf0-1fb6-48c8-a7c0-d3fa6d08e3c2" />
<img width="436" height="65" alt="image" src="https://github.com/user-attachments/assets/3cddec0a-67c5-4a22-81fb-6c716667745a" />
<img width="1004" height="65" alt="image" src="https://github.com/user-attachments/assets/378f31e3-1388-4903-b541-c3cc022e0530" />
<img width="512" height="171" alt="image" src="https://github.com/user-attachments/assets/6e93a668-becc-4405-ad84-d4ff039b536e" />
<img width="524" height="37" alt="image" src="https://github.com/user-attachments/assets/06ad4e2b-8940-4eba-8448-4558c2bb9dfe" />
<img width="693" height="107" alt="image" src="https://github.com/user-attachments/assets/74af237b-8994-4df4-a1b8-6c615496fad1" />
<img width="526" height="73" alt="image" src="https://github.com/user-attachments/assets/c7953a62-387f-4207-a963-ed6b53428976" />
<img width="889" height="34" alt="image" src="https://github.com/user-attachments/assets/663c704f-2417-48e5-bfdd-7a817c18b0ca" />
<img width="883" height="30" alt="image" src="https://github.com/user-attachments/assets/174bed38-8102-4d95-a17e-d7ceb4e10909" />
**И как итог!**
<img width="942" height="206" alt="image" src="https://github.com/user-attachments/assets/c6ceba5d-45f2-4b4f-85f2-97ed9f444ebf" />





