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

Нужны: nginx, mkcert (`mkcert -install` один раз), htpasswd, Go, Node.js, PostgreSQL из лабы 0.

```bash
echo '127.0.0.1 todo.local project2.local' | sudo tee -a /etc/hosts
```

```bash
cd lab1
```

```bash
./lab.sh setup
```

```bash
./lab.sh up
```

`setup` выпускает сертификат на `todo.local`, `project2.local`, `localhost`, `127.0.0.1`,
создаёт `nginx/.htpasswd` (спросит пароль; можно задать `ADMIN_USER`/`ADMIN_PASSWORD`),
собирает фронт (`vite build`) и бэкенд (`run/todo-backend`).
`up` поднимает `backend-1` на :5040 и `backend-2` на :5041 и запускает nginx.

Открыть: <https://todo.local>, <https://todo.local/docs/>, <https://todo.local/admin/>, <https://project2.local>.