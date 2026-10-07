# Лаба 1 — nginx

nginx - Точка входа сайта

## Что сделали
1) Скачали инструментарий, mkcert, nginx. 
2) Сделали https, самоподисали через mkcert, чтобы сайт считался https (cертификат подтверждает, что сервер владеет именем) , и можно было редиректить из 80 на 443. 
3) Сверстали 2 проект, ошибки, alias сайт, admin сайт.
   - Alias - отдельная папка, которая открывается по своему пути .../docs/, но лежит не внутри сборки фронта, а отдельно (www/docs).
   - Admin часть сделали htpasswd, в такую часть можно попасть аналогично как и по alias, но при входе будет требовать пароль
   - Кастомные ошибки, сам сайт - отдает nginx, о нем в следующем пункте
4) Добавили виртуальные хосты: два домена todo.local и project2.local на одном nginx, каждый со своим server-блоком. Чтобы домены вообще открывались локально, прописали их в /etc/hosts: echo '127.0.0.1 todo.local project2.local' | sudo tee -a /etc/hosts
5) Nginx! - тяжелый и беспощадный
Статику собранного фронта (vite build) nginx отдает сам, без Node.js, а так-же теперь проксируется на бекенд. 
Nginx подставляет подписанные сертификаты и при попытке зайти на сайт, сразу редиректит на https.
Подключили upstream (балансировка, если упал 1 бекенд, то запросы отправляются на второй, а так-же nginx распределяет запросы по очереди (round-robin)). Теперь если упал 1 сервер, то запросы летят только на 2, при этом, первый выходит из ротации на 10 секунд.
Подключили limit-req, 5 запросов с 1 ip, пропускает сразу до 10 лишних запросов сверху, все что больше - уходит в 429.

Важный нюанс, для отказоустойчивости используется zone (общая память для upstream, счетчики для worker-процессов),без него каждый воркер пытался бы еще работать с мертвым сервером.

## Как сделали

### HTTPS и редирект с 80 на 443

Файлы: `sites/00-http-redirect.conf`, `snippets/ssl.conf`

```nginx
server {
    listen 80;
    server_name todo.local project2.local;
    return 301 https://$host$request_uri;
}
```

- На 80 порту ничего не отдаем, только 301 на https. `$request_uri` - это путь вместе с `?query`, поэтому `http://todo.local/test?a=1` уходит ровно на `https://todo.local/test?a=1`, а не на главную.
- Сертификат выпустили через mkcert сразу на оба домена + localhost и 127.0.0.1. mkcert ставит свой корневой сертификат в систему (`mkcert -install`), поэтому браузер не ругается, хотя сертификат самоподписанный.
- Настройки TLS вынесли в `snippets/ssl.conf` и подключаем через include в каждый https server, чтобы не копировать одно и то же.

Проверка: `curl -I http://todo.local/` вернет `301`, `Location: https://todo.local/`

### Фронт и бек на одном хосте

Файл: `sites/todo.local.conf`

```nginx
root  ../lab0/frontend/dist;

location / {
    try_files $uri $uri/ =404;
}

location /api/ {
    proxy_pass http://todo_backend;
}
```

- Все что не `/api/` - nginx ищет файл в сборке фронта и отдает сам.
- Все что начинается с `/api/` - уходит на бекенд. Фронт собран с `VITE_BACKEND_URL=/api`, так что браузер шлет запросы на тот же домен и CORS не нужен.
- В `proxy_pass` нет слэша в конце - это важно. Без слэша бекенд получает путь как есть (`/api/tasks`). Со слэшем (`http://todo_backend/`) nginx отрезал бы `/api/` и бекенд получил бы `/tasks`, а у нас роуты в Go как раз `/api/...`.

### Балансировка и идентификатор бекенда

Файлы: `nginx.conf` (upstream), `snippets/proxy.conf`, `lab0/backend/internal/main.go`

```nginx
upstream todo_backend {
    zone todo_backend 1m;
    server 127.0.0.1:5040 max_fails=1 fail_timeout=10s;
    server 127.0.0.1:5041 max_fails=1 fail_timeout=10s;
    keepalive 16;
}
```

- Подняли 2 копии одного и того же бекенда на 5040 и 5041, порт и имя передаем через переменные окружения `PORT` и `INSTANCE_ID`.
- По умолчанию nginx раскидывает запросы по очереди (round-robin): 1-й на первый, 2-й на второй и тд.
- `keepalive 16` - nginx держит открытые соединения до бекенда и не открывает новое на каждый запрос. Для этого в `proxy.conf` стоит `proxy_http_version 1.1` и пустой `Connection`.

Проверка: несколько раз `curl https://todo.local/api/whoami` - backend-1 и backend-2 чередуются.

### Отказоустойчивость

Файл: `snippets/proxy.conf` + параметры server в upstream

```nginx
proxy_connect_timeout     1s;
proxy_next_upstream       error timeout http_502 http_503 http_504;
proxy_next_upstream_tries 2;
```

