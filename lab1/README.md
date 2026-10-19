# Лаба 1 - nginx

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
<img width="406" height="463" alt="image" src="https://github.com/user-attachments/assets/9f95b3f3-a6a7-4cb3-a53f-e9504c5a56c4" />
<img width="387" height="452" alt="image" src="https://github.com/user-attachments/assets/cb80b44e-af11-4d89-9f10-57c75e329707" />



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



## Звездочка!

Проверим уязвимости 3 способами.

Искать уязвимости будем у "https://www.ftsspb.ru"

1) Directory listing. Проверяем, не показывает ли сервер список файлов и папок вместо обычной страницы
Одна из причин такой уязвимости - autoindex on. Она позволяет серверу показывать посетителю список файлов и папок в каталоге, для которого не настроена индексная страница.

Отправим открытый HTTP запрос через curl -I. -I для получения только заголовеов, без html.

![alt text](image-2.png)

Заметим что server - nging 1.31.3, новый, уязвимостей возможно будет меньше.
Так-же обратим внимание на x-powered-by: PHP/5.2.17-pl0-gentoo - очень старая версия, вполне себе следует сюда копать, но заголовок можно подменить.

Попробуем обратиться и получить тело ответа, при /files/ пути, и сравним на всякий с несуществующим
![alt text](image-3.png)
Мы точно может утверждать что происходит вакханалия, но заметив что тело ответа пустое, хотя http/200. Значит особенность php, или архитектуры. Признаков автоматического листинга каталогов в полученных ответах нет. Причина одинакового поведения требует дополнительной проверки.

![alt text](image-4.png)
Для /images/ сервер явно отказал в просмотре каталога.
При обращении к каталогу /images/ сервер вернул HTTP 403 Forbidden. В теле ответа содержится сообщение об отсутствии индексного документа или ограничении доступа к каталогу. Признаков успешного просмотра списка файлов не обнаружено. Для данного URL уязвимость Directory Listing не подтверждена.

![alt text](image-5.png)
![alt text](image-6.png)
Нашли интересный путь, etc/passwd. Хотя его и отверг сервер. Теперь мы знаем что поверх сайта - sweb.ru

![alt text](image-7.png)
В целом, на первый взгляд, все защищено.



Уязвимостей через directory listing - необнаружено.

2) Перебор путей через ffuf (content discovery)
ffuf подставляет значения из словаря в заданную позицию URL и отправляет HTTP-запросы.
Подготовим необходимые зависимости 

```brew install ffuf```
![alt text](image-8.png)
```git clone --depth 1 https://github.com/danielmiessler/SecLists /opt/SecLists``` - Словарь перебора

![alt text](image-10.png)
![alt text](image-11.png)
На удивление много каталогов и путей, robots, и другие, проверим их.
![alt text](image-12.png) 
Требует httpaswd, интересно.
.htaccess,htpasswd, 403 отдают.
![alt text](image-15.png)

![alt text](image-13.png)
/awstats открылся
![alt text](image-14.png)
Кажется получили доступ куда нельзя, не уверен что пользователю можно видеть полную статистику обо всем)

Остальные ручные переборы curl, ffuf не дали успеха в поиске уязвимости. Но отнюдь, старая версия php - ворота для "реального" хакера.

3) Host header injection
![alt text](image-16.png)

Сервер взял значение Host из запроса и подставил его в Location редиректа. Это CWE-644 (Improper Neutralization of HTTP Headers) + CWE-601 (Open Redirect). И это уже вторая подтвержденная ```уязвимость``` после AWStats.

Что это? А это:
- Атакующий шлёт жертве письмо «сброс пароля» с запросом, в котором Host: evil.example
- Приложение (PHP 5.2, Joomla) строит ссылку в письме из $_SERVER['HTTP_HOST']
- Жертва получает письмо с валидной ссылкой, но домен evil.example - токен сброса уходит атакующему

Почему? А потому-что nginx использует заголовок Host для формирования Location редиректа; для неизвестного Host срабатывает default_server, который выполняет return 302 http://$host/.
  - Произвольный Host ведет в произвольный редирект. А это открытый редирект.
  - Редирект ведёт на HTTP, хотя запрос шёл по HTTPS - дополнительный downgrade. HSTS отсутствует (проверка 4.1), поэтому браузер пойдёт по HTTP без предупреждения.

