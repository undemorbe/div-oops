# Лаба 1 — nginx

nginx - Точка входа сайта

## Что сделали
1) Скачали инструментарий, mkcert, nginx, 
2) Сделали https, самоподисали через mkcert, чтобы сайт считался https, и можно было редиректить из 80 на 443.
3) Сверстали 2 проект, ошибки, alias сайт, admin сайт.
   - Alias - часть сайта которая будет открываться только по прямому .../NAME/, попасть из поиска в Гугл например, нельзя.
   - Admin часть сделали htpasswd, в такую часть можно попасть аналогично как и по alias, но при входе будет требовать пароль
   - Кастомные ошибки, сам сайт - отдает nginx, о нем в следующем пункте
4) Добавили виртуальные хосты: echo '127.0.0.1 todo.local project2.local' | sudo tee -a /etc/hosts
5) Nginx! - тяжелый и беспощадный
Статику собранного фронта (vite build) nginx отдаёт сам, без Node.js, а так-же теперь проксируется на бекенд. 
Nginx подставляет подписанные сертификаты и при попытке зайти на сайт, сразу редиректит на https.
Подключили upstream (балансировка, если упал 1 бекенд, то запросы отправляются на второй, а так-же nginx распределяет запросы по очереди (round-robin)). Теперь если упал 1 сервер, то запросы летят только на 2, при этом, первый выходит из ротации на 10 секунд.
Подключили limit-req, 5 запросов с 1 ip, пропускает сразу до 10 лишних запросов сверху, все что больше - уходит в 429.

Важный нюанс, для отказоустойчивости используется zone (общая память для upstream, счетчики для worker-процессов),без него каждый воркер пытался бы еще работать с мертвым сервером.

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
│   ├── docs/               отдаётся через alias
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