- `proxy_next_upstream` - если nginx не смог подключиться к бекенду (процесс убит) или тот вернул 502/503/504, nginx тут же повторяет этот же запрос на втором. Клиент получает 200 и ничего не замечает.
- `max_fails=1 fail_timeout=10s` - после первой же ошибки мертвый бекенд выкидывается из ротации на 10 секунд, туда даже не пробуем. Потом nginx пробует снова, если поднялся - возвращает в очередь.
- `proxy_connect_timeout 1s` - по умолчанию nginx ждет подключения 60 секунд, с мертвым сервером это было бы долго.
- `zone` - общая память для всех worker-процессов nginx. Без нее у каждого воркера свой счетчик, и каждый отдельно спотыкался бы об упавший сервер. Мы это поймали на практике - без zone запросы еще и распределялись криво (5 из 6 на один бекенд).
- `non_idempotent` специально НЕ включали, если POST уже дошел до бекенда и тот завис, повтор создал бы задачу 2 раза.

Проверка: гасим backend-1 Ctrl+C) - все ответы 200 и только от backend-2. Первый запрос после падения видно по `X-Upstream: 127.0.0.1:5040, 127.0.0.1:5041` - значит nginx попробовал первый, не вышло, ответил второй.

### alias

Файл: `sites/todo.local.conf`

```nginx
location /docs/ {
    alias www/docs/;
}
```

- alias подменяет начало пути на папку: `/docs/index.html` -> `www/docs/index.html`. То есть страница лежит вообще отдельно от сборки фронта.
- Разница с `root`: root приклеивает весь путь к папке. Если написать `root www/docs;`, nginx пошел бы искать `www/docs/docs/index.html` и выдал 404.
- Слэш в конце должен быть и у location, и у alias, иначе пути склеятся криво.

Проверка: `curl https://todo.local/docs/` - открывается страница из `www/docs`.

### Виртуальные хосты

Файлы: `sites/todo.local.conf`, `sites/project2.local.conf`, `sites/zz-default.conf`

- Оба сайта висят на одном nginx и одном порту 443. nginx выбирает server-блок по заголовку `Host` (а для https еще раньше - по SNI, это имя сайта, которое браузер отправляет при TLS-рукопожатии).
- У `project2.local` свой `root www/project2` и больше ничего - нет ни `/api`, ни `/docs`, ни `/admin`. Поэтому `https://project2.local/admin/` = 404, чужое не протекает.
- Главный нюанс - чужие домены. Если нет `default_server`, nginx отдает запрос с незнакомым Host ПЕРВОМУ server-блоку на порту, то есть кто-нибудь зашел бы по левому домену и увидел наш сайт. Поэтому сделали отдельный сервер по умолчанию:

```nginx
server {
    listen 80 default_server;
    server_name _;
    return 444;                 # просто закрыть соединение, без ответа
}
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;    # неизвестное имя - даже TLS не устанавливаем
    return 444;
}
```

- 444 - специальный код nginx, он ничего не отвечает и просто рвет соединение.

Проверка:
- `curl -H 'Host: project2.local' https://todo.local/` - отдается Project Two, а не todo
- `curl https://evil.local/` (через --resolve на 127.0.0.1) - TLS отклонен
- `curl --http1.1 -H 'Host: evil.local' https://todo.local/` - пустой ответ

### Ограничение частоты запросов (limit_req)

Файлы: `nginx.conf` (зона), `sites/todo.local.conf` (сам лимит на /api)

```nginx
# nginx.conf
limit_req_zone   $binary_remote_addr zone=api:10m rate=5r/s;
limit_req_status 429;

# location /api/
limit_req zone=api burst=10 nodelay;
```

- Считаем по IP клиента (`$binary_remote_addr` - тот же IP, только в 4 байтах, экономит память). Под счетчики выделено 10 Мб.
- `rate=5r/s` - в среднем 5 запросов в секунду с одного IP.
- `burst=10` - разрешаем всплеск еще на 10 запросов сверху. `nodelay` - эти 10 выполняются сразу, а не ставятся в очередь с задержкой.
- Все что сверх - отказ. По умолчанию nginx отдает 503, поэтому поставили `limit_req_status 429` (Too Many Requests) - так правильнее.
- Лимит только на `/api`. Статику фронта не режем, а то браузер грузит сразу кучу файлов и сам бы себя заблокировал.

Проверка: 40 запросов одновременно - 11 прошло (1 по скорости + 10 из burst), 29 получили 429.

### Свои страницы 404 и 50x

Файл: `snippets/errors.conf`, страницы в `www/errors/`

```nginx
error_page 404             /_errors/404.html;
error_page 500 502 503 504 /_errors/50x.html;

location ^~ /_errors/ {
    internal;
    alias www/errors/;
}
```

- `error_page` делает внутренний переход на нашу страницу, код ответа при этом остается 404 (или 502 и тд).
- `internal` - напрямую по адресу `/_errors/404.html` эту страницу не открыть, только когда nginx сам на нее переходит.
- `^~` - чтобы этот location точно выигрывал у любых регулярок, если они появятся.
- Сниппет подключен в оба сайта, так что и у project2 своя 404.
- 50x видно, если погасить оба бекенда: `/api/` отдает 502 со страницей "Сервис временно недоступен".