Потенциально это:
  - фишинг через редирект на чужой домен;
  - password reset poisoning, если приложение строит ссылки из Host (не проверялось — эксплуатация не производилась);
  - cache poisoning при наличии кэша (не проверялось).

Проверим hsts:
![alt text](image-19.png)
Его нет. Без него нету force https. Следствие - MITM!

Проверим CSP:
![alt text](image-20.png)
Его нет. Без него возможна кража cookie, редирект, keylogger'ы, ну и xss атаки!

СMS - Joomla старой ветки (1.5 / 2.5) + PHP 5.2.17 (EOL с 2011). У Joomla 1.5/2.5 - десятки публичных XSS-CVE (com_content, com_search, com_users, шаблоны). Без CSP любой из них дает рабочий эксплойт.
Плюс: /awstats/ без auth. Если в AWStats есть reflected XSS через config= (а в старых версиях есть) - без CSP это сразу RCE-цепочка «XSS -> кража админской сессии».
Отсутствие CSP на этом сайте - не «формальность», а реальный усилитель риска, потому что остальное ПО — устаревшее

Проверим x-frame-options:
![alt text](image-21.png)



Clickjacking:
![alt text](image-22.png)
![alt text](image-23.png)

Ну и еще) 
![alt text](image-17.png)
![alt text](image-18.png)
![alt text](image-24.png)
```<address>Apache/2.2.29 (Gentoo) mod_dp/0.99.10 Phusion_Passenger/4.0.60 PHP/5.2.17-pl0-gentoo mod_wsgi/4.4.21 Python/2.7.18 Server at ftsspb.ru Port 80</address>``` - Это ServerSignature On + ServerTokens Full в Apache - настройка, которая запрещена к продакшену. Каждый раз, когда Apache генерирует страницу ошибки (301, 403, 404, 500), он дописывает полный баннер со всеми модулями и версиями. CWE-200 (Exposure of Sensitive Information).

Вообщем, честно, получили достаточно мест куда можно атаковать, полностью знаем бекенд : ```nginx 1.31.3 (frontend) -> Apache 2.2.29 + mod_wsgi + Phusion Passenger (backend)```.


## Вывод:

В ходе работы проверено шесть классов уязвимостей на сайте www.ftsspb.ru.

Что проверяли и что нашли:
Directory listing - не подтверждён, autoindex отключён.
Path traversal - не подтверждён, nginx нормализует путь, возвращает 400/403/404.
Перебор путей через ffuf - найдена уязвимость: /awstats/ открыт без авторизации, доступна полная статистика сайта (referrers, crawler'ы, пути, параметры запросов). Класс CWE-306 / CWE-200.
Security headers - найдена уязвимость: отсутствуют Strict-Transport-Security, Content-Security-Policy, X-Frame-Options, X-Content-Type-Options, Referrer-Policy. HTTP->HTTPS редирект есть, но без HSTS первый запрос уязвим к SSL-strip. Класс CWE-319, CWE-693, CWE-1021, CWE-200.
HTTP-методы - проверены корректно: TRACE и PUT возвращают 405, опасные методы запрещены. Это единственный пункт, где конфигурация верная.
Host Header Injection - найдена уязвимость: запрос с Host: evil.example возвращает 302 Location: http://evil.example/. Сервер не валидирует Host и перенаправляет на произвольный домен, причём на HTTP. Класс CWE-644 / CWE-601.
Error-страницы - найдена уязвимость: Apache отдаёт полный баннер со стеком: Apache/2.2.29 (Gentoo), PHP/5.2.17, Python/2.7.18, Phusion_Passenger/4.0.60, mod_wsgi/4.4.21. Apache EOL с 2017, PHP с 2011, Python с 2020. Класс CWE-200, CWE-1104, CWE-497. Дополнительно раскрыта архитектура: nginx как frontend, Apache + PHP + Python + Passenger как backend.

## Итог
Взлом успешен. Попадание в неположенное место подтверждено минимум дважды: в /awstats/ без авторизации и редирект на произвольный домен через подмену Host. Дополнительно подтверждены отсутствие security-заголовков и раскрытие устаревшего стека с точными версиями.

Эксплуатация не производилась: данные из AWStats не выгружались, формы сброса пароля не проверялись, публичные эксплойты под найденные версии не применялись. Содержимое чувствительных файлов не читалось. Все проверки — одиночные пассивные запросы, без брутфорса и нагрузки.

Найденные уязвимости требуют уведомления владельца сайта через преподавателя.