Проверка: `curl https://todo.local/nope` - 404 и в теле "Такой страницы нет".

### /admin под паролем

Файл: `sites/todo.local.conf`, пароли в `nginx/.htpasswd`

```nginx
location /admin {
    auth_basic           "Admin area";
    auth_basic_user_file .htpasswd;
    root www;
}
```

- Файл паролей создали `htpasswd -cB nginx/.htpasswd admin`. `-c` создает файл, `-B` - хэш bcrypt, в файле лежит не сам пароль, а хэш. В git файл не попадает.
- Без пароля или с неправильным nginx отвечает 401, и браузер показывает окно логина.
- location сделан без слэша (`/admin`), чтобы под пароль попадал и `/admin`, и `/admin/`. Проверка пароля идет до отдачи файла, поэтому даже на `/admin` сначала 401, а не редирект.
- Нюанс: basic auth передает логин и пароль почти открытым текстом (base64), поэтому без https его использовать нельзя. У нас все через https, так что ок.

Проверка: `curl -I https://todo.local/admin/` - 401, `curl -u admin:wrong ...` - 401.

### Без абсолютных путей

- Раньше в конфиге были пути вида `/Users/.../lab0/...` - на другом компе ничего бы не завелось. Теперь все пути относительные.
- nginx запускается с `-p` (prefix): `nginx -p "$PWD/" -c nginx/nginx.conf`. От prefix (`lab1/`) считаются `root`, `alias`, логи, pid. А `include`, сертификаты и `.htpasswd` считаются от папки, где лежит `nginx.conf` (`lab1/nginx/`).
- nginx запускаем без sudo (macOS разрешает обычному пользователю занимать 80 и 443), поэтому воркер и так работает от нас и спокойно читает файлы из домашней папки без 403.


Результат выполнения check.sh:



Конфиг:
```worker_processes auto;
pid              run/nginx.pid;
error_log        run/error.log warn;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    sendfile      on;
    server_tokens off;

    access_log run/access.log;

    client_body_temp_path run/tmp/client_body;
    proxy_temp_path       run/tmp/proxy;
    fastcgi_temp_path     run/tmp/fastcgi;
    uwsgi_temp_path       run/tmp/uwsgi;
    scgi_temp_path        run/tmp/scgi;

    # Балансировка
    upstream todo_backend {
        zone todo_backend 1m;
        server 127.0.0.1:5040 max_fails=1 fail_timeout=10s;
        server 127.0.0.1:5041 max_fails=1 fail_timeout=10s;
        keepalive 16;
    }

    # Rate limit
    limit_req_zone   $binary_remote_addr zone=api:10m rate=5r/s;
    limit_req_status 429;
    limit_req_log_level warn;

    include sites/*.conf;
}
```

Разбит на множество файлов, для лучшей читаемости


## Структура

```
lab1/
├── check.sh                проверка всех пунктов лабы
├── nginx/
│   ├── nginx.conf          http, upstream, limit_req_zone, include sites/*.conf
│   ├── mime.types
│   ├── snippets/           ssl.conf, proxy.conf, errors.conf
│   ├── sites/              по файлу на server-блок
├── www/
│   ├── docs/               отдается через alias
│   ├── admin/
│   ├── errors/             404.html, 50x.html
│   └── project2/           второй виртуальный хост
```

## Запуск

Все команды - из каталога `lab1/`.

**Один раз:** сертификат, пароль для `/admin`, сборка фронта, каталог для pid/логов.

```bash
mkdir -p nginx/certs && mkcert -cert-file nginx/certs/local.pem -key-file nginx/certs/local-key.pem todo.local project2.local localhost 127.0.0.1
```

```bash
htpasswd -cB nginx/.htpasswd admin
```

```bash
(cd ../lab0/frontend && npm install && npm run build)
```

```bash
mkdir -p run/tmp
```

**Каждый запуск:**

Терминал 1 — backend-1:

```bash
cd ../lab0/backend && PORT=5040 INSTANCE_ID=backend-1 go run ./internal
```

Терминал 2 — backend-2:

```bash
cd ../lab0/backend && PORT=5041 INSTANCE_ID=backend-2 go run ./internal
```

Терминал 3 — проверить конфиг и запустить nginx (без sudo):

```bash
nginx -p "$PWD/" -c nginx/nginx.conf -e run/error.log -t
```

```bash
nginx -p "$PWD/" -c nginx/nginx.conf -e run/error.log
```

Балансировка:

```bash
for i in $(seq 6); do curl -s https://todo.local/api/whoami; echo; done
```

Отказ: Ctrl+C в терминале 1, повторить цикл `curl`.

Перечитать конфиг после правки / остановить nginx:

```bash
nginx -p "$PWD/" -c nginx/nginx.conf -e run/error.log -s reload
```

```bash
nginx -p "$PWD/" -c nginx/nginx.conf -e run/error.log -s quit
```

При ручном запуске проверки гоняются без автоматического гашения бэкенда:

```bash
SKIP_FAILOVER=1 ./check.sh
```

Открыть: <https://todo.local>, <https://todo.local/docs/>, <https://todo.local/admin/>, <https://project2.local